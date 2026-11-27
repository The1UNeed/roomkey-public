// psm-agent connects a server to the PSM panel.
//
// It opens no port, not even on loopback: it makes one HTTPS request to the
// panel at a time, which carries the results of its last tasks (and, every
// ten minutes, the traffic counters) and brings back new ones, then waits as
// long as the panel says (30 s when idle, 3 s while there is work). Each task
// is run as a psm command with its arguments passed as an argv array (never
// through a shell) and checked against allowlists first, so the panel can make
// the server do nothing the psm command line cannot.
//
// Tasks: node.add (installing the core first when the server has never run
// it), node.update, node.delete, node.export, standalone.install and
// standalone.remove (Snell / ss-rust), traffic.set, traffic.reset,
// traffic.report (send the counters with the next sync), status, check.run
// (psm check: the server's IP from outside, and which services let it in),
// agent.update
// user.sync (the panel's users for this server: psm user import), local.code
// (a one-time code for this server's local page)
// (the panel asks for a newer psm-agent: report, then run psm agent upgrade
// detached) and agent.leave (the server was removed from the panel: delete the
// panel's nodes, report, then uninstall psm-agent itself).
//
//	psm-agent join -panel https://psm.example.com -token <join token>
//	psm-agent run
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const agentVersion = "0.15.0"

const (
	commandTimeout  = 120 * time.Second // one psm command
	checkTimeout    = 3 * time.Minute   // psm check: fetching ipcheck, then its requests
	probeTimeout    = time.Minute       // psm reality probe: a handshake and three CDN probes
	installTimeout  = 15 * time.Minute  // installing a core or a standalone server
	requestTimeout  = 30 * time.Second  // one request to the panel
	maxTaskData     = 64 << 10          // a task's node settings
	maxUserData     = 1 << 20           // a user.sync task's users
	maxResponse     = 1 << 20           // a response from the panel
	maxReport       = 512 << 10         // a status report sent to the panel
	defaultInterval = 30 * time.Second  // the panel says how long to wait; this is the fallback
	trafficEvery    = 10 * time.Minute  // how often the traffic counters go to the panel
	versionEvery    = time.Hour         // how often PSM's version is looked up again
	maxLimitBytes   = 1 << 53           // a traffic limit (8 PiB)
	defaultConfig   = "/etc/psm/agent.json"
)

var cores = map[string]bool{"xray": true, "sing-box": true, "mihomo": true}

var protocols = map[string]bool{
	"reality": true, "vision": true, "xhttp": true, "ss2022": true, "trojan": true,
	// no socks: roomkey offers no SOCKS nodes (a public one is an open proxy waiting to happen)
	"vmess": true, "hysteria2": true, "anytls": true, "snell": true,
	"vless": true, "tuic": true, "wireguard": true,
}

// the standalone servers (`psm standalone`)
var standalones = map[string]bool{"snell": true, "ss2022": true}

// an API key psm check passes on (letters, digits, - and _)
var checkKeyRe = regexp.MustCompile(`^[A-Za-z0-9_-]{8,128}$`)

var ssMethods = map[string]bool{
	"2022-blake3-aes-128-gcm": true, "2022-blake3-aes-256-gcm": true, "2022-blake3-chacha20-poly1305": true,
}

var snellVersions = map[string]bool{"4": true, "5": true, "6": true}

var (
	// a tag never starts with "-": psm would read "--show-secrets" as an option
	tagRe  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$`)
	hostRe = regexp.MustCompile(`^([A-Za-z0-9-]{1,63}\.)*[A-Za-z0-9-]{1,63}$|^[0-9a-fA-F:.]+$`)
	// a relay's hosts: DNS labels do not start or end with "-" (nor would a
	// host psm or realm should ever see: "--help" passes hostRe)
	relayHostRe = regexp.MustCompile(`^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$|^[0-9a-fA-F:.]+$`)
	pskRe       = regexp.MustCompile(`^[A-Za-z0-9+/=_][A-Za-z0-9+/=_-]{7,127}$`)
	keyRe       = regexp.MustCompile(`^[A-Za-z0-9+/]{16,86}={0,2}$`)
	// a relay tunnel's password, the WebSocket path, the exit's certificate hash,
	// an expiry (UTC) and a port range for --listen-port auto
	secretRe  = regexp.MustCompile(`^[A-Za-z0-9_-]{8,64}$`)
	wsPathRe  = regexp.MustCompile(`^/[A-Za-z0-9._~/%-]{0,127}$`)
	pinRe     = regexp.MustCompile(`^[0-9a-fA-F]{64}$`)
	expiresRe = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$`)
	rangeRe   = regexp.MustCompile(`^([0-9]{1,5})-([0-9]{1,5})$`)
)

// ── config ────────────────────────────────────────────────────────────────────

type config struct {
	Panel     string `json:"panel"`                // https://psm.example.com
	Token     string `json:"token"`                // this server's agent token
	PSM       string `json:"psm,omitempty"`        // the psm command, /usr/local/bin/psm by default
	AllowHTTP bool   `json:"allow_http,omitempty"` // local testing only
	// The local page (local.go): where it listens (loopback only; "off" for
	// none) and its password (PBKDF2, set with psm-agent local-password). A
	// user paused on this server is PSM's own record (local_paused), not here.
	LocalAddr     string `json:"local_addr,omitempty"`
	LocalPassword string `json:"local_password,omitempty"`
}

func checkPanelURL(raw string, allowHTTP bool) (string, error) {
	u, err := url.Parse(strings.TrimRight(raw, "/"))
	if err != nil || u.Host == "" || u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("panel %q: not a URL like https://psm.example.com", raw)
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && allowHTTP) {
		return "", fmt.Errorf("panel %q: must be https://", raw)
	}
	return u.String(), nil
}

func loadConfig(path string) (*config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c config
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if c.Panel, err = checkPanelURL(c.Panel, c.AllowHTTP); err != nil {
		return nil, err
	}
	if len(c.Token) < 32 {
		return nil, errors.New("token: missing or too short; run psm-agent join")
	}
	if c.PSM == "" {
		c.PSM = "/usr/local/bin/psm"
	}
	return &c, nil
}

// saveConfig writes the config readable by root only, replacing it atomically.
func saveConfig(path string, c *config) error {
	raw, _ := json.MarshalIndent(c, "", "  ")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(raw, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ── talking to the panel ─────────────────────────────────────────────────────

// The panel learns this server's address from the connection (and keeps the
// node's DNS A record on it), so the agent reaches it over IPv4 when it can and
// falls back to anything else.
var client = &http.Client{Timeout: requestTimeout, Transport: ipv4First()}

func ipv4First() *http.Transport {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	d := &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}
	tr.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		if network == "tcp" {
			if c, err := d.DialContext(ctx, "tcp4", addr); err == nil {
				return c, nil
			}
		}
		return d.DialContext(ctx, network, addr)
	}
	return tr
}

