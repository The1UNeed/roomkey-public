package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestUserSyncImportsTheListAndReportsItsRevision(t *testing.T) {
	users := `{"revision":5,"users":[{"name":"alice","uuid":"u","password":"p","enabled":true},{"name":"bob","enabled":false}]}`
	p := &fakePanel{tasks: []task{{ID: 1, Kind: "user.sync", Data: json.RawMessage(users)}}}
	f := &fakeRunner{stdout: map[string]string{"import": `{"status":"imported","revision":5,"managed":2,"applied":true}`,
		"": `{"caps":["users.import.revision"]}`}}
	a, done := newTestAgent(t, p, f)
	defer done()

	_, _ = a.step(context.Background())
	// psm caps first (a PSM that does not take numbered lists gets none), then the import
	if len(f.calls) != 2 || !reflect.DeepEqual(f.calls[0].args, []string{"caps"}) || !reflect.DeepEqual(f.calls[1].args, []string{"user", "import", "--json"}) {
		t.Fatalf("psm calls: %q", f.calls)
	}
	// passed on as it came: a pause made here lives in PSM, not in the list
	if f.calls[1].stdin != users {
		t.Fatalf("stdin changed: %s", f.calls[1].stdin)
	}
	if !a.lastTraffic.IsZero() {
		t.Error("the users' counters should go with the next sync")
	}
	_, _ = a.step(context.Background())
	if string(p.requests[1]["users_rev"]) != "5" {
		t.Fatalf("users_rev reported: %s", p.requests[1]["users_rev"])
	}
}

func TestBadUserSyncNeverReachesPSM(t *testing.T) {
	for _, data := range []string{``, `[]`, `{"users":null}`, `{"users":[{"name":"--help"}]}`, `{"users":[{"name":"Bad Name"}]}`, `{"revision":-1,"users":[]}`} {
		p := &fakePanel{tasks: []task{{ID: 1, Kind: "user.sync", Data: json.RawMessage(data)}}}
		f := &fakeRunner{}
		a, done := newTestAgent(t, p, f)
		_, _ = a.step(context.Background())
		_, _ = a.step(context.Background())
		done()
		if len(f.calls) != 0 {
			t.Fatalf("%q reached psm: %q", data, f.calls)
		}
		if rs := results(t, p.requests[1]["results"]); len(rs) != 1 || rs[0].OK || !strings.Contains(rs[0].Error, "rejected") {
			t.Fatalf("%q: %+v", data, rs)
		}
	}
}

