package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

const agentToken = "agent-token-0123456789abcdef0123456789abcdef"

// call is one psm invocation seen by the fake runner.
type call struct {
	args  []string
	stdin string
}

type fakeRunner struct {
	mu     sync.Mutex
	calls  []call
	stdout map[string]string // by the psm subcommand ("add", "export", …; "" for `psm version`)
	fail   map[string]string // subcommand → stderr of a failure
}

func (f *fakeRunner) run(_ context.Context, stdin []byte, args ...string) ([]byte, []byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	// reading the node list (the upsert's look before a create or change)
	// changes nothing on the server, so the tests' call lists leave it out
	if !(len(args) > 1 && args[0] == "node" && args[1] == "list") {
		f.calls = append(f.calls, call{args, string(stdin)})
	}
	sub := ""
	if len(args) > 1 {
		sub = args[1]
	}
	if msg, ok := f.fail[sub]; ok {
		return nil, []byte(msg), errors.New("exit status 1")
	}
	// a server with no nodes, unless the test says what it has
	if _, set := f.stdout[sub]; !set && len(args) > 1 && args[0] == "node" && args[1] == "list" {
		return []byte(`{"count":0,"items":[]}`), nil, nil
	}
	return []byte(f.stdout[sub]), nil, nil
}

// fakePanel serves /api/agent/sync: the queued tasks once, and records every
// request's body.
type fakePanel struct {
	mu       sync.Mutex
	tasks    []task
	requests []map[string]json.RawMessage
	failNext int      // answer this many syncs with 500
	ack      []string // event ids the next answer confirms
}

func (p *fakePanel) handler(t *testing.T) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.mu.Lock()
		defer p.mu.Unlock()
		switch r.URL.Path {
		case "/api/agent/join":
			var body map[string]string
			_ = json.NewDecoder(r.Body).Decode(&body)
			if body["join_token"] != "join-ok" {
				w.WriteHeader(http.StatusForbidden)
				_, _ = io.WriteString(w, `{"error":{"message":"invalid or expired join token"}}`)
				return
			}
			_, _ = io.WriteString(w, `{"agent_token":"`+agentToken+`","server":{"id":1,"name":"hk1"}}`)
		case "/api/agent/sync":
			if r.Header.Get("Authorization") != "Bearer "+agentToken {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			if p.failNext > 0 {
				p.failNext--
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			var body map[string]json.RawMessage
			_ = json.NewDecoder(r.Body).Decode(&body)
			p.requests = append(p.requests, body)
			resp, _ := json.Marshal(map[string]any{"interval": 10, "tasks": p.tasks, "events_acked": p.ack})
			p.tasks, p.ack = nil, nil
			_, _ = w.Write(resp)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
}

// newTestAgent: the traffic report, the relay measurement and the version
// lookup are not due, so the psm calls a test sees are those of its tasks.
func newTestAgent(t *testing.T, p *fakePanel, f *fakeRunner) (*agent, func()) {
	srv := httptest.NewServer(p.handler(t))
	return &agent{cfg: &config{Panel: srv.URL, Token: agentToken, AllowHTTP: true}, run: f.run, hostname: "hk1",
		lastTraffic: time.Now(), versionAt: time.Now(),
		psmVersion: "2026-09-15 abc1234"}, srv.Close
}

// delivered: the results of every sync from request <from> on, after syncing
// until none is pending (they go a few per sync).
func delivered(t *testing.T, a *agent, p *fakePanel, from int) []result {
	t.Helper()
	for n := 0; len(a.pending) > 0 && n < 50; n++ {
		if _, err := a.step(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	var rs []result
	for _, req := range p.requests[from:] {
		rs = append(rs, results(t, req["results"])...)
	}
	return rs
}

func results(t *testing.T, raw json.RawMessage) []result {
	t.Helper()
	var rs []result
	if err := json.Unmarshal(raw, &rs); err != nil {
		t.Fatalf("results: %v (%s)", err, raw)
	}
	return rs
}

func TestJoinWritesConfig(t *testing.T) {
	p := &fakePanel{}
	srv := httptest.NewServer(p.handler(t))
	defer srv.Close()
	path := filepath.Join(t.TempDir(), "etc", "agent.json")

	if err := join(context.Background(), path, srv.URL, "join-wrong", true); err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("a wrong join token: err=%v, want a 403", err)
	}
	if _, err := os.Stat(path); err == nil {
		t.Fatal("a failed join wrote a config")
	}
	if err := join(context.Background(), path, srv.URL, "join-ok", true); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("config: %v, mode %v, want 0600", err, st.Mode().Perm())
	}
	cfg, err := loadConfig(path)
	if err != nil || cfg.Token != agentToken || cfg.Panel != srv.URL {
		t.Fatalf("config read back: %+v %v", cfg, err)
	}
}

func TestPanelMustBeHTTPS(t *testing.T) {
	for raw, ok := range map[string]bool{
		"https://psm.example.com": true, "https://psm.example.com/": true,
		"http://psm.example.com": false, "psm.example.com": false, "https://psm.example.com/?a=1": false, "ftp://x": false,
	} {
		if _, err := checkPanelURL(raw, false); (err == nil) != ok {
			t.Errorf("%s: err=%v, want ok=%v", raw, err, ok)
		}
	}
}

func TestTheRealityTargetSearchIsGone(t *testing.T) {
	// roomkey's REALITY uses each node's own site: neither search runs here
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "sni.find", Data: json.RawMessage(`{"engine":"netlas","key":"k-123"}`)},
		{ID: 2, Kind: "sni.check", Data: json.RawMessage(`{"pairs":[{"sni":"www.example.com","dest":"203.0.113.9:443"}]}`)},
	}}
	f := &fakeRunner{}
	a, done := newTestAgent(t, p, f)
	defer done()
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 0 {
		t.Fatalf("psm ran: %q", f.calls)
	}
	rs := delivered(t, a, p, len(p.requests))
	if len(rs) != 2 {
		t.Fatalf("%d results, want 2 refusals", len(rs))
	}
	for _, r := range rs {
		if r.OK {
			t.Fatalf("task %d was accepted", r.TaskID)
		}
	}
}