// post sends a JSON body to the panel and decodes the JSON answer into out.
func post(ctx context.Context, panel, path, bearer string, body, out any) error {
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, panel+path, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "psm-agent/"+agentVersion)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxResponse))
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		var e struct {
			Error struct{ Message string } `json:"error"`
		}
		_ = json.Unmarshal(data, &e)
		return &httpError{status: resp.StatusCode, message: e.Error.Message}
	}
	return json.Unmarshal(data, out)
}

type httpError struct {
	status  int
	message string
}

func (e *httpError) Error() string { return fmt.Sprintf("panel answered %d: %s", e.status, e.message) }

// join trades a one-time join token for this server's agent token.
func join(ctx context.Context, cfgPath, panel, joinToken string, allowHTTP bool) error {
	panel, err := checkPanelURL(panel, allowHTTP)
	if err != nil {
		return err
	}
	host, _ := os.Hostname()
	var resp struct {
		AgentToken string                `json:"agent_token"`
		Server     struct{ Name string } `json:"server"`
	}
	req := map[string]string{"join_token": joinToken, "hostname": host, "agent_version": agentVersion}
	if err := post(ctx, panel, "/api/agent/join", "", req, &resp); err != nil {
		return err
	}
	if len(resp.AgentToken) < 32 {
		return errors.New("the panel returned no agent token")
	}
	if err := saveConfig(cfgPath, &config{Panel: panel, Token: resp.AgentToken, AllowHTTP: allowHTTP}); err != nil {
		return err
	}
	// a new enrollment: results and replays of an earlier one mean nothing to this panel
	_ = os.Remove(filepath.Join(filepath.Dir(cfgPath), "agent-tasks.json"))
	log.Printf("joined the panel as %s; config in %s", resp.Server.Name, cfgPath)
	return nil
}

// ── tasks ─────────────────────────────────────────────────────────────────────

type task struct {
	ID         int64           `json:"id"`
	UID        string          `json:"uid,omitempty"` // unique per task, whatever the panel's row numbering (a restored panel starts again at 1)
	Kind       string          `json:"kind"`
	Core       string          `json:"core,omitempty"`
	Protocol   string          `json:"protocol,omitempty"` // PSM's protocol; snell / ss2022 for standalone.*
	Tag        string          `json:"tag,omitempty"`      // the node's tag (its name in the panel)
	Data       json.RawMessage `json:"data,omitempty"`     // node settings
	Server     string          `json:"server,omitempty"`   // the address in exported links
	Mount443   bool            `json:"mount443,omitempty"` // share the public 443 by SNI (psm node add --mount-443)
	Recover    bool            `json:"recover,omitempty"`  // node.add: the panel is unsure the node is absent (a restore, an unrecorded result)
	Create     bool            `json:"create,omitempty"`   // standalone.install: the panel's first install, not a change of its own
	Format     string          `json:"format,omitempty"`   // uri | surge
	LimitBytes int64           `json:"limit_bytes,omitempty"`
	ResetDay   int             `json:"reset_day,omitempty"`
	CodeHash   string          `json:"code_hash,omitempty"`  // local.code: SHA-256 of the code, hex
	ExpiresAt  int64           `json:"expires_at,omitempty"` // local.code: when it stops working (unix seconds, from the panel)
}

type result struct {
	TaskID   int64           `json:"task_id"`
	UID      string          `json:"uid,omitempty"` // the task's uid: the panel takes the result only for that task
	OK       bool            `json:"ok"`
	Output   json.RawMessage `json:"output,omitempty"`
	Link     string          `json:"link,omitempty"`
	Outbound json.RawMessage `json:"outbound,omitempty"` // the node as a sing-box client outbound
	Clash    json.RawMessage `json:"clash,omitempty"`    // the node as a mihomo proxy (TLS protocols)
	Error    string          `json:"error,omitempty"`
}

// runner runs psm with the given arguments (and stdin, when not nil).
type runner func(ctx context.Context, stdin []byte, args ...string) (stdout, stderr []byte, err error)

func execRunner(bin string) runner {
	return func(ctx context.Context, stdin []byte, args ...string) ([]byte, []byte, error) {
		cmd := exec.CommandContext(ctx, bin, args...)
		cmd.Env = append(os.Environ(), "PSM_LANG=en", "LANG=C.UTF-8", "TERM=dumb")
		if stdin != nil {
			cmd.Stdin = bytes.NewReader(stdin)
		}
		var out, errOut bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &errOut
		err := cmd.Run()
		return out.Bytes(), errOut.Bytes(), err
	}
}

type agent struct {
	cfg         *config
	run         runner
	spawn       func(args ...string) error // starts a psm command that outlives psm-agent
	hostname    string
	pending     []result  // results not yet delivered to the panel (kept on disk: journal.go)
	recent      []result  // the last tasks' results, to answer a task handed out again
	lastTraffic time.Time // when the traffic counters last went to the panel
	psmVersion  string
	versionAt   time.Time
	leaving     bool // agent.leave ran: uninstall once its result is delivered
	left        bool // the uninstall has been started
	upgrading   bool // agent.update ran: upgrade once its result is delivered
	upgraded    bool // the upgrade has been started

	cfgPath  string     // where cfg lives; events are kept beside it
	mu       sync.Mutex // guards what the local page shares with the sync loop below
	events   []event    // what was done on the local page, until the panel confirms them
	codes    map[string]time.Time
	consumed map[string]time.Time // codes used, until they would have expired (kept on disk too)
	caps     map[string]bool      // what this server's PSM can do (psm caps); nil: not looked up yet
	eventErr string               // why the local page's changes could not be kept on disk, if they could not
	usersRev int64                // the user list revision PSM holds (-1: not known yet)
	lastSync time.Time            // the last sync the panel answered
	// serializes the commands that change the server: a task and a click on
	// the local page never run psm at the same time
	change sync.Mutex
}

// event is one thing done on this server's local page, reported with the next
// sync and kept (on disk) until the panel says it has recorded it.
type event struct {
	ID     string          `json:"id"`
	At     string          `json:"at"`
	Kind   string          `json:"kind"`
	Target string          `json:"target,omitempty"`
	Detail json.RawMessage `json:"detail,omitempty"`
}

