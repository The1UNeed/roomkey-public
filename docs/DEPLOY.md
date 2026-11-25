# Deploying roomkey

What you need to put roomkey into service. The code is built and tested locally (see `docs/PLAN.md`); the first real deployment is yours. The short way is `./setup.sh`, below.

## Quick start: `setup.sh`

One command on your computer (macOS, or Linux with Node.js 20+ and git):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/The1UNeed/roomkey-public/main/setup.sh)
```

(From a checkout: `./setup.sh`.) On a machine without a browser (a server over SSH) it asks for a Cloudflare API token instead of opening the sign-in page. Without Go it takes psm-agent from the published release.

It checks the tools (Node 20+, git; Go optional; `brew install node` if missing), signs you in to Cloudflare (a browser window), asks for the two addresses (admin, subscriptions), the admin password and an optional DNS token, then:

1. builds what servers download: PSM's scripts from the last commit and psm-agent for amd64 / arm64 / armv7, with their SHA256SUMS;
2. creates the D1 database `roomkey` if it is missing, writes `panel/wrangler.local.jsonc` (not committed) with your addresses as custom domains, and deploys the Worker with its secrets (`ADMIN_PASSWORD`, `TOKEN_KEY` made once and kept in `~/.roomkey/token-key` — back it up — and `CF_DNS_TOKEN` if given);
3. waits for the admin address to answer, makes your first server in the panel and prints its install command.

Run it again after pulling changes: it remembers the answers (`~/.roomkey/setup.env`) and only rebuilds and redeploys. `./setup.sh --dry-run` does everything except talk to Cloudflare.

## 0. How servers download PSM and psm-agent

**From the panel itself** (what `setup.sh` sets up): the repository stays private. The Worker carries the bundle in hidden assets (`/_install/` answers 404) and hands it out at `/api/agent/bundle/<file>` only with a join token that is still good (the install) or a server's agent token (every upgrade after). The install command is

```
(command -v curl >/dev/null 2>&1 && curl -fsSL https://<sub>/api/agent/install/<token> || wget -qO- …) | sh
```

which fetches a small script made for that one token: it downloads PSM, checks it against SHA256SUMS, and runs PSM's bootstrap, which installs it unattended and joins the panel. `psm agent upgrade` (the panel's 升级 agent button) gets newer scripts and psm-agent from the panel the same way, so **redeploying the panel (`./setup.sh`) is how a new version reaches the servers**. Tested end to end on a fresh Debian 13 VM: install, join, agent running, upgrade.

The older way still works if you ever publish `stack/` (`git subtree split --prefix=stack`, a public repo with an `agent-v0.14.0` release): set the Worker variables `INSTALL_URL` and `PSM_REPO`, and deploy without a bundle (`NO_BUNDLE=1 npm run build`).

## 1. Cloudflare: the panel

Requirements: the `myroom.asia` zone on Cloudflare DNS, and a new, empty D1 database (roomkey refuses a psm-panel database: servers join roomkey with its own install command). The Workers **free plan** is enough for a few servers: the five-minute cron is 288 runs a day, and each agent syncs every 30 s.

```bash
cd panel
npm ci
npx wrangler login
npx wrangler secret put ADMIN_PASSWORD      # 8+ characters
npx wrangler secret put TOKEN_KEY           # openssl rand -base64 32 — keep a copy somewhere safe
npx wrangler secret put CF_DNS_TOKEN        # optional, see below
# variables (wrangler.jsonc "vars", or the dashboard): ADMIN_HOSTS (set to admin.myroom.asia),
# PANEL_URL (https://sub.myroom.asia), CF_ZONE_ID (the zone's ID, optional); npm run bundle first
# so the Worker carries the server install (step 0)
npm run deploy
```

Then, in the Cloudflare dashboard:

- **Custom domains.** Add `admin.myroom.asia` and `sub.myroom.asia` to the Worker (Workers → psm-panel → Settings → Domains & Routes). `workers.dev` and preview addresses are switched off in `wrangler.jsonc` (and `*.workers.dev` is blocked in mainland China anyway).
- **The admin page answers on `ADMIN_HOSTS` only** (`admin.myroom.asia`). Every other name, `sub.myroom.asia` included, serves only `/sub/…` (subscriptions) and `/api/agent/…` (psm-agent, which authenticates with its own token): the login page and admin API are a 404 there.
- **Cloudflare Access** (free for small teams) in front of `admin.myroom.asia`: an e-mail login before the panel's own password. Leave `sub.myroom.asia` open, because clients have to reach it.
- **Panel address.** In the panel, go to 系统设置 → 面板地址 and set `https://sub.myroom.asia`. Install commands and subscription links use it.

`CF_DNS_TOKEN`: create a Cloudflare API token with **Zone · DNS · Edit**, limited to the `myroom.asia` zone, and set `CF_ZONE_ID` to that zone's ID (Overview page, right column). Without `CF_ZONE_ID` the token also needs **Zone · Zone · Read** so the panel can find the zone. The panel then keeps each server's host name (服务器 → ⋯ → 域名跟随 IP) pointing at the server's current IPv4 address, unproxied with TTL 60; after a failed update it waits 10 minutes before trying again.

**Domains.** Put the nodes' host names on a different registered domain from `admin.` and `sub.` (`admin.myroom.asia` and `sub.myroom.asia` for the panel, `n1…nN.<your node domain>` for the servers; the `nN.myroom.asia` names used elsewhere in this guide are just examples). Certificate transparency logs publish every node name, and one blocked suffix should not take out both the nodes and the subscription host you would use to ship replacements. `CF_ZONE_ID` names the nodes' zone.

**Logs.** Workers invocation logs are off (`wrangler.jsonc`): they would record each request's URL, and a subscription URL is that friend's key.

**Time.** Days, months and expiry dates are Beijing time (UTC+8): an expiry date ends at 23:59 there, and periods and daily charts start at midnight there.

## 2. Each server

0. The panel's install command is plain `sh` with curl or wget, so it runs on a bare Alpine too. Use a fresh VPS (reinstalling the old DMIT box is simplest): roomkey joins only servers whose cores, if any, run exactly PSM's own service setup, so a server with an older PSM install or another proxy setup is refused, unchanged. Join refuses, and leaves the server as it is, when anything on it is a proxy PSM did not make: another panel (3x-ui, Marzban) or its containers, an Xray started some other way or at boot, inbounds in a core's config that are no PSM node's, or a public listener without accounts. The output names each one. Don't install nginx yourself, nor bootstrap with one: a server with nginx already on it, or with files left under `/etc/nginx` by a removed one (`apt purge nginx-common` clears them), is refused (PSM installs nginx with the first node on the shared 443 and writes all of its configuration).
1. Create an A record `nN.myroom.asia` for the server, **DNS only (grey cloud)**. Once the server has joined, the panel keeps it updated.
2. Make sure ports 80 and 443 are open. 80 answers the certificate's HTTP-01 challenges, at issue and at every renewal (keep it open); everything else on it is a 404.
3. In the panel: 服务器 → 添加服务器. Run the command it gives you as root.
4. Set its host name: 服务器 → ⋯ → 域名跟随 IP → `nN.myroom.asia`.
5. Create the REALITY node with 本机域名 `nN.myroom.asia`, and use `nN.myroom.asia` as the node address as well. REALITY always falls back to the node's own HTTPS site (127.0.0.1:8443, a Let's Encrypt certificate renewed over a permanent port-80 challenge site); there is no third-party target to pick, and PSM refuses a CDN-fronted one even from its own command line.
6. Check from another machine that the old relay is gone:
   `curl -sv --resolve persistent.oaistatic.com:443:<IP> https://persistent.oaistatic.com -o /dev/null`
   must **not** return `server: cloudflare`.

