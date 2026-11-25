// The local page: a small web page on this server for the simple things —
// what runs, restart a core, read its log, change a node's port or name, see
// the panel's users here and switch one off on this server only.
//
// It listens on loopback only (127.0.0.1:2096 by default) and is reached
// through an SSH tunnel:
//
//	ssh -L 2096:127.0.0.1:2096 root@server   →   http://127.0.0.1:2096
//
// Sign-in takes the password set with `psm-agent local-password`, or a
// one-time code the panel hands out (local.code task). Everything it does runs
// a psm command, checked as strictly as a panel task, and is reported to the
// panel (kept on disk until the panel confirms it), so the central view stays
// right. The panel stays in charge of users: the page can only pause one on
// this server (PSM's local_paused) and lift that same pause — never enable a
// user the panel switched off.
package main

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

//go:embed local
var localFiles embed.FS

const (
	defaultLocalAddr = "127.0.0.1:2096"
	sessionTTL       = 12 * time.Hour
	maxLoginFailures = 5 // per minute, then 429
	pbkdf2Iterations = 210000
	maxLocalBody     = 16 << 10
	maxEvents        = 500 // the local page's changes waiting for the panel
)

var userNameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,31}$`)

// ── passwords ─────────────────────────────────────────────────────────────────

// pbkdf2SHA256 is PBKDF2 (RFC 8018) with HMAC-SHA-256, one block (32 bytes).
func pbkdf2SHA256(password, salt []byte, iter int) []byte {
	mac := hmac.New(sha256.New, password)
	mac.Write(salt)
	mac.Write([]byte{0, 0, 0, 1})
	u := mac.Sum(nil)
	out := append([]byte(nil), u...)
	for i := 1; i < iter; i++ {
		mac.Reset()
		mac.Write(u)
		u = mac.Sum(u[:0])
		for j := range out {
			out[j] ^= u[j]
		}
	}
	return out
}

// hashPassword → "pbkdf2-sha256$ITER$SALT$HASH" (base64url).
func hashPassword(p string) string {
	salt := make([]byte, 16)
	_, _ = rand.Read(salt)
	enc := base64.RawURLEncoding
	return fmt.Sprintf("pbkdf2-sha256$%d$%s$%s", pbkdf2Iterations, enc.EncodeToString(salt),
		enc.EncodeToString(pbkdf2SHA256([]byte(p), salt, pbkdf2Iterations)))
}

func checkPassword(stored, p string) bool {
	parts := strings.Split(stored, "$")
	if len(parts) != 4 || parts[0] != "pbkdf2-sha256" {
		return false
	}
	iter, err := strconv.Atoi(parts[1])
	if err != nil || iter < 1000 || iter > 10_000_000 {
		return false
	}
	enc := base64.RawURLEncoding
	salt, err1 := enc.DecodeString(parts[2])
	want, err2 := enc.DecodeString(parts[3])
	if err1 != nil || err2 != nil {
		return false
	}
	return subtle.ConstantTimeCompare(pbkdf2SHA256([]byte(p), salt, iter), want) == 1
}

// ── users from the panel ──────────────────────────────────────────────────────

// userSyncInput checks a user.sync task's users (psm checks every field
// again) and passes the list on unchanged: a pause made on this server lives
// in PSM's store and survives the import there.
func (a *agent) userSyncInput(data json.RawMessage) ([]byte, string) {
	if len(data) == 0 || len(data) > maxUserData {
		return nil, "user.sync needs its users (at most 1 MiB)"
	}
	var in struct {
		Revision int64            `json:"revision"`
		Users    []map[string]any `json:"users"`
	}
	if err := json.Unmarshal(data, &in); err != nil || in.Users == nil || in.Revision < 0 {
		return nil, "user.sync: not {\"revision\": n, \"users\": [...]}"
	}
	for _, u := range in.Users {
		name, _ := u["name"].(string)
		if !userNameRe.MatchString(name) {
			return nil, "user.sync: bad user name"
		}
	}
	return data, ""
}

// ── the server ────────────────────────────────────────────────────────────────

type localState struct {
	sessions map[string]time.Time
	failures []time.Time
}

// localAddr is where the page listens, or "" for no page. Only a loopback
// address is accepted: the page must never be reachable from the internet.
func localAddr(cfg *config) (string, error) {
	addr := cfg.LocalAddr
	if addr == "off" {
		return "", nil
	}
	if addr == "" {
		addr = defaultLocalAddr
	}
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return "", fmt.Errorf("local_addr %q: %w", addr, err)
	}
	if n, err := strconv.Atoi(port); err != nil || n < 1 || n > 65535 {
		return "", fmt.Errorf("local_addr %q: bad port", addr)
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return "", fmt.Errorf("local_addr %q: only a loopback address (127.0.0.1 or ::1) is allowed", addr)
	}
	return addr, nil
}

func (a *agent) serveLocal(ctx context.Context) {
	addr, err := localAddr(a.cfg)
	if err != nil {
		log.Printf("local page off: %v", err)
		return
	}
	if addr == "" {
		return
	}
	srv := &http.Server{Addr: addr, Handler: a.localHandler(addr), ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout: 30 * time.Second, WriteTimeout: 10 * time.Minute}
	go func() { <-ctx.Done(); _ = srv.Close() }()
	log.Printf("local page on http://%s (reach it through an SSH tunnel)", addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Printf("local page: %v", err)
	}
}

func (a *agent) localHandler(addr string) http.Handler {
	st := &localState{sessions: map[string]time.Time{}}
	_, port, _ := net.SplitHostPort(addr)
	// DNS rebinding: a page elsewhere that points a name at 127.0.0.1 still
	// sends its own name as the Host
	okHost := map[string]bool{addr: true, "localhost:" + port: true, "127.0.0.1:" + port: true, "[::1]:" + port: true}
	static, _ := fs.Sub(localFiles, "local")
	files := http.FileServer(http.FS(static))
	mux := http.NewServeMux()

	mux.HandleFunc("/api/session", func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		hasPassword := a.cfg.LocalPassword != ""
		a.mu.Unlock()
		writeJSON(w, 200, map[string]any{"authenticated": st.valid(a, r), "password_set": hasPassword,
			"hostname": a.hostname, "agent_version": agentVersion})
	})
	mux.HandleFunc("/api/login", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeErr(w, 405, "POST only")
			return
		}
		var b struct{ Password, Code string }
		if !readJSON(w, r, &b) {
			return
		}
		a.mu.Lock()
		defer a.mu.Unlock()
		now := time.Now()
		recent := st.failures[:0]
		for _, t := range st.failures {
			if now.Sub(t) < time.Minute {
				recent = append(recent, t)
			}
		}
		st.failures = recent
		if len(st.failures) >= maxLoginFailures {
			writeErr(w, 429, "too many attempts; wait a minute")
			return
		}
		ok := false
		if b.Code != "" {
			sum := sha256.Sum256([]byte(strings.TrimSpace(b.Code)))
			h := hex.EncodeToString(sum[:])
			if exp, found := a.codes[h]; found && now.Before(exp) {
				// one use, remembered (on disk) until it would have expired; a code
				// whose use cannot be recorded is not accepted
				a.loadConsumedLocked()
				a.consumed[h] = exp
				if !a.saveConsumedLocked() {
					delete(a.consumed, h)
					writeErr(w, 500, "the code's use could not be saved to disk; nothing was signed in")
					return
				}
				delete(a.codes, h)
				ok = true
			}
		} else if a.cfg.LocalPassword != "" && b.Password != "" {
			ok = checkPassword(a.cfg.LocalPassword, b.Password)
		}
		if !ok {
			st.failures = append(st.failures, now)
			writeErr(w, 401, "wrong password or code")
			return
		}
		tok := make([]byte, 32)
		_, _ = rand.Read(tok)
		id := base64.RawURLEncoding.EncodeToString(tok)
		st.sessions[id] = now.Add(sessionTTL)
		a.pushEventLocked("local.login", "", nil)
		http.SetCookie(w, &http.Cookie{Name: "psm_local", Value: id, Path: "/", HttpOnly: true,
			SameSite: http.SameSiteStrictMode, MaxAge: int(sessionTTL.Seconds())})
		writeJSON(w, 200, map[string]bool{"ok": true})
	})
	mux.HandleFunc("/api/logout", func(w http.ResponseWriter, r *http.Request) {
		if c, err := r.Cookie("psm_local"); err == nil {
			a.mu.Lock()
			delete(st.sessions, c.Value)
			a.mu.Unlock()
		}
		http.SetCookie(w, &http.Cookie{Name: "psm_local", Value: "", Path: "/", MaxAge: -1, HttpOnly: true, SameSite: http.SameSiteStrictMode})
		w.WriteHeader(204)
	})

	authed := func(h http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if !st.valid(a, r) {
				writeErr(w, 401, "sign in first")
				return
			}
			h(w, r)
		}
	}

	mux.HandleFunc("/api/overview", authed(func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		a.mu.Lock()
		ver, last, pending, evErr := a.psmVersion, a.lastSync, len(a.events), a.eventErr
		a.mu.Unlock()
		var lastSync any
		if !last.IsZero() {
			lastSync = last.UTC().Format(time.RFC3339)
		}
		writeJSON(w, 200, map[string]any{
			"hostname": a.hostname, "agent_version": agentVersion, "psm_version": ver, "panel": a.cfg.Panel,
			"last_sync": lastSync, "events_pending": pending, "events_error": evErr, "system": systemStats(),
			"cores":   a.jsonPart(ctx, "core", "list", "--json"),
			"nodes":   a.jsonPart(ctx, "node", "list", "--json"),
			"traffic": a.jsonPart(ctx, "traffic", "list", "--json"),
		})
	}))
	// how this server's IP looks from outside (psm check: owner, blacklists, unlocks)
	mux.HandleFunc("/api/check", authed(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeErr(w, 405, "POST only")
			return
		}
		out, err := a.psmFor(r.Context(), checkTimeout, nil, "check", "all", "--json")
		if err != nil {
			writeErr(w, 400, err.Error())
			return
		}
		writeJSON(w, 200, map[string]any{"check": jsonOrNil(out)})
	}))
	mux.HandleFunc("/api/doctor", authed(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"doctor": a.jsonPart(r.Context(), "doctor", "--json")})
	}))
	mux.HandleFunc("/api/users", authed(func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		writeJSON(w, 200, map[string]any{"usage": a.jsonPart(ctx, "user", "usage", "--json"),
			"online": a.jsonPart(ctx, "user", "online", "--json")})
	}))
	// POST /api/users/NAME/disable | enable: this server only
	mux.HandleFunc("/api/users/", authed(func(w http.ResponseWriter, r *http.Request) {
		parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/users/"), "/")
		if r.Method != http.MethodPost || len(parts) != 2 || !userNameRe.MatchString(parts[0]) ||
			(parts[1] != "disable" && parts[1] != "enable") {
			writeErr(w, 404, "no such action")
			return
		}
		if why := a.mayChange(); why != "" {
			writeErr(w, 507, why)
			return
		}
		name, off := parts[0], parts[1] == "disable"
		// PSM's own pause on this server: it never touches what the panel
		// decided (a user the panel switched off stays off when resumed here)
		flag := "--local-resume"
		if off {
			flag = "--local-pause"
		}
		a.change.Lock()
		_, err := a.psm(r.Context(), nil, "user", "update", name, flag, "--json")
		a.change.Unlock()
		if err != nil {
			writeErr(w, 400, err.Error())
			return
		}
		if !a.addEvent("user."+parts[1]+"_here", name, nil) {
			writeErr(w, 500, "done on this server, but it could not be saved for the panel: "+a.eventError())
			return
		}
		writeJSON(w, 200, map[string]any{"ok": true})
	}))
	// POST /api/cores/CORE/restart, GET /api/cores/CORE/logs
	mux.HandleFunc("/api/cores/", authed(func(w http.ResponseWriter, r *http.Request) {
		parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/cores/"), "/")
		if len(parts) != 2 || !cores[parts[0]] {
			writeErr(w, 404, "no such core")
			return
		}
		core := parts[0]
		switch {
		case parts[1] == "logs" && r.Method == http.MethodGet:
			out, err := a.psm(r.Context(), nil, "core", "logs", core, "--lines", "200")
			if err != nil {
				writeErr(w, 400, err.Error())
				return
			}
			writeJSON(w, 200, map[string]string{"log": string(out)})
		case parts[1] == "restart" && r.Method == http.MethodPost:
			if why := a.mayChange(); why != "" {
				writeErr(w, 507, why)
				return
			}
			a.change.Lock()
			out, err := a.psm(r.Context(), nil, "core", "restart", core, "--json")
			a.change.Unlock()
			if err != nil {
				writeErr(w, 400, err.Error())
				return
			}
			if !a.addEvent("core.restart", core, nil) {
				writeErr(w, 500, "restarted, but it could not be saved for the panel: "+a.eventError())
				return
			}
			writeJSON(w, 200, map[string]any{"ok": true, "core": jsonOrNil(out)})
		default:
			writeErr(w, 404, "no such action")
		}
	}))
	// POST /api/nodes/CORE/PROTO/TAG {"port": n, "display_name": s}
	mux.HandleFunc("/api/nodes/", authed(func(w http.ResponseWriter, r *http.Request) {
		parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/nodes/"), "/")
		if r.Method != http.MethodPost || len(parts) != 3 {
			writeErr(w, 404, "no such node")
			return
		}
		t := task{Core: parts[0], Protocol: parts[1], Tag: parts[2]}
		if why := checkNode(t, true); why != "" {
			writeErr(w, 400, why)
			return
		}
		if why := a.mayChange(); why != "" {
			writeErr(w, 507, why)
			return
		}
		var b struct {
			Port        *int    `json:"port"`
			DisplayName *string `json:"display_name"`
		}
		if !readJSON(w, r, &b) {
			return
		}
		patch := map[string]any{}
		if b.Port != nil {
			if *b.Port < 1 || *b.Port > 65535 {
				writeErr(w, 400, "port: 1..65535")
				return
			}
			patch["port"] = *b.Port
		}
		if b.DisplayName != nil {
			d := strings.TrimSpace(*b.DisplayName)
			if len(d) > 64 || strings.ContainsAny(d, "=,\r\n\t\"") {
				writeErr(w, 400, "display name: up to 64 characters, no = , or quotes")
				return
			}
			patch["display_name"] = d
		}
		if len(patch) == 0 {
			writeErr(w, 400, "nothing to change")
			return
		}
		data, _ := json.Marshal(patch)
		a.change.Lock()
		out, err := a.psmFor(r.Context(), installTimeout, data, "node", "update", t.Core, t.Protocol, t.Tag, "--input", "-", "--json")
		a.change.Unlock()
		if err != nil {
			writeErr(w, 400, err.Error())
			return
		}
		detail, _ := json.Marshal(map[string]any{"core": t.Core, "protocol": t.Protocol, "tag": t.Tag, "changes": patch})
		if !a.addEvent("node.changed", t.Tag, detail) {
			writeErr(w, 500, "changed on this server, but it could not be saved for the panel (the panel will not know the new port): "+a.eventError())
			return
		}
		writeJSON(w, 200, map[string]any{"ok": true, "result": jsonOrNil(out)})
	}))
	mux.Handle("/", files)

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		h.Set("Content-Security-Policy", "default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		if !okHost[r.Host] {
			writeErr(w, 421, "open this page as http://127.0.0.1:"+port)
			return
		}
		// a change must come from this page itself
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			site := r.Header.Get("Sec-Fetch-Site")
			origin := r.Header.Get("Origin")
			if (site != "" && site != "same-origin") || (origin != "" && !okHost[strings.TrimPrefix(origin, "http://")]) ||
				r.Header.Get("X-PSM-Local") != "1" {
				writeErr(w, 403, "a change must come from the local page itself")
				return
			}
		}
		mux.ServeHTTP(w, r)
	})
}

func (st *localState) valid(a *agent, r *http.Request) bool {
	c, err := r.Cookie("psm_local")
	if err != nil {
		return false
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	exp, ok := st.sessions[c.Value]
	if ok && time.Now().After(exp) {
		delete(st.sessions, c.Value)
		return false
	}
	return ok
}

func (a *agent) addEvent(kind, target string, detail json.RawMessage) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.pushEventLocked(kind, target, detail)
}

// pushEventLocked records an event (a.mu held) and keeps the list on disk: a
// restart while the panel is unreachable must not lose what was done here.
// False: it could not be kept (too many unreported, or the disk refused).
func (a *agent) pushEventLocked(kind, target string, detail json.RawMessage) bool {
	if len(a.events) >= maxEvents {
		a.eventErr = fmt.Sprintf("%d changes wait for the panel; reconnect the server before changing more", len(a.events))
		return false
	}
	id := make([]byte, 8)
	_, _ = rand.Read(id)
	a.events = append(a.events, event{ID: hex.EncodeToString(id), At: time.Now().UTC().Format(time.RFC3339), Kind: kind, Target: target, Detail: detail})
	return a.saveEventsLocked()
}

func (a *agent) eventError() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.eventErr
}

// mayChange: whether the local page may make one more change (its report can be kept).
func (a *agent) mayChange() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	if len(a.events) >= maxEvents {
		return fmt.Sprintf("%d changes wait for the panel; reconnect the server before changing more", len(a.events))
	}
	return ""
}

// ackEvents drops the events the panel says it recorded.
func (a *agent) ackEvents(ids []string) {
	done := map[string]bool{}
	for _, id := range ids {
		done[id] = true
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	kept := a.events[:0]
	for _, e := range a.events {
		if !done[e.ID] {
			kept = append(kept, e)
		}
	}
	a.events = kept
	a.saveEventsLocked()
}

func (a *agent) eventsPath() string {
	if a.cfgPath == "" {
		return "" // tests
	}
	return filepath.Join(filepath.Dir(a.cfgPath), "agent-events.json")
}

func (a *agent) saveEventsLocked() bool {
	p := a.eventsPath()
	if p == "" {
		return true
	}
	raw, _ := json.Marshal(a.events)
	err := os.WriteFile(p+".tmp", raw, 0o600)
	if err == nil {
		err = os.Rename(p+".tmp", p)
	}
	if err != nil {
		a.eventErr = "the local page's changes could not be saved to disk: " + err.Error()
		log.Printf("events: %v", err)
		return false
	}
	a.eventErr = ""
	return true
}

// consumed codes, on disk until they would have expired
func (a *agent) codesPath() string {
	if a.cfgPath == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(a.cfgPath), "agent-codes.json")
}

func (a *agent) loadConsumedLocked() {
	if a.consumed != nil {
		return
	}
	a.consumed = map[string]time.Time{}
	if p := a.codesPath(); p != "" {
		if raw, err := os.ReadFile(p); err == nil {
			var m map[string]int64
			if json.Unmarshal(raw, &m) == nil {
				for h, exp := range m {
					if t := time.Unix(exp, 0); time.Now().Before(t) {
						a.consumed[h] = t
					}
				}
			}
		}
	}
}

func (a *agent) saveConsumedLocked() bool {
	p := a.codesPath()
	if p == "" {
		return true
	}
	m := map[string]int64{}
	for h, t := range a.consumed {
		if time.Now().Before(t) {
			m[h] = t.Unix()
		}
	}
	raw, _ := json.Marshal(m)
	if err := os.WriteFile(p+".tmp", raw, 0o600); err != nil {
		return false
	}
	return os.Rename(p+".tmp", p) == nil
}

func (a *agent) loadEvents() {
	p := a.eventsPath()
	if p == "" {
		return
	}
	raw, err := os.ReadFile(p)
	if err != nil {
		return
	}
	var evs []event
	if json.Unmarshal(raw, &evs) == nil {
		a.mu.Lock()
		a.events = evs
		a.mu.Unlock()
	}
}

// systemStats: load, memory, the root file system and uptime (Linux /proc;
// fields it cannot read are left out).
func systemStats() map[string]any {
	out := map[string]any{}
	if b, err := os.ReadFile("/proc/loadavg"); err == nil {
		if f := strings.Fields(string(b)); len(f) >= 3 {
			out["load"] = f[:3]
		}
	}
	if f, err := os.Open("/proc/meminfo"); err == nil {
		mem := map[string]int64{}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			p := strings.Fields(sc.Text())
			if len(p) >= 2 {
				n, _ := strconv.ParseInt(p[1], 10, 64)
				mem[strings.TrimSuffix(p[0], ":")] = n * 1024
			}
		}
		f.Close()
		if mem["MemTotal"] > 0 {
			out["mem_total"], out["mem_available"] = mem["MemTotal"], mem["MemAvailable"]
		}
	}
	var st syscall.Statfs_t
	if syscall.Statfs("/", &st) == nil {
		bs := uint64(st.Bsize)
		out["disk_total"], out["disk_free"] = uint64(st.Blocks)*bs, uint64(st.Bavail)*bs
	}
	if b, err := os.ReadFile("/proc/uptime"); err == nil {
		if f := strings.Fields(string(b)); len(f) > 0 {
			if v, err := strconv.ParseFloat(f[0], 64); err == nil {
				out["uptime_s"] = int64(v)
			}
		}
	}
	return out
}

func readJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	body, err := io.ReadAll(io.LimitReader(r.Body, maxLocalBody))
	if err != nil || json.Unmarshal(body, v) != nil {
		writeErr(w, 400, "expected a JSON body")
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"message": msg}})
}

// ── REALITY's own site ────────────────────────────────────────────────────────

// caps is what this server's PSM says it can do (psm caps), looked up with the version.
func (a *agent) capsHave(ctx context.Context, cap string) bool {
	a.mu.Lock()
	known := a.caps != nil
	a.mu.Unlock()
	if !known {
		var c struct {
			Caps []string `json:"caps"`
		}
		_ = json.Unmarshal(a.jsonPart(ctx, "caps"), &c)
		a.mu.Lock()
		a.caps = map[string]bool{}
		for _, k := range c.Caps {
			a.caps[k] = true
		}
		a.mu.Unlock()
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.caps[cap]
}

// ownSiteReady: REALITY (and REALITY under XHTTP / gRPC) is only ever made on
// this server's own site — a task without own_site, an old one queued before,
// is refused — and only on a PSM that sets that site up and refuses any other
// fallback when a core starts.
func (a *agent) ownSiteReady(ctx context.Context, proto string, data map[string]any) string {
	reality := proto == "reality" || (proto == "xhttp" && data["mode"] == "reality-layer")
	if reality && data["own_site"] != true {
		return "REALITY is only made on this server's own site (own_site): a third-party fallback would make the server an open relay"
	}
	if data["own_site"] != true {
		return ""
	}
	if d, _ := data["dest"].(string); d != "" && d != "127.0.0.1:8443" {
		return "own_site with a target other than 127.0.0.1:8443"
	}
	if !a.capsHave(ctx, "reality.own_site") || !a.capsHave(ctx, "reality.guard") {
		return "this server's PSM does not support REALITY's own site: update PSM (psm agent upgrade)"
	}
	return ""
}

// ownSiteHolds checks what PSM stored for an own-site node: its fallback must
// be this server's site.
func (a *agent) ownSiteHolds(ctx context.Context, core, proto, tag string) string {
	var show struct {
		Item struct {
			Node struct {
				Dest    string `json:"dest"`
				OwnSite bool   `json:"own_site"`
			} `json:"node"`
		} `json:"item"`
	}
	if err := json.Unmarshal(a.jsonPart(ctx, "node", "show", core, proto, tag, "--json"), &show); err != nil {
		return "could not read back the node from PSM"
	}
	if show.Item.Node.Dest != "127.0.0.1:8443" || !show.Item.Node.OwnSite {
		return fmt.Sprintf("PSM stored REALITY with fallback %q, not this server's own site: the node was removed", show.Item.Node.Dest)
	}
	return ""
}