// spawnDetached starts `psm <args>` outside psm-agent's service, so that it
// survives psm-agent being stopped by it: stopping a systemd service kills its
// whole cgroup (hence systemd-run, a unit of its own); OpenRC stops the process
// it started (a new session is enough).
func spawnDetached(psm string) func(args ...string) error {
	return func(args ...string) error {
		if _, err := os.Stat("/run/systemd/system"); err == nil {
			if sr, err := exec.LookPath("systemd-run"); err == nil {
				// a unit named after the command: leaving and upgrading must not
				// share one, or the second fails to start while the first is
				// still around
				unit := "psm-" + strings.Join(args[:min(2, len(args))], "-")
				return exec.Command(sr, append([]string{"--unit", unit, "--collect", "--quiet", psm}, args...)...).Run()
			}
		}
		cmd := exec.Command(psm, args...)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		return cmd.Start()
	}
}

// leavePlan is what agent.leave removes: the panel's own nodes (nodes made on
// the server's command line are not in it) and standalone servers.
type leavePlan struct {
	Nodes []struct {
		Core     string `json:"core"`
		Protocol string `json:"protocol"`
		Tag      string `json:"tag"`
	} `json:"nodes"`
	Standalone []string `json:"standalone"`
	// the relays this server carries; an agent too old to know the field just
	// ignores it and leaves the realm rules behind, as it did before
	Relays []string `json:"relays"`
}

func rejected(t task, why string) result {
	return result{TaskID: t.ID, Error: "rejected by psm-agent: " + why}
}

// checkNode validates a task's core, protocol and (when wanted) tag.
func checkNode(t task, withTag bool) string {
	switch {
	case !cores[t.Core]:
		return "unknown core " + t.Core
	case !protocols[t.Protocol]:
		return "unknown protocol " + t.Protocol
	case withTag && !tagRe.MatchString(t.Tag):
		return "bad tag " + t.Tag
	}
	return ""
}

// nodeData checks that a task's settings are one JSON object of sane size.

func nodeData(t task) (map[string]any, string) {
	if len(t.Data) == 0 || len(t.Data) > maxTaskData {
		return nil, "missing or oversized node settings"
	}
	var obj map[string]any
	if err := json.Unmarshal(t.Data, &obj); err != nil || obj == nil {
		return nil, "node settings are not a JSON object"
	}
	return obj, ""
}

func goodPort(v any) (int, bool) {
	p, ok := v.(float64)
	return int(p), ok && p == float64(int(p)) && p >= 1 && p <= 65535
}

// text reads a setting that may have been sent as a string or a number.
func text(obj map[string]any, key string) string {
	switch v := obj[key].(type) {
	case string:
		return v
	case float64:
		return strconv.FormatFloat(v, 'f', -1, 64)
	}
	return ""
}

// standaloneArgs turns a standalone.install task into the psm arguments.
func standaloneArgs(t task) ([]string, string) {
	obj, why := nodeData(t)
	if why != "" {
		return nil, why
	}
	port, ok := goodPort(obj["port"])
	if !ok {
		return nil, "bad port"
	}
	args := []string{"standalone", "install", t.Protocol, "--port", strconv.Itoa(port), "--json"}
	switch t.Protocol {
	case "snell":
		v := text(obj, "version")
		if v == "" {
			v = "5"
		}
		if !snellVersions[v] {
			return nil, "bad Snell version " + v
		}
		args = append(args, "--version", v)
		if psk := text(obj, "psk"); psk != "" {
			if !pskRe.MatchString(psk) {
				return nil, "bad PSK"
			}
			args = append(args, "--psk", psk)
		}
	case "ss2022":
		m := text(obj, "method")
		if m == "" {
			m = "2022-blake3-aes-128-gcm"
		}
		if !ssMethods[m] {
			return nil, "bad method " + m
		}
		args = append(args, "--method", m)
		if pw := text(obj, "password"); pw != "" {
			if !keyRe.MatchString(pw) {
				return nil, "bad password (a base64 key)"
			}
			args = append(args, "--password", pw)
		}
	}
	return args, ""
}

// psm runs one command; on failure the error is psm's own last line.
func (a *agent) psm(ctx context.Context, stdin []byte, args ...string) ([]byte, error) {
	return a.psmFor(ctx, commandTimeout, stdin, args...)
}

func (a *agent) psmFor(ctx context.Context, timeout time.Duration, stdin []byte, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	out, errOut, err := a.run(ctx, stdin, args...)
	if err != nil {
		if msg := lastLine(errOut); msg != "" {
			return nil, errors.New(msg)
		}
		return nil, err
	}
	return out, nil
}

// jsonPart runs a read-only command and returns its JSON output, or null. psm
// doctor exits non-zero when a check fails, yet its report is still wanted.
func (a *agent) jsonPart(ctx context.Context, args ...string) json.RawMessage {
	ctx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	out, _, _ := a.run(ctx, nil, args...)
	out = bytes.TrimSpace(out)
	if len(out) == 0 || !json.Valid(out) {
		return json.RawMessage("null")
	}
	return json.RawMessage(out)
}

// exported is a node as the panel's subscriptions carry it.
type exported struct {
	link     string
	outbound json.RawMessage // a sing-box client outbound, when sing-box has one for it
	clash    json.RawMessage // a mihomo proxy, for the TLS protocols (see psm node export --format clash)
}

// jsonOf is psm's output when it is one JSON value, else nil.
func jsonOf(out []byte, err error) json.RawMessage {
	if out = bytes.TrimSpace(out); err != nil || len(out) == 0 || !json.Valid(out) {
		return nil
	}
	return json.RawMessage(out)
}

// export returns a node's client link, sing-box outbound and mihomo proxy.
// standalone: the standalone server named by t.Protocol, shown in links as
// PSM-<tag> (no mihomo proxy: its share link imports as it is).
func (a *agent) export(ctx context.Context, t task, standalone bool) (exported, error) {
	format := t.Format
	if format == "" {
		format = "uri"
	}
	if format != "uri" && format != "surge" {
		return exported{}, errors.New("rejected by psm-agent: bad export format " + format)
	}
	if t.Server == "" || len(t.Server) > 253 || !hostRe.MatchString(t.Server) {
		return exported{}, errors.New("rejected by psm-agent: bad server address")
	}
	base := []string{"node", "export", t.Core, t.Protocol, t.Tag}
	if standalone {
		base = []string{"standalone", "export", t.Protocol, "--name", "PSM-" + t.Tag}
	}
	with := func(f string) []string {
		return append(append([]string{}, base...), "--format", f, "--server", t.Server)
	}
	out, err := a.psm(ctx, nil, with(format)...)
	if err != nil {
		return exported{}, err
	}
	e := exported{link: strings.TrimSpace(string(out))}
	e.outbound = jsonOf(a.psm(ctx, nil, with("singbox")...))
	if !standalone {
		e.clash = jsonOf(a.psm(ctx, nil, with("clash")...))
	}
	return e, nil
}