func TestCheckRunsPSMCheck(t *testing.T) {
	report := `{"version":"0.1.0","ipv4":{"ip":"203.0.113.5","services":[]},"ipv6":null}`
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "check.run"},
		{ID: 2, Kind: "check.run", Data: json.RawMessage(`{"family":"6"}`)},
		{ID: 3, Kind: "check.run", Data: json.RawMessage(`{"family":"--lang"}`)},
		{ID: 4, Kind: "check.run", Data: json.RawMessage(`[1]`)},
		{ID: 5, Kind: "check.run", Data: json.RawMessage(`{"keys":{"ipqs":"k-ipqs-0123456789","abuseipdb":"k-abuse-0123456789","other":"x"}}`)},
		{ID: 6, Kind: "check.run", Data: json.RawMessage(`{"keys":{"ipqs":"bad key\nIPQS=x"}}`)},
	}}
	f := &fakeRunner{stdout: map[string]string{"all": report}}
	a, done := newTestAgent(t, p, f)
	defer done()

	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := []call{{[]string{"check", "all", "--json"}, ""}, {[]string{"check", "all", "--json", "-6"}, ""},
		{[]string{"check", "all", "--json", "--keys-stdin"}, "ABUSEIPDB=k-abuse-0123456789\nIPQS=k-ipqs-0123456789\n"}}
	if !reflect.DeepEqual(f.calls, want) {
		t.Fatalf("psm calls\n got %q\nwant %q (a family that is not 4 or 6, data that is not an object, or a key with more in it never reach psm; keys go on stdin only)", f.calls, want)
	}
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	rs := delivered(t, a, p, len(p.requests)-1)
	if len(rs) != 6 || !rs[0].OK || string(rs[0].Output) != report || rs[2].OK || rs[3].OK || !rs[4].OK || rs[5].OK {
		t.Fatalf("results: %+v", rs)
	}
}

func TestSyncRunsTasksAndReportsResults(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "node.add", Core: "xray", Protocol: "trojan", Data: json.RawMessage(`{"tag":"hk","port":443}`), Server: "203.0.113.10", Format: "uri"},
		{ID: 2, Kind: "node.delete", Core: "sing-box", Protocol: "tuic", Tag: "old"},
	}}
	f := &fakeRunner{stdout: map[string]string{"install": `{"core":"xray","installed":true}`, "add": `{"status":"created"}`,
		"export": "vless://x@203.0.113.10:443#PSM-hk\n", "delete": `{"status":"deleted"}`}}
	a, done := newTestAgent(t, p, f)
	defer done()

	if wait, err := a.step(context.Background()); err != nil || wait != 0 {
		t.Fatalf("first sync: wait=%v err=%v (with results pending it reports at once)", wait, err)
	}
	want := []call{
		{[]string{"core", "install", "xray", "--if-missing", "--json"}, ""},
		{[]string{"node", "add", "xray", "trojan", "--input", "-", "--json"}, `{"tag":"hk","port":443}`},
		{[]string{"node", "export", "xray", "trojan", "hk", "--format", "uri", "--server", "203.0.113.10"}, ""},
		{[]string{"node", "export", "xray", "trojan", "hk", "--format", "singbox", "--server", "203.0.113.10"}, ""},
		{[]string{"node", "export", "xray", "trojan", "hk", "--format", "clash", "--server", "203.0.113.10"}, ""},
		{[]string{"node", "delete", "sing-box", "tuic", "old", "--yes", "--if-exists", "--json"}, ""},
	}
	if !reflect.DeepEqual(f.calls, want) {
		t.Fatalf("psm calls\n got %q\nwant %q", f.calls, want)
	}
	if wait, err := a.step(context.Background()); err != nil || wait.Seconds() != 10 {
		t.Fatalf("second sync: wait=%v err=%v", wait, err)
	}
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 2 || !rs[0].OK || rs[0].Link != "vless://x@203.0.113.10:443#PSM-hk" || rs[0].Outbound != nil || !rs[1].OK {
		t.Fatalf("results delivered: %+v", rs)
	}
	if len(results(t, p.requests[0]["results"])) != 0 {
		t.Error("the first sync carried results before any task ran")
	}
	if string(p.requests[0]["psm_version"]) != `"2026-09-15 abc1234"` {
		t.Errorf("psm_version sent: %s", p.requests[0]["psm_version"])
	}
}

func TestACoreThatWillNotInstallFailsTheNode(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 4, Kind: "node.add", Core: "mihomo", Protocol: "anytls", Data: json.RawMessage(`{"tag":"m","port":8443}`)}}}
	f := &fakeRunner{fail: map[string]string{"install": "psm core: installing mihomo failed\n"}}
	a, done := newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	if len(f.calls) != 1 {
		t.Fatalf("psm node add ran although the core did not install: %q", f.calls)
	}
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 1 || rs[0].OK || rs[0].Error != "installing mihomo: psm core: installing mihomo failed" {
		t.Fatalf("result %+v", rs)
	}
}

