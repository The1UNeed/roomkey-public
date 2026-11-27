# roomkey plan

One central panel on Cloudflare Workers manages every server, every node and every user. Each server also has a small local page for simple tasks, and the central panel stays in charge.

Status, 2026-11-24: phases 1–5 are built on branch `build/v1` and tested locally (unit tests, PSM shell tests, and an end-to-end run of the Worker with a simulated agent). Not deployed. Where the build differs from this plan, see "What was built" at the end.

## 1. What we start from

| Part | Has today | Missing |
|---|---|---|
| `panel/` (Workers + D1) | Servers, nodes, task queue, per-node traffic and quota, subscriptions filtered by label, relays, audit log, one admin password | **Users**, per-user subscriptions, per-user traffic, an "own site" option for REALITY |
| `stack/` (PSM, on each VPS) | `psm user add/update/delete`: one UUID and password per user, node tags, expiry, monthly quota. Disabled, expired and over-quota users are dropped from the core configs. | Per-user traffic outside Xray. An import command that takes a full user list from the panel. |
| `stack/agent/` (Go) | Outbound-only HTTPS sync, allowlisted `psm` commands, traffic report every 10 min | `user.*` tasks, per-user counters in the report, a local page |
| `3x-ui/` | Reference: client model (`internal/database/model/model.go`), traffic reset periods, first-use expiry, IP limits from the access log, bulk client actions | Not deployed. We borrow ideas and code from it, not the app. |

Good news from the code: PSM's shared-443 mode already drops connections with unknown SNIs (`stack/lib/nginx.sh`, `SNI_DEFAULT_BLACKHOLE`). That alone doesn't fix the DMIT problem, though. A scanner that sends our configured serverName still gets passed through to `dest`, which is exactly what DMIT's scan did with `persistent.oaistatic.com`. The panel's REALITY form also still requires a third-party `dest` (placeholder `learn.microsoft.com:443`). Phase 1 fixes that.

## 2. Target architecture

```
                     Cloudflare (Workers + D1)
      admin.myroom.asia ─ admin page + API   (behind Cloudflare Access)
      sub.myroom.asia   ─ /sub/<user token>  (Shadowrocket, Clash Verge, Throne)
                │  ▲
     tasks,     │  │  sync every 30 s (3 s while busy): task results,
     users      ▼  │  traffic per node and per user, public IP
   ┌──────────────────────────────────────────────┐
   │ VPS: psm-agent ── psm CLI ── Xray / sing-box  │  × N servers
   │       └─ local page on 127.0.0.1 (SSH tunnel)  │
   └──────────────────────────────────────────────┘
                ▲
   clients connect directly to n1.myroom.asia, n2…  (DNS only, grey cloud)
```

Rules that hold everywhere:

- The panel never carries proxy traffic.
- REALITY's fallback goes to the node's own site by default, and the panel warns before accepting a CDN-hosted `dest`.
- The panel holds the truth for users. Each server enforces what it can locally, so expiry and per-server limits keep working while the panel is unreachable.
- No admin page listens on a public port: not the panel (it's on Cloudflare) and not the local page (loopback only).
- No "vpn" in hostnames.

## 3. Data model (new D1 migrations, `0016_users.sql` onward)

```sql
CREATE TABLE users (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  name              TEXT NOT NULL UNIQUE,         -- a-z0-9_-, same rule as psm user
  note              TEXT NOT NULL DEFAULT '',
  uuid_enc          TEXT NOT NULL,                -- AES-GCM, like nodes.params_enc
  password_enc      TEXT NOT NULL,
  enabled           INTEGER NOT NULL DEFAULT 1,
  expires_at        TEXT,                         -- NULL = never
  first_use_days    INTEGER,                      -- set: expiry starts at first traffic
  quota_total_bytes INTEGER,                      -- NULL = no total limit
  reset_period      TEXT NOT NULL DEFAULT 'monthly',  -- daily | weekly | monthly | never
  reset_day         INTEGER NOT NULL DEFAULT 1,
  period_start      TEXT NOT NULL,
  used_total_bytes  INTEGER NOT NULL DEFAULT 0,   -- this period, all servers
  sub_token_hash    TEXT NOT NULL UNIQUE,
  sub_token_enc     TEXT NOT NULL,
  last_sub_at       TEXT,
  created_at        TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Which nodes a user gets: everything, by label, or one node at a time.
CREATE TABLE user_access (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind    TEXT NOT NULL,                          -- all | label | node
  value   TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (user_id, kind, value)
);

-- Optional limit on one server, plus usage there this period.
CREATE TABLE user_servers (
  user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  server_id   INTEGER NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
  quota_bytes INTEGER,                            -- NULL = only the total applies
  used_bytes  INTEGER NOT NULL DEFAULT 0,
  last_counter INTEGER NOT NULL DEFAULT 0,        -- last raw counter seen, to compute deltas
  PRIMARY KEY (user_id, server_id)
);

CREATE TABLE user_traffic_daily (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  server_id INTEGER NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
  day TEXT NOT NULL, bytes INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, server_id, day)
);
```

A user is **active on server S** when all of these hold:
enabled, and not past `expires_at`, and (`quota_total_bytes` is NULL or `used_total_bytes` < it), and (no limit on S or `used_bytes` on S < `quota_bytes`).

So the two quota modes work together. Set only a total, only per-server limits, or both, and whichever runs out first pauses the user, everywhere or on that server only.

## 4. Sync users to servers: full state, not step by step

- New task `user.sync`: the panel sends each server the **complete** list of users that may use it, with `name`, `uuid`, `password`, node tags, `active`, `expires_at`, and the per-server `quota_bytes`. A full list makes every sync idempotent, so a missed task can't leave a server out of step.
- New PSM command `psm user import --json` (stdin), in `stack/lib/users.sh`. It replaces the user set, keeps the local counters, and calls `users_apply`. The agent allowlist gets `user.sync`, mapped to that command only.
- The panel queues `user.sync` for affected servers after any user change, and also when a total quota runs out or a period resets.
- The server enforces expiry and its own per-server limit locally, as `users_check` already does. The total quota needs every server's numbers, so the panel enforces it. A user can overshoot by at most one report interval, about 10 minutes of traffic.

## 5. Per-user traffic

- PSM adds a counter per user that never resets (`counter_bytes`). The agent sends it with the 10-minute traffic report.
- The panel computes `delta = counter − last_counter` (if the counter went down, the server restarted or was reinstalled, so use the counter as the delta). It adds the delta to `user_servers.used_bytes`, `users.used_total_bytes` and `user_traffic_daily`. **Periods and resets live only in the panel**, which avoids PSM's fixed calendar month disagreeing with the reset day you set.
- **Gap to close in phase 0:** today PSM counts per user only on Xray. For Hysteria2 and AnyTLS, compare and pick one:
  1. Run them on a core that counts per user, if PSM's Xray build supports them.
  2. Official Hysteria2 server: its traffic-stats API reports per user.
  3. sing-box built with the `with_v2ray_api` tag: per-user stats.

  Until that's done, the panel marks those nodes **"not metered"** and you choose whether users with a quota get them.

## 6. Per-user subscriptions

- `GET sub.myroom.asia/sub/<user token>` returns the user's active nodes, filtered by `user_access`, in `uri` (Shadowrocket, Throne), `clash` (Clash Verge) or `sing-box` format. `pickFormat` in `worker/src/subscription.ts` already picks the format from the User-Agent.
- Credentials are swapped into each node's stored owner link and outbound (`link_enc`, `outbound_enc`) by a pure function covered by unit tests: UUID for VLESS, password for Hysteria2 and AnyTLS.
- A `Subscription-Userinfo` header (`upload=…; download=…; total=…; expire=…`) lets Shadowrocket and Clash Verge show remaining traffic and the expiry date.
- An expired or paused user gets one placeholder entry, "Expired: contact the admin", instead of an empty list, so they know why it stopped.
- Tokens can be reset in the admin page, which kills the old link.

## 7. Node IP changes and REALITY "own site" (phase 1)

- Every node gets a hostname, `nN.myroom.asia`. The agent reports its public IP on each sync. When the IP changes, the panel updates the A record through the Cloudflare API (a `CF_DNS_TOKEN` Worker secret limited to DNS:Edit on `myroom.asia`, `proxied: false`). Clients never need an update.
- New REALITY option, **"This node's site" (default)**: PSM serves a static site with the node's Let's Encrypt certificate on `127.0.0.1:8443` (`stack/lib/nginx.sh` already builds this kind of listener). It sets `dest = 127.0.0.1:8443` and `serverNames = [nN.myroom.asia]`. (Built: there is no "another site" option any more. The panel always sends `own_site` with `dest = 127.0.0.1:8443`, whatever a request supplies, and PSM's start check refuses any REALITY dest off the server.)

## 8. Local page on each node

Features, the simple things 3x-ui does:

- **Status:** cores, CPU, memory, disk, uptime, and the last sync with the panel
- **Nodes:** list, enable or disable, restart a core, view logs, and quick edits (port, SNI, Hysteria2 bandwidth)
- **Users on this server:** usage and state, read-only, plus an emergency "disable here" switch
- **Maintenance:** certificate status and renewal, firewall ports, `psm check` (IP reachability), backup

How it works:

- Built into `psm-agent`, as a small embedded page plus a JSON API on `127.0.0.1:2096`. You open it with `ssh -L 2096:127.0.0.1:2096 nN.myroom.asia`. It never listens on a public interface.
- **Same allowlists as the tasks:** the page can only run what a panel task could, so it adds no new powers on the server.
- **Who wins:**
  - Users are managed only in the central panel. Locally they're read-only, apart from "disable here", which is reported up.
  - Node and server settings can be changed locally. The agent reports each change with its next sync, and the panel records it, so the central view stays correct.
  - If the panel is unreachable, the local page keeps working and the reports go up later.
- **Login:** a one-time link generated by the central panel ("Open local page" shows the SSH command and a code), or a local password set at join time.

## 9. Security

- Put `admin.myroom.asia` behind **Cloudflare Access** (free for small teams), on top of the admin password. Serve `sub.myroom.asia` without it, since clients have to reach it.
- Set `TOKEN_KEY` as a Worker secret, not the fallback key stored in D1 (the README warns about this).
- Install nodes from **our own repo**, not `psm.jinqians.com`, so a third-party domain can't change what runs as root on our servers.
- AGPL: friends who use the panel or subscriptions can get the source. The repo is private, so share it with them if they ask.

## 10. Phases

| Phase | Work | Done when |
|---|---|---|
| **0. Groundwork** | Deploy `panel/` unchanged to `admin.` / `sub.myroom.asia`. Join one node through our own install script. Pick the Hysteria2/AnyTLS metering approach (§5). | A friend in China opens the subscription URL. One node shows up and reports traffic. |
| **1. Safe nodes** | REALITY "This node's site" option. Hostnames per node with automatic DNS updates. Warning for CDN targets. | `curl --resolve <old SNI>:443:<ip>` gets nothing from Cloudflare. Changing a node's IP updates DNS within 1 minute. |
| **2. Users** | Migrations, admin pages (list, create, edit, notes, access), `user.sync`, `psm user import`, per-user subscriptions with the userinfo header | Create a user in the panel, import the link in Shadowrocket, Clash Verge and Throne, and connect to every assigned node. Disable the user and they're cut off on every server within 1 minute. |
| **3. Quotas and expiry** | Per-user counters, deltas, total and per-server limits, reset periods, first-use expiry, usage charts | A test user with a 1 GB total limit is paused everywhere after about 1 GB. A 500 MB limit on one server pauses only that server. Resetting the period brings them back. |
| **4. Local page** | Embedded page in `psm-agent`, local change reports | Through an SSH tunnel: restart a core, toggle a node, see the change in the central panel at the next sync. Works with the panel unreachable. |
| **5. Extras** | Device/IP limits (3x-ui's access-log method), Telegram alerts (PSM has `tg_bot.sh`), a self-service page per user, backups of D1 | Each item gets its own small spec when we get there. |

## 11. Tests

- **Panel:** add Vitest to `panel/` for credential swapping, the active-user rule, delta and reset math, and subscription output per format. Run `npm run typecheck` on every change.
- **Agent:** extend `stack/agent/main_test.go` for the `user.sync` allowlist and the local page API.
- **PSM:** add a smoke test in `stack/tests/` for `psm user import`.
- **End to end:** after each phase, check on one real node with real Shadowrocket, Clash Verge and Throne clients, and record the result.

## 12. Open questions

1. Hysteria2/AnyTLS per-user metering: which approach from §5? To be decided in phase 0.
2. Should paused users see the placeholder entry, or simply get an empty list?
3. Device limits: needed in the first version, or can they wait for phase 5?
4. Which nodes come first? The DMIT node stays suspended until DMIT reactivates it.

## What was built (and where it differs)

- **REALITY uses its own site unless you borrow one on purpose.** The own site (§7) is the default for both REALITY and REALITY + XHTTP/gRPC. A borrowed site (since psm-agent 0.15.0) needs the risk ticked in the panel and `borrowed_site: true` all the way down. It must be a domain on port 443 equal to the node's SNI, and the core guard (`psm_borrowed_sites`) lets through only that pair. CDN-shared targets get the fallback speed limit instead of a refusal. PSM refuses CDN-fronted targets, its watchdog never fails an own-site node over to another site, and the panel sends REALITY only to servers whose PSM supports it.
- **One final guard in every core's restart path** (`psm_users_merge`, lib/common.sh): accounts merged (a failed merge refuses the restart), BitTorrent and port 25 blocked, and any REALITY fallback that is not this server refused — whichever menu, rebuild, rollback or watchdog wrote the config.
- **The same check runs before every core start** (the service's pre-start hook, on systemd and OpenRC), so a reboot, a restore or an install can't start a core with an outside fallback or with revoked users.
  - *What it refuses:* a public control API (mihomo external-controller, sing-box clash/v2ray API), a public mihomo DNS server, a public listener anyone can use without an account (SOCKS/HTTP/mixed with no named users, mihomo SOCKS with UDP, unencrypted Shadowsocks, a port forward, mihomo tunnels and global ports without authentication), VLESS/Trojan fallbacks off the server, and a REALITY dest other than the node's own site. mihomo listeners PSM does not manage (`ss-config`, `vmess-config`, `tuic-server`) are refused. An address counts as loopback only when it really is one (127.0.0.0/8 or ::1 however written; `127.example.com` and an empty host are public). Xray and sing-box configs are read the way the cores read them: key spellings in any case are normalised (two spellings of one key are refused) and protocol and security names are lower-cased.
  - *Destinations:* every core refuses users' traffic to the server itself and private networks (Xray `geoip:private`, sing-box `ip_is_private`, mihomo IP-CIDR rejects ahead of every rule).
  - The standalone Hysteria2 unit checks its masquerade before every start; a standalone Hysteria2 service from an older install is refused. No SOCKS nodes: the panel offers none, psm-agent refuses them, and PSM makes them on 127.0.0.1 only. Hysteria2 hopping ranges never overlap each other or another node's UDP port, and no Xray rebuild removes another protocol's node.
- **`psm guard`** puts the hook on cores installed by an older PSM (it checks for the directive itself, not a mention), restarts running cores so the checked config is what serves, and stops (and, without a hook, disables) a core it can't make safe.
  - It refuses (unsafe), as they are and never rewritten: any Xray, V2Ray, sing-box, mihomo or Clash process that is not one of PSM's cores running exactly its checked config (another panel's copy such as 3x-ui's, a `-confdir`, a second instance), one its service does not supervise or that carries configuration in its environment (XRAY_LOCATION_CONFDIR), any boot-enabled service that starts a proxy outside PSM (3x-ui's x-ui, an xray@ instance), and a core whose loaded start command or environment is not PSM's (a drop-in). The start command is read before PSM writes its unit (only PSM's own launch passes) and again after.
  - It checks nginx for forwards off the server and stops nginx if it finds one.
  - "Stopped" and "disabled" are only clear answers from the service manager (an empty or unknown value is not one) with no process of that core running outside it. The scan reads three times a second apart, so PSM's own short-lived core runs do not count. `psm agent join` and every `upgrade` run it, and stop if a core is left unsafe.
- **Joining** first runs a read-only check of the whole server (every core's launch and listeners, the camouflage and open-listener rules on the configs as they are, other proxies or relays running, enabled at boot or in containers, relay rules, a standalone Hysteria2 masquerade) and refuses, changing nothing, if anything is not PSM's. It also lists the public listening sockets: only SSH and ordinary system daemons (DHCP, NTP, a DNS stub) may listen on a fresh server; anything else (HAProxy, a panel) is named.
- **nginx.** An nginx already on the server (binary, service, a linked `/etc/nginx`, or any file or link left under it, such as a site from a removed but unpurged nginx) is refused at join, and PSM's first nginx install refuses the same leftovers before it installs anything (one shared check, `psm_nginx_leftovers`; PSM's own certificates in `/etc/nginx/ssl` are not leftovers). PSM installs and configures nginx itself.
  - nginx forwards nowhere off the server: PSM's menus take only loopback upstreams, and `psm_nginx_forwards` (the configuration as `nginx -T` shows it, every include, tokenised) is checked before every reload (PSM's and acme.sh's renewals), before nginx starts under systemd (a drop-in), and by `psm guard`. Cloudflare Tunnel routes go to services on the server only.
  - The first REALITY own site waits up to 10 seconds in all (one deadline) for nginx to answer after its reload.
- **Restore.** `psm migrate import` / `push` are off (a server moves through the panel: add the new one, recreate its nodes; `psm migrate export` stays, as an archive), and a migration bundle given to `psm restore` is refused. `psm restore` never restores nginx (the server keeps its own).
  - Restoring certificates merges them into the live ones and puts the previous set back if nginx rejects the result (the restore then reports failure).
  - A restore starts again only the services it stopped. That list is written (atomically) before anything stops, or nothing stops, and kept until they run again, so a retry after a restore that stopped half way still starts them; nothing starts while a restore is unfinished, a reboot included (services enabled at boot are taken off boot meanwhile and put back when they start). A service the service manager won't take off boot or stop fails the restore before anything is copied, and what was already changed is put back.
  - Docker volumes that can't be restored (no Docker, a bad archive) fail the restore, and each archive is unpacked whole on the volume's own filesystem before the live entries are swapped out by rename (and back on any failure), so a bad archive or a full disk leaves the volume as it was.
- **Meters** in the traffic menu reset under the traffic lock, like the timer and the CLI.
- **A new D1 only.** roomkey's panel does not take over a psm-panel database: migration 0016 fails on one that already has servers, and the panel answers 503 saying so. Servers join with roomkey's install command, which runs the guard before psm-agent is installed or replaced.
- **No relays.** psm-panel's relays (中转: a port on one server forwarded to a node on another) are gone. The panel keeps no relay (migration 0018 drops the old rows) and has no page or API for one; PSM refuses `psm relay add` / `update` and any new rule in its store; psm-agent refuses relay adds and changes. `psm guard`, which `psm agent join` and every upgrade run before anything else, takes realm and gost off the server for good (`psm relay off`: stopped, disabled, their units, binaries and generated configs removed, read back as strictly as the cores) and only then empties the rule store and each rule's firewall opening, meter and certificates; a server where that can't be shown does not join or upgrade. A psm-agent older than roomkey's is handed only its upgrade (and status reports), so nothing reaches a server until that guard has run there. `psm doctor` reports any relay rule or running relay engine as an error and `--fix` runs `psm relay off`; a PSM migration bundle brings no relay rules, engine configs or agent enrollment, and keeps the user store that is here (under the user lock, with the same unfinished-restore marker as a backup restore; while it is there no core starts and no user list is imported). A public forward is the easiest way to become an open relay, and roomkey's servers are reached directly.
- **Hysteria2 masquerade** stays on the server: no masquerade by default (404), PSM refuses one that proxies another site, and every core start strips such a masquerade from sing-box and mihomo configs.
- **Nodes made by hand stay the owner's**: a node is the panel's (`nodes.owned`) only once psm-agent confirms it created it (a create that half ran counts). Until then nothing else is sent for it: no metering, no users, no removal. A first create of a node (or standalone server) already on the server, or one psm-agent can't tell is there (an unreadable node list, a Docker-installed Snell), is refused, and deleting that row only forgets it. psm-agent keeps each result on disk until the panel has it, so a task handed out again is answered with its first result instead of running twice; every task carries a uid (a restored panel numbers tasks from 1 again), and both the journal and the panel match results on it. A tag names one node on the whole server (PSM's `node add` and the panel's first create both refuse a tag another core uses), and a node change whose rebuild would drop an Xray or sing-box inbound no PSM node owns is undone (store and live config), so a direct install's own inbounds survive the first panel node. Users are granted nodes as `core/tag`, so a node of the same name on another core (made by hand) never gets a friend's account; a local edit, an export, traffic counters and links count only for owned nodes.
- **Task results**: a task finishes only after its effects are saved; a result the panel can't take fails the task and its node (saving retries) but still records whether the create made the node, and a database outage fails the sync so psm-agent sends the results again. A change of an owned node whose node is gone is recreated (with its shared-443 mount). A node on its way to its server can't be deleted, and a server with a node task out can't start its removal; the removal plan lists only owned nodes.
- **Removing a server** first takes the panel's users off it. The server leaves the panel only when the agent confirms that; the leave carries each user's last reading, and the server's use this period still counts toward each user's total. If the panel's answer to the leave is lost, the agent takes the refused retry as the confirmation.
- **Restoring a PSM backup** on a server keeps its current panel users (a user revoked since the backup stays revoked); on a rebuilt server the archive's panel users are dropped until the panel sends its list. The relay rules stay as they were too (an archive's rules were withdrawn, and `doctor --fix` would start them again). The user lock sits beside the config directory, so a restore can't split it.
- **Usage**: this period's use is PSM's own per-period count, taken as it is (idempotent), with counter generations that sort by time; the lifetime counter only feeds the history and the start of a first-use term.
- **User lists carry revisions.** Each server's list is numbered, and PSM ignores an older one. The panel records which revision, and which users' credentials, each server took. A subscription lists a server's nodes only once that server has the user. Each sync carries the revision PSM holds, so a rebuilt server is sent the list again.
- **The local page (§8)** has status (load, memory, disk, uptime, last sync, events waiting to be reported), cores (restart, logs), node port and display-name edits, the panel's users with a pause on this server only, `psm doctor` and `psm check`. **Not built:** turning nodes on and off (PSM has no such command), SNI and bandwidth edits, certificate renewal (renewal is automatic through acme.sh), firewall changes and a local backup. Each needs PSM support first.
- **The admin page** answers only on `ADMIN_HOSTS`. The subscription host serves subscriptions and agent endpoints only.
- **Quota meters** belong to their node: a paused node's block carries its tag, so lifting one node's pause never lifts another node's on the same port over the other transport. Moving a meter (a port, transport or interface change) banks what the old rules counted before they go; rules that stay keep the baseline that checkpoint took and new rules count from zero, so traffic during an edit is neither lost nor counted twice. An edit that moves nothing keeps its checkpoint as taken, and so does an Xray port change (its counter is per tag). An edit that can't read the counters changes nothing. A poll that can't read them (an iptables listing that fails, an Xray API that doesn't answer) skips those meters and keeps their checkpoints; where a baseline is lost (reads failing right after an edit or a reset), the next good reading becomes the baseline, uncharged, so no usage is ever counted twice. A resume removes only rules carrying PSM's tag, never an untagged rule of the same shape. Pausing an Xray node behind the shared 443 closes only its own loopback backend's connections, never everything on 443. An edit that changes only a node's limit or reset day sends just the meter change (`traffic.set`), written in the same D1 batch as the row: the node stays applied and its core is not touched.
- **Standalone Snell / SS2022** changes swap in only when the new release starts: the download must run first, the previous binary, settings and service definition are kept, and on a failed start they all go back; recovery is reported only once the previous service listens again. The download must be built for this CPU (its ELF machine field) and execute here before the running server is stopped (Snell too), and a failed activation also puts the service's boot setting back. An install with no key keeps the key in use, read whole (a Snell key ending in `=` padding included; for SS2022 when the method, and so the key length, stays the same). A panel edit that only spells out a default the node was made with counts as no change.
- **Device limits** come from Xray's online-IP statistics, not access-log parsing. Nodes on the shared 443 can't see client IPs, so they don't count.
- **Backups** are restorable SQL, not JSON; work that was on its way restores as "save again" (a node whose creation was on its way as failed, so saving sends a create), and no user counts as delivered until a server takes its list.
- **Beijing time** for days, periods and expiry dates.
- **Not built yet (from the opinion round):** Xray's live user API (today every change to a server's served users restarts its cores, briefly dropping connections — only cores that are behind are restarted), a QR code on the friend's page, and per-node camouflage pages (every node serves PSM's stock page).