// status gathers what the panel shows for a server.
func (a *agent) status(ctx context.Context) json.RawMessage {
	raw, _ := json.Marshal(map[string]any{
		"psm_version":   a.version(ctx, true),
		"agent_version": agentVersion,
		"cores":         a.jsonPart(ctx, "core", "list", "--json"),
		"doctor":        a.jsonPart(ctx, "doctor", "--json"),
		"nodes":         a.jsonPart(ctx, "node", "list", "--json"),
		"traffic":       a.jsonPart(ctx, "traffic", "list", "--json"),
		"snell":         a.jsonPart(ctx, "standalone", "show", "snell", "--json"),
		"ss2022":        a.jsonPart(ctx, "standalone", "show", "ss2022", "--json"),
	})
	if len(raw) > maxReport {
		raw, _ = json.Marshal(map[string]any{"error": "status report too large"})
	}
	return raw
}

// upsert: a change whose node is gone (a restore, a rebuilt server) goes ahead
// as a create, with the same shared-443 mount. A create whose node is already
// here goes ahead as a change only when the panel says it is recovering (a
// restored panel, a result it could not record): a first create never takes
// over a node made on this server by hand (PSM refuses it as a conflict).
// When PSM can't say which, the task runs as it was sent.
//
// A first create of a node that is already here is a conflict: the node is
// someone else's (made with psm by hand), and the panel learns that, so it
// never removes it either. PSM itself would take an identical one as
// "unchanged", which would hand the panel a node that isn't its own.
func (a *agent) upsert(ctx context.Context, t task) (task, bool, error) {
	if checkNode(t, false) != "" {
		return t, false, nil // refused by the checks that follow
	}
	obj, why := nodeData(t)
	if why != "" {
		return t, false, nil
	}
	tag, _ := obj["tag"].(string)
	if !tagRe.MatchString(tag) || (t.Kind == "node.update" && tag != t.Tag) {
		return t, false, nil
	}
	// PSM can't say which nodes are here: nothing runs (a first create could
	// take over a node made by hand, a change could create one)
	has, err := a.hasNode(ctx, t.Core, t.Protocol, tag)
	if err != nil {
		return t, false, fmt.Errorf("could not read this server's nodes, nothing was changed: %w", err)
	}
	// A first create also needs the tag free on every core: PSM meters and
	// grants by tag, so a node of the same name made by hand on another core
	// would share the panel node's meter.
	if t.Kind == "node.add" && !t.Recover && !has {
		any, err := a.hasNode(ctx, "", "", tag)
		if err != nil {
			return t, false, fmt.Errorf("could not read this server's nodes, nothing was changed: %w", err)
		}
		if any {
			return t, true, nil
		}
	}
	switch {
	case t.Kind == "node.add" && has && t.Recover:
		t.Kind, t.Tag = "node.update", tag
	case t.Kind == "node.add" && has:
		return t, true, nil
	case t.Kind == "node.update" && !has:
		t.Kind = "node.add"
	}
	return t, false, nil
}

// conflicted: a create refused because what it would make is already here and
// not the panel's. The panel marks its node so that removing it never touches
// the other one.
func conflicted(r result, why string) result {
	r.Error, r.Output = why, json.RawMessage(`{"conflict":true}`)
	return r
}

// hasStandalone says whether a standalone server (Snell, ss-rust) is installed.
func (a *agent) hasStandalone(ctx context.Context, protocol string) (bool, error) {
	out, err := a.psm(ctx, nil, "standalone", "show", protocol, "--json")
	if err != nil {
		return false, err
	}
	// any sign of one counts: a Docker install shows as active and
	// configured with no native binary (installed:false)
	var s struct {
		Installed  *bool `json:"installed"`
		Active     bool  `json:"active"`
		Configured bool  `json:"configured"`
	}
	if json.Unmarshal(out, &s) != nil || s.Installed == nil {
		return false, fmt.Errorf("psm standalone show: unreadable output")
	}
	return *s.Installed || s.Active || s.Configured, nil
}

// hasNode: is a node with this tag on this server, for this core and protocol
// (both empty: on any core).
func (a *agent) hasNode(ctx context.Context, core, protocol, tag string) (bool, error) {
	args := []string{"node", "list", "--json"}
	if core != "" {
		args = append(args, "--core", core, "--protocol", protocol)
	}
	out, err := a.psm(ctx, nil, args...)
	if err != nil {
		return false, err
	}
	var list struct {
		Items *[]struct {
			Core     string `json:"core"`
			Protocol string `json:"protocol"`
			Tag      string `json:"tag"`
		} `json:"items"`
	}
	if err := json.Unmarshal(out, &list); err != nil || list.Items == nil {
		return false, fmt.Errorf("psm node list: unreadable output")
	}
	for _, it := range *list.Items {
		if it.Tag == tag && (core == "" || (it.Core == core && it.Protocol == protocol)) {
			return true, nil
		}
	}
	return false, nil
}