func TestStandaloneAndTrafficTasks(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "standalone.install", Protocol: "snell", Tag: "hk-snell", Data: json.RawMessage(`{"port":31000,"version":"6","psk":"abcdefgh12"}`), Server: "203.0.113.10", Format: "surge"},
		{ID: 2, Kind: "standalone.install", Protocol: "ss2022", Tag: "hk-ss", Data: json.RawMessage(`{"port":31001,"method":"2022-blake3-aes-256-gcm"}`), Server: "203.0.113.10", Format: "uri"},
		{ID: 3, Kind: "traffic.set", Tag: "hk-ss", LimitBytes: 1 << 30, ResetDay: 5},
		{ID: 4, Kind: "traffic.set", Tag: "hk-snell"},
		{ID: 5, Kind: "traffic.reset", Tag: "hk-ss"},
		{ID: 6, Kind: "standalone.remove", Protocol: "snell"},
	}}
	f := &fakeRunner{stdout: map[string]string{"install": `{"active":true}`, "export": `{"type":"shadowsocks"}`,
		"set": `{"tag":"x"}`, "reset": `{"tag":"x"}`, "remove": `{"status":"removed"}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := [][]string{
		{"standalone", "install", "snell", "--port", "31000", "--json", "--version", "6", "--psk", "abcdefgh12"},
		{"standalone", "export", "snell", "--name", "PSM-hk-snell", "--format", "surge", "--server", "203.0.113.10"},
		{"standalone", "export", "snell", "--name", "PSM-hk-snell", "--format", "singbox", "--server", "203.0.113.10"},
		{"standalone", "install", "ss2022", "--port", "31001", "--json", "--method", "2022-blake3-aes-256-gcm"},
		{"standalone", "export", "ss2022", "--name", "PSM-hk-ss", "--format", "uri", "--server", "203.0.113.10"},
		{"standalone", "export", "ss2022", "--name", "PSM-hk-ss", "--format", "singbox", "--server", "203.0.113.10"},
		{"traffic", "set", "hk-ss", "--limit-bytes", "1073741824", "--json", "--reset-day", "5"},
		{"traffic", "set", "hk-snell", "--limit-bytes", "0", "--json"},
		{"traffic", "reset", "hk-ss", "--json"},
		{"standalone", "remove", "snell", "--yes", "--json"},
	}
	var got [][]string
	for _, c := range f.calls {
		got = append(got, c.args)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("psm calls\n got %q\nwant %q", got, want)
	}
	if !a.lastTraffic.IsZero() {
		t.Error("a traffic task did not make the counters due")
	}
	f.stdout["list"] = `[{"tag":"hk-ss","used_bytes":5}]`
	_, _ = a.step(context.Background())
	req := p.requests[len(p.requests)-1]
	if string(req["traffic"]) != `[{"tag":"hk-ss","used_bytes":5}]` {
		t.Fatalf("traffic sent: %s", req["traffic"])
	}
	rs := delivered(t, a, p, len(p.requests)-1)
	if len(rs) != 6 || string(rs[1].Outbound) != `{"type":"shadowsocks"}` || rs[0].Link == "" {
		t.Fatalf("results: %+v", rs)
	}
	for _, r := range rs {
		if !r.OK {
			t.Errorf("task %d failed: %s", r.TaskID, r.Error)
		}
	}
}

func TestTrafficIsReportedWhenDue(t *testing.T) {
	p := &fakePanel{}
	f := &fakeRunner{stdout: map[string]string{"list": `[{"tag":"a","used_bytes":1}]`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	a.lastTraffic = time.Now().Add(-trafficEvery)
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	if string(p.requests[0]["traffic"]) != `[{"tag":"a","used_bytes":1}]` {
		t.Fatalf("first sync traffic: %s", p.requests[0]["traffic"])
	}
	if _, sent := p.requests[1]["traffic"]; sent {
		t.Fatal("traffic sent again before ten minutes")
	}
	// the panel can ask for the counters at once
	p.tasks = []task{{ID: 9, Kind: "traffic.report"}}
	_, _ = a.step(context.Background()) // takes the task
	_, _ = a.step(context.Background()) // reports its result, with the counters
	if string(p.requests[3]["traffic"]) != `[{"tag":"a","used_bytes":1}]` {
		t.Fatalf("traffic after traffic.report: %s", p.requests[3]["traffic"])
	}
}

func TestLeaveRemovesTheNodesThenTheAgent(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 5, Kind: "agent.leave", Data: json.RawMessage(
		`{"nodes":[{"core":"xray","protocol":"reality","tag":"a"},{"core":"sing-box","protocol":"ss2022","tag":"b"}],"standalone":["snell"],"relays":["r1"]}`)}}}
	f := &fakeRunner{stdout: map[string]string{"delete": `{"status":"deleted"}`, "remove": `{"status":"removed"}`, "purge": `{"status":"purged","ok":true}`,
		"usage": `{"revision":3,"users":[]}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	var spawned [][]string
	a.spawn = func(args ...string) error { spawned = append(spawned, args); return nil }

	if _, err := a.step(context.Background()); err != nil { // runs the task
		t.Fatal(err)
	}
	want := [][]string{
		// their last reading for the panel, then the panel's users: once the
		// server has left nothing could revoke them
		{"user", "usage", "--json"},
		{"user", "purge", "--json"},
		{"node", "delete", "xray", "reality", "a", "--yes", "--if-exists", "--json"},
		{"node", "delete", "sing-box", "ss2022", "b", "--yes", "--if-exists", "--json"},
		{"standalone", "remove", "snell", "--yes", "--json"},
		// the relays go too, or realm keeps forwarding on a machine the panel
		// has forgotten, with its accounting rules still in place
		{"relay", "delete", "r1", "--yes", "--if-exists", "--json"},
	}
	var got [][]string
	for _, c := range f.calls {
		got = append(got, c.args)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("psm calls\n got %q\nwant %q", got, want)
	}
	if len(spawned) != 0 || a.left {
		t.Fatal("psm-agent started removing itself before the panel had the result")
	}
	if _, err := a.step(context.Background()); err != nil { // delivers it
		t.Fatal(err)
	}
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 1 || !rs[0].OK || string(rs[0].Output) != `{"failed":[],"removed":["panel users","a","b","snell","r1"],"usage":{"revision":3,"users":[]}}` {
		t.Fatalf("leave result: %+v", rs)
	}
	if !a.left || !reflect.DeepEqual(spawned, [][]string{{"agent", "remove", "--yes"}}) {
		t.Fatalf("after delivering: left=%v spawned=%q", a.left, spawned)
	}
}

// The panel took the leave result and deleted the server, but its answer was
// lost: the retry is refused (the token is gone), and that is the confirmation.
func TestALostLeaveAnswerStillUninstalls(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 5, Kind: "agent.leave", Data: json.RawMessage(`{"nodes":[],"standalone":[],"relays":[]}`)}}}
	f := &fakeRunner{stdout: map[string]string{"purge": `{"status":"purged","ok":true}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	var spawned [][]string
	a.spawn = func(args ...string) error { spawned = append(spawned, args); return nil }
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	a.cfg.Token = "revoked"
	if _, err := a.step(context.Background()); err != nil {
		t.Fatalf("refused retry of a delivered leave: %v", err)
	}
	if !a.left || len(spawned) != 1 {
		t.Fatalf("left=%v spawned=%q", a.left, spawned)
	}
}

// Without a leave under way, a refused token is an error as before.
func TestARefusedTokenIsAnErrorOtherwise(t *testing.T) {
	p := &fakePanel{}
	a, done := newTestAgent(t, p, &fakeRunner{})
	defer done()
	a.cfg.Token = "revoked"
	if _, err := a.step(context.Background()); err == nil || a.left {
		t.Fatalf("err=%v left=%v", err, a.left)
	}
}

// The panel asks for a newer psm-agent. The upgrade replaces this binary and
// restarts the service, so it must not begin before the panel has the result:
// the restart would kill the very process that reports it, leaving the task
// stuck in 下发中 forever.
func TestTheAgentUpgradesItselfOnlyAfterReporting(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 7, Kind: "agent.update"}}}
	f := &fakeRunner{}
	a, done := newTestAgent(t, p, f)
	defer done()
	var spawned [][]string
	a.spawn = func(args ...string) error { spawned = append(spawned, args); return nil }

	if _, err := a.step(context.Background()); err != nil { // runs the task
		t.Fatal(err)
	}
	if len(f.calls) != 0 {
		t.Fatalf("the upgrade ran a psm command before reporting: %q", f.calls)
	}
	if len(spawned) != 0 || a.upgraded {
		t.Fatal("psm-agent started upgrading itself before the panel had the result")
	}
	if _, err := a.step(context.Background()); err != nil { // delivers it
		t.Fatal(err)
	}
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 1 || !rs[0].OK || string(rs[0].Output) != `{"from":"`+agentVersion+`"}` {
		t.Fatalf("update result: %+v", rs)
	}
	if !a.upgraded || a.upgrading || !reflect.DeepEqual(spawned, [][]string{{"agent", "upgrade", "--yes"}}) {
		t.Fatalf("after delivering: upgraded=%v upgrading=%v spawned=%q", a.upgraded, a.upgrading, spawned)
	}
	// started once: a later sync must not run the upgrade all over again
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(spawned) != 1 {
		t.Fatalf("the upgrade was started again: %q", spawned)
	}
}

func TestABadLeavePlanRemovesNothing(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "agent.leave", Data: json.RawMessage(`{"nodes":[{"core":"xray","protocol":"reality","tag":"ok"},{"core":"xray","protocol":"reality","tag":"--all"}]}`)},
		{ID: 2, Kind: "agent.leave", Data: json.RawMessage(`{"standalone":["hysteria2"]}`)},
		{ID: 3, Kind: "agent.leave", Data: json.RawMessage(`[1]`)},
	}}
	f := &fakeRunner{}
	a, done := newTestAgent(t, p, f)
	defer done()
	a.spawn = func(args ...string) error { t.Fatalf("spawned %q for a rejected plan", args); return nil }
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	if len(f.calls) != 0 || a.leaving || a.left {
		t.Fatalf("calls=%q leaving=%v left=%v", f.calls, a.leaving, a.left)
	}
	for _, r := range results(t, p.requests[1]["results"]) {
		if r.OK || !strings.HasPrefix(r.Error, "rejected by psm-agent") {
			t.Errorf("task %d: %+v", r.TaskID, r)
		}
	}
}

func TestBadTasksNeverReachPSM(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "node.add", Core: "v2ray", Protocol: "reality", Data: json.RawMessage(`{"tag":"a","port":1}`)},
		{ID: 2, Kind: "node.add", Core: "xray", Protocol: "naive", Data: json.RawMessage(`{"tag":"a","port":1}`)},
		{ID: 3, Kind: "node.add", Core: "xray", Protocol: "reality", Data: json.RawMessage(`{"tag":"--show-secrets","port":1}`)},
		{ID: 4, Kind: "node.add", Core: "xray", Protocol: "reality", Data: json.RawMessage(`{"tag":"a","port":70000}`)},
		{ID: 5, Kind: "node.add", Core: "xray", Protocol: "reality", Data: json.RawMessage(`[1,2]`)},
		{ID: 6, Kind: "node.delete", Core: "xray", Protocol: "reality", Tag: "--yes"},
		{ID: 7, Kind: "node.update", Core: "xray", Protocol: "reality", Tag: "a", Data: json.RawMessage(`"x"`)},
		{ID: 8, Kind: "node.export", Core: "xray", Protocol: "reality", Tag: "a", Server: "$(id)"},
		{ID: 9, Kind: "shell", Core: "xray", Protocol: "reality"},
		{ID: 10, Kind: "standalone.install", Protocol: "hysteria2", Tag: "a", Data: json.RawMessage(`{"port":1}`)},
		{ID: 11, Kind: "standalone.install", Protocol: "snell", Tag: "a", Data: json.RawMessage(`{"port":1,"psk":"--help me"}`)},
		{ID: 12, Kind: "standalone.install", Protocol: "snell", Tag: "a", Data: json.RawMessage(`{"port":1,"version":"3"}`)},
		{ID: 13, Kind: "standalone.install", Protocol: "ss2022", Tag: "a", Data: json.RawMessage(`{"port":1,"method":"aes-256-gcm"}`)},
		{ID: 14, Kind: "standalone.install", Protocol: "ss2022", Tag: "a", Data: json.RawMessage(`{"port":1,"password":"not base64!"}`)},
		{ID: 15, Kind: "standalone.install", Protocol: "ss2022", Tag: "-a", Data: json.RawMessage(`{"port":1}`)},
		{ID: 16, Kind: "standalone.remove", Protocol: "xray"},
		{ID: 17, Kind: "traffic.set", Tag: "--all", LimitBytes: 1},
		{ID: 18, Kind: "traffic.set", Tag: "a", LimitBytes: -1},
		{ID: 19, Kind: "traffic.set", Tag: "a", ResetDay: 31},
		{ID: 20, Kind: "traffic.reset", Tag: "a b"},
	}}
	// relays: the hop itself, then every field psm relay reads, and none it does not
	rl := func(extra string) json.RawMessage {
		return json.RawMessage(`{"tag":"r","listen_port":1000,"remote_host":"198.51.100.2","remote_port":443` + extra + `}`)
	}
	for i, d := range []json.RawMessage{
		json.RawMessage(`{"tag":"r","listen_port":1000,"remote_host":"$(id)","remote_port":443}`),
		rl(`,"tls_cert":"/etc/shadow"`), // a file on the server: never from the panel
		rl(`,"exit_ca":"/etc/shadow"`),  // psm's own to choose
		rl(`,"engine":"nginx"`),
		rl(`,"mode":"proxy"`),
		rl(`,"transport":"kcp"`),
		rl(`,"strategy":"best"`),
		rl(`,"targets":[]`),
		rl(`,"targets":[{"host":"--help","port":1}]`),
		rl(`,"targets":[{"host":"a-.example.com","port":1}]`),
		rl(`,"ws_host":"-x.example.com"`),
		rl(`,"targets":[{"host":"a","port":1,"path":"/x"}]`),
		rl(`,"targets":[` + strings.Repeat(`{"host":"a","port":1},`, 16) + `{"host":"a","port":1}]`),
		rl(`,"secret":"short"`),
		rl(`,"ws_path":"../../etc"`),
		rl(`,"exit_pin":"xyz"`),
		rl(`,"exit_cert_pem":"not a certificate"`),
		rl(`,"expires_at":"tomorrow"`),
		rl(`,"limit_bytes":-1`),
		rl(`,"reset_day":31`),
		rl(`,"speed_mbps":"fast"`),
		rl(`,"port_range":"9000-100"`),
		rl(`,"udp":"yes"`),
		rl(`,"tls_sni":"a b"`),
	} {
		p.tasks = append(p.tasks, task{ID: int64(21 + i), Kind: "relay.add", Tag: "r", Data: d})
	}
	nbad := len(p.tasks)
	f := &fakeRunner{}
	a, done := newTestAgent(t, p, f)
	defer done()
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 0 {
		t.Fatalf("psm ran for a bad task: %q", f.calls)
	}
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	rs := delivered(t, a, p, 1)
	if len(rs) != nbad {
		t.Fatalf("%d results, want %d", len(rs), nbad)
	}
	for _, r := range rs {
		if r.OK || !strings.HasPrefix(r.Error, "rejected by psm-agent") {
			t.Errorf("task %d: %+v, want a rejection", r.TaskID, r)
		}
	}
}

// roomkey runs no relays: adding or changing one is refused before psm runs;
// removing one (a rule left from before) still works.
func TestRelaysCanOnlyBeRemoved(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "relay.add", Tag: "hk", Data: json.RawMessage(`{"tag":"hk","listen_port":443,"remote_host":"203.0.113.9","remote_port":8443}`)},
		{ID: 2, Kind: "relay.update", Tag: "jp", Data: json.RawMessage(`{"tag":"jp","listen_port":8443,"remote_host":"127.0.0.1","remote_port":443}`)},
		{ID: 3, Kind: "relay.delete", Tag: "old"},
	}}
	f := &fakeRunner{stdout: map[string]string{"delete": `{"status":"deleted"}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	var ran []string
	for _, c := range f.calls {
		if len(c.args) > 1 && c.args[0] == "relay" && c.args[1] != "probe" {
			ran = append(ran, strings.Join(c.args, " "))
		}
	}
	if len(ran) != 1 || ran[0] != "relay delete old --yes --if-exists --json" {
		t.Fatalf("psm relay calls: %q", ran)
	}
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 3 || rs[0].OK || rs[1].OK || !rs[2].OK || !strings.Contains(rs[0].Error, "relays are off") {
		t.Fatalf("results: %+v", rs)
	}
}

// The panel's first install of a standalone server never replaces one that is
// already there (made by hand); a change of its own (no create) goes ahead.
func TestStandaloneFirstInstallLeavesAnExistingOneAlone(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "standalone.install", Protocol: "snell", Tag: "hk-snell", Create: true, Data: json.RawMessage(`{"port":31000,"version":"6","psk":"abcdefgh12"}`)},
		{ID: 2, Kind: "standalone.install", Protocol: "snell", Tag: "hk-snell", Data: json.RawMessage(`{"port":31000,"version":"6","psk":"abcdefgh12"}`)},
	}}
	f := &fakeRunner{stdout: map[string]string{"show": `{"installed":true}`, "install": `{"status":"installed"}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	installs := 0
	for _, c := range f.calls {
		if len(c.args) > 1 && c.args[0] == "standalone" && c.args[1] == "install" {
			installs++
		}
	}
	rs := results(t, p.requests[1]["results"])
	if installs != 1 || len(rs) != 2 || rs[0].OK || string(rs[0].Output) != `{"conflict":true}` || !rs[1].OK {
		t.Fatalf("installs=%d results=%+v", installs, rs)
	}
}

func TestPSMFailureIsReported(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 7, Kind: "node.add", Core: "xray", Protocol: "tuic", Data: json.RawMessage(`{"tag":"t","port":9443}`)}}}
	f := &fakeRunner{fail: map[string]string{"add": "loading…\npsm node: unsupported core/protocol: xray/tuic\n"}}
	a, done := newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 1 || rs[0].OK || rs[0].Error != "psm node: unsupported core/protocol: xray/tuic" {
		t.Fatalf("result %+v", rs)
	}
}

func TestStatusGathersTheServer(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 3, Kind: "status"}}}
	f := &fakeRunner{stdout: map[string]string{"list": `{"count":0,"items":[]}`, "show": `{"installed":false}`},
		fail: map[string]string{"--json": "doctor found problems\n"}}
	a, done := newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	rs := results(t, p.requests[1]["results"])
	var st map[string]json.RawMessage
	if len(rs) != 1 || !rs[0].OK || json.Unmarshal(rs[0].Output, &st) != nil {
		t.Fatalf("status result %+v", rs)
	}
	if string(st["nodes"]) != `{"count":0,"items":[]}` || string(st["snell"]) != `{"installed":false}` || string(st["agent_version"]) != `"`+agentVersion+`"` {
		t.Fatalf("status: %s", rs[0].Output)
	}
}

func TestResultsSurviveAFailedSync(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 3, Kind: "status"}}}
	f := &fakeRunner{stdout: map[string]string{"list": `{"count":0,"items":[]}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	if _, err := a.step(context.Background()); err != nil { // runs the task
		t.Fatal(err)
	}
	p.failNext = 1
	if _, err := a.step(context.Background()); err == nil {
		t.Fatal("a 500 from the panel was not an error")
	}
	if len(a.pending) != 1 {
		t.Fatalf("%d pending results after a failed sync, want 1", len(a.pending))
	}
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rs := results(t, p.requests[len(p.requests)-1]["results"]); len(rs) != 1 || rs[0].TaskID != 3 || !rs[0].OK {
		t.Fatalf("delivered after the retry: %+v", rs)
	}
}

func TestResultsGoAFewPerSync(t *testing.T) {
	var ts []task
	for i := 1; i <= 12; i++ {
		ts = append(ts, task{ID: int64(i), Kind: "status"})
	}
	p := &fakePanel{tasks: ts}
	f := &fakeRunner{stdout: map[string]string{"list": `{"count":0,"items":[]}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	wait, err := a.step(context.Background()) // runs the twelve tasks
	if err != nil {
		t.Fatal(err)
	}
	if wait != 0 {
		t.Fatalf("results waiting, but the next sync is in %v", wait)
	}
	var got []int64
	for n := 0; n < 3; n++ {
		if _, err := a.step(context.Background()); err != nil {
			t.Fatal(err)
		}
		rs := results(t, p.requests[len(p.requests)-1]["results"])
		if len(rs) > resultsPerSync {
			t.Fatalf("sync %d carried %d results, want at most %d", n, len(rs), resultsPerSync)
		}
		for _, r := range rs {
			got = append(got, r.TaskID)
		}
	}
	if len(got) != 12 || len(a.pending) != 0 {
		t.Fatalf("delivered %v, %d still pending", got, len(a.pending))
	}
	for i, id := range got {
		if id != int64(i+1) {
			t.Fatalf("delivered out of order: %v", got)
		}
	}
}

func TestWrongTokenIsAnHTTPError(t *testing.T) {
	p := &fakePanel{}
	a, done := newTestAgent(t, p, &fakeRunner{})
	defer done()
	a.cfg.Token = "wrong-token-0123456789abcdef0123456789abcdef"
	_, err := a.step(context.Background())
	var he *httpError
	if !errors.As(err, &he) || he.status != http.StatusUnauthorized {
		t.Fatalf("err=%v, want a 401 httpError", err)
	}
}

// A leave that could not remove everything (here: the panel's users) fails:
// the server stays joined with the reason, and psm-agent does not uninstall.
func TestALeaveThatFailsKeepsTheAgent(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 5, Kind: "agent.leave", Data: json.RawMessage(`{"nodes":[],"standalone":[]}`)}}}
	f := &fakeRunner{fail: map[string]string{"purge": "psm user: xray did not accept"}}
	a, done := newTestAgent(t, p, f)
	defer done()
	var spawned [][]string
	a.spawn = func(args ...string) error { spawned = append(spawned, args); return nil }
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 1 || rs[0].OK || !strings.Contains(rs[0].Error, "panel users") {
		t.Fatalf("leave result: %+v", rs)
	}
	if a.left || a.leaving || len(spawned) != 0 {
		t.Fatalf("psm-agent removed itself after a failed leave: left=%v spawned=%q", a.left, spawned)
	}
}

// REALITY's own site goes only to a PSM that supports it, and what PSM stored
// is read back: a fallback anywhere else takes the node down again.
func TestOwnSiteNeedsTheCapabilityAndIsReadBack(t *testing.T) {
	node := json.RawMessage(`{"tag":"hk","port":443,"server_name":"n1.example.org","own_site":true,"dest":"127.0.0.1:8443"}`)
	// an old PSM: no caps
	p := &fakePanel{tasks: []task{{ID: 1, Kind: "node.add", Core: "xray", Protocol: "reality", Data: node}}}
	f := &fakeRunner{stdout: map[string]string{"": `{"caps":[]}`}}
	a, done := newTestAgent(t, p, f)
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	done()
	if rs := results(t, p.requests[1]["results"]); rs[0].OK || !strings.Contains(rs[0].Error, "own site") {
		t.Fatalf("old PSM: %+v", rs)
	}
	for _, c := range f.calls {
		if len(c.args) > 1 && c.args[1] == "add" {
			t.Fatal("node add reached a PSM without the capability")
		}
	}
	// a PSM that stored something else: the node is removed and the task fails
	p = &fakePanel{tasks: []task{{ID: 2, Kind: "node.add", Core: "xray", Protocol: "reality", Data: node}}}
	f = &fakeRunner{stdout: map[string]string{"": `{"caps":["reality.own_site","reality.guard"]}`, "add": `{"status":"created"}`,
		"show": `{"item":{"node":{"dest":"www.cloudflare.com:443","own_site":true}}}`, "delete": `{"status":"deleted"}`}}
	a, done = newTestAgent(t, p, f)
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	done()
	if rs := results(t, p.requests[1]["results"]); rs[0].OK || !strings.Contains(rs[0].Error, "cloudflare") {
		t.Fatalf("bad stored fallback: %+v", rs)
	}
	last := f.calls[len(f.calls)-1].args
	if !reflect.DeepEqual(last, []string{"node", "delete", "xray", "reality", "hk", "--yes", "--if-exists", "--json"}) {
		t.Fatalf("the node was not taken down: %q", last)
	}
	// and the good case
	p = &fakePanel{tasks: []task{{ID: 3, Kind: "node.add", Core: "xray", Protocol: "reality", Data: node}}}
	f = &fakeRunner{stdout: map[string]string{"": `{"caps":["reality.own_site","reality.guard"]}`, "add": `{"status":"created"}`,
		"show": `{"item":{"node":{"dest":"127.0.0.1:8443","own_site":true}}}`}}
	a, done = newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	if rs := results(t, p.requests[1]["results"]); !rs[0].OK {
		t.Fatalf("own site: %+v", rs)
	}
}

// REALITY is only ever made on this server's own site: a task without
// own_site (one queued before roomkey, say) never reaches PSM.
func TestRealityWithoutOwnSiteIsRefused(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "node.add", Core: "xray", Protocol: "reality", Data: json.RawMessage(`{"tag":"hk","port":443,"server_name":"a.example","dest":"a.example:443"}`)},
		{ID: 2, Kind: "node.add", Core: "xray", Protocol: "xhttp", Data: json.RawMessage(`{"tag":"hx","port":2443,"mode":"reality-layer","server_name":"a.example"}`)},
	}}
	f := &fakeRunner{}
	a, done := newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	for _, r := range results(t, p.requests[1]["results"]) {
		if r.OK || !strings.Contains(r.Error, "own site") {
			t.Fatalf("result: %+v", r)
		}
	}
	// reading the node list (is it there already?) is all that may run
	for _, c := range f.calls {
		if len(c.args) < 2 || c.args[0] != "node" || c.args[1] != "list" {
			t.Fatalf("psm ran: %q", f.calls)
		}
	}
}

// A create whose node is already on the server goes ahead as a change, and a
// change whose node is gone as a create: a restored panel, a lost result.
func TestNodeAddAndUpdateUpsert(t *testing.T) {
	list := `{"api_version":1,"count":1,"items":[{"core":"xray","protocol":"trojan","tag":"there"}]}`
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "node.add", Core: "xray", Protocol: "trojan", Recover: true, Data: json.RawMessage(`{"tag":"there","port":8443}`)},
		{ID: 2, Kind: "node.update", Core: "xray", Protocol: "trojan", Tag: "gone", Mount443: true, Data: json.RawMessage(`{"tag":"gone","port":8444}`)},
		// a first create of a node that is there (made by hand) is a conflict, reported as such
		{ID: 3, Kind: "node.add", Core: "xray", Protocol: "trojan", Data: json.RawMessage(`{"tag":"there","port":8445}`)},
	}}
	f := &fakeRunner{stdout: map[string]string{"list": list}}
	a, done := newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	var ran []string
	for _, c := range f.calls {
		if len(c.args) >= 2 && c.args[0] == "node" && (c.args[1] == "add" || c.args[1] == "update") {
			ran = append(ran, strings.Join(c.args[:min(len(c.args), 5)], " "))
		}
	}
	// the first create of a node that is there is a conflict: nothing runs for it
	if len(ran) != 2 || !strings.HasPrefix(ran[0], "node update xray trojan there") || !strings.HasPrefix(ran[1], "node add xray trojan") {
		t.Fatalf("ran: %q", ran)
	}
	_, _ = a.step(context.Background())
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 3 || rs[2].OK || string(rs[2].Output) != `{"conflict":true}` {
		t.Fatalf("results: %+v", rs)
	}
	// the recreated node keeps the shared 443
	for _, c := range f.calls {
		if len(c.args) > 1 && c.args[1] == "add" && strings.Contains(c.stdin, `"gone"`) && !strings.Contains(strings.Join(c.args, " "), "--mount-443") {
			t.Fatalf("recreated without --mount-443: %q", c.args)
		}
	}
}

// Tasks after a successful leave in the same batch never run.
func TestNothingRunsAfterALeave(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 5, Kind: "agent.leave", Data: json.RawMessage(`{"nodes":[],"standalone":[]}`)},
		{ID: 6, Kind: "user.sync", Data: json.RawMessage(`{"revision":9,"users":[]}`)},
	}}
	f := &fakeRunner{stdout: map[string]string{"purge": `{"status":"purged","ok":true}`, "": `{"caps":["users.import.revision"]}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	a.spawn = func(args ...string) error { return nil }
	_, _ = a.step(context.Background())
	for _, c := range f.calls {
		if len(c.args) > 1 && c.args[1] == "import" {
			t.Fatal("a user list ran after the leave")
		}
	}
	if len(a.pending) != 2 || !a.pending[0].OK || a.pending[1].OK {
		t.Fatalf("results: %+v", a.pending)
	}
}

// A task the panel hands out again (its result was lost, psm-agent restarted
// before reporting it) is answered from the journal on disk, not run twice: a
// node created once must not come back as a conflict with itself.
func TestATaskHandedOutAgainIsNotRunAgain(t *testing.T) {
	dir := t.TempDir()
	add := task{ID: 7, UID: "u-7a", Kind: "node.add", Core: "xray", Protocol: "trojan", Data: json.RawMessage(`{"tag":"mine","port":8443}`)}
	p := &fakePanel{tasks: []task{add}, failNext: 0}
	f := &fakeRunner{stdout: map[string]string{"add": `{"status":"created"}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	a.cfgPath = filepath.Join(dir, "agent.json")
	_, _ = a.step(context.Background()) // runs it; the result is on disk before any report
	// restarted before the report: a fresh process reads the journal
	b := &agent{cfg: a.cfg, cfgPath: a.cfgPath, run: f.run, hostname: "hk1", lastTraffic: time.Now(),
		versionAt: time.Now(), psmVersion: a.psmVersion}
	b.loadJournal()
	if len(b.pending) != 1 || !b.pending[0].OK {
		t.Fatalf("pending after a restart: %+v", b.pending)
	}
	// the result went; the panel hands the same task out again
	_, _ = b.step(context.Background())
	p.mu.Lock()
	p.tasks = []task{add}
	p.mu.Unlock()
	_, _ = b.step(context.Background())
	_, _ = b.step(context.Background())
	adds := 0
	for _, c := range f.calls {
		if len(c.args) > 1 && c.args[0] == "node" && c.args[1] == "add" {
			adds++
		}
	}
	rs := results(t, p.requests[len(p.requests)-1]["results"])
	if adds != 1 || len(rs) != 1 || !rs[0].OK || rs[0].TaskID != 7 || rs[0].UID != "u-7a" {
		t.Fatalf("adds=%d last results=%+v", adds, rs)
	}
	// a restored panel numbers from 1 again: the same id with another uid is
	// another task, and runs
	other := task{ID: 7, UID: "u-7b", Kind: "node.add", Core: "xray", Protocol: "trojan", Data: json.RawMessage(`{"tag":"other","port":8444}`)}
	p.mu.Lock()
	p.tasks = []task{other}
	p.mu.Unlock()
	_, _ = b.step(context.Background())
	_, _ = b.step(context.Background())
	adds = 0
	for _, c := range f.calls {
		if len(c.args) > 1 && c.args[0] == "node" && c.args[1] == "add" {
			adds++
		}
	}
	rs = results(t, p.requests[len(p.requests)-1]["results"])
	if adds != 2 || len(rs) != 1 || rs[0].UID != "u-7b" {
		t.Fatalf("same id, another uid: adds=%d results=%+v", adds, rs)
	}
}

// When PSM can't list the nodes, a create or change does not run at all.
func TestUnreadableNodeListChangesNothing(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "node.add", Core: "xray", Protocol: "trojan", Data: json.RawMessage(`{"tag":"a","port":8443}`)},
		{ID: 2, Kind: "node.update", Core: "xray", Protocol: "trojan", Tag: "a", Data: json.RawMessage(`{"tag":"a","port":8444}`)},
	}}
	f := &fakeRunner{stdout: map[string]string{"list": `not json`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	for _, c := range f.calls {
		if len(c.args) > 1 && c.args[0] == "node" && (c.args[1] == "add" || c.args[1] == "update") {
			t.Fatalf("ran %q with an unreadable node list", c.args)
		}
	}
	if len(a.pending) != 2 || a.pending[0].OK || a.pending[1].OK || !strings.Contains(a.pending[0].Error, "nothing was changed") {
		t.Fatalf("results: %+v", a.pending)
	}
}

// A standalone server PSM sees running or configured (a Docker install shows
// installed:false) is someone else's to a first install; an unreadable answer
// installs nothing.
func TestStandaloneFirstInstallSeesADockerOne(t *testing.T) {
	for _, show := range []string{`{"installed":false,"active":true,"configured":true}`, `garbage`} {
		p := &fakePanel{tasks: []task{{ID: 1, Kind: "standalone.install", Protocol: "snell", Tag: "hk-snell", Create: true,
			Data: json.RawMessage(`{"port":31000,"version":"6","psk":"abcdefgh12"}`)}}}
		f := &fakeRunner{stdout: map[string]string{"show": show, "install": `{"status":"installed"}`}}
		a, done := newTestAgent(t, p, f)
		_, _ = a.step(context.Background())
		done()
		for _, c := range f.calls {
			if len(c.args) > 1 && c.args[0] == "standalone" && c.args[1] == "install" {
				t.Fatalf("show %s: installed over it", show)
			}
		}
		if len(a.pending) != 1 || a.pending[0].OK {
			t.Fatalf("show %s: %+v", show, a.pending)
		}
	}
}

// A first create that failed after PSM wrote the node says so: the panel then
// owns it, and removes it when asked.
func TestAHalfRunCreateIsReportedAsCreated(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 1, Kind: "node.add", Core: "xray", Protocol: "trojan", Data: json.RawMessage(`{"tag":"half","port":8443}`)}}}
	f := &fakeRunner{fail: map[string]string{"add": "psm node: core did not restart\n"}}
	a, done := newTestAgent(t, p, f)
	defer done()
	// the list is empty before the add and has the node after it
	added := false
	run := f.run
	a.run = func(ctx context.Context, stdin []byte, args ...string) ([]byte, []byte, error) {
		if len(args) > 1 && args[0] == "node" && args[1] == "add" {
			added = true
		}
		if len(args) > 1 && args[0] == "node" && args[1] == "list" {
			if added {
				return []byte(`{"count":1,"items":[{"core":"xray","protocol":"trojan","tag":"half"}]}`), nil, nil
			}
			return []byte(`{"count":0,"items":[]}`), nil, nil
		}
		return run(ctx, stdin, args...)
	}
	_, _ = a.step(context.Background())
	if len(a.pending) != 1 || a.pending[0].OK || string(a.pending[0].Output) != `{"created":true}` {
		t.Fatalf("result: %+v", a.pending)
	}
}

// A leave whose result was journalled but not yet delivered when psm-agent
// restarted still uninstalls psm-agent once the panel has it.
func TestALeaveSurvivesARestart(t *testing.T) {
	dir := t.TempDir()
	p := &fakePanel{tasks: []task{{ID: 5, UID: "u-leave", Kind: "agent.leave", Data: json.RawMessage(`{"nodes":[],"standalone":[]}`)}}}
	f := &fakeRunner{stdout: map[string]string{"purge": `{"status":"purged","ok":true}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	a.cfgPath = filepath.Join(dir, "agent.json")
	p.failNext = 0
	// run the leave, then lose the process before the report goes
	_, _ = a.step(context.Background())
	if !a.leaving || len(a.pending) != 1 {
		t.Fatalf("leaving=%v pending=%+v", a.leaving, a.pending)
	}
	b := &agent{cfg: a.cfg, cfgPath: a.cfgPath, run: f.run, hostname: "hk1", lastTraffic: time.Now(), versionAt: time.Now(), psmVersion: a.psmVersion}
	b.loadJournal()
	var spawned []string
	b.spawn = func(args ...string) error { spawned = args; return nil }
	_, _ = b.step(context.Background())
	if !b.left || strings.Join(spawned, " ") != "agent remove --yes" {
		t.Fatalf("after a restart: left=%v spawned=%q", b.left, spawned)
	}
}

// A first create whose tag a node on another core already has is a conflict:
// PSM meters and grants by tag.
func TestAFirstCreateNeedsItsTagFreeOnEveryCore(t *testing.T) {
	list := `{"count":1,"items":[{"core":"sing-box","protocol":"anytls","tag":"hk"}]}`
	p := &fakePanel{tasks: []task{{ID: 1, UID: "u1", Kind: "node.add", Core: "xray", Protocol: "trojan", Data: json.RawMessage(`{"tag":"hk","port":8443}`)}}}
	f := &fakeRunner{stdout: map[string]string{"list": list}}
	a, done := newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	for _, c := range f.calls {
		if len(c.args) > 1 && c.args[0] == "node" && c.args[1] == "add" {
			t.Fatal("created beside a same-name node on another core")
		}
	}
	if len(a.pending) != 1 || a.pending[0].OK || string(a.pending[0].Output) != `{"conflict":true}` {
		t.Fatalf("result: %+v", a.pending)
	}
}

// A borrowed REALITY site: only with borrowed_site, only a domain on 443 that
// is the node's SNI, only on a PSM that supports it, and what PSM stored is
// read back.
func TestBorrowedSiteIsExplicitAndReadBack(t *testing.T) {
	caps := `{"caps":["reality.own_site","reality.guard","reality.borrowed","reality.probe"]}`
	good := json.RawMessage(`{"tag":"hk","port":443,"server_name":"www.samsung.com","dest":"www.samsung.com:443","borrowed_site":true}`)
	for i, bad := range []string{
		`{"tag":"hk","port":443,"server_name":"192.0.2.1","dest":"192.0.2.1:443","borrowed_site":true}`,
		`{"tag":"hk","port":443,"server_name":"www.samsung.com","dest":"10.0.0.1:80","borrowed_site":true}`,
		`{"tag":"hk","port":443,"server_name":"www.samsung.com","dest":"www.samsung.com:8443","borrowed_site":true}`,
		`{"tag":"hk","port":443,"server_name":"www.samsung.com","borrowed_site":true,"own_site":true}`,
		`{"tag":"hk","port":443,"server_name":"www.samsung.com","dest":"www.samsung.com:443"}`,
	} {
		p := &fakePanel{tasks: []task{{ID: int64(i + 1), Kind: "node.add", Core: "xray", Protocol: "reality", Data: json.RawMessage(bad)}}}
		f := &fakeRunner{stdout: map[string]string{"": caps}}
		a, done := newTestAgent(t, p, f)
		_, _ = a.step(context.Background())
		_, _ = a.step(context.Background())
		done()
		if rs := results(t, p.requests[1]["results"]); rs[0].OK {
			t.Fatalf("accepted %s", bad)
		}
		for _, c := range f.calls {
			if len(c.args) > 1 && c.args[1] == "add" {
				t.Fatalf("node add ran for %s", bad)
			}
		}
	}
	// a PSM without the capability
	p := &fakePanel{tasks: []task{{ID: 9, Kind: "node.add", Core: "xray", Protocol: "reality", Data: good}}}
	f := &fakeRunner{stdout: map[string]string{"": `{"caps":["reality.own_site","reality.guard"]}`}}
	a, done := newTestAgent(t, p, f)
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	done()
	if rs := results(t, p.requests[1]["results"]); rs[0].OK || !strings.Contains(rs[0].Error, "borrowed") {
		t.Fatalf("old PSM: %+v", rs)
	}
	// stored with another fallback: taken down
	p = &fakePanel{tasks: []task{{ID: 10, Kind: "node.add", Core: "xray", Protocol: "reality", Data: good}}}
	f = &fakeRunner{stdout: map[string]string{"": caps, "add": `{"status":"created"}`,
		"show": `{"item":{"node":{"dest":"www.apple.com:443","borrowed_site":true}}}`, "delete": `{"status":"deleted"}`}}
	a, done = newTestAgent(t, p, f)
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	done()
	if rs := results(t, p.requests[1]["results"]); rs[0].OK || !strings.Contains(rs[0].Error, "apple") {
		t.Fatalf("bad stored fallback: %+v", rs)
	}
	// the good case
	p = &fakePanel{tasks: []task{{ID: 11, Kind: "node.add", Core: "xray", Protocol: "reality", Data: good}}}
	f = &fakeRunner{stdout: map[string]string{"": caps, "add": `{"status":"created"}`,
		"show": `{"item":{"node":{"dest":"www.samsung.com:443","borrowed_site":true}}}`}}
	a, done = newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	if rs := results(t, p.requests[1]["results"]); !rs[0].OK {
		t.Fatalf("borrowed site: %+v", rs)
	}
}

// The 探测 button: a domain only, passed to psm reality probe as one argument.
func TestRealityProbe(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "reality.probe", Data: json.RawMessage(`{"host":"WWW.AMD.com"}`)},
		{ID: 2, Kind: "reality.probe", Data: json.RawMessage(`{"host":"--json"}`)},
		{ID: 3, Kind: "reality.probe", Data: json.RawMessage(`{"host":"10.0.0.1"}`)},
		{ID: 4, Kind: "reality.probe", Data: json.RawMessage(`{"hosts":["www.amd.com","www.amd.com"]}`)},
		{ID: 5, Kind: "reality.probe", Data: json.RawMessage(`{"hosts":["www.amd.com","a.b;rm -rf"]}`)},
	}}
	f := &fakeRunner{stdout: map[string]string{"": `{"caps":["reality.probe"]}`, "probe": `{"host":"www.amd.com","ok":true,"shared_frontend":false}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	rs := results(t, p.requests[1]["results"])
	if !rs[0].OK || !strings.Contains(string(rs[0].Output), `"sites":[{"host":"www.amd.com"`) || rs[1].OK || rs[2].OK || !rs[3].OK || rs[4].OK {
		t.Fatalf("results: %+v", rs)
	}
	ran := 0
	for _, c := range f.calls {
		if len(c.args) > 1 && c.args[0] == "reality" {
			ran++
			if !reflect.DeepEqual(c.args, []string{"reality", "probe", "www.amd.com", "--json"}) {
				t.Fatalf("probe args: %q", c.args)
			}
		}
	}
	if ran != 3 {
		t.Fatalf("probes run: %d", ran)
	}
}