func TestUsersAndOnlineGoWithTheTrafficReport(t *testing.T) {
	p := &fakePanel{}
	f := &fakeRunner{stdout: map[string]string{"list": `[]`, "usage": `{"users":[{"name":"a","counter_bytes":5}]}`, "online": `{"users":[]}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	a.lastTraffic = time.Now().Add(-trafficEvery)
	_, _ = a.step(context.Background())
	if string(p.requests[0]["users"]) != `{"users":[{"name":"a","counter_bytes":5}]}` || string(p.requests[0]["online"]) != `{"users":[]}` {
		t.Fatalf("users=%s online=%s", p.requests[0]["users"], p.requests[0]["online"])
	}
}

func TestEventsStayUntilThePanelRecordsThem(t *testing.T) {
	p := &fakePanel{}
	a, done := newTestAgent(t, p, &fakeRunner{})
	defer done()
	a.cfgPath = filepath.Join(t.TempDir(), "agent.json")
	a.addEvent("core.restart", "xray", nil)

	// on disk at once: a restart before the panel answers keeps it
	b := &agent{cfg: a.cfg, cfgPath: a.cfgPath}
	b.loadEvents()
	if len(b.events) != 1 || b.events[0].Kind != "core.restart" || len(b.events[0].ID) != 16 {
		t.Fatalf("persisted events: %+v", b.events)
	}
	// the panel did not confirm it: sent again
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	var evs []event
	_ = json.Unmarshal(p.requests[1]["events"], &evs)
	if len(evs) != 1 {
		t.Fatalf("an unconfirmed event must be sent again: %s", p.requests[1]["events"])
	}
	// confirmed: gone, from memory and from disk
	p.ack = []string{evs[0].ID}
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	if _, again := p.requests[3]["events"]; again {
		t.Fatal("a confirmed event was sent again")
	}
	b.events = nil
	b.loadEvents()
	if len(b.events) != 0 {
		t.Fatalf("confirmed events left on disk: %+v", b.events)
	}
}

func TestPasswordHash(t *testing.T) {
	h := hashPassword("correct horse battery")
	if !checkPassword(h, "correct horse battery") || checkPassword(h, "wrong") || checkPassword("garbage", "x") {
		t.Fatal("password check")
	}
	// RFC 7914 §11 test vector for PBKDF2-HMAC-SHA256 (passwd/salt, c=1)
	got := hex.EncodeToString(pbkdf2SHA256([]byte("passwd"), []byte("salt"), 1))
	if got != "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc" {
		t.Fatalf("pbkdf2: %s", got)
	}
}

func TestLocalAddrIsLoopbackOnly(t *testing.T) {
	for addr, ok := range map[string]bool{"": true, "127.0.0.1:2096": true, "[::1]:9000": true, "off": true,
		"0.0.0.0:2096": false, "203.0.113.5:2096": false, "localhost:2096": false, "127.0.0.1:0": false} {
		_, err := localAddr(&config{LocalAddr: addr})
		if (err == nil) != ok {
			t.Errorf("%q: err=%v", addr, err)
		}
	}
}

// local runs the local page's handler with a fake psm and returns a client
// for it that signs in with a one-time code from the panel.
func localPage(t *testing.T, f *fakeRunner) (*agent, *httptest.Server, func(method, path, body string) *http.Response) {
	a := &agent{cfg: &config{Panel: "https://panel.example"}, run: f.run, hostname: "hk1"}
	srv := httptest.NewServer(a.localHandler("127.0.0.1:2096"))
	t.Cleanup(srv.Close)
	cookie := ""
	do := func(method, path, body string) *http.Response {
		req, _ := http.NewRequest(method, srv.URL+path, strings.NewReader(body))
		req.Host = "127.0.0.1:2096"
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-PSM-Local", "1")
		if cookie != "" {
			req.Header.Set("Cookie", cookie)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		for _, c := range resp.Cookies() {
			if c.Name == "psm_local" {
				cookie = "psm_local=" + c.Value
			}
		}
		return resp
	}
	return a, srv, do
}

func giveCode(t *testing.T, a *agent, code string) {
	sum := sha256.Sum256([]byte(code))
	r := a.execute(context.Background(), task{ID: 1, Kind: "local.code", CodeHash: hex.EncodeToString(sum[:]), ExpiresAt: time.Now().Add(5 * time.Minute).Unix()})
	if !r.OK {
		t.Fatalf("local.code: %+v", r)
	}
}

func TestALateOrReplayedCodeDoesNotWork(t *testing.T) {
	f := &fakeRunner{}
	a, _, do := localPage(t, f)
	sum := sha256.Sum256([]byte("late-code"))
	r := a.execute(context.Background(), task{ID: 1, Kind: "local.code", CodeHash: hex.EncodeToString(sum[:]), ExpiresAt: time.Now().Add(-time.Second).Unix()})
	if r.OK {
		t.Fatal("a code delivered after its deadline was taken")
	}
	if resp := do("POST", "/api/login", `{"code":"late-code"}`); resp.StatusCode != 401 {
		t.Fatalf("late code signed in: %d", resp.StatusCode)
	}
	// used once, then the same task delivered again: still used
	giveCode(t, a, "once-code")
	if resp := do("POST", "/api/login", `{"code":"once-code"}`); resp.StatusCode != 200 {
		t.Fatalf("first use: %d", resp.StatusCode)
	}
	giveCode(t, a, "once-code")
	a.mu.Lock()
	_, back := a.codes[hex.EncodeToString(func() []byte { s := sha256.Sum256([]byte("once-code")); return s[:] }())]
	a.mu.Unlock()
	if back {
		t.Fatal("a replayed task brought back a used code")
	}
}

func TestLocalPageSignsInWithAOneTimeCode(t *testing.T) {
	f := &fakeRunner{stdout: map[string]string{"restart": `{"core":"xray","active":true}`}}
	a, _, do := localPage(t, f)
	if r := do("POST", "/api/cores/xray/restart", `{}`); r.StatusCode != 401 {
		t.Fatalf("before sign-in: %d", r.StatusCode)
	}
	giveCode(t, a, "7KQ2-9XM4")
	if r := do("POST", "/api/login", `{"code":"WRONG-CODE"}`); r.StatusCode != 401 {
		t.Fatalf("wrong code: %d", r.StatusCode)
	}
	if r := do("POST", "/api/login", `{"code":"7KQ2-9XM4"}`); r.StatusCode != 200 {
		t.Fatalf("sign-in: %d", r.StatusCode)
	}
	if r := do("POST", "/api/cores/xray/restart", `{}`); r.StatusCode != 200 {
		t.Fatalf("restart: %d", r.StatusCode)
	}
	if want := []string{"core", "restart", "xray", "--json"}; !reflect.DeepEqual(f.calls[len(f.calls)-1].args, want) {
		t.Fatalf("psm: %q", f.calls)
	}
	// the code worked once
	a.mu.Lock()
	left := len(a.codes)
	kinds := []string{}
	for _, e := range a.events {
		kinds = append(kinds, e.Kind)
	}
	a.mu.Unlock()
	if left != 0 {
		t.Fatal("a one-time code was left after use")
	}
	if !reflect.DeepEqual(kinds, []string{"local.login", "core.restart"}) {
		t.Fatalf("events: %v", kinds)
	}
}

func TestLocalPageRefusesOtherHostsAndCrossSiteChanges(t *testing.T) {
	f := &fakeRunner{}
	a, srv, do := localPage(t, f)
	giveCode(t, a, "code-1234")
	_ = do("POST", "/api/login", `{"code":"code-1234"}`)

	// DNS rebinding: another name pointed at 127.0.0.1
	req, _ := http.NewRequest("GET", srv.URL+"/api/session", nil)
	req.Host = "evil.example:2096"
	if r, _ := http.DefaultClient.Do(req); r.StatusCode != 421 {
		t.Fatalf("foreign Host: %d", r.StatusCode)
	}
	// a change without the page's header, or from another site
	for _, h := range []map[string]string{{}, {"X-PSM-Local": "1", "Sec-Fetch-Site": "cross-site"}, {"X-PSM-Local": "1", "Origin": "http://evil.example"}} {
		req, _ := http.NewRequest("POST", srv.URL+"/api/cores/xray/restart", strings.NewReader(`{}`))
		req.Host = "127.0.0.1:2096"
		for k, v := range h {
			req.Header.Set(k, v)
		}
		if r, _ := http.DefaultClient.Do(req); r.StatusCode != 403 {
			t.Fatalf("headers %v: %d", h, r.StatusCode)
		}
	}
	if len(f.calls) != 0 {
		t.Fatalf("psm ran: %q", f.calls)
	}
}

func TestLocalPageSwitchesAUserOffHereOnly(t *testing.T) {
	f := &fakeRunner{stdout: map[string]string{"update": `{"status":"updated"}`}}
	a, _, do := localPage(t, f)
	giveCode(t, a, "code-5678")
	_ = do("POST", "/api/login", `{"code":"code-5678"}`)
	if r := do("POST", "/api/users/bob/disable", `{}`); r.StatusCode != 200 {
		t.Fatalf("disable: %d", r.StatusCode)
	}
	// PSM's own pause, never --disable / --enable (those are the panel's)
	if want := []string{"user", "update", "bob", "--local-pause", "--json"}; !reflect.DeepEqual(f.calls[0].args, want) {
		t.Fatalf("psm: %q", f.calls)
	}
	if r := do("POST", "/api/users/bob/enable", `{}`); r.StatusCode != 200 {
		t.Fatalf("enable: %d", r.StatusCode)
	}
	if want := []string{"user", "update", "bob", "--local-resume", "--json"}; !reflect.DeepEqual(f.calls[1].args, want) {
		t.Fatalf("psm: %q", f.calls)
	}
	if r := do("POST", "/api/users/--help/disable", `{}`); r.StatusCode != 404 {
		t.Fatalf("bad name: %d", r.StatusCode)
	}
}

func TestLocalPageNodeEditIsChecked(t *testing.T) {
	f := &fakeRunner{stdout: map[string]string{"update": `{"status":"updated"}`}}
	a, _, do := localPage(t, f)
	giveCode(t, a, "code-9999")
	_ = do("POST", "/api/login", `{"code":"code-9999"}`)
	for _, c := range [][2]string{
		{"/api/nodes/xray/reality/hk", `{"port":70000}`},
		{"/api/nodes/bogus/reality/hk", `{"port":443}`},
		{"/api/nodes/xray/reality/--x", `{"port":443}`},
		{"/api/nodes/xray/reality/hk", `{"display_name":"a,b"}`},
		{"/api/nodes/xray/reality/hk", `{}`},
		{"/api/nodes/xray/reality/hk/x", `{"port":443}`},
	} {
		if r := do("POST", c[0], c[1]); r.StatusCode == 200 {
			t.Fatalf("%s %s accepted", c[0], c[1])
		}
	}
	if len(f.calls) != 0 {
		t.Fatalf("psm ran: %q", f.calls)
	}
	if r := do("POST", "/api/nodes/xray/reality/hk", `{"port":8443,"display_name":"香港"}`); r.StatusCode != 200 {
		t.Fatalf("edit: %d", r.StatusCode)
	}
	c := f.calls[0]
	if !reflect.DeepEqual(c.args, []string{"node", "update", "xray", "reality", "hk", "--input", "-", "--json"}) ||
		c.stdin != `{"display_name":"香港","port":8443}` {
		t.Fatalf("psm: %q %s", c.args, c.stdin)
	}
}

// A code used before a restart stays used after it, even if its task is
// delivered again within the original deadline.
func TestAUsedCodeStaysUsedAcrossARestart(t *testing.T) {
	dir := t.TempDir()
	f := &fakeRunner{}
	a, _, do := localPage(t, f)
	a.cfgPath = filepath.Join(dir, "agent.json")
	giveCode(t, a, "restart-code")
	if r := do("POST", "/api/login", `{"code":"restart-code"}`); r.StatusCode != 200 {
		t.Fatalf("first use: %d", r.StatusCode)
	}
	// a new process, the same task again
	b := &agent{cfg: &config{Panel: "https://panel.example"}, run: f.run, cfgPath: a.cfgPath}
	giveCode(t, b, "restart-code")
	sum := sha256.Sum256([]byte("restart-code"))
	b.mu.Lock()
	_, back := b.codes[hex.EncodeToString(sum[:])]
	b.mu.Unlock()
	if back {
		t.Fatal("a code used before the restart works again")
	}
}