The local page (optional): 服务器 → ⋯ → 本机页面 gives you an SSH command and a one-time code. You can also set a permanent password on the server with `printf '%s' 'a-long-password' | psm-agent local-password`.

## 3. Users

用户 → 新建用户. Send them the link from the user's page. Opened in a browser, it shows their usage and one-tap import buttons for Shadowrocket, Clash Verge and sing-box. Throne takes the link pasted in as a subscription.

- Per-user traffic is counted on **Xray** nodes only. Run Hysteria2 on Xray if it should count. AnyTLS runs on sing-box only, so it isn't counted per user: users with a quota, or with a "from first use" term that hasn't started, don't get it unless you tick the option to include unmetered nodes.
- A server's nodes appear in a user's subscription once that server has taken the user (a few seconds after saving); the user's page in the panel shows 已下发 / 未下发 per server.
- Every core blocks SMTP (port 25) outbound, and Xray and sing-box block BitTorrent they recognise by sniffing (detection is best effort; mihomo has no BitTorrent rule). These are the usual causes of abuse complaints on a shared server, and the rules are put back at every core restart.
- Every start of a core (PSM's restarts, installs, restores, reboots, rollbacks) passes a check in the service's pre-start hook: any REALITY or ShadowTLS fallback other than PSM's own site (`127.0.0.1:8443`) stops the core from starting at all.
- Changing only a node's traffic limit or reset day doesn't touch the server's cores: only the meter changes, and the node stays applied. A paused node is unpaused when its limit is raised past its use or its period resets; other nodes on the same port keep their own pause.
- No relays (中转): servers are reached directly. A relay is a public forward, the easiest way to become an open relay. Neither the panel nor PSM can make one (PSM's nginx menus take only loopback upstreams, and every nginx reload, every nginx start under systemd and `psm guard` refuse a `proxy_pass`, upstream server or SNI route off the server), and `psm guard` (run by `psm agent join` and every upgrade) removes any relay rule a server has and takes realm and gost off the server (stopped, disabled, their units, binaries and generated configs removed); a server where that can't be shown doesn't join or upgrade. Every core start also refuses a public SOCKS, HTTP or mixed listener without accounts (or, on mihomo, with UDP), any public port forward, and a VLESS/Trojan fallback off the server. The panel offers no SOCKS nodes, and PSM makes SOCKS on 127.0.0.1 only. A psm-agent older than roomkey's (a server from psm-panel) is sent nothing but its upgrade.
- Hysteria2 nodes have no masquerade (a request without the password gets 404). A masquerade that proxies another site would fetch that site for anyone at your expense, so PSM refuses it and removes it at every core start.
- The panel only changes, meters or removes a node it made: psm-agent confirms each create. Creating a node whose name is already taken on the server by one made there by hand fails with a note and leaves that node alone; deleting the panel's row then only removes it from the panel.
- Removing a server (服务器 → 删除) asks its agent to remove the panel's users first. If that fails, the server stays in the list with the reason. Use on a removed server still counts toward each user's total for the current period.
- Device limits count client IPs on Xray nodes. A user over the limit is paused for 15 minutes. Nodes on the shared 443 (nginx) only see 127.0.0.1, so they don't count toward the limit. Pausing and resuming a user changes what their servers serve, so those servers' cores restart (twice per episode), briefly dropping everyone's connections there: leave the limit empty (unlimited) for most friends, and use it only where sharing is the problem.

## 4. Telegram (optional)

系统设置 → Telegram 告警: a bot token from @BotFather and your chat ID. Send the bot a message first, then use 发测试消息.

## 5. Backups

- 系统设置 → 备份 downloads a SQL file. Restore with `npx wrangler d1 execute psm-panel --remote --file roomkey-backup-….sql` into a panel whose tables exist (open it once first). Secrets stay encrypted, so keep `TOKEN_KEY` separately; traffic history and queued tasks are not included, and every server is sent its user list again afterwards.
- D1 Time Travel can also restore the database to any minute in the last 30 days (paid plan) or 7 days (free plan).

## 6. Day two

- **Checks.** CI (`.github/workflows/ci.yml`) runs on every push: the stack's ShellCheck, i18n and shell tests, psm-agent's vet and race tests, and the panel's typecheck, tests, build and end-to-end run (`cd panel && npm run e2e`).
- **Updating the panel.** `cd panel && npm run deploy` after pulling. Migrations apply on the next request.
- **Updating a server.** 服务器 → 升级 agent / 更新 PSM (or `psm upgrade` on the server). Every upgrade runs `psm guard` and stops if a core is left unsafe.
- **Adding a server.** 服务器 → 添加, then run the command on a fresh VPS. Then create its nodes and tick it for the users who should have it (labels).
- **Moving a server** (a new IP, a blocked one): add the new server, recreate its nodes, then remove the old one. Give the new server the old `nN.myroom.asia` name and users only need to refresh their subscription (the new nodes have new keys).
- **Removing a server.** The panel takes its users off it first, then the server leaves when psm-agent confirms; its last usage is kept.
- **A friend leaves.** Disable the user (each server takes it at its next sync, within about 30 seconds), or delete them. A shared link: rotate it from the user's page (the old one stops working).
- **Something looks wrong on a server.** `psm doctor`, `psm guard`, and the server's local page (code from the panel) show cores, listeners and recent events.