// execute runs one task and says how it went. A task that fails the checks
// never reaches psm.
func (a *agent) execute(ctx context.Context, t task) result {
	a.change.Lock()
	defer a.change.Unlock()
	r := result{TaskID: t.ID}
	fail := func(err error) result { r.Error = err.Error(); return r }
	if t.Kind == "node.add" || t.Kind == "node.update" {
		var conflict bool
		var err error
		if t, conflict, err = a.upsert(ctx, t); err != nil {
			return fail(err)
		} else if conflict {
			return conflicted(r, "a node with this tag is already on this server, not made by the panel: it is left alone (rename the panel's node, or remove the other one with psm node delete)")
		}
	}
	switch t.Kind {
	case "node.add":
		if why := checkNode(t, false); why != "" {
			return rejected(t, why)
		}
		obj, why := nodeData(t)
		if why != "" {
			return rejected(t, why)
		}
		tag, _ := obj["tag"].(string)
		if !tagRe.MatchString(tag) {
			return rejected(t, "bad tag "+tag)
		}
		if _, ok := goodPort(obj["port"]); !ok {
			return rejected(t, "bad port")
		}
		ownSite, borrowed := obj["own_site"] == true, borrowedOf(obj)
		if why := a.ownSiteReady(ctx, t.Protocol, obj); why != "" {
			return rejected(t, why)
		}
		// a server that has never run this core gets it first
		if _, err := a.psmFor(ctx, installTimeout, nil, "core", "install", t.Core, "--if-missing", "--json"); err != nil {
			return fail(fmt.Errorf("installing %s: %w", t.Core, err))
		}
		// Sharing the public 443 is not a node setting but how the node is made:
		// PSM puts it on 127.0.0.1 and routes 443 to it by SNI.
		args := []string{"node", "add", t.Core, t.Protocol, "--input", "-", "--json"}
		if t.Mount443 {
			args = append(args, "--mount-443")
		}
		// the long timeout: a node whose exit is the residential tunnel connects it first
		out, err := a.psmFor(ctx, installTimeout, t.Data, args...)
		if err != nil {
			// it was not here before this create (upsert): if it is now, the
			// create half ran, and the node is the panel's
			if has, herr := a.hasNode(ctx, t.Core, t.Protocol, tag); herr == nil && has {
				r.Output = json.RawMessage(`{"created":true}`)
			}
			return fail(err)
		}
		// REALITY on its own site: what PSM stored must fall back to this server
		// only (a borrowed site: to that site only); anything else is taken
		// down again and reported
		if ownSite || borrowed != "" {
			if why := a.ownSiteHolds(ctx, t.Core, t.Protocol, tag, borrowed); why != "" {
				if _, err := a.psm(ctx, nil, "node", "delete", t.Core, t.Protocol, tag, "--yes", "--if-exists", "--json"); err != nil {
					// still here, and made by this create: the panel's to remove
					r.Output = json.RawMessage(`{"created":true}`)
					return fail(fmt.Errorf("%s, and it could not be removed: %v (its core will not start with it: PSM refuses such a config)", why, err))
				}
				return fail(errors.New(why + ": the node was removed"))
			}
		}
		r.OK, r.Output = true, jsonOrNil(out)
		if t.Server != "" { // the client link, for the panel's subscription
			t.Tag = tag
			if e, err := a.export(ctx, t, false); err == nil {
				r.Link, r.Outbound, r.Clash = e.link, e.outbound, e.clash
			} else {
				log.Printf("task %d: node added, export failed: %v", t.ID, err)
			}
		}
	case "node.update":
		if why := checkNode(t, true); why != "" {
			return rejected(t, why)
		}
		upd, why := nodeData(t)
		if why != "" {
			return rejected(t, why)
		}
		if why := a.ownSiteReady(ctx, t.Protocol, upd); why != "" {
			return rejected(t, why)
		}
		out, err := a.psmFor(ctx, installTimeout, t.Data, "node", "update", t.Core, t.Protocol, t.Tag, "--input", "-", "--json")
		if err != nil {
			return fail(err)
		}
		if upd["own_site"] == true || borrowedOf(upd) != "" {
			if why := a.ownSiteHolds(ctx, t.Core, t.Protocol, t.Tag, borrowedOf(upd)); why != "" {
				return fail(errors.New(why + " (the node is still there; its core will not start with it: PSM refuses such a config)"))
			}
		}
		r.OK, r.Output = true, jsonOrNil(out)
		if t.Server != "" {
			if e, err := a.export(ctx, t, false); err == nil {
				r.Link, r.Outbound, r.Clash = e.link, e.outbound, e.clash
			}
		}
	case "node.delete":
		if why := checkNode(t, true); why != "" {
			return rejected(t, why)
		}
		out, err := a.psm(ctx, nil, "node", "delete", t.Core, t.Protocol, t.Tag, "--yes", "--if-exists", "--json")
		if err != nil {
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
	case "node.export":
		if why := checkNode(t, true); why != "" {
			return rejected(t, why)
		}
		e, err := a.export(ctx, t, false)
		if err != nil {
			return fail(err)
		}
		r.OK, r.Link, r.Outbound, r.Clash = true, e.link, e.outbound, e.clash
	case "standalone.install":
		if !standalones[t.Protocol] {
			return rejected(t, "not a standalone server: "+t.Protocol)
		}
		if !tagRe.MatchString(t.Tag) {
			return rejected(t, "bad tag "+t.Tag)
		}
		args, why := standaloneArgs(t)
		if why != "" {
			return rejected(t, why)
		}
		// the panel's first install never replaces one that is already here
		// (its key would change under whoever uses it)
		if t.Create {
			has, err := a.hasStandalone(ctx, t.Protocol)
			if err != nil {
				return fail(fmt.Errorf("could not tell whether %s is installed, nothing was changed: %w", t.Protocol, err))
			}
			if has {
				return conflicted(r, t.Protocol+" is already installed on this server, not by the panel: it is left alone")
			}
			// its traffic meter is named after the protocol: a core node of
			// that name (an older install's) would share it
			if any, err := a.hasNode(ctx, "", "", t.Protocol); err != nil {
				return fail(fmt.Errorf("could not read this server's nodes, nothing was changed: %w", err))
			} else if any {
				return conflicted(r, "a node called "+t.Protocol+" is on this server, and the standalone server's traffic meter has that name: it is left alone")
			}
		}
		out, err := a.psmFor(ctx, installTimeout, nil, args...)
		if err != nil {
			// a first install that failed half way may have left it here: the
			// panel then owns it (and removes it when asked)
			if has, herr := a.hasStandalone(ctx, t.Protocol); t.Create && herr == nil && has {
				r.Output = json.RawMessage(`{"created":true}`)
			}
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
		if t.Server != "" {
			if e, err := a.export(ctx, t, true); err == nil {
				r.Link, r.Outbound = e.link, e.outbound
			} else {
				log.Printf("task %d: %s installed, export failed: %v", t.ID, t.Protocol, err)
			}
		}
	case "standalone.remove":
		if !standalones[t.Protocol] {
			return rejected(t, "not a standalone server: "+t.Protocol)
		}
		out, err := a.psmFor(ctx, installTimeout, nil, "standalone", "remove", t.Protocol, "--yes", "--json")
		if err != nil {
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
	case "relay.add", "relay.update":
		// roomkey does not forward ports: a public forward hands whatever is
		// behind it to anyone. Existing relay rules can only be removed.
		return rejected(t, "relays are off in roomkey: a relay can only be removed")
	case "relay.delete":
		if !tagRe.MatchString(t.Tag) {
			return rejected(t, "bad tag "+t.Tag)
		}
		out, err := a.psm(ctx, nil, "relay", "delete", t.Tag, "--yes", "--if-exists", "--json")
		if err != nil {
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
	case "relay.list":
		out, err := a.psm(ctx, nil, "relay", "list", "--json")
		if err != nil {
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
	case "traffic.set":
		if !tagRe.MatchString(t.Tag) {
			return rejected(t, "bad tag "+t.Tag)
		}
		if t.LimitBytes < 0 || t.LimitBytes > maxLimitBytes {
			return rejected(t, "bad traffic limit")
		}
		if t.ResetDay < 0 || t.ResetDay > 28 {
			return rejected(t, "bad reset day")
		}
		args := []string{"traffic", "set", t.Tag, "--limit-bytes", strconv.FormatInt(t.LimitBytes, 10), "--json"}
		if t.ResetDay > 0 {
			args = append(args, "--reset-day", strconv.Itoa(t.ResetDay))
		}
		out, err := a.psm(ctx, nil, args...)
		if err != nil {
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
		a.lastTraffic = time.Time{} // the next sync carries the counters
	case "traffic.reset":
		if !tagRe.MatchString(t.Tag) {
			return rejected(t, "bad tag "+t.Tag)
		}
		out, err := a.psm(ctx, nil, "traffic", "reset", t.Tag, "--json")
		if err != nil {
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
		a.lastTraffic = time.Time{}
	case "agent.leave":
		var plan leavePlan
		if len(t.Data) > maxTaskData || json.Unmarshal(t.Data, &plan) != nil {
			return rejected(t, "bad leave plan")
		}
		// every entry is checked before anything is removed
		for _, n := range plan.Nodes {
			if why := checkNode(task{Core: n.Core, Protocol: n.Protocol, Tag: n.Tag}, true); why != "" {
				return rejected(t, why)
			}
		}
		for _, p := range plan.Standalone {
			if !standalones[p] {
				return rejected(t, "not a standalone server: "+p)
			}
		}
		for _, tag := range plan.Relays {
			if !tagRe.MatchString(tag) {
				return rejected(t, "bad relay tag "+tag)
			}
		}
		removed, failed := []string{}, []string{}
		// each user's last reading, so the panel counts the use since the last
		// report toward this period before the server goes
		usage := a.jsonPart(ctx, "user", "usage", "--json")
		// the panel's users go first: once the server has left, nothing could
		// revoke them (users made on the server itself stay)
		if out, err := a.psmFor(ctx, installTimeout, nil, "user", "purge", "--json"); err != nil {
			failed = append(failed, "panel users: "+err.Error())
		} else {
			// purge's own reading, after its last checkpoint, is the later one
			var p struct {
				Usage json.RawMessage `json:"usage"`
			}
			if json.Unmarshal(out, &p) == nil && len(p.Usage) > 0 && string(p.Usage) != "null" {
				usage = p.Usage
			}
			removed = append(removed, "panel users")
		}
		for _, n := range plan.Nodes {
			if _, err := a.psm(ctx, nil, "node", "delete", n.Core, n.Protocol, n.Tag, "--yes", "--if-exists", "--json"); err != nil {
				failed = append(failed, n.Tag+": "+err.Error())
			} else {
				removed = append(removed, n.Tag)
			}
		}
		for _, p := range plan.Standalone {
			if _, err := a.psmFor(ctx, installTimeout, nil, "standalone", "remove", p, "--yes", "--json"); err != nil {
				failed = append(failed, p+": "+err.Error())
			} else {
				removed = append(removed, p)
			}
		}
		// the realm rules and the accounting rules that go with them
		for _, tag := range plan.Relays {
			if _, err := a.psm(ctx, nil, "relay", "delete", tag, "--yes", "--if-exists", "--json"); err != nil {
				failed = append(failed, tag+": "+err.Error())
			} else {
				removed = append(removed, tag)
			}
		}
		out, _ := json.Marshal(map[string]any{"removed": removed, "failed": failed, "usage": usage})
		r.Output = out
		if len(failed) > 0 {
			// the server stays joined, the failure shown in the panel, so the
			// removal can be tried again (or the server removed from the panel only)
			r.Error = "could not remove everything: " + strings.Join(failed, "; ")
			return r
		}
		r.OK = true
		a.leaving = true
	case "agent.update":
		// Nothing is done here: the upgrade replaces this very binary and
		// restarts the service, which would kill the process before it could
		// report. psm agent upgrade is started detached once the panel has this
		// result, the way agent.leave's uninstall is.
		r.OK, r.Output = true, json.RawMessage(`{"from":"`+agentVersion+`"}`)
		a.upgrading = true
	case "check.run":
		// The IP's owner, registry, kind and risk, mail and blacklists, and
		// which streaming and AI services let it in: all of it, or one address
		// family. The optional API keys travel on stdin only.
		var q struct {
			Family string            `json:"family"`
			Keys   map[string]string `json:"keys"`
		}
		if len(t.Data) > 0 && json.Unmarshal(t.Data, &q) != nil {
			return rejected(t, "check.run: bad data")
		}
		args := []string{"check", "all", "--json"}
		switch q.Family {
		case "":
		case "4", "6":
			args = append(args, "-"+q.Family)
		default:
			return rejected(t, "check.run: family is 4 or 6")
		}
		var stdin []byte
		if len(q.Keys) > 0 {
			var lines []string
			for _, name := range []string{"abuseipdb", "ipqs", "ip2location"} {
				k, ok := q.Keys[name]
				if !ok || k == "" {
					continue
				}
				if !checkKeyRe.MatchString(k) {
					return rejected(t, "check.run: the "+name+" key is not a key")
				}
				lines = append(lines, strings.ToUpper(name)+"="+k)
			}
			if len(lines) > 0 {
				args = append(args, "--keys-stdin")
				stdin = []byte(strings.Join(lines, "\n") + "\n")
			}
		}
		out, err := a.psmFor(ctx, checkTimeout, stdin, args...)
		if err != nil {
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
	case "reality.probe":
		// Whether sites work as a borrowed REALITY site, seen from this server
		// (TLS 1.3, X25519, its certificate, HTTP/2, a shared CDN frontend):
		// read-only, the panel's 探测 and 扫描 buttons. One site or up to 12,
		// each its own psm reality probe; the answer is their list.
		var q struct {
			Host  string   `json:"host"`
			Hosts []string `json:"hosts"`
		}
		if json.Unmarshal(t.Data, &q) != nil {
			return rejected(t, "reality.probe: bad data")
		}
		hosts := q.Hosts
		if q.Host != "" {
			hosts = append([]string{q.Host}, hosts...)
		}
		if len(hosts) == 0 || len(hosts) > 12 {
			return rejected(t, "reality.probe: 1 to 12 domains")
		}
		for i, h := range hosts {
			hosts[i] = strings.ToLower(h)
			if !borrowedSiteRe.MatchString(hosts[i]) || len(hosts[i]) > 253 {
				return rejected(t, "reality.probe: a domain, such as www.samsung.com")
			}
		}
		if !a.capsHave(ctx, "reality.probe") {
			return rejected(t, "this server's PSM cannot probe sites: update PSM (psm agent upgrade)")
		}
		var all []json.RawMessage
		for _, h := range hosts {
			out, err := a.psmFor(ctx, probeTimeout, nil, "reality", "probe", h, "--json")
			if err != nil {
				b, _ := json.Marshal(map[string]any{"host": h, "ok": false, "reason": err.Error()})
				all = append(all, b)
				continue
			}
			if o := jsonOrNil(out); o != nil {
				all = append(all, o)
			}
		}
		b, _ := json.Marshal(map[string]any{"sites": all})
		r.OK, r.Output = true, b
	case "traffic.report": // the panel's 流量 page asks for the counters now
		a.lastTraffic = time.Time{}
		r.OK = true
	case "status":
		r.OK, r.Output = true, a.status(ctx)
	case "user.sync":
		in, why := a.userSyncInput(t.Data)
		if why != "" {
			return rejected(t, why)
		}
		if !a.capsHave(ctx, "users.import.revision") {
			return rejected(t, "this server's PSM does not take numbered user lists: update PSM (psm agent upgrade)")
		}
		out, err := a.psm(ctx, in, "user", "import", "--json")
		if err != nil {
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
		var imp struct {
			Revision *int64 `json:"revision"`
		}
		if json.Unmarshal(out, &imp) == nil && imp.Revision != nil {
			a.mu.Lock()
			a.usersRev = *imp.Revision
			a.mu.Unlock()
		}
		a.lastTraffic = time.Time{} // the next sync carries the users' counters
	case "local.code":
		// the deadline is the panel's, not counted from when the code arrives: a
		// code queued while this server was offline does not come back to life
		exp := time.Unix(t.ExpiresAt, 0)
		if !pinRe.MatchString(t.CodeHash) || time.Until(exp) > time.Hour {
			return rejected(t, "bad local code")
		}
		if time.Now().After(exp) {
			return rejected(t, "local code arrived after it expired")
		}
		h := strings.ToLower(t.CodeHash)
		a.mu.Lock()
		if a.codes == nil {
			a.codes = map[string]time.Time{}
		}
		a.loadConsumedLocked()
		for k, e := range a.codes {
			if time.Now().After(e) {
				delete(a.codes, k)
			}
		}
		for k, e := range a.consumed {
			if time.Now().After(e) {
				delete(a.consumed, k)
			}
		}
		// a task delivered again — even after a restart — must not bring back a
		// code already used
		a.loadConsumedLocked()
		if _, used := a.consumed[h]; !used {
			a.codes[h] = exp
		}
		a.mu.Unlock()
		r.OK = true
	default:
		return rejected(t, "unsupported task kind "+t.Kind)
	}
	return r
}

func jsonOrNil(b []byte) json.RawMessage {
	if json.Valid(b) {
		return json.RawMessage(bytes.TrimSpace(b))
	}
	return nil
}

func lastLine(b []byte) string {
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

// version is PSM's version ("2026-09-15 abc1234"), looked up once an hour.
func (a *agent) version(ctx context.Context, fresh bool) string {
	a.mu.Lock()
	due := fresh || time.Since(a.versionAt) >= versionEvery
	a.mu.Unlock()
	if due {
		out, err := a.psm(ctx, nil, "version")
		a.mu.Lock()
		if err == nil {
			a.psmVersion = strings.TrimSpace(string(out))
		}
		a.versionAt = time.Now()
		a.caps = nil // looked up again when next needed: PSM may have been updated
		a.mu.Unlock()
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.psmVersion
}

// ── the sync loop ─────────────────────────────────────────────────────────────

// step is one sync: deliver pending results (and, when due, the traffic
// counters), take and run new tasks. It says how long to wait before the next
// one. Results survive a failed sync.
// resultsPerSync: how many task results one sync delivers (see step).
const resultsPerSync = 5

func (a *agent) step(ctx context.Context) (time.Duration, error) {
	var resp struct {
		Interval    int      `json:"interval"`
		Tasks       []task   `json:"tasks"`
		EventsAcked []string `json:"events_acked"`
	}
	// A few results per sync (the rest go with the next ones, right after):
	// each costs the panel several D1 queries, and the Workers free plan
	// allows 50 per request. A leave or an upgrade goes whole: its answer
	// must arrive in the sync that carries it.
	batch := a.pending
	if len(batch) > resultsPerSync && !a.leaving && !a.upgrading {
		batch = batch[:resultsPerSync]
	}
	req := map[string]any{"agent_version": agentVersion, "hostname": a.hostname, "results": batch}
	if batch == nil {
		req["results"] = []result{}
	}
	if v := a.version(ctx, false); v != "" {
		req["psm_version"] = v
	}
	trafficDue := time.Since(a.lastTraffic) >= trafficEvery
	if trafficDue {
		if tr := a.jsonPart(ctx, "traffic", "list", "--json"); string(tr) != "null" {
			req["traffic"] = tr
		}
		// each user's counter (only grows) and their client IPs now
		if us := a.jsonPart(ctx, "user", "usage", "--json"); string(us) != "null" {
			req["users"] = us
			var u struct {
				Revision *int64 `json:"revision"`
			}
			if json.Unmarshal(us, &u) == nil && u.Revision != nil {
				a.mu.Lock()
				a.usersRev = *u.Revision
				a.mu.Unlock()
			}
		}
		if on := a.jsonPart(ctx, "user", "online", "--json"); string(on) != "null" {
			req["online"] = on
		}
	}
	a.mu.Lock()
	if len(a.events) > 0 {
		req["events"] = append([]event(nil), a.events[:min(len(a.events), 100)]...)
	}
	// which user list PSM holds: the panel sends it again when this is behind
	// (a server rebuilt, or a list that never arrived)
	if a.usersRev >= 0 {
		req["users_rev"] = a.usersRev
	}
	a.mu.Unlock()
	delivering := a.leaving  // this sync carries agent.leave's result
	upgrading := a.upgrading // … or agent.update's
	if err := post(ctx, a.cfg.Panel, "/api/agent/sync", a.cfg.Token, req, &resp); err != nil {
		// The panel deletes the server, and with it this agent's token, when it
		// takes the leave result. If its answer was lost, the next try is
		// refused: that refusal is the confirmation (the users are purged already).
		var he *httpError
		if !(delivering && errors.As(err, &he) && he.status == http.StatusUnauthorized) {
			return 0, err
		}
		resp.Tasks, resp.EventsAcked = nil, nil
	}
	if len(batch) > 0 {
		if rest := a.pending[len(batch):]; len(rest) > 0 {
			a.pending = append([]result(nil), rest...)
		} else {
			a.pending = nil
		}
		a.saveJournal()
	}
	a.mu.Lock()
	a.lastSync = time.Now()
	a.mu.Unlock()
	if len(resp.EventsAcked) > 0 {
		a.ackEvents(resp.EventsAcked)
	}
	if trafficDue {
		a.lastTraffic = time.Now()
	}
	if delivering {
		// the panel has the result: uninstall psm-agent (which stops this process)
		a.left = true
		if a.spawn != nil {
			if err := a.spawn("agent", "remove", "--yes"); err != nil {
				log.Printf("could not start psm agent remove: %v", err)
			}
		}
		return 0, nil
	}
	if upgrading {
		// the panel has the result: psm agent upgrade updates PSM, installs the
		// psm-agent that PSM then names and restarts the service — stopping
		// this process. Cleared either way: a spawn that failed must not make
		// every later sync try again.
		a.upgrading, a.upgraded = false, true
		a.saveJournal()
		if a.spawn != nil {
			if err := a.spawn("agent", "upgrade", "--yes"); err != nil {
				log.Printf("could not start psm agent upgrade: %v", err)
			}
		}
		return 0, nil
	}
	for _, t := range resp.Tasks {
		// once the server has left (its panel users purged), nothing else in
		// the batch runs: a user list after the purge would bring them back
		if a.leaving {
			r := rejected(t, "the server is leaving the panel")
			r.UID = t.UID
			a.ran(r)
			continue
		}
		// handed out again (its result was lost on the way): the same answer, not a second run
		if r, ok := a.replayed(t); ok {
			log.Printf("task %d %s: ran before, its result is sent again", t.ID, t.Kind)
			a.pending = append(a.pending, r)
			continue
		}
		r := a.execute(ctx, t)
		r.TaskID, r.UID = t.ID, t.UID
		log.Printf("task %d %s %s/%s %s: ok=%v %s", t.ID, t.Kind, t.Core, t.Protocol, t.Tag, r.OK, r.Error)
		a.ran(r)
	}
	if len(a.pending) > 0 {
		return 0, nil // report right away
	}
	interval := time.Duration(resp.Interval) * time.Second
	if interval < 3*time.Second || interval > 5*time.Minute {
		interval = defaultInterval
	}
	return interval, nil
}

func (a *agent) loop(ctx context.Context) {
	backoff := 5 * time.Second
	for {
		wait, err := a.step(ctx)
		if a.left {
			log.Printf("removed from the panel: psm-agent is uninstalling itself")
			<-ctx.Done() // `psm agent remove` stops this service
			return
		}
		if err != nil {
			var he *httpError
			if errors.As(err, &he) && he.status == http.StatusUnauthorized {
				log.Printf("the panel refused this agent's token; run psm-agent join again (%v)", err)
				wait = 5 * time.Minute
			} else {
				log.Printf("sync failed: %v", err)
				wait = backoff
				backoff = min(backoff*2, time.Minute)
			}
		} else {
			backoff = 5 * time.Second
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}

func main() {
	log.SetFlags(log.LstdFlags)
	if len(os.Args) > 1 && (os.Args[1] == "-version" || os.Args[1] == "--version" || os.Args[1] == "version") {
		fmt.Println(agentVersion)
		return
	}
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: psm-agent join -panel URL -token JOIN_TOKEN | psm-agent run | psm-agent local-password < PASSWORD | psm-agent version")
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	switch os.Args[1] {
	case "join":
		fs := flag.NewFlagSet("join", flag.ExitOnError)
		cfgPath := fs.String("config", defaultConfig, "config file to write")
		panel := fs.String("panel", "", "the panel's address, https://…")
		token := fs.String("token", "", "the one-time join token from the install command (or PSM_AGENT_TOKEN)")
		allowHTTP := fs.Bool("allow-http", false, "accept an http:// panel (local testing only)")
		_ = fs.Parse(os.Args[2:])
		// from the environment, psm agent join passes it: a command line is
		// there for every local user to read in ps
		if *token == "" {
			*token = os.Getenv("PSM_AGENT_TOKEN")
		}
		if *panel == "" || *token == "" {
			log.Fatal("psm-agent join: -panel and -token (or PSM_AGENT_TOKEN) are required")
		}
		if err := join(ctx, *cfgPath, *panel, *token, *allowHTTP); err != nil {
			log.Fatalf("psm-agent join: %v", err)
		}
	case "run":
		fs := flag.NewFlagSet("run", flag.ExitOnError)
		cfgPath := fs.String("config", defaultConfig, "config file")
		_ = fs.Parse(os.Args[2:])
		cfg, err := loadConfig(*cfgPath)
		if err != nil {
			log.Fatalf("psm-agent: %v", err)
		}
		host, _ := os.Hostname()
		log.Printf("psm-agent %s syncing with %s", agentVersion, cfg.Panel)
		a := &agent{cfg: cfg, cfgPath: *cfgPath, run: execRunner(cfg.PSM), spawn: spawnDetached(cfg.PSM), hostname: host, usersRev: -1}
		a.loadEvents()
		a.loadJournal()
		go a.serveLocal(ctx)
		a.loop(ctx)
	case "local-password":
		// the local page's password, read from stdin (never from argv: ps shows that)
		fs := flag.NewFlagSet("local-password", flag.ExitOnError)
		cfgPath := fs.String("config", defaultConfig, "config file")
		_ = fs.Parse(os.Args[2:])
		cfg, err := loadConfig(*cfgPath)
		if err != nil {
			log.Fatalf("psm-agent: %v", err)
		}
		pw, _ := io.ReadAll(io.LimitReader(os.Stdin, 1024))
		p := strings.TrimRight(string(pw), "\r\n")
		if len(p) < 10 {
			log.Fatal("psm-agent local-password: give a password of 10 or more characters on stdin")
		}
		cfg.LocalPassword = hashPassword(p)
		if err := saveConfig(*cfgPath, cfg); err != nil {
			log.Fatalf("psm-agent: %v", err)
		}
		fmt.Println("local page password saved; restart psm-agent to use it")
	default:
		log.Fatalf("psm-agent: unknown command %q", os.Args[1])
	}
}
