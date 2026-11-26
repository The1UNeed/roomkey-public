// PSM panel backend: servers, nodes, traffic, subscriptions, the one-click
// install command, and the task queue each server's psm-agent syncs with. The
// panel never connects to a server: agents connect out to it (like Xboard's
// node backends), so no server needs a subdomain or an open port.
import { Hono, type Context } from 'hono'
import { decrypt, encrypt } from './crypto'
import { ensureSchema, storedTokenKey, UpstreamDatabase } from './schema'
import {
  adminConfigured, clearFailures, clearedCookie, ipKey, passwordIgnored, passwordMatches, recordFailure, revokeSessions,
  usernameMatches, usernameRequired,
  sessionCookie, syncAdminPassword, tooManyFailures, validSession,
} from './auth'
import { buildSubscription, displayName, pickFormat, renamed, type SubNode } from './subscription'
import { BUILTIN_TEMPLATES, FORMAT_LABELS, TEMPLATE_FORMATS, type TemplateFormat } from './templates'
import { activeFields, currentVariant, findVariant, trafficTag, validateNode, type NodeInput } from '../../shared/protocols'
import { applyLeaveUsage, cron as roomkeyCron, onSync as roomkeySync, reconcileUsers, registerRoutes as registerRoomkey, userSubscription, userSyncResult, type Deps } from './roomkey'

// not exported: every export of a Worker's main module is taken for an entrypoint
// Shown in 系统设置 as 面板版本; bump it whenever the panel gains something, so
// that it answers "did my deploy take effect?" — the only marker a user has.
const PANEL_VERSION = '0.11.0-roomkey'
/** A result the panel could not record (its node is failed; whether it ran on the server is unknown). */
const UNRECORDED = '面板没能记录这个结果：'
/** A create the server refused because the same node (or standalone server) is already there, not the panel's: never removed by the panel. */
const CONFLICT = '服务器上已有同名节点（不是面板建的），没有动它：'

// The psm-agent release this panel expects its servers to run: the 服务器 page
// offers an upgrade to every joined server reporting anything else. Bump it
// together with the agent-v… release the panel's install command installs.
const AGENT_VERSION = '0.14.0'

export type Env = {
  DB: D1Database
  ASSETS: Fetcher
  /** the admin password (secret; the Deploy to Cloudflare form asks for it) */
  ADMIN_PASSWORD?: string
  /** the admin username (secret, optional): when set, sign-in asks for it too */
  ADMIN_USERNAME?: string
  /** the key for D1 (secret, optional): filled in from D1's own when not set */
  TOKEN_KEY: string
  /** the panel's public address, used in the install command (default: the request's origin) */
  PANEL_URL?: string
  /** where bootstrap.sh is served */
  INSTALL_URL?: string
  ALLOW_HTTP_INSTALL?: string   // local tests only: an http:// panel address in the install script
  /** seconds between agent syncs when there is nothing to do (default 30) */
  SYNC_INTERVAL?: string
  /** tests only: a stand-in for Netlas's API (the REALITY target search) */
  /** a Cloudflare API token (Zone · DNS · Edit) for keeping servers' host names on their addresses (secret, optional) */
  CF_DNS_TOKEN?: string
  /** the Cloudflare zone of the servers' host names (optional: found by name, which needs Zone · Zone · Read) */
  CF_ZONE_ID?: string
  /** the host names the admin page and API answer on (comma-separated); others serve only /sub/ and /api/agent/ */
  ADMIN_HOSTS?: string
  /** the git repository servers install PSM (and psm-agent's release) from, passed to bootstrap.sh --repo */
  PSM_REPO?: string
  /** tests only: stand-ins for Cloudflare's and Telegram's APIs */
  CF_API_BASE?: string
  TELEGRAM_API_BASE?: string
}

type ServerRow = {
  id: number; name: string; agent_token_hash: string | null; hostname: string | null
  agent_version: string | null; note: string; last_seen: string | null; created_at: string
  psm_version: string | null; status_enc: string | null; status_at: string | null
  leaving: number; leave_error: string | null
  last_ip: string | null
  asn: number | null; country: string | null; sync_window: string | null; sync_count: number
  check_enc: string | null; check_at: string | null; check_error: string | null
}
type NodeRow = {
  id: number; server_id: number; protocol: string; variant: string; engine: string; psm_protocol: string
  name: string; address: string; port: number; public_port: number | null; traffic_limit_gb: number
  labels: string; params_enc: string; link_enc: string | null; outbound_enc: string | null; clash_enc: string | null
  status: string; last_error: string | null; created_at: string
  traffic_used: number; traffic_paused: number; traffic_at: string | null; reset_day: number
  mount_443: number; display_name: string; owned: number
}
type TaskRow = { id: number; server_id: number; node_id: number | null; relay_id: number | null; kind: string; payload_enc: string; status: string }
type AgentResult = { task_id: number; uid?: string; ok: boolean; link?: string; outbound?: unknown; clash?: unknown; error?: string; output?: unknown }
type TrafficEntry = { tag?: unknown; used_bytes?: unknown; paused?: unknown }
type C = Context<{ Bindings: Env }>

const app = new Hono<{ Bindings: Env }>()

const fail = (code: string, message: string, extra: Record<string, unknown> = {}) => ({ error: { code, message, ...extra } })
const SERVER_NAME_RE = /^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$/
const JOIN_TTL_HOURS = 24
const FAST_INTERVAL = 3        // seconds between syncs while a server has tasks under way
const TASK_RETRY_MINUTES = 5   // a task claimed but not reported for this long is handed out again
const GB = 1024 ** 3
const MASK = '••••••'          // how the page sees a stored password
const SYNCS_PER_MINUTE = 120   // more from one agent token is not a psm-agent: it is told to slow down

// Agents sync every SYNC_INTERVAL seconds when idle (30 by default; each sync
// is one Worker request and one D1 write, so a longer interval leaves the free
// quotas for more servers) and every FAST_INTERVAL seconds while tasks are
// under way. A server is online while it synced within three intervals.
function syncInterval(env: Env): number {
  const n = Number(env.SYNC_INTERVAL)
  return Number.isFinite(n) && n >= 5 && n <= 300 ? Math.round(n) : 30
}

app.onError((err, c) => {
  if (err instanceof UpstreamDatabase) return c.json(fail('upstream_database', err.message), 503)
  console.error(err)
  return c.json(fail('internal', 'internal error'), 500)
})

// ── helpers ──────────────────────────────────────────────────────────────────
async function sha256Hex(s: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)))
  return [...d].map((b) => b.toString(16).padStart(2, '0')).join('')
}

function randomToken(bytes = 32): string {
  const b = crypto.getRandomValues(new Uint8Array(bytes))
  return btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

async function getSetting(env: Env, key: string): Promise<string | null> {
  const r = await env.DB.prepare('SELECT value FROM settings WHERE key = ?').bind(key).first<{ value: string }>()
  return r?.value ?? null
}

/** The address servers and subscribers use: the setting, PANEL_URL, or this request's origin. */
async function panelUrl(c: C): Promise<string> {
  return (await getSetting(c.env, 'panel_url')) || c.env.PANEL_URL || new URL(c.req.url).origin
}

// roomkey's servers must get roomkey's PSM and psm-agent (users, own-site
// REALITY): with no INSTALL_URL there is no command to run — a shell comment
// that does nothing, rather than one that silently installs upstream's.
async function installCommand(c: C, token: string): Promise<string> {
  // roomkey's private install: PSM and psm-agent come from this panel itself
  // (the bundle setup.sh deploys with it), so no repository has to be public
  if (await hasBundle(c)) {
    const url = `${await panelUrl(c)}/api/agent/install/${token}`
    return `(command -v curl >/dev/null 2>&1 && curl -fsSL ${url} || wget -qO- ${url}) | sh`
  }
  const install = c.env.INSTALL_URL, repo = c.env.PSM_REPO
  const url = /^https:\/\/[A-Za-z0-9.-]+\/[A-Za-z0-9._/%-]+$/
  if (!install || !repo || !url.test(install) || !url.test(repo))
    return '# 面板还没有设置 INSTALL_URL 和 PSM_REPO（两个都要，https:// 地址），装不了 roomkey 版的 PSM 和 psm-agent：见 docs/DEPLOY.md 第 0 步'
  // POSIX sh, curl or wget: a bare Alpine has neither bash nor curl (the
  // bootstrap's shim installs bash, then runs itself again from this URL)
  return `(command -v curl >/dev/null 2>&1 && curl -fsSL ${install} || wget -qO- ${install}) | PSM_BOOTSTRAP_URL=${install} sh -s -- --panel ${await panelUrl(c)} --join ${token} --repo ${repo}`
}

async function audit(env: Env, action: string, target = '', detail = '', actor = 'admin') {
  await env.DB.prepare('INSERT INTO audit (actor, action, target, detail) VALUES (?, ?, ?, ?)')
    .bind(actor, action, target.slice(0, 120), detail.slice(0, 500)).run()
}

/**
 * The join token in a server's install command: the one it has while that
 * stays valid for another hour, or a new one. Every node added to a
 * server that has not joined yet shows the same command — forty nodes do not
 * mint forty live tokens (the audit's L7) — and a command already handed out
 * keeps working. The token is kept encrypted to be shown again; D1 never has
 * it in clear. `fresh`: a new token, and every older one stops working (安装命令
 * → 重新生成). The first one used makes the server join and voids the rest.
 */
async function joinToken(env: Env, serverId: number, fresh = false): Promise<string> {
  if (!fresh) {
    const live = await env.DB.prepare(
      `SELECT token_enc FROM join_tokens WHERE server_id = ? AND used_at IS NULL AND token_enc IS NOT NULL
          AND expires_at > datetime('now', '+1 hours') ORDER BY expires_at DESC LIMIT 1`).bind(serverId).first<{ token_enc: string }>()
    if (live) {
      try { return await decrypt(env.TOKEN_KEY, live.token_enc) } catch { /* written under another key: a new one */ }
    }
  }
  const token = randomToken()
  await env.DB.batch([
    env.DB.prepare(`DELETE FROM join_tokens WHERE expires_at <= datetime('now')`),
    ...(fresh ? [env.DB.prepare(`DELETE FROM join_tokens WHERE server_id = ? AND used_at IS NULL`).bind(serverId)] : []),
    env.DB.prepare(`INSERT INTO join_tokens (token_hash, server_id, expires_at, token_enc) VALUES (?, ?, datetime('now', '+${JOIN_TTL_HOURS} hours'), ?)`)
      .bind(await sha256Hex(token), serverId, await encrypt(env.TOKEN_KEY, token)),
  ])
  return token
}

const serverStatusSQL = (env: Env) => `CASE WHEN s.leaving = 1 THEN 'leaving' WHEN s.agent_token_hash IS NULL THEN 'pending'
  WHEN s.last_seen >= datetime('now', '-${syncInterval(env) * 3} seconds') THEN 'online' ELSE 'offline' END`

/** A row id from the URL or a body: a positive integer, or null (never NaN into a query). */
function idOf(v: unknown): number | null {
  const s = String(v ?? '')
  return /^[1-9]\d{0,15}$/.test(s) ? Number(s) : null
}

async function getServer(env: Env, id: unknown): Promise<ServerRow | null> {
  const n = idOf(id)
  return n === null ? null : env.DB.prepare('SELECT * FROM servers WHERE id = ?').bind(n).first<ServerRow>()
}

async function getNode(env: Env, id: unknown): Promise<NodeRow | null> {
  const n = idOf(id)
  return n === null ? null : env.DB.prepare('SELECT * FROM nodes WHERE id = ?').bind(n).first<NodeRow>()
}

/** A task, as a statement to run alone or in a batch with others. */
async function taskStmt(env: Env, serverId: number, nodeId: number | null, task: Record<string, unknown>) {
  // uid: the task's own name, whatever its row number (a panel restored from a
  // backup numbers tasks from 1 again): psm-agent answers a task handed out
  // again from its journal only for the same uid, and a result counts only
  // for the task whose uid it carries
  return env.DB.prepare('INSERT INTO tasks (server_id, node_id, kind, payload_enc) VALUES (?, ?, ?, ?)')
    .bind(serverId, nodeId, task.kind as string, await encrypt(env.TOKEN_KEY, JSON.stringify({ ...task, uid: crypto.randomUUID() })))
}

async function enqueue(env: Env, serverId: number, nodeId: number | null, task: Record<string, unknown>): Promise<number> {
  const r = await (await taskStmt(env, serverId, nodeId, task)).run()
  return Number(r.meta.last_row_id)
}

const linkFormat = (n: { psm_protocol: string }) => (n.psm_protocol === 'snell' ? 'surge' : 'uri')

/**
 * The tasks that put a node on its server.
 *
 * A node the panel owns (psm-agent confirmed it created it: nodes.owned) is
 * changed in place, or created again if it is gone, and its traffic metering
 * and limit follow. One it does not own yet goes as a first create, and
 * nothing else does: psm-agent refuses it as a conflict if a node of that name
 * is already there (made by hand), and the metering is queued only once the
 * create is confirmed (applyResult), so a node that turns out to be someone
 * else's is never touched.
 */
async function applyStmts(env: Env, n: NodeRow, data: Record<string, unknown>, onServer = false) {
  const owned = !!n.owned
  const common = { protocol: n.psm_protocol, server: n.address, format: linkFormat(n), ...(owned ? { recover: true } : {}) }
  const task = n.engine === 'standalone'
    ? { kind: 'standalone.install', tag: n.name, data, ...common, ...(owned ? {} : { create: true }) }
    : owned && onServer
      ? { kind: 'node.update', core: n.engine, tag: n.name, data, mount443: !!n.mount_443, ...common }
      // mount443 is not a node setting but how PSM must create it (--mount-443)
      : { kind: 'node.add', core: n.engine, data, mount443: !!n.mount_443, ...common }
  const stmts = [await taskStmt(env, n.server_id, n.id, task)]
  if (owned) stmts.push(await taskStmt(env, n.server_id, n.id, trafficTask(n)))
  return stmts
}

/** Queue a node marked "queued"; if the task can't be written, the node is failed (saving retries), never queued with nothing on its way. */
async function queueOrFail(env: Env, n: NodeRow, data: Record<string, unknown>, onServer = false) {
  try {
    await env.DB.batch(await applyStmts(env, n, data, onServer))
  } catch (e) {
    await env.DB.prepare(`UPDATE nodes SET status = 'failed', last_error = ? WHERE id = ?`)
      .bind(`没能下发：${(e as Error).message}`.slice(0, 500), n.id).run()
    throw e
  }
}

/**
 * Ask a server for its nodes' client exports again (share link, sing-box
 * outbound, mihomo proxy). A PSM update can change them without the node
 * changing — a certificate pin in the links, a node newly written as a mihomo
 * proxy — and the panel only stores what the agent sent at the node's last add
 * or edit. Standalone servers export the same as before.
 */
async function queueExports(env: Env, serverId: number) {
  const { results } = await env.DB.prepare(
    `SELECT * FROM nodes WHERE server_id = ? AND status = 'applied' AND owned = 1 AND engine != 'standalone'`).bind(serverId).all<NodeRow>()
  const stmts = await Promise.all(results.map((n) => taskStmt(env, serverId, n.id,
    { kind: 'node.export', core: n.engine, protocol: n.psm_protocol, tag: n.name, server: n.address, format: linkFormat(n) })))
  if (stmts.length) await env.DB.batch(stmts)
}

function trafficTask(n: NodeRow) {
  return { kind: 'traffic.set', tag: trafficTag(n), limit_bytes: Math.round(Math.min(n.traffic_limit_gb || 0, 1e6) * GB), reset_day: n.reset_day || 1 }
}

/** The node store fields for a node (as validated when it was entered). */
async function nodeData(env: Env, n: NodeRow): Promise<Record<string, unknown>> {
  const params = JSON.parse(await decrypt(env.TOKEN_KEY, n.params_enc)) as Record<string, unknown>
  const v = validateNode({
    protocol: n.protocol, variant: n.variant, engine: n.engine as NodeInput['engine'], name: n.name,
    address: n.address, port: n.port, public_port: n.public_port ?? undefined, params,
  })
  if (!v.ok) throw new Error(`stored node ${n.id} no longer validates: ${v.errors.join('; ')}`)
  return v.data
}

/** What a display name already in use says, or null: two nodes of one name would be one proxy to Clash. */
async function displayNameTaken(env: Env, name: string | undefined, id: number | null): Promise<string | null> {
  if (!name) return null
  const hit = await env.DB.prepare('SELECT 1 FROM nodes WHERE display_name = ? AND id != ?').bind(name, id ?? -1).first()
  return hit ? `显示名：「${name}」已经是另一个节点的名字` : null
}

/** A node row for the list: nothing decrypted (a list of many nodes costs no AES), no link. */
function listNode(n: NodeRow) {
  const { params_enc: _p, link_enc: _l, outbound_enc: _o, clash_enc: _c, ...rest } = n
  return { ...rest, traffic_paused: !!n.traffic_paused, mount_443: !!n.mount_443,
    labels: JSON.parse(n.labels) as string[], has_link: !!n.link_enc }
}

/** A node row for its edit form: params decrypted, secrets masked, no link. */
async function publicNode(env: Env, n: NodeRow) {
  const params = JSON.parse(await decrypt(env.TOKEN_KEY, n.params_enc)) as Record<string, unknown>
  const v = findVariant(n.protocol, n.variant)
  const secret = new Set((v?.fields ?? []).filter((f) => f.type === 'password').map((f) => f.key))
  for (const k of Object.keys(params)) if (secret.has(k) && params[k]) params[k] = MASK
  return { ...listNode(n), params }
}

function cleanLabels(raw: unknown): string[] {
  return (Array.isArray(raw) ? raw : []).map(String).map((l) => l.trim().slice(0, 24)).filter(Boolean).slice(0, 10)
}

/** The params a node keeps: those of its form, with masked passwords replaced by the stored ones. */
function keptParams(variantFields: { key: string }[], incoming: Record<string, unknown>, stored: Record<string, unknown> = {}) {
  const params: Record<string, unknown> = {}
  for (const f of variantFields) {
    let v = incoming[f.key]
    if (v === MASK) v = stored[f.key]
    if (v !== undefined && v !== '') params[f.key] = v
  }
  return params
}

// VLESS nodes made before 0.10.2 get the variant they have now
// (currentVariant in shared/protocols.ts): only the panel's record changes.
// It reads their settings, so it runs after the key, once per database, and
// is recorded among the migrations. A node whose settings do not decrypt
// (written under another key) leaves it to be tried again.
const VARIANTS_MIGRATION = 'data:0015_vless_variants'
let variantsReady: Promise<void> | null = null
async function migrateVariants(env: Env) {
  if (await env.DB.prepare('SELECT 1 FROM psm_migrations WHERE name = ?').bind(VARIANTS_MIGRATION).first()) return
  const { results } = await env.DB.prepare(
    `SELECT id, protocol, variant, engine, params_enc FROM nodes WHERE protocol = 'vless' AND variant IN ('vless-tls', 'vless-xhttp')`)
    .all<Pick<NodeRow, 'id' | 'protocol' | 'variant' | 'engine' | 'params_enc'>>()
  const stmts: D1PreparedStatement[] = []
  let unreadable = 0
  for (const n of results) {
    let params: Record<string, unknown>
    try {
      params = JSON.parse(await decrypt(env.TOKEN_KEY, n.params_enc)) as Record<string, unknown>
    } catch {
      unreadable++
      continue
    }
    const v = currentVariant(n.protocol, n.variant, n.engine, params)
    if (v !== n.variant) stmts.push(env.DB.prepare('UPDATE nodes SET variant = ? WHERE id = ?').bind(v, n.id))
  }
  if (!unreadable) stmts.push(env.DB.prepare('INSERT OR IGNORE INTO psm_migrations (name) VALUES (?)').bind(VARIANTS_MIGRATION))
  else console.error(`vless variants: ${unreadable} node(s) not readable, left for the next start`)
  if (stmts.length) await env.DB.batch(stmts)
}

// ── every request the Worker sees: the tables and the key ────────────────────
// Where TOKEN_KEY came from: the secret, or the panel's own copy in D1 (a
// one-click deploy); 系统设置 warns about the second.
let tokenKeySource: 'secret' | 'panel' | null = null
let panelKey: string | null = null
// The admin page and API answer only on the admin host names (ADMIN_HOSTS,
// where Cloudflare Access sits in front); every other name the Worker has (the
// public subscription host) serves subscriptions and the agents' endpoints
// only. Unset: every host serves everything (local development).
app.use('*', async (c, next) => {
  const admin = (c.env.ADMIN_HOSTS ?? '').split(',').map((h) => h.trim().toLowerCase()).filter(Boolean)
  if (admin.length) {
    const u = new URL(c.req.url)
    if (!admin.includes(u.hostname.toLowerCase()) && !u.pathname.startsWith('/sub/') && !u.pathname.startsWith('/api/agent/'))
      return c.text('not found', 404)
  }
  await next()
})

app.use('*', async (c, next) => {
  await ensureSchema(c.env.DB)
  tokenKeySource ??= c.env.TOKEN_KEY ? 'secret' : 'panel'
  if (!c.env.TOKEN_KEY) c.env.TOKEN_KEY = panelKey ??= await storedTokenKey(c.env.DB)
  variantsReady ??= migrateVariants(c.env).catch((e) => { variantsReady = null; throw e })
  await variantsReady
  // after TOKEN_KEY: the session signature is derived from it
  await syncAdminPassword(c.env)
  await next()
})

// Every answer from the API: never sniffed as another type, never framed,
// never cached (it carries links, keys and tokens), no referrer. The pages
// themselves get theirs from web/public/_headers.
app.use('/api/*', async (c, next) => {
  await next()
  c.header('X-Content-Type-Options', 'nosniff')
  c.header('X-Frame-Options', 'DENY')
  c.header('Referrer-Policy', 'no-referrer')
  if (!c.res.headers.has('Cache-Control')) c.header('Cache-Control', 'no-store')
})
app.use('/sub/*', async (c, next) => {
  await next()
  c.header('X-Content-Type-Options', 'nosniff')
  c.header('Referrer-Policy', 'no-referrer')
})

// A change made from a browser must come from the panel's own page. The
// cookie is SameSite=Strict already; this is the second lock. Browsers say
// where a request comes from in Sec-Fetch-Site (a proxy in front cannot make
// that look cross-site, as it could a Host that differs from the Origin);
// one too old for it still sends Origin. Tools without a browser send
// neither and are let through on their session alone.
const CHANGES = new Set(['POST', 'PUT', 'PATCH', 'DELETE'])
function crossSite(c: C): boolean {
  if (!CHANGES.has(c.req.method)) return false
  const site = c.req.header('Sec-Fetch-Site')
  if (site) return site !== 'same-origin' && site !== 'none'
  const origin = c.req.header('Origin')
  return !!origin && origin !== new URL(c.req.url).origin
}

// The admin API needs a session. psm-agent's endpoints use its own token, and
// signing in is open (limited per address).
const OPEN = new Set(['/api/session', '/api/login', '/api/logout'])
app.use('/api/*', async (c, next) => {
  const path = new URL(c.req.url).pathname
  if (path.startsWith('/api/agent/')) return next()
  if (crossSite(c)) return c.json(fail('cross_site', 'a change must come from the panel itself'), 403)
  if (OPEN.has(path)) return next()
  if (!adminConfigured(c.env)) return c.json(fail('not_configured', 'set the ADMIN_PASSWORD secret (8+ characters)'), 503)
  if (!(await validSession(c.env, c.req.header('Cookie')))) return c.json(fail('unauthorized', 'sign in first'), 401)
  await next()
})

const isHttps = (url: string) => new URL(url).protocol === 'https:'

app.get('/api/session', async (c) =>
  c.json({ configured: adminConfigured(c.env), authenticated: await validSession(c.env, c.req.header('Cookie')),
    version: PANEL_VERSION, password_ignored: passwordIgnored(c.env), username_required: usernameRequired(c.env) }))

app.post('/api/login', async (c) => {
  if (!adminConfigured(c.env)) return c.json(fail('not_configured', 'set the ADMIN_PASSWORD secret (8+ characters)'), 503)
  const ip = ipKey(c.req.header('CF-Connecting-IP') ?? 'unknown')
  if (await tooManyFailures(c.env.DB, ip)) return c.json(fail('too_many', 'too many failed sign-ins; try again in 15 minutes'), 429)
  const body = await c.req.json<{ username?: unknown; password?: unknown }>().catch(() => null)
  const text = (v: unknown) => (typeof v === 'string' ? v : '')
  // both checked every time, so a wrong username takes as long as a wrong password
  const [userOk, passOk] = await Promise.all([
    usernameMatches(c.env, text(body?.username)), passwordMatches(c.env, text(body?.password))])
  if (!userOk || !passOk) {
    await recordFailure(c.env.DB, ip)
    await audit(c.env, 'login.failed', ip, '', 'anonymous')
    return c.json(fail('bad_password', usernameRequired(c.env) ? 'wrong username or password' : 'wrong password'), 401)
  }
  await clearFailures(c.env.DB, ip)
  await audit(c.env, 'login', ip)
  c.header('Set-Cookie', await sessionCookie(c.env, isHttps(c.req.url)))
  return c.json({ ok: true })
})

// Signing out ends every session (see auth.ts) — only for someone signed in:
// anyone may ask for their cookie to be cleared, not end the admin's.
app.post('/api/logout', async (c) => {
  if (await validSession(c.env, c.req.header('Cookie'))) {
    await revokeSessions(c.env.DB)
    await audit(c.env, 'logout', ipKey(c.req.header('CF-Connecting-IP') ?? ''))
  }
  c.header('Set-Cookie', clearedCookie(isHttps(c.req.url)))
  return c.body(null, 204)
})

// ── servers ──────────────────────────────────────────────────────────────────
app.get('/api/servers', async (c) => {
  const { results } = await c.env.DB.prepare(
    `SELECT s.id, s.name, ${serverStatusSQL(c.env)} AS status, s.hostname, s.agent_version, s.psm_version, s.note,
            s.last_seen, s.created_at, s.status_at, s.leave_error, s.last_ip,
            s.asn, s.country, s.dns_name, s.dns_ip, s.dns_error, s.users_error,
            (SELECT COUNT(*) FROM nodes n WHERE n.server_id = s.id) AS node_count,
            (SELECT COALESCE(SUM(n.traffic_used), 0) FROM nodes n WHERE n.server_id = s.id) AS traffic_used
       FROM servers s ORDER BY s.id`).all()
  // agent_latest rides along so the page can mark an outdated agent without a
  // second request
  return c.json(results.map((r) => ({ ...r, agent_latest: AGENT_VERSION })))
})

// Add a server; it waits for its install command.
app.post('/api/servers', async (c) => {
  const body = await c.req.json<{ name?: string; note?: string }>().catch(() => null)
  const name = body?.name?.trim().toLowerCase() ?? ''
  if (!SERVER_NAME_RE.test(name)) return c.json(fail('bad_name', 'name: 1-32 lowercase letters, digits and -'), 400)
  let id: number
  try {
    const r = await c.env.DB.prepare('INSERT INTO servers (name, note) VALUES (?, ?)').bind(name, body?.note?.slice(0, 200) ?? '').run()
    id = Number(r.meta.last_row_id)
  } catch (e) {
    if (String(e).includes('UNIQUE')) return c.json(fail('exists', 'a server with this name exists'), 409)
    throw e
  }
  await audit(c.env, 'server.add', name)
  return c.json({ id, install_command: await installCommand(c, await joinToken(c.env, id)) }, 201)
})

// A server's note.
app.patch('/api/servers/:id', async (c) => {
  const s = await getServer(c.env, c.req.param('id'))
  if (!s) return c.json(fail('not_found', 'no such server'), 404)
  const b = await c.req.json<{ note?: string }>().catch(() => null)
  if (!b || typeof b !== 'object') return c.json(fail('bad_body', 'the body must be a JSON object'), 400)
  const note = b.note === undefined ? s.note : String(b.note).slice(0, 200)
  await c.env.DB.prepare('UPDATE servers SET note = ? WHERE id = ?').bind(note, s.id).run()
  await audit(c.env, 'server.update', s.name)
  return c.json({ id: s.id, note })
})

// The server's install command: the same one while it is valid, or with
// {"fresh": true} a new one that voids the others (a command shown somewhere
// it should not have been).
app.post('/api/servers/:id/install-command', async (c) => {
  const s = await getServer(c.env, c.req.param('id'))
  if (!s) return c.json(fail('not_found', 'no such server'), 404)
  const fresh = (await c.req.json<{ fresh?: unknown }>().catch(() => null))?.fresh === true
  if (fresh) await audit(c.env, 'server.new-command', s.name)
  return c.json({ install_command: await installCommand(c, await joinToken(c.env, s.id, fresh)) })
})

// Upgrade psm-agent on a server, so that it does not need the install command
// run by hand over SSH. The agent reports this task before doing any of it: the
// upgrade updates PSM first (the psm-agent version to install is named in PSM's
// own lib/agent.sh), then replaces the binary and restarts the service, which
// stops the process that would otherwise report the result.
app.post('/api/servers/:id/upgrade-agent', async (c) => {
  const s = await getServer(c.env, c.req.param('id'))
  if (!s) return c.json(fail('not_found', 'no such server'), 404)
  if (!s.agent_token_hash) return c.json(fail('not_joined', 'the server has not joined yet'), 409)
  await enqueue(c.env, s.id, null, { kind: 'agent.update' })
  await audit(c.env, 'server.upgrade-agent', s.name, s.agent_version === AGENT_VERSION
    ? `更新 PSM（psm-agent 已是 ${AGENT_VERSION}）` : `${s.agent_version ?? '未知'} → ${AGENT_VERSION}`)
  return c.json({ status: 'queued' }, 202)
})

// Remove a server. One that has joined is asked to clean up first: its agent
// deletes the nodes and standalone servers made from the panel (not those made
// on the server's own command line; PSM and the cores stay), reports, and
// uninstalls psm-agent; the server leaves the panel when that report arrives
// (202). ?force=1 removes it from the panel only — for a server that is gone or
// offline (it keeps its nodes; `psm agent remove --yes` there uninstalls the
// agent). One that never joined goes at once (204).
app.delete('/api/servers/:id', async (c) => {
  const s = await getServer(c.env, c.req.param('id'))
  if (!s) return c.json(fail('not_found', 'no such server'), 404)
  const force = new URL(c.req.url).searchParams.get('force') === '1'
  if (!s.agent_token_hash || force) {
    await c.env.DB.batch([bankRetired(c.env, s.id), c.env.DB.prepare('DELETE FROM servers WHERE id = ?').bind(s.id)])
    await audit(c.env, s.agent_token_hash ? 'server.forget' : 'server.delete', s.name)
    return c.body(null, 204)
  }
  // leaving with its leave task out: under way. Leaving without one (the
  // request that reserved it stopped before queuing it) is planned again.
  if (s.leaving && await c.env.DB.prepare(`SELECT 1 FROM tasks WHERE server_id = ? AND kind = 'agent.leave' AND status IN ('queued', 'running')`).bind(s.id).first())
    return c.json({ status: 'leaving' }, 202)
  // removal takes the panel's users off the server first, which only roomkey's
  // psm-agent does; an older one would leave accounts nothing could revoke
  if (!versionAtLeast(s.agent_version, OWN_SITE_AGENT))
    return c.json(fail('agent_too_old', `${s.name} 的 psm-agent 是 ${s.agent_version ?? '旧版'}，移除时不会删掉面板用户：先升级 psm-agent 再移除，或者选「只从面板移除」（服务器上的东西原样保留）`), 409)
  // A node task out on the server (a create whose answer has not come back)
  // would leave the plan below unsure what is the panel's: it settles first.
  // The server is marked leaving in the same statement that checks, and a
  // leaving server is handed nothing but its leave, so no create can start
  // between this check and the plan. (A node forgotten with ?force=1 is the
  // owner's call: its task no longer counts.)
  const reserved = await c.env.DB.prepare(`UPDATE servers SET leaving = 1, leave_error = NULL WHERE id = ?
      AND NOT EXISTS (SELECT 1 FROM tasks WHERE server_id = ? AND kind = 'agent.leave' AND status IN ('queued', 'running'))
      AND NOT EXISTS (SELECT 1 FROM tasks WHERE server_id = ? AND status = 'running' AND node_id IS NOT NULL
        AND kind IN ('node.add', 'node.update', 'node.delete', 'standalone.install', 'standalone.remove'))`).bind(s.id, s.id, s.id).run()
  if (!reserved.meta.changes) return c.json(fail('busy', `${s.name} 正在处理节点任务：等它完成后再移除（服务器不再上线的话，选「只从面板移除」）`), 409)
  // Only what psm-agent confirmed it created: a create that never ran, failed
  // or met a node made by hand there (a conflict) is not the panel's to remove.
  const { results } = await c.env.DB.prepare(`SELECT * FROM nodes WHERE server_id = ? AND owned = 1`).bind(s.id).all<NodeRow>()
  const plan = {
    nodes: results.filter((n) => n.engine !== 'standalone').map((n) => ({ core: n.engine, protocol: n.psm_protocol, tag: n.name })),
    standalone: [...new Set(results.filter((n) => n.engine === 'standalone').map((n) => n.psm_protocol))],
    // roomkey runs no relays: psm guard took them off when the server joined
    relays: [] as string[],
  }
  // never "leaving" for long without the task that does it
  try {
    await c.env.DB.batch([
      c.env.DB.prepare(`DELETE FROM tasks WHERE server_id = ? AND status = 'queued'`).bind(s.id),
      await taskStmt(c.env, s.id, null, { kind: 'agent.leave', data: plan }),
    ])
  } catch (e) {
    await c.env.DB.prepare(`UPDATE servers SET leaving = 0, leave_error = ? WHERE id = ?`).bind(`没能开始移除：${(e as Error).message}`.slice(0, 500), s.id).run()
    throw e
  }
  await audit(c.env, 'server.leave', s.name, `${plan.nodes.length} 个节点，${plan.standalone.length} 个独立安装`)
  return c.json({ status: 'leaving' }, 202)
})

// Diagnostics: ask the server's agent for a status report (psm doctor, cores,
// nodes, traffic, standalone servers); it arrives with the next sync.
app.post('/api/servers/:id/status', async (c) => {
  const s = await getServer(c.env, c.req.param('id'))
  if (!s) return c.json(fail('not_found', 'no such server'), 404)
  if (!s.agent_token_hash) return c.json(fail('not_joined', 'the server has not joined yet'), 409)
  await enqueue(c.env, s.id, null, { kind: 'status' })
  await audit(c.env, 'server.diagnose', s.name)
  return c.json({ status: 'queued' }, 202)
})

app.get('/api/servers/:id/status', async (c) => {
  const s = await getServer(c.env, c.req.param('id'))
  if (!s) return c.json(fail('not_found', 'no such server'), 404)
  const pending = !!(await c.env.DB.prepare(`SELECT 1 FROM tasks WHERE server_id = ? AND kind = 'status' AND status IN ('queued', 'running') LIMIT 1`)
    .bind(s.id).first())
  const report = s.status_enc ? JSON.parse(await decrypt(c.env.TOKEN_KEY, s.status_enc)) : null
  return c.json({ at: s.status_at, pending, report })
})

// ── the IP quality and unlock check (psm check, jinqians/ipcheck) ────────────
// The server runs it and reports; the last report stays on the server row.
app.post('/api/servers/:id/check', async (c) => {
  const s = await getServer(c.env, c.req.param('id'))
  if (!s) return c.json(fail('not_found', 'no such server'), 404)
  if (!s.agent_token_hash) return c.json(fail('not_joined', '服务器还没有接入面板'), 409)
  if (!versionAtLeast(s.agent_version, CHECK_AGENT))
    return c.json(fail('agent_too_old', `${s.name} 的 psm-agent 是 ${s.agent_version ?? '旧版'}，IP 检测要 ${CHECK_AGENT} 以上：先在 ⋯ 里升级 psm-agent`), 409)
  const body = await c.req.json<{ family?: unknown }>().catch(() => ({} as { family?: unknown }))
  const family = body.family === '4' || body.family === '6' ? body.family : ''
  if (await c.env.DB.prepare(`SELECT 1 FROM tasks WHERE server_id = ? AND kind = 'check.run' AND status IN ('queued', 'running') LIMIT 1`).bind(s.id).first())
    return c.json({ status: 'queued' }, 202)   // one is on its way already
  const keys = await ipcheckKeys(c.env)
  const data = { ...(family ? { family } : {}), ...(Object.keys(keys).length ? { keys } : {}) }
  await enqueue(c.env, s.id, null, { kind: 'check.run', ...(Object.keys(data).length ? { data } : {}) })
  await audit(c.env, 'server.check', s.name, family ? `IPv${family}` : '')
  return c.json({ status: 'queued' }, 202)
})

app.get('/api/servers/:id/check', async (c) => {
  const s = await getServer(c.env, c.req.param('id'))
  if (!s) return c.json(fail('not_found', 'no such server'), 404)
  const pending = !!(await c.env.DB.prepare(`SELECT 1 FROM tasks WHERE server_id = ? AND kind = 'check.run' AND status IN ('queued', 'running') LIMIT 1`)
    .bind(s.id).first())
  const report = s.check_enc ? JSON.parse(await decrypt(c.env.TOKEN_KEY, s.check_enc)) : null
  return c.json({ at: s.check_at, pending, report, error: s.check_error,
    // what the server needs first, if anything
    needs: !s.agent_token_hash ? 'join' : versionAtLeast(s.agent_version, CHECK_AGENT) ? null : CHECK_AGENT })
})

// ── nodes ────────────────────────────────────────────────────────────────────
// The list carries no settings (GET /api/nodes/:id does): decrypting every
// node's for a table that shows none of them was most of the list's cost.
app.get('/api/nodes', async (c) => {
  const sid = idOf(new URL(c.req.url).searchParams.get('server_id'))
  const stmt = sid !== null
    ? c.env.DB.prepare('SELECT * FROM nodes WHERE server_id = ? ORDER BY id').bind(sid)
    : c.env.DB.prepare('SELECT * FROM nodes ORDER BY id')
  const { results } = await stmt.all<NodeRow>()
  return c.json(results.map(listNode))
})

app.get('/api/nodes/:id', async (c) => {
  const n = await getNode(c.env, c.req.param('id'))
  return n ? c.json(await publicNode(c.env, n)) : c.json(fail('not_found', 'no such node'), 404)
})

// Create a node: checked against the protocol table and saved. On a server
// that has joined, tasks for its agent are queued; otherwise the node waits
// for the install command, which is then returned.
app.post('/api/nodes', async (c) => {
  const body = await c.req.json<NodeInput & { server_id?: number; reset_day?: number }>().catch(() => null)
  if (!body) return c.json(fail('bad_body', 'the body must be a JSON object'), 400)
  const server = await getServer(c.env, body.server_id ?? '')
  if (!server) return c.json(fail('bad_server', 'choose a server'), 400)
  const v = validateNode(body)
  if (!v.ok) return c.json(fail('invalid', v.errors.join('；'), { errors: v.errors }), 400)
  const tooOld = psmTooOld(server, v.data)
  if (tooOld) return c.json(fail('psm_too_old', tooOld, { errors: [tooOld] }), 409)
  const taken = await displayNameTaken(c.env, body.display_name, null)
  if (taken) return c.json(fail('exists', taken, { errors: [taken] }), 409)
  const resetDay = body.reset_day ?? 1
  if (!Number.isInteger(resetDay) || resetDay < 1 || resetDay > 28) return c.json(fail('invalid', '流量重置日：1-28', { errors: ['流量重置日：1-28'] }), 400)
  // on the shared 443 clients reach 443: another public port would be dropped without a word
  if (body.mount_443 && body.public_port !== undefined && body.public_port !== null && body.public_port !== 443) {
    const msg = '挂到 443 复用的节点，连接端口就是 443'
    return c.json(fail('invalid', msg, { errors: [msg] }), 400)
  }
  // one being removed does not count: its removal runs on the server before this install
  if (v.engine === 'standalone' && await c.env.DB.prepare(
    `SELECT 1 FROM nodes WHERE server_id = ? AND engine = 'standalone' AND psm_protocol = ? AND status != 'deleting'`).bind(server.id, v.psmProtocol).first()) {
    const msg = `${server.name} 已有一个独立安装的 ${v.psmProtocol === 'snell' ? 'Snell' : 'SS2022'}（每台服务器一个），可以改用内核运行`
    return c.json(fail('exists', msg, { errors: [msg] }), 409)
  }

  const variant = findVariant(body.protocol, body.variant)!
  const params = keptParams(activeFields(variant, v.engine, body.params ?? {}), body.params ?? {})
  const joined = !!server.agent_token_hash
  const status = joined ? 'queued' : 'waiting'
  const mount443 = !!body.mount_443

  let id: number
  try {
    const r = await c.env.DB.prepare(
      `INSERT INTO nodes (server_id, protocol, variant, engine, psm_protocol, name, address, port, public_port, traffic_limit_gb, reset_day, labels, params_enc, status, mount_443, display_name)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .bind(server.id, body.protocol, body.variant, v.engine, v.psmProtocol, body.name, body.address, body.port,
        // on the shared 443 the node listens on 127.0.0.1 and clients reach 443
        mount443 ? 443 : body.public_port ?? null, body.traffic_limit_gb ?? 0, resetDay, JSON.stringify(cleanLabels(body.labels)),
        await encrypt(c.env.TOKEN_KEY, JSON.stringify(params)), status, mount443 ? 1 : 0, body.display_name ?? '')
      .run()
    id = Number(r.meta.last_row_id)
  } catch (e) {
    if (String(e).includes('UNIQUE')) return c.json(fail('exists', `${server.name} already has a node named ${body.name}`), 409)
    throw e
  }
  if (status === 'queued') await queueOrFail(c.env, (await getNode(c.env, id))!, v.data)
  await audit(c.env, 'node.add', `${server.name}/${body.name}`, `${v.engine} ${v.psmProtocol}`)
  // a server that has not joined needs the install command; one that has gets
  // the node through its agent (to reinstall it, the servers page issues one)
  const install_command = joined ? undefined : await installCommand(c, await joinToken(c.env, server.id))
  return c.json({ id, status, joined, install_command }, 201)
})

// Edit a node: its address, ports, traffic limit, labels and settings (the
// protocol, how it runs, its server and its name stay). A node on its server is
// updated there by the agent; one that failed is tried again.
app.patch('/api/nodes/:id', async (c) => {
  const n = await getNode(c.env, c.req.param('id'))
  if (!n) return c.json(fail('not_found', 'no such node'), 404)
  if (n.status === 'queued' || n.status === 'deleting') return c.json(fail('busy', '节点正在下发或删除，稍后再改'), 409)
  const body = await c.req.json<Partial<NodeInput> & { reset_day?: number }>().catch(() => null)
  if (!body) return c.json(fail('bad_body', 'the body must be a JSON object'), 400)
  // PSM refuses to move a node onto or off the shared 443 as an update: the
  // node's public address changes, so that is a delete and an add.
  if (body.mount_443 !== undefined && !!body.mount_443 !== !!n.mount_443) {
    const msg = '443 端口复用不能改：请删除这个节点后按新的方式重建'
    return c.json(fail('invalid', msg, { errors: [msg] }), 400)
  }
  // null takes a public port away (clients use the port itself); left out keeps it
  const publicPort = body.public_port === undefined ? (n.public_port ?? undefined) : (body.public_port ?? undefined)
  if (n.mount_443 && publicPort !== 443) {
    const msg = '挂到 443 复用的节点，连接端口就是 443'
    return c.json(fail('invalid', msg, { errors: [msg] }), 400)
  }
  const stored = JSON.parse(await decrypt(c.env.TOKEN_KEY, n.params_enc)) as Record<string, unknown>
  const input: NodeInput = {
    protocol: n.protocol, variant: n.variant, engine: n.engine as NodeInput['engine'], name: n.name,
    address: body.address ?? n.address, port: body.port ?? n.port,
    public_port: publicPort,
    traffic_limit_gb: body.traffic_limit_gb ?? n.traffic_limit_gb,
    labels: body.labels ?? JSON.parse(n.labels),
    params: { ...stored, ...(body.params ?? {}) },
    display_name: body.display_name ?? n.display_name,
  }
  for (const [k, val] of Object.entries(input.params!)) if (val === MASK) input.params![k] = stored[k]
  const v = validateNode(input)
  if (!v.ok) return c.json(fail('invalid', v.errors.join('；'), { errors: v.errors }), 400)
  const tooOld = psmTooOld((await getServer(c.env, n.server_id))!, v.data)
  if (tooOld) return c.json(fail('psm_too_old', tooOld, { errors: [tooOld] }), 409)
  const resetDay = body.reset_day ?? n.reset_day
  if (!Number.isInteger(resetDay) || resetDay < 1 || resetDay > 28) return c.json(fail('invalid', '流量重置日：1-28', { errors: ['流量重置日：1-28'] }), 400)
  const variant = findVariant(n.protocol, n.variant)!
  const params = keptParams(activeFields(variant, v.engine, input.params!), input.params!, stored)
  const server = (await getServer(c.env, n.server_id))!
  const dn = input.display_name ?? ''
  const taken = await displayNameTaken(c.env, dn, n.id)
  if (taken) return c.json(fail('exists', taken, { errors: [taken] }), 409)
  // nothing but the display name changed: it is the panel's own, and the node
  // is not sent to its server again (one that failed still is: saving retries it)
  // settings compared as they take effect: a form that spells out a default
  // the node was made without (an implicit encryption method) is no change
  const sameNode = input.address === n.address && input.port === n.port
    && (input.public_port ?? input.port) === (n.public_port ?? n.port)
    && JSON.stringify(cleanLabels(input.labels)) === n.labels
    && (JSON.stringify(params) === JSON.stringify(stored)
      || JSON.stringify(v.data) === JSON.stringify(await nodeData(c.env, n).catch(() => null)))
  const same = sameNode && (input.traffic_limit_gb ?? 0) === n.traffic_limit_gb && resetDay === n.reset_day
  // (one with an error — a change that did not take, a restored one — is sent again too)
  if (same && n.status !== 'failed' && !n.last_error) {
    if (dn !== n.display_name) {
      await c.env.DB.prepare('UPDATE nodes SET display_name = ? WHERE id = ?').bind(dn, n.id).run()
      await audit(c.env, 'node.update', `${server.name}/${n.name}`, `显示名：${dn || '（国旗 + 名称）'}`)
    }
    return c.json(await publicNode(c.env, (await getNode(c.env, n.id))!))
  }
  const joined = !!server.agent_token_hash
  const onServer = n.status === 'applied'
  // Only the limit or the reset day changed on a node that runs as the panel
  // made it: only its meter is changed. Installing it again would change
  // nothing on the node, and for a standalone server it used to restart it
  // (and, with an automatic key, hand it a new one, so every link broke).
  if (sameNode && joined && onServer && n.owned && !n.last_error) {
    // the row and its meter task in one batch: a failed queue write leaves
    // the node as it was, so saving again sends it
    const limitGb = input.traffic_limit_gb ?? 0
    await c.env.DB.batch([
      c.env.DB.prepare('UPDATE nodes SET traffic_limit_gb = ?, reset_day = ?, display_name = ? WHERE id = ?')
        .bind(limitGb, resetDay, dn, n.id),
      await taskStmt(c.env, n.server_id, n.id, trafficTask({ ...n, traffic_limit_gb: limitGb, reset_day: resetDay })),
    ])
    const updated = (await getNode(c.env, n.id))!
    await audit(c.env, 'node.update', `${server.name}/${n.name}`, `流量限额 ${updated.traffic_limit_gb} GB，每月 ${resetDay} 日重置`)
    return c.json(await publicNode(c.env, updated))
  }
  const status = joined && (onServer || n.status === 'failed') ? 'queued' : n.status
  await c.env.DB.prepare(
    `UPDATE nodes SET address = ?, port = ?, public_port = ?, traffic_limit_gb = ?, reset_day = ?, labels = ?, params_enc = ?,
            display_name = ?, status = ?, last_error = NULL WHERE id = ?`)
    .bind(input.address, input.port, input.public_port ?? null, input.traffic_limit_gb ?? 0, resetDay,
      JSON.stringify(cleanLabels(input.labels)), await encrypt(c.env.TOKEN_KEY, JSON.stringify(params)), dn, status, n.id).run()
  const updated = (await getNode(c.env, n.id))!
  // a node the panel owns is changed in place (or made again if it is gone);
  // one it does not own yet is a first create again (applyStmts)
  if (status === 'queued') await queueOrFail(c.env, updated, v.data, onServer)
  await audit(c.env, 'node.update', `${server.name}/${n.name}`)
  // its labels decide which users reach it
  if (updated.labels !== n.labels) await reconcileUsers(c.env, deps, n.server_id)
  return c.json(await publicNode(c.env, updated))
})

// Delete a node: one the panel owns on its server is removed by the agent
// first (202); one it never made there goes at once (204).
app.delete('/api/nodes/:id', async (c) => {
  const n = await getNode(c.env, c.req.param('id'))
  if (!n) return c.json(fail('not_found', 'no such node'), 404)
  const server = await getServer(c.env, n.server_id)
  // ?force=1 forgets it without waiting for the server, as for a server
  // itself: a node on a machine that never answers again would sit in
  // "deleting" for ever, and nothing could remove it.
  const force = new URL(c.req.url).searchParams.get('force') === '1'
  // On its way to the server: the agent may be creating or changing it right
  // now, and forgetting it here would leave it running there, unmanaged.
  if (!force && n.status === 'queued') return c.json(fail('busy', '节点正在下发：等它完成后再删除'), 409)
  // Removed there only if it is the panel's: psm-agent confirmed it created
  // it (a create that half ran counts). One that never got there, failed
  // before PSM wrote it, or met a node of the same name made by hand (a
  // conflict) is only forgotten here.
  if (!force && n.owned && server?.agent_token_hash && n.status !== 'waiting') {
    if (n.status !== 'deleting') {
      await enqueue(c.env, n.server_id, n.id, n.engine === 'standalone'
        ? { kind: 'standalone.remove', protocol: n.psm_protocol }
        : { kind: 'node.delete', core: n.engine, protocol: n.psm_protocol, tag: n.name })
      await c.env.DB.prepare(`UPDATE nodes SET status = 'deleting' WHERE id = ?`).bind(n.id).run()
      await audit(c.env, 'node.delete', `${server.name}/${n.name}`)
    }
    return c.json({ status: 'deleting' }, 202)
  }
  await c.env.DB.batch([
    c.env.DB.prepare(`DELETE FROM tasks WHERE node_id = ? AND status = 'queued'`).bind(n.id),
    c.env.DB.prepare('DELETE FROM nodes WHERE id = ?').bind(n.id),
  ])
  await audit(c.env, 'node.delete', `${server?.name}/${n.name}`, n.owned ? '' : '服务器上没有面板建的这个节点：只从面板移除')
  return c.body(null, 204)
})

// The client link (or Surge line for Snell) the agent exported, named as the
// subscriptions name the node.
app.get('/api/nodes/:id/link', async (c) => {
  const n = await getNode(c.env, c.req.param('id'))
  if (!n) return c.json(fail('not_found', 'no such node'), 404)
  if (!n.link_enc || !n.owned) return c.json(fail('no_link', 'the node has no link yet'), 409)
  const server = await getServer(c.env, n.server_id)
  const link = await decrypt(c.env.TOKEN_KEY, n.link_enc)
  const name = displayName({ server: server?.name ?? '', name: n.name, country: server?.country, display_name: n.display_name, link, outbound: null })
  return c.json({ format: linkFormat(n), content: renamed(link, name) })
})

// ── traffic ──────────────────────────────────────────────────────────────────
// Every node's traffic this month (as its server counts it, reset on its
// reset day) and the bytes per day over the last `days` days.
app.get('/api/traffic', async (c) => {
  const days = Math.min(Math.max(Number(new URL(c.req.url).searchParams.get('days')) || 30, 1), 90)
  const { results: nodes } = await c.env.DB.prepare(
    `SELECT n.id, n.name, n.protocol, n.variant, n.engine, n.status, n.traffic_used, n.traffic_limit_gb, n.traffic_paused,
            n.traffic_at, n.reset_day, s.id AS server_id, s.name AS server
       FROM nodes n JOIN servers s ON s.id = n.server_id ORDER BY n.traffic_used DESC, n.id`).all()
  const { results: daily } = await c.env.DB.prepare(
    `SELECT day, SUM(bytes) AS bytes FROM traffic_daily WHERE day >= date('now', '+8 hours', ?) GROUP BY day ORDER BY day`)
    .bind(`-${days - 1} days`).all()
  const { results: perNode } = await c.env.DB.prepare(
    `SELECT node_id, day, bytes FROM traffic_daily WHERE day >= date('now', '+8 hours', ?) ORDER BY day`)
    .bind(`-${days - 1} days`).all()
  return c.json({ days, nodes: nodes.map((n) => ({ ...n, traffic_paused: !!n.traffic_paused })), daily, per_node: perNode })
})

// Ask every joined server for its counters now (they arrive within seconds).
app.post('/api/traffic/refresh', async (c) => {
  const { results } = await c.env.DB.prepare('SELECT id FROM servers WHERE agent_token_hash IS NOT NULL').all<{ id: number }>()
  const stmts = await Promise.all(results.map((s) => taskStmt(c.env, s.id, null, { kind: 'traffic.report' })))
  if (stmts.length) await c.env.DB.batch(stmts)
  return c.json({ servers: results.length }, 202)
})

// Start a node's count from zero again (and lift a pause).
app.post('/api/nodes/:id/traffic/reset', async (c) => {
  const n = await getNode(c.env, c.req.param('id'))
  if (!n) return c.json(fail('not_found', 'no such node'), 404)
  if (n.status !== 'applied') return c.json(fail('not_applied', 'the node is not running on its server'), 409)
  await enqueue(c.env, n.server_id, n.id, { kind: 'traffic.reset', tag: trafficTag(n) })
  await audit(c.env, 'traffic.reset', n.name)
  return c.json({ status: 'queued' }, 202)
})

// psm check (the IP quality and unlock check) came with psm-agent 0.12.0
const CHECK_AGENT = '0.12.0'

// PSM learnt Hysteria2's disable_pmtud on 2026-10-07 (proxy-stack #7). An older
// PSM keeps the setting and does nothing with it, so a server that reported an
// older PSM ("2026-10-06 58642cc", psm version) is asked to update first; one
// that has not joined yet gets the current PSM when it does.
/** Before a server leaves the panel: its users' use this period, kept toward their total quota. */
const bankRetired = (env: Env, serverId: number) => env.DB.prepare(
  `UPDATE users SET period_retired_bytes = period_retired_bytes + COALESCE((SELECT used_bytes FROM user_servers WHERE user_id = users.id AND server_id = ?), 0)
    WHERE id IN (SELECT user_id FROM user_servers WHERE server_id = ?)`).bind(serverId, serverId)
const PSM_PMTUD = '2026-10-07'
const OWN_SITE_AGENT = '0.14.0'
// REALITY's own site goes only to roomkey's psm-agent, which checks that its
// PSM says it supports it (psm caps) and reads back what PSM stored. A server
// that has not joined yet is checked when it joins.
function psmTooOld(s: ServerRow, data: Record<string, unknown>): string | null {
  if (data.own_site === true && s.agent_token_hash && !versionAtLeast(s.agent_version, OWN_SITE_AGENT))
    return `${s.name} 的 psm-agent 是 ${s.agent_version ?? '旧版'}，不支持 REALITY 本机站点：先在服务器页的 ⋯ 里升级 psm-agent（会先更新 PSM），再保存`
  const d = /^(\d{4}-\d{2}-\d{2})\b/.exec(s.psm_version ?? '')?.[1]
  if (!d) return null   // not joined yet: it installs the current PSM
  if (data.disable_pmtud === true && d < PSM_PMTUD)
    return `${s.name} 上的 PSM 是 ${d} 的版本，还不认识「关闭 MTU 探测」：先在服务器页的 ⋯ 里点「升级 agent」（会先更新 PSM），再保存`
  return null
}

/** "1.2.3" at least "1.2.0"? An unknown version is not. */
function versionAtLeast(v: string | null, want: string): boolean {
  const p = (s: string) => s.replace(/^v/, '').split('.').map((x) => Number.parseInt(x, 10) || 0)
  if (!v || !/^v?\d+\.\d+/.test(v)) return false
  const [a, b] = [p(v), p(want)]
  for (let i = 0; i < 3; i++) if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) > (b[i] ?? 0)
  return true
}

// ── subscriptions ────────────────────────────────────────────────────────────
type SubRow = { id: number; name: string; labels: string; token_hash: string; token_enc: string; last_used: string | null; created_at: string; templates: string }

async function publicSub(c: C, s: SubRow) {
  const token = await decrypt(c.env.TOKEN_KEY, s.token_enc)
  const url = `${await panelUrl(c)}/sub/${token}`
  return { id: s.id, name: s.name, labels: JSON.parse(s.labels), last_used: s.last_used, created_at: s.created_at, url,
    templates: JSON.parse(s.templates || '{}') as Record<string, number> }
}

/** A subscription's template choices, checked: format → one of the user's templates of that format. */
async function cleanTemplateChoices(env: Env, raw: unknown): Promise<Record<string, number> | string> {
  const out: Record<string, number> = {}
  if (!raw || typeof raw !== 'object') return out
  for (const [format, id] of Object.entries(raw as Record<string, unknown>)) {
    if (!(TEMPLATE_FORMATS as string[]).includes(format)) return `没有这种格式：${format}`
    if (id === null || id === '' || id === 'builtin') continue   // the built-in template
    const row = Number.isInteger(id)
      ? await env.DB.prepare('SELECT id FROM templates WHERE id = ? AND format = ?').bind(id, format).first()
      : null
    if (!row) return `${FORMAT_LABELS[format as TemplateFormat]} 模板不存在`
    out[format] = id as number
  }
  return out
}

app.get('/api/subscriptions', async (c) => {
  const { results } = await c.env.DB.prepare('SELECT * FROM subscriptions ORDER BY id').all<SubRow>()
  return c.json(await Promise.all(results.map((s) => publicSub(c, s))))
})

const getSub = (env: Env, id: unknown) => {
  const n = idOf(id)
  return n === null ? Promise.resolve(null) : env.DB.prepare('SELECT * FROM subscriptions WHERE id = ?').bind(n).first<SubRow>()
}

app.post('/api/subscriptions', async (c) => {
  const body = await c.req.json<{ name?: string; labels?: unknown }>().catch(() => null)
  const name = typeof body?.name === 'string' ? body.name.trim().slice(0, 48) : ''
  if (!name) return c.json(fail('bad_name', '订阅名称：必填'), 400)
  // 24 random bytes do not collide; should they ever, the unique hash says so and another is drawn
  for (let attempt = 0; ; attempt++) {
    const token = randomToken(24)
    try {
      const r = await c.env.DB.prepare('INSERT INTO subscriptions (name, labels, token_hash, token_enc) VALUES (?, ?, ?, ?)')
        .bind(name, JSON.stringify(cleanLabels(body?.labels)), await sha256Hex(token), await encrypt(c.env.TOKEN_KEY, token)).run()
      await audit(c.env, 'subscription.add', name)
      const s = (await getSub(c.env, r.meta.last_row_id))!
      return c.json(await publicSub(c, s), 201)
    } catch (e) {
      if (attempt < 2 && String(e).includes('UNIQUE')) continue
      throw e
    }
  }
})

app.patch('/api/subscriptions/:id', async (c) => {
  const s = await getSub(c.env, c.req.param('id'))
  if (!s) return c.json(fail('not_found', 'no such subscription'), 404)
  const body = await c.req.json<{ name?: string; labels?: unknown; templates?: unknown }>().catch(() => null)
  const name = (typeof body?.name === 'string' ? body.name.trim().slice(0, 48) : '') || s.name
  const labels = body?.labels !== undefined ? JSON.stringify(cleanLabels(body.labels)) : s.labels
  let templates = s.templates || '{}'
  if (body?.templates !== undefined) {
    const t = await cleanTemplateChoices(c.env, body.templates)
    if (typeof t === 'string') return c.json(fail('invalid', t, { errors: [t] }), 400)
    templates = JSON.stringify(t)
  }
  await c.env.DB.prepare('UPDATE subscriptions SET name = ?, labels = ?, templates = ? WHERE id = ?').bind(name, labels, templates, s.id).run()
  await audit(c.env, 'subscription.update', name)
  return c.json(await publicSub(c, { ...s, name, labels, templates }))
})

// A new URL; the old one stops working.
app.post('/api/subscriptions/:id/reset', async (c) => {
  const s = await getSub(c.env, c.req.param('id'))
  if (!s) return c.json(fail('not_found', 'no such subscription'), 404)
  const token = randomToken(24)
  const hash = await sha256Hex(token), enc = await encrypt(c.env.TOKEN_KEY, token)
  await c.env.DB.prepare('UPDATE subscriptions SET token_hash = ?, token_enc = ? WHERE id = ?').bind(hash, enc, s.id).run()
  await audit(c.env, 'subscription.reset', s.name)
  return c.json(await publicSub(c, { ...s, token_hash: hash, token_enc: enc }))
})

app.delete('/api/subscriptions/:id', async (c) => {
  const s = await getSub(c.env, c.req.param('id'))
  if (!s) return c.json(fail('not_found', 'no such subscription'), 404)
  await c.env.DB.prepare('DELETE FROM subscriptions WHERE id = ?').bind(s.id).run()
  await audit(c.env, 'subscription.delete', s.name)
  return c.body(null, 204)
})

// The subscription itself (no sign-in: the token in the URL is the key).
app.get('/sub/:token', async (c) => {
  const token = c.req.param('token')
  const s = token.length >= 24
    ? await c.env.DB.prepare('SELECT * FROM subscriptions WHERE token_hash = ?').bind(await sha256Hex(token)).first<SubRow>()
    : null
  if (!s) {
    // not a shared subscription: maybe a user's own
    const own = token.length >= 24 ? await userSubscription(c, deps, token) : null
    return own ?? c.text('not found', 404)
  }
  const labels = JSON.parse(s.labels) as string[]
  const { results } = await c.env.DB.prepare(
    `SELECT n.id, n.name, n.display_name, n.labels, n.link_enc, n.outbound_enc, n.clash_enc, n.traffic_used, n.traffic_limit_gb,
            s.name AS server, s.country
       FROM nodes n JOIN servers s ON s.id = n.server_id
      WHERE n.status = 'applied' AND n.traffic_paused = 0 ORDER BY s.id, n.id`)
    .all<{ id: number; name: string; display_name: string; labels: string; link_enc: string | null; outbound_enc: string | null; clash_enc: string | null;
           traffic_used: number; traffic_limit_gb: number; server: string; country: string | null }>()
  const chosen = results.filter((n) => !labels.length || (JSON.parse(n.labels) as string[]).some((l) => labels.includes(l)))
  const own: SubNode[] = await Promise.all(chosen.map(async (n) => ({
    server: n.server, name: n.name, country: n.country, display_name: n.display_name,
    link: n.link_enc ? await decrypt(c.env.TOKEN_KEY, n.link_enc) : null,
    outbound: n.outbound_enc ? JSON.parse(await decrypt(c.env.TOKEN_KEY, n.outbound_enc)) : null,
    clash: n.clash_enc ? JSON.parse(await decrypt(c.env.TOKEN_KEY, n.clash_enc)) : null,
  })))
  const nodes: SubNode[] = own
  const url = new URL(c.req.url)
  const format = pickFormat(url.searchParams.get('format'), c.req.header('User-Agent') ?? '')
  // the subscription's own template for this format, or the built-in one
  const chosen_tpl = format === 'uri' ? undefined : (JSON.parse(s.templates || '{}') as Record<string, unknown>)[format]
  const tpl = Number.isInteger(chosen_tpl)
    ? await c.env.DB.prepare('SELECT body FROM templates WHERE id = ? AND format = ?').bind(chosen_tpl, format).first<{ body: string }>()
    : null
  const out = buildSubscription(format, nodes, `${await panelUrl(c)}/sub/${token}`, { name: s.name, template: tpl?.body })
  await c.env.DB.prepare(`UPDATE subscriptions SET last_used = datetime('now') WHERE id = ?`).bind(s.id).run()
  const used = chosen.reduce((a, n) => a + (n.traffic_used || 0), 0)
  const total = chosen.every((n) => n.traffic_limit_gb > 0) ? Math.round(chosen.reduce((a, n) => a + n.traffic_limit_gb * GB, 0)) : 0
  return c.body(out.body, 200, {
    'Content-Type': out.type,
    'Content-Disposition': `attachment; filename*=UTF-8''${encodeURIComponent(s.name)}.${out.ext}`,
    'Profile-Update-Interval': '12',
    'Subscription-Userinfo': `upload=0; download=${used}; total=${total}`,
    'Cache-Control': 'no-store',
  })
})


// ── subscription templates ───────────────────────────────────────────────────
// The built-in ones (templates.ts) to start from, and the user's own.
type TemplateRow = { id: number; name: string; format: string; body: string; created_at: string; updated_at: string | null }

function templateProblem(format: string, name: string, body: string): string | null {
  if (!(TEMPLATE_FORMATS as string[]).includes(format)) return '格式：Clash、Stash、sing-box、Surge、Quantumult X 或 Loon'
  if (!name.trim() || name.trim().length > 48) return '模板名称：1-48 个字符'
  if (!body.trim() || body.length > 64 * 1024) return '模板内容：不能为空，最多 64 KB'
  // Clash can take its nodes from the proxy-provider instead, and then there is
  // no {{proxies}} line to fill in — the built-in Clash template works that way.
  if (!/\{\{provider_url\}\}/.test(body) && !/^[ \t]*\{\{proxies\}\}[ \t]*$/m.test(body))
    return '模板里要有单独占一行的 {{proxies}}（节点写在那里），或者用 {{provider_url}} 让 Clash 自己从订阅拉取节点'
  return null
}

app.get('/api/templates', async (c) => {
  const { results } = await c.env.DB.prepare('SELECT * FROM templates ORDER BY format, id').all<TemplateRow>()
  return c.json({
    formats: FORMAT_LABELS,
    builtin: TEMPLATE_FORMATS.map((f) => ({ format: f, name: BUILTIN_TEMPLATES[f].name, body: BUILTIN_TEMPLATES[f].body })),
    custom: results,
  })
})

app.post('/api/templates', async (c) => {
  const b = await c.req.json<{ name?: string; format?: string; body?: string }>().catch(() => null)
  const str = (v: unknown) => (typeof v === 'string' ? v : '')
  const problem = templateProblem(str(b?.format), str(b?.name), str(b?.body))
  if (problem) return c.json(fail('invalid', problem, { errors: [problem] }), 400)
  const r = await c.env.DB.prepare('INSERT INTO templates (name, format, body) VALUES (?, ?, ?)').bind(b!.name!.trim(), b!.format, b!.body).run()
  await audit(c.env, 'template.add', b!.name!.trim(), FORMAT_LABELS[b!.format as TemplateFormat])
  return c.json(await c.env.DB.prepare('SELECT * FROM templates WHERE id = ?').bind(Number(r.meta.last_row_id)).first<TemplateRow>(), 201)
})

const getTemplate = (env: Env, id: unknown) => {
  const n = idOf(id)
  return n === null ? Promise.resolve(null) : env.DB.prepare('SELECT * FROM templates WHERE id = ?').bind(n).first<TemplateRow>()
}

app.put('/api/templates/:id', async (c) => {
  const t = await getTemplate(c.env, c.req.param('id'))
  if (!t) return c.json(fail('not_found', '没有这个模板'), 404)
  const b = await c.req.json<{ name?: string; body?: string }>().catch(() => null)
  const name = typeof b?.name === 'string' ? b.name.trim() : t.name
  const body = typeof b?.body === 'string' ? b.body : t.body
  const problem = templateProblem(t.format, name, body)
  if (problem) return c.json(fail('invalid', problem, { errors: [problem] }), 400)
  await c.env.DB.prepare(`UPDATE templates SET name = ?, body = ?, updated_at = datetime('now') WHERE id = ?`).bind(name, body, t.id).run()
  await audit(c.env, 'template.update', name, FORMAT_LABELS[t.format as TemplateFormat])
  return c.json(await c.env.DB.prepare('SELECT * FROM templates WHERE id = ?').bind(t.id).first<TemplateRow>())
})

// Subscriptions that used it go back to the built-in template.
app.delete('/api/templates/:id', async (c) => {
  const t = await getTemplate(c.env, c.req.param('id'))
  if (!t) return c.json(fail('not_found', '没有这个模板'), 404)
  const { results } = await c.env.DB.prepare('SELECT id, templates FROM subscriptions').all<{ id: number; templates: string }>()
  for (const s of results) {
    const m = JSON.parse(s.templates || '{}') as Record<string, unknown>
    if (m[t.format] !== t.id) continue
    delete m[t.format]
    await c.env.DB.prepare('UPDATE subscriptions SET templates = ? WHERE id = ?').bind(JSON.stringify(m), s.id).run()
  }
  await c.env.DB.prepare('DELETE FROM templates WHERE id = ?').bind(t.id).run()
  await audit(c.env, 'template.delete', t.name, FORMAT_LABELS[t.format as TemplateFormat])
  return c.body(null, 204)
})

// ── settings and the audit log ───────────────────────────────────────────────
/**
 * Where the key that encrypts D1 lives. 'panel': only in D1, next to what it
 * encrypts (a one-click deploy) — a copy of the database is enough to read
 * everything. 'both': the TOKEN_KEY secret holds the same key and D1's copy
 * can go. 'secret': only the secret (as it should be). 'mismatch': the secret
 * is another key than the one D1's data was written with.
 */
async function tokenKeyState(env: Env): Promise<'panel' | 'secret' | 'both' | 'mismatch'> {
  if (tokenKeySource === 'panel') return 'panel'
  const stored = await getSetting(env, 'token_key')
  return !stored ? 'secret' : stored === env.TOKEN_KEY ? 'both' : 'mismatch'
}

app.get('/api/settings', async (c) => c.json({
  version: PANEL_VERSION,
  agent_version: AGENT_VERSION,
  panel_url: (await getSetting(c.env, 'panel_url')) ?? '',
  effective_panel_url: await panelUrl(c),
  sync_interval: syncInterval(c.env),
  token_key: await tokenKeyState(c.env),
  ipcheck_keys: Object.fromEntries(await Promise.all(IPCHECK_KEYS.map(async (k) => [k, !!(await getSetting(c.env, `ipcheck_key_${k}_enc`))]))),
}))

// The IP check's optional databases, by their free API keys (kept encrypted;
// they go to a server with each check, on psm-agent's stdin, never in argv)
const IPCHECK_KEYS = ['abuseipdb', 'ipqs', 'ip2location'] as const
const IPCHECK_KEY_RE = /^[A-Za-z0-9_-]{8,128}$/
async function ipcheckKeys(env: Env): Promise<Record<string, string>> {
  const out: Record<string, string> = {}
  for (const k of IPCHECK_KEYS) {
    const enc = await getSetting(env, `ipcheck_key_${k}_enc`)
    if (enc) out[k] = await decrypt(env.TOKEN_KEY, enc)
  }
  return out
}

const putSetting = (env: Env, key: string, value: string) =>
  env.DB.prepare(`INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`).bind(key, value).run()

/**
 * The panel's address, as install commands and subscriptions carry it: HTTPS
 * (an agent token and every node's secrets travel over it), plain HTTP only
 * for an address that never leaves the machine or its LAN (a test panel).
 */
function panelUrlProblem(url: string): string | null {
  let u: URL
  try { u = new URL(url) } catch { return '面板地址：形如 https://psm.example.com' }
  if (!/^https?:\/\/[A-Za-z0-9.-]+(:\d{1,5})?$/.test(url) || u.username || u.password) return '面板地址：形如 https://psm.example.com'
  if (u.protocol === 'https:') return null
  const h = u.hostname
  const local = h === 'localhost' || /^127\./.test(h) || /^10\./.test(h) || /^192\.168\./.test(h) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(h) || !h.includes('.')
  return local ? null : '面板地址要用 https://（节点的密钥和 agent 的令牌经它传输）；http:// 只能用于本机或内网地址'
}

// Each setting changes only when it is sent: the panel address and the IP
// check's API keys (kept encrypted). (roomkey has no REALITY target search:
// REALITY uses each node's own site.)
app.put('/api/settings', async (c) => {
  const body = await c.req.json<{ panel_url?: unknown; ipcheck_keys?: unknown }>().catch(() => null)
  if (!body || typeof body !== 'object') return c.json(fail('invalid', 'bad request'), 400)
  const invalid = (m: string) => c.json(fail('invalid', m, { errors: [m] }), 400)
  // the IP check's keys: each one sent is saved ('' clears it)
  const ipKeys: [string, string][] = []
  if (body.ipcheck_keys !== undefined) {
    if (!body.ipcheck_keys || typeof body.ipcheck_keys !== 'object') return invalid('IP 检测的 API Key 不正确')
    for (const [k, v] of Object.entries(body.ipcheck_keys as Record<string, unknown>)) {
      const value = String(v ?? '').trim()
      if (!(IPCHECK_KEYS as readonly string[]).includes(k)) return invalid(`没有这个数据库：${k}`)
      if (value && !IPCHECK_KEY_RE.test(value)) return invalid(`${k} 的 API Key 只含字母、数字、- 和 _（8-128 位）`)
      ipKeys.push([k, value])
    }
  }
  if (body.panel_url !== undefined) {
    const url = String(body.panel_url).trim().replace(/\/+$/, '')
    const problem = url ? panelUrlProblem(url) : null
    if (problem) return invalid(problem)
    if (url) await putSetting(c.env, 'panel_url', url)
    else await c.env.DB.prepare(`DELETE FROM settings WHERE key = 'panel_url'`).run()
    await audit(c.env, 'settings.update', 'panel_url', url)
  }
  for (const [k, value] of ipKeys) {
    if (value) await putSetting(c.env, `ipcheck_key_${k}_enc`, await encrypt(c.env.TOKEN_KEY, value))
    else await c.env.DB.prepare('DELETE FROM settings WHERE key = ?').bind(`ipcheck_key_${k}_enc`).run()
    await audit(c.env, 'settings.update', `ipcheck_key_${k}`, value ? '已更新' : '已清除')
  }
  return c.json({ panel_url: (await getSetting(c.env, 'panel_url')) ?? '', effective_panel_url: await panelUrl(c) })
})

// The key D1 is encrypted with, shown once more to the admin (the password
// again, and counted as a sign-in attempt): to be set as the TOKEN_KEY secret,
// after which D1's copy can be forgotten.
app.post('/api/settings/token-key/reveal', async (c) => {
  const ip = ipKey(c.req.header('CF-Connecting-IP') ?? 'unknown')
  if (await tooManyFailures(c.env.DB, ip)) return c.json(fail('too_many', 'too many failed attempts; try again in 15 minutes'), 429)
  const body = await c.req.json<{ password?: unknown }>().catch(() => null)
  if (!(await passwordMatches(c.env, typeof body?.password === 'string' ? body.password : ''))) {
    await recordFailure(c.env.DB, ip)
    await audit(c.env, 'settings.reveal-key.failed', ip)
    return c.json(fail('bad_password', '密码不对'), 403)
  }
  const stored = await getSetting(c.env, 'token_key')
  if (!stored) return c.json(fail('not_found', '数据库里没有密钥：它只在 TOKEN_KEY 机密里'), 404)
  await audit(c.env, 'settings.reveal-key', ip)
  return c.json({ token_key: stored })
})

// D1's copy goes once the secret holds the same key (never otherwise: that
// copy would be the only one).
app.post('/api/settings/token-key/forget', async (c) => {
  if ((await tokenKeyState(c.env)) !== 'both') {
    const msg = '先把 TOKEN_KEY 机密设成数据库里的这把密钥，再删除数据库里的副本'
    return c.json(fail('invalid', msg, { errors: [msg] }), 409)
  }
  await c.env.DB.prepare(`DELETE FROM settings WHERE key = 'token_key'`).run()
  panelKey = null
  await audit(c.env, 'settings.forget-key')
  return c.json({ token_key: await tokenKeyState(c.env) })
})

app.get('/api/tasks/:id', async (c) => {
  const id = idOf(c.req.param('id'))
  const t = id === null ? null
    : await c.env.DB.prepare('SELECT id, kind, status, error, result_enc FROM tasks WHERE id = ?').bind(id)
      .first<{ id: number; kind: string; status: string; error: string | null; result_enc: string | null }>()
  if (!t) return c.json(fail('not_found', '没有这个任务'), 404)
  return c.json({ id: t.id, kind: t.kind, status: t.status, error: t.error,
    result: t.result_enc ? JSON.parse(await decrypt(c.env.TOKEN_KEY, t.result_enc)) : null })
})

// Newest first; ?before=<id> for the page after, ?action=<prefix> to narrow it.
app.get('/api/audit', async (c) => {
  const q = new URL(c.req.url).searchParams
  const limit = Math.min(Math.max(Number(q.get('limit')) || 100, 1), 500)
  const before = idOf(q.get('before'))
  const action = (q.get('action') ?? '').replace(/[^a-z0-9.-]/g, '').slice(0, 40)
  const { results } = await c.env.DB.prepare(
    `SELECT * FROM audit WHERE (? IS NULL OR id < ?) AND (? = '' OR action = ? OR action LIKE ? || '.%')
      ORDER BY id DESC LIMIT ?`).bind(before, before, action, action, action, limit).all()
  return c.json(results)
})

// ── roomkey's private install ────────────────────────────────────────────────
// setup.sh deploys the panel with a bundle in its assets (web/dist/_install):
// PSM's scripts (stack.tgz), psm-agent for each architecture and their
// SHA256SUMS. Nobody can fetch them directly (/_install/ is a 404); a server
// gets them through /api/agent/bundle/<file> with a join token that is still
// good (the install) or its own agent token (every upgrade after).
const BUNDLE_FILES = new Set(['stack.tgz', 'SHA256SUMS', 'psm-agent-linux-amd64', 'psm-agent-linux-arm64', 'psm-agent-linux-armv7'])
let bundleReady: boolean | null = null
async function hasBundle(c: C): Promise<boolean> {
  if (bundleReady === null) {
    const r = await c.env.ASSETS.fetch(new Request(new URL('/_install/SHA256SUMS', c.req.url))).catch(() => null)
    bundleReady = !!r && r.ok
  }
  return bundleReady
}
const TOKEN_RE = /^[A-Za-z0-9_-]{32,256}$/
async function joinTokenGood(env: Env, token: string): Promise<boolean> {
  if (!TOKEN_RE.test(token)) return false
  return !!(await env.DB.prepare(`SELECT 1 FROM join_tokens WHERE token_hash = ? AND used_at IS NULL AND expires_at > datetime('now')`)
    .bind(await sha256Hex(token)).first())
}
async function agentTokenGood(env: Env, token: string): Promise<boolean> {
  if (!TOKEN_RE.test(token)) return false
  return !!(await env.DB.prepare('SELECT 1 FROM servers WHERE agent_token_hash = ?').bind(await sha256Hex(token)).first())
}

// The install command's script, for one join token: POSIX sh (a bare Alpine
// has no bash or curl yet). It downloads PSM, checks it against SHA256SUMS
// and hands over to PSM's own bootstrap, which installs it unattended and
// joins this panel. A token used, expired or unknown gets nothing.
app.get('/api/agent/install/:token', async (c) => {
  const token = c.req.param('token')
  if (!(await hasBundle(c)) || !(await joinTokenGood(c.env, token))) return c.text('not found\n', 404)
  const panel = await panelUrl(c)
  if (!/^https:\/\/[A-Za-z0-9.-]+(:\d+)?$/.test(panel) && !(c.env.ALLOW_HTTP_INSTALL === '1' && /^http:\/\/[A-Za-z0-9.:-]+$/.test(panel)))
    return c.text('# the panel address is not set to an https:// address (系统设置 → 面板地址)\nexit 1\n', 500)
  const script = INSTALL_SCRIPT.replace('@PANEL@', panel).replace('@TOKEN@', token)
  return c.body(script, 200, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' })
})

app.get('/api/agent/bundle/:file', async (c) => {
  const file = c.req.param('file')
  if (!BUNDLE_FILES.has(file) || !(await hasBundle(c))) return c.json(fail('not_found', 'no such file'), 404)
  const bearer = c.req.header('Authorization')?.replace(/^Bearer /, '') ?? ''
  const join = c.req.header('X-PSM-Join') ?? ''
  if (!((join && await joinTokenGood(c.env, join)) || (bearer && await agentTokenGood(c.env, bearer))))
    return c.json(fail('unauthorized', 'a join token that is still good, or an agent token'), 401)
  const r = await c.env.ASSETS.fetch(new Request(new URL(`/_install/${file}`, c.req.url)))
  if (!r.ok) return c.json(fail('not_found', 'no such file'), 404)
  return new Response(r.body, { headers: { 'Content-Type': 'application/octet-stream', 'Cache-Control': 'no-store' } })
})

const INSTALL_SCRIPT = `#!/bin/sh
# roomkey: install PSM on this server and connect it to the panel.
# Made by the panel for one install command (one join token, 24 hours).
set -eu
PANEL='@PANEL@'
JOIN='@TOKEN@'
say() { printf 'roomkey: %s\\n' "$*" >&2; }
if [ "$(id -u)" != 0 ]; then say "run this as root (sudo -i, then the command again)"; exit 1; fi
need() { command -v "$1" >/dev/null 2>&1; }
if ! need bash || ! need curl || ! need tar || ! need sha256sum; then
  say "installing bash, curl and tar ..."
  if need apk; then apk add --no-cache bash curl tar coreutils >/dev/null
  elif need apt-get; then apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bash curl tar coreutils >/dev/null
  elif need dnf; then dnf install -y -q bash curl tar coreutils >/dev/null
  elif need yum; then yum install -y -q bash curl tar coreutils >/dev/null
  fi
fi
for t in bash curl tar sha256sum; do need "$t" || { say "$t is needed and could not be installed"; exit 1; }; done
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
( umask 077; printf 'X-PSM-Join: %s\\n' "$JOIN" > "$dir/h" )
get() { curl --retry 5 --connect-timeout 15 -fsSL -H "@$dir/h" -o "$dir/$1" "$PANEL/api/agent/bundle/$1"; }
say "downloading PSM from $PANEL ..."
if ! get SHA256SUMS || ! get stack.tgz; then say "download failed: make a new install command in the panel (each works once, for 24 hours)"; exit 1; fi
want=$(awk '$2 == "stack.tgz" || $2 == "*stack.tgz" { print $1 }' "$dir/SHA256SUMS")
got=$(sha256sum "$dir/stack.tgz" | awk '{ print $1 }')
if [ -z "$want" ] || [ "$want" != "$got" ]; then say "the download does not match its checksum: nothing was installed"; exit 1; fi
mkdir "$dir/x"
tar -xzf "$dir/stack.tgz" -C "$dir/x"
PSM_PANEL_URL="$PANEL" bash "$dir/x/bootstrap.sh" --panel "$PANEL" --join "$JOIN" --bundle "$dir/stack.tgz" </dev/null
`

// ── psm-agent ────────────────────────────────────────────────────────────────
// Join: a one-time join token becomes this server's agent token. Nodes and
// standalone servers that were waiting for the server get their tasks.
app.post('/api/agent/join', async (c) => {
  const body = await c.req.json<{ join_token?: unknown; hostname?: unknown; agent_version?: unknown }>().catch(() => null)
  const jt = typeof body?.join_token === 'string' ? body.join_token : ''
  if (jt.length < 32 || jt.length > 256) return c.json(fail('bad_token', 'invalid or expired join token'), 403)
  // Claimed in one statement: of two joins racing with the same token, one
  // gets the row and the other nothing (a read, then a write, let both in).
  const claim = await c.env.DB.prepare(
    `UPDATE join_tokens SET used_at = datetime('now')
      WHERE token_hash = ? AND used_at IS NULL AND expires_at > datetime('now') RETURNING server_id`)
    .bind(await sha256Hex(jt)).first<{ server_id: number }>()
  if (!claim) return c.json(fail('bad_token', 'invalid or expired join token'), 403)
  const server = await getServer(c.env, claim.server_id)
  if (!server) return c.json(fail('bad_token', 'invalid or expired join token'), 403)
  const str = (v: unknown, n: number) => (typeof v === 'string' ? v.slice(0, n) : null)
  const hostname = str(body?.hostname, 64)
  const agentToken = randomToken()
  await c.env.DB.batch([
    // the server has joined: any other install command handed out for it stops working
    c.env.DB.prepare(`DELETE FROM join_tokens WHERE server_id = ? AND used_at IS NULL`).bind(server.id),
    c.env.DB.prepare(`UPDATE servers SET agent_token_hash = ?, hostname = ?, agent_version = ?, last_seen = datetime('now') WHERE id = ?`)
      .bind(await sha256Hex(agentToken), hostname, str(body?.agent_version, 16), server.id),
  ])

  // What waited for the server, in one batch. A node that can no longer be
  // sent (its stored settings do not decrypt or validate) is marked failed
  // with the reason — it must not stop the others, nor the join itself: the
  // token is spent, and an error here would leave the server joined with
  // nothing sent.
  const stmts: D1PreparedStatement[] = []
  const { results: waiting } = await c.env.DB.prepare(
    `SELECT * FROM nodes WHERE server_id = ? AND status IN ('waiting', 'failed')`).bind(server.id).all<NodeRow>()
  for (const n of waiting) {
    try {
      const data = await nodeData(c.env, n)
      const tooOld = psmTooOld({ ...server, agent_token_hash: 'joined', agent_version: str(body?.agent_version, 16) }, data)
      if (tooOld) throw new Error(tooOld)
      stmts.push(...await applyStmts(c.env, n, data),
        c.env.DB.prepare(`UPDATE nodes SET status = 'queued', last_error = NULL WHERE id = ?`).bind(n.id))
    } catch (e) {
      console.error(`join ${server.name}: node ${n.id}`, e)
      stmts.push(c.env.DB.prepare(`UPDATE nodes SET status = 'failed', last_error = ? WHERE id = ?`)
        .bind(`无法下发：${(e as Error).message}`.slice(0, 500), n.id))
    }
  }
  if (stmts.length) await c.env.DB.batch(stmts)
  await enqueue(c.env, server.id, null, { kind: 'status' })
  await audit(c.env, 'server.join', server.name, hostname ?? '', 'agent')
  return c.json({ agent_token: agentToken, server: { id: server.id, name: server.name }, interval: syncInterval(c.env) })
})

/**
 * A task result on its node (and, for status reports, its server). `dirty`:
 * servers whose user lists must be rebuilt, once, after every result of a
 * sync (a node added or removed); without it they are rebuilt at once.
 */
async function applyResult(env: Env, server: ServerRow, t: TaskRow, r: AgentResult, dirty?: Set<number>) {
  const usersChanged = async () => { if (dirty) dirty.add(server.id); else await reconcileUsers(env, deps, server.id) }
  const error = r.ok ? null : String(r.error ?? 'failed').slice(0, 500)
  const link = r.ok && typeof r.link === 'string' && r.link ? await encrypt(env.TOKEN_KEY, r.link.slice(0, 8192)) : null
  const outbound = r.ok && r.outbound && typeof r.outbound === 'object' ? await encrypt(env.TOKEN_KEY, JSON.stringify(r.outbound).slice(0, 16384)) : null
  const clash = r.ok && r.clash && typeof r.clash === 'object' ? await encrypt(env.TOKEN_KEY, JSON.stringify(r.clash).slice(0, 16384)) : null
  const db = env.DB
  switch (t.kind) {
    case 'agent.leave': {
      if (!r.ok) {   // e.g. an agent too old for agent.leave: the server stays, with the reason
        await db.prepare('UPDATE servers SET leaving = 0, leave_error = ? WHERE id = ?').bind(error, server.id).run()
        return
      }
      const out = r.output as { failed?: unknown; removed?: unknown } | undefined
      const failed = Array.isArray(out?.failed) ? out!.failed.map(String) : []
      const removed = Array.isArray(out?.removed) ? out!.removed.map(String) : []
      // anything left behind (or a psm-agent that did not say it removed the
      // panel's users) keeps the server, with the reason, to be tried again
      if (failed.length || !removed.includes('panel users')) {
        await db.prepare('UPDATE servers SET leaving = 0, leave_error = ? WHERE id = ?')
          .bind(failed.length ? `未能全部删除：${failed.join('；')}`.slice(0, 500) : 'psm-agent 没有确认删掉面板用户：升级 psm-agent 后再移除', server.id).run()
        return
      }
      // the use since the last report, read just before the purge, first
      const last = (out as { usage?: { users?: unknown } } | undefined)?.usage?.users
      if (Array.isArray(last)) await applyLeaveUsage(env, server.id, last)
      // this period's use there still counts toward each user's total quota
      await db.batch([bankRetired(env, server.id), db.prepare('DELETE FROM servers WHERE id = ?').bind(server.id)])
      await audit(env, 'server.left', server.name, failed.length ? `未能删除：${failed.join('；')}`.slice(0, 500) : '节点和 psm-agent 已卸载', 'agent')
      return
    }
    case 'status':
      if (r.ok && r.output) {
        const report = JSON.stringify(r.output)
        const version = (r.output as { psm_version?: unknown }).psm_version
        await db.prepare(`UPDATE servers SET status_enc = ?, status_at = datetime('now'), psm_version = COALESCE(?, psm_version) WHERE id = ?`)
          .bind(await encrypt(env.TOKEN_KEY, report.slice(0, 512 * 1024)), typeof version === 'string' ? version.slice(0, 40) : null, server.id).run()
      }
      return
    case 'check.run':
      if (r.ok && r.output && typeof r.output === 'object') {
        await db.prepare(`UPDATE servers SET check_enc = ?, check_at = datetime('now'), check_error = NULL WHERE id = ?`)
          .bind(await encrypt(env.TOKEN_KEY, JSON.stringify(r.output).slice(0, 64 * 1024)), server.id).run()
      } else {
        await db.prepare(`UPDATE servers SET check_error = ?, check_at = datetime('now') WHERE id = ?`)
          .bind(error ?? '服务器没有返回检测结果', server.id).run()
      }
      return
    case 'node.add': case 'standalone.install': {
      if (!t.node_id) return
      const before = await getNode(env, t.node_id)
      if (!before) return
      // A conflict: the node there is someone else's (it stays unowned, so no
      // removal ever touches it). A create that made the node, even one that
      // failed after PSM wrote it, makes it the panel's.
      const out = r.output as { conflict?: unknown; created?: unknown } | undefined
      const conflict = !r.ok && out?.conflict === true
      const made = r.ok || out?.created === true
      // newly the panel's: its metering and limit now (never before: it might
      // have been someone else's), in the same transaction as the ownership
      const stmts = [db.prepare(`UPDATE nodes SET status = ?, last_error = ?, owned = CASE WHEN ? THEN 1 ELSE owned END,
          link_enc = COALESCE(?, link_enc), outbound_enc = COALESCE(?, outbound_enc), clash_enc = COALESCE(?, clash_enc) WHERE id = ?`)
        .bind(r.ok ? 'applied' : 'failed', conflict ? `${CONFLICT}${error}`.slice(0, 500) : error, made ? 1 : 0, link, outbound, clash, t.node_id)]
      if (made && !before.owned) stmts.push(await taskStmt(env, before.server_id, before.id, trafficTask(before)))
      await db.batch(stmts)
      // a new node: the users who may reach it get it on its server (once per sync, after all results)
      if (r.ok) await usersChanged()
      return
    }
    case 'user.sync':
      await userSyncResult(env, server.id, JSON.parse(await decrypt(env.TOKEN_KEY, t.payload_enc)), r.ok, error, r.output)
      return
    case 'local.code':
      return
    case 'node.update':
      if (!t.node_id) return
      // a failed update leaves the node running as before (PSM rolls back)
      if (!r.ok) {
        await db.prepare(`UPDATE nodes SET status = 'applied', last_error = ? WHERE id = ?`).bind(`修改没有生效：${error}`, t.node_id).run()
        return
      }
      // a sing-box outbound or mihomo proxy the node no longer has goes (turning
      // VLESS Encryption on takes it out of sing-box): kept, it would be a dead node
      await db.prepare(`UPDATE nodes SET status = 'applied', last_error = NULL, link_enc = COALESCE(?, link_enc), outbound_enc = ?, clash_enc = ? WHERE id = ?`)
        .bind(link, outbound, clash, t.node_id).run()
      return
    case 'node.delete': case 'standalone.remove':
      if (!t.node_id) return
      if (r.ok) {
        await db.prepare('DELETE FROM nodes WHERE id = ?').bind(t.node_id).run()
        await usersChanged()
      } else await db.prepare(`UPDATE nodes SET status = 'applied', last_error = ? WHERE id = ?`).bind(error, t.node_id).run()
      return
    case 'node.export':
      // as for an update: what the node exports now, nothing it no longer has
      if (t.node_id && r.ok && link) {
        await db.prepare('UPDATE nodes SET link_enc = ?, outbound_enc = ?, clash_enc = ? WHERE id = ? AND owned = 1')
          .bind(link, outbound, clash, t.node_id).run()
      }
      return
    case 'traffic.set': case 'traffic.reset': {
      if (!t.node_id) return
      const what = t.kind === 'traffic.reset' ? '流量重置' : '流量限额'
      // A limit or a reset the server did not take is said on the node (it
      // used to vanish: the node looked limited, or reset, and was not) —
      // on a node that runs and has no other error: when the node itself
      // failed, its limit fails with it, and the node's own reason is the one
      // to read.
      if (!r.ok) {
        await db.prepare(`UPDATE nodes SET last_error = ? WHERE id = ? AND status = 'applied' AND last_error IS NULL`)
          .bind(`${what}没有生效：${error}`.slice(0, 500), t.node_id).run()
        return
      }
      const o = r.output as { used_bytes?: unknown; paused?: unknown } | undefined
      const clear = `last_error = CASE WHEN last_error LIKE '流量%没有生效：%' THEN NULL ELSE last_error END`
      if (o && typeof o.used_bytes === 'number' && Number.isFinite(o.used_bytes)) {
        await db.prepare(`UPDATE nodes SET traffic_used = ?, traffic_paused = ?, traffic_at = datetime('now'), ${clear} WHERE id = ?`)
          .bind(Math.max(0, Math.floor(o.used_bytes)), o.paused === true ? 1 : 0, t.node_id).run()
      } else if (t.kind === 'traffic.reset') {
        // a reset that succeeded without counts is still a reset: zero, running
        await db.prepare(`UPDATE nodes SET traffic_used = 0, traffic_paused = 0, traffic_at = datetime('now'), ${clear} WHERE id = ?`)
          .bind(t.node_id).run()
      } else {
        await db.prepare(`UPDATE nodes SET ${clear} WHERE id = ?`).bind(t.node_id).run()
      }
      return
    }
  }
}

/**
 * The traffic counters a server sent: this month's totals, and today's
 * increase. `skip`: nodes whose limit or reset was reported in the same sync —
 * the counters were read before that ran, and would put back what the reset
 * just cleared.
 */
async function applyTraffic(env: Env, server: ServerRow, entries: TrafficEntry[], skip: Set<number>) {
  // only the panel's own nodes: a node of the same name made by hand there is not counted on the panel's row
  const { results: nodes } = await env.DB.prepare('SELECT * FROM nodes WHERE server_id = ? AND owned = 1').bind(server.id).all<NodeRow>()
  const byTag = new Map(nodes.map((n) => [trafficTag(n), n]))
  const stmts: D1PreparedStatement[] = []
  for (const e of entries.slice(0, 500)) {
    const n = typeof e.tag === 'string' ? byTag.get(e.tag) : undefined
    if (!n || skip.has(n.id) || typeof e.used_bytes !== 'number' || !Number.isFinite(e.used_bytes)) continue
    const used = Math.max(0, Math.floor(e.used_bytes)), paused = e.paused === true ? 1 : 0
    if (used === n.traffic_used && paused === n.traffic_paused) continue
    // a smaller count means it was reset (monthly, or by hand): all of it is new
    const delta = used >= n.traffic_used ? used - n.traffic_used : used
    stmts.push(env.DB.prepare(`UPDATE nodes SET traffic_used = ?, traffic_paused = ?, traffic_at = datetime('now') WHERE id = ?`).bind(used, paused, n.id))
    if (delta > 0) {
      stmts.push(env.DB.prepare(`INSERT INTO traffic_daily (node_id, day, bytes) VALUES (?, date('now', '+8 hours'), ?)
        ON CONFLICT(node_id, day) DO UPDATE SET bytes = bytes + excluded.bytes`).bind(n.id, delta))
    }
  }
  if (stmts.length) await env.DB.batch(stmts)
}

/**
 * What grows without end, trimmed: the audit log and finished tasks after 7
 * days, daily traffic after 60
 * (the 流量 page shows 30), sign-in failures and spent or expired join tokens
 * after a day. Once a day by the cron trigger (wrangler.jsonc), whether or
 * not any server syncs; and at most once an hour after a sync, as before (a
 * panel whose trigger was taken away). After the answer is sent (waitUntil):
 * no request waits for it.
 */
let lastHousekeeping = 0
async function housekeeping(env: Env, scheduled = false) {
  if (!scheduled) {
    if (Date.now() - lastHousekeeping < 3600_000) return
    lastHousekeeping = Date.now()
    const due = await env.DB.prepare(`INSERT INTO settings (key, value) VALUES ('housekeeping_at', datetime('now'))
        ON CONFLICT(key) DO UPDATE SET value = excluded.value WHERE value < datetime('now', '-1 hour') RETURNING value`).first()
    if (!due) return   // another isolate did it within the hour
  }
  await env.DB.batch([
    env.DB.prepare(`DELETE FROM audit WHERE at < datetime('now', '-7 days')`),
    env.DB.prepare(`DELETE FROM tasks WHERE status IN ('done', 'failed') AND finished_at < datetime('now', '-7 days')`),
    env.DB.prepare(`DELETE FROM traffic_daily WHERE day < date('now', '-60 days')`),
    env.DB.prepare(`DELETE FROM login_failures WHERE at < datetime('now', '-1 day')`),
    env.DB.prepare(`DELETE FROM join_tokens WHERE expires_at < datetime('now', '-1 day') OR used_at < datetime('now', '-1 day')`),
  ])
}

// Sync: the agent reports the results of its tasks (and its traffic
// counters) and takes new ones.
app.post('/api/agent/sync', async (c) => {
  const token = c.req.header('Authorization')?.replace(/^Bearer /, '') ?? ''
  const server = token.length >= 32 && token.length <= 256
    ? await c.env.DB.prepare('SELECT * FROM servers WHERE agent_token_hash = ?').bind(await sha256Hex(token)).first<ServerRow>()
    : null
  if (!server) return c.json(fail('unauthorized', 'unknown agent token'), 401)
  type SyncBody = { hostname?: string; agent_version?: string; psm_version?: string; results?: AgentResult[]; traffic?: TrafficEntry[]
    users?: unknown; online?: unknown; events?: unknown; users_rev?: unknown }
  const body = await c.req.json<SyncBody>().catch((): SyncBody => ({}))
  const psmBefore = server.psm_version
  const ip = c.req.header('CF-Connecting-IP') ?? null
  // where the server is: Cloudflare knows the network the agent connects from
  const cf = (c.req.raw as { cf?: { asn?: unknown; country?: unknown } }).cf
  const asn = typeof cf?.asn === 'number' && cf.asn > 0 ? cf.asn : null
  const country = typeof cf?.country === 'string' && /^[A-Z]{2}$/.test(cf.country) ? cf.country : null
  const str = (v: unknown, n: number) => (typeof v === 'string' ? v.slice(0, n) : null)
  // the syncs of this minute counted in the same write (no extra round trip)
  const seen = await c.env.DB.prepare(`UPDATE servers SET last_seen = datetime('now'), hostname = COALESCE(?, hostname),
      agent_version = COALESCE(?, agent_version), psm_version = COALESCE(?, psm_version), last_ip = COALESCE(?, last_ip),
      asn = COALESCE(?, asn), country = COALESCE(?, country),
      sync_count = CASE WHEN sync_window IS NULL OR sync_window < datetime('now', '-60 seconds') THEN 1 ELSE sync_count + 1 END,
      sync_window = CASE WHEN sync_window IS NULL OR sync_window < datetime('now', '-60 seconds') THEN datetime('now') ELSE sync_window END
      WHERE id = ? RETURNING sync_count`)
    .bind(str(body.hostname, 64), str(body.agent_version, 16), str(body.psm_version, 40),
      ip && /^[0-9a-fA-F:.]{2,45}$/.test(ip) ? ip : null, asn, country, server.id).first<{ sync_count: number }>()
  // psm-agent keeps its results when told this, and comes back later
  if ((seen?.sync_count ?? 0) > SYNCS_PER_MINUTE) return c.json(fail('too_many', 'too many syncs; slow down'), 429)

  const trafficTouched = new Set<number>()
  const dirty = new Set<number>()
  for (const r of (Array.isArray(body.results) ? body.results : []).slice(0, 100)) {
    const id = r && typeof r === 'object' ? idOf(r.task_id) : null
    if (id === null) continue
    const t = await c.env.DB.prepare(`SELECT * FROM tasks WHERE id = ? AND server_id = ? AND status = 'running'`)
      .bind(id, server.id).first<TaskRow>()
    if (!t) continue
    // the result of this very task (its uid), not of another that once had its number
    const uid = typeof r.uid === 'string' ? r.uid : ''
    let want = ''
    try { want = String((JSON.parse(await decrypt(c.env.TOKEN_KEY, t.payload_enc)) as { uid?: unknown }).uid ?? '') } catch { /* unreadable: judged below */ }
    if (!want || uid !== want) continue
    const ok = r.ok === true
    // A leave's result is recorded before its task is finished, and a failure
    // fails the sync: psm-agent keeps the result, sends it again, and
    // uninstalls itself only once the panel has taken it.
    if (t.kind === 'agent.leave') {
      await applyResult(c.env, server, t, { ...r, ok })
      await c.env.DB.prepare(`UPDATE tasks SET status = ?, error = ?, finished_at = datetime('now') WHERE id = ?`)
        .bind(ok ? 'done' : 'failed', ok ? null : String(r.error ?? 'failed').slice(0, 500), t.id).run()
      continue
    }
    if (t.kind === 'traffic.set' || t.kind === 'traffic.reset') { if (t.node_id) trafficTouched.add(t.node_id) }
    // The result's effects first, then the task finished: a task is never
    // "done" while its node still says it is on its way. If the effects fail
    // the task stays running and the result can be sent again.
    try {
      await applyResult(c.env, server, t, { ...r, ok }, dirty)
    } catch (e) {
      console.error(`sync ${server.name}: result of task ${t.id} (${t.kind})`, e)
      // One result the panel cannot take must not fail every sync after it:
      // the task fails, and its node with it, so saving it again retries.
      // What the result says about ownership is still kept: a create that
      // made the node makes it the panel's (saving then changes it in
      // place), a conflict marks it someone else's. Only if even that cannot
      // be written (the database is down) does the sync fail, and psm-agent
      // keeps its results for the next one.
      const out = r.output as { conflict?: unknown; created?: unknown } | undefined
      const creates = t.kind === 'node.add' || t.kind === 'standalone.install'
      const made = creates && (ok || out?.created === true)
      const why = `${creates && out?.conflict === true ? CONFLICT : UNRECORDED}${(e as Error).message}`.slice(0, 500)
      try {
        await c.env.DB.batch([
          c.env.DB.prepare(`UPDATE tasks SET status = 'failed', error = ?, finished_at = datetime('now') WHERE id = ? AND status = 'running'`).bind(why, t.id),
          c.env.DB.prepare(`UPDATE nodes SET status = 'failed', last_error = ?, owned = CASE WHEN ? THEN 1 ELSE owned END
              WHERE id = ? AND status IN ('queued', 'deleting')`).bind(why, made ? 1 : 0, t.node_id ?? -1),
        ])
      } catch (e2) {
        console.error(`sync ${server.name}: database unavailable`, e2)
        return c.json(fail('unavailable', 'the panel could not record the results; send them again'), 503)
      }
      continue
    }
    await c.env.DB.prepare(`UPDATE tasks SET status = ?, error = ?, finished_at = datetime('now') WHERE id = ? AND status = 'running'`)
      .bind(ok ? 'done' : 'failed', ok ? null : String(r.error ?? 'failed').slice(0, 500), t.id).run()
  }
  // gone already when it carried its leave result
  if (!(await c.env.DB.prepare('SELECT 1 FROM servers WHERE id = ?').bind(server.id).first())) return c.json({ interval: syncInterval(c.env), tasks: [] })
  for (const id of dirty) await reconcileUsers(c.env, deps, id)
  if (Array.isArray(body.traffic)) await applyTraffic(c.env, server, body.traffic, trafficTouched)
  // PSM on the server changed (updated by hand, or by 更新 PSM / 升级 agent):
  // its nodes' exports may have changed with it (a status result above reads
  // the version afresh, so compare after the results)
  const psmNow = (await c.env.DB.prepare('SELECT psm_version FROM servers WHERE id = ?').bind(server.id).first<{ psm_version: string | null }>())?.psm_version
  if (psmBefore && psmNow && psmNow !== psmBefore) await queueExports(c.env, server.id)
  // users' usage and devices, the local page's events, the host name (roomkey)
  const waitUntil = (p: Promise<unknown>) => { try { c.executionCtx.waitUntil(p) } catch { void p } }
  let eventsAcked: string[] = []
  try {
    // gone already when this sync carried its leave result
    const fresh = await c.env.DB.prepare('SELECT * FROM servers WHERE id = ?').bind(server.id).first<Parameters<typeof roomkeySync>[2]>()
    if (fresh) eventsAcked = (await roomkeySync(c.env, deps, fresh, body, ip, waitUntil)).eventsAcked
  } catch (e) {
    console.error(`sync ${server.name}: roomkey`, e)
  }

  // Claimed in one statement: a second sync of the same server racing this
  // one (a retry, a second agent with a copied token) cannot be handed the
  // same tasks. A task claimed but not reported for a while goes out again.
  //
  // A psm-agent older than roomkey's is handed nothing but its upgrade (and a
  // status report): it knows neither ownership (a first create could take
  // over a node made by hand) nor the guard that takes old relays off, and the
  // upgrade runs that guard before anything else. The rest waits, queued.
  const capable = versionAtLeast(str(body.agent_version, 16), OWN_SITE_AGENT)
  // a server on its way out is handed its leave only (server delete reserves it)
  const kinds = (capable ? '' : ` AND kind IN ('agent.update', 'status')`) +
    ` AND (kind = 'agent.leave' OR NOT EXISTS (SELECT 1 FROM servers WHERE id = tasks.server_id AND leaving = 1))`
  const due = `(status = 'queued' OR (status = 'running' AND claimed_at < datetime('now', '-${TASK_RETRY_MINUTES} minutes')))${kinds}`
  const { results: claimed } = await c.env.DB.prepare(
    `UPDATE tasks SET status = 'running', claimed_at = datetime('now')
      WHERE id IN (SELECT id FROM tasks WHERE server_id = ? AND ${due} ORDER BY id LIMIT 20) AND ${due}
      RETURNING *`).bind(server.id).all<TaskRow>()
  const tasks = []
  for (const t of claimed.sort((a, b) => a.id - b.id)) {
    // a task that cannot be read (written with another TOKEN_KEY) fails with
    // the reason, on its node too — rather than failing every sync
    try {
      const task = JSON.parse(await decrypt(c.env.TOKEN_KEY, t.payload_enc)) as Record<string, unknown>
      tasks.push({ id: t.id, ...task })
    } catch (e) {
      const error = `面板读不出这个任务（TOKEN_KEY 换过？）：${(e as Error).message}`.slice(0, 500)
      await c.env.DB.prepare(`UPDATE tasks SET status = 'failed', error = ?, finished_at = datetime('now') WHERE id = ?`).bind(error, t.id).run()
      await applyResult(c.env, server, t, { task_id: t.id, ok: false, error }).catch((err) => console.error(err))
    }
  }
  try { c.executionCtx.waitUntil(housekeeping(c.env).catch((e) => console.error('housekeeping', e))) } catch { /* no context (tests) */ }
  // more queued behind these, or results just came in: come back soon
  const busy = tasks.length > 0 || (body.results?.length ?? 0) > 0 ||
    !!(await c.env.DB.prepare(`SELECT 1 FROM tasks WHERE server_id = ? AND status = 'queued'${kinds} LIMIT 1`).bind(server.id).first())
  // the local page's events the panel recorded: psm-agent drops those, keeps the rest
  return c.json({ interval: busy ? FAST_INTERVAL : syncInterval(c.env), tasks, events_acked: eventsAcked })
})

// The dashboard in one request: counts and sums, nothing decrypted.
app.get('/api/overview', async (c) => {
  const db = c.env.DB
  const [servers, nodes, today, failing, resetDays] = await db.batch([
    db.prepare(`SELECT ${serverStatusSQL(c.env)} AS status, COUNT(*) AS n FROM servers s GROUP BY 1`),
    db.prepare(`SELECT status, COUNT(*) AS n, SUM(traffic_used) AS used, SUM(traffic_paused) AS paused FROM nodes GROUP BY status`),
    db.prepare(`SELECT day, SUM(bytes) AS bytes FROM traffic_daily WHERE day >= date('now', '+8 hours', '-13 days') GROUP BY day ORDER BY day`),
    db.prepare(`SELECT 'node' AS type, n.id, n.name, s.name AS server, n.last_error AS error FROM nodes n JOIN servers s ON s.id = n.server_id
                 WHERE n.status = 'failed' OR (n.last_error IS NOT NULL AND n.status = 'applied')
                LIMIT 20`),
    // the days of the month the nodes' counts start over on (本月 counts from there)
    db.prepare('SELECT DISTINCT reset_day FROM nodes'),
  ])
  return c.json({
    version: PANEL_VERSION,
    servers: servers.results, nodes: nodes.results,
    daily: today.results, problems: failing.results,
    reset_days: (resetDays.results as { reset_day: number }[]).map((r) => r.reset_day),
  })
})

// roomkey: users, host names, local page codes, alerts, backup (roomkey.ts)
const deps: Deps = {
  audit, taskStmt: (env, serverId, nodeId, task) => taskStmt(env, serverId, nodeId, task), enqueue: (env, serverId, nodeId, task) => enqueue(env, serverId, nodeId, task),
  panelUrl, randomToken, sha256Hex, idOf, fail, versionAtLeast, syncInterval,
  // as an edit of the port in the panel: metering on the new port, and the
  // node's links asked for again
  nodePortChanged: async (env, nodeId) => {
    const n = await getNode(env, nodeId)
    if (!n || !n.owned) return
    await env.DB.batch([
      await taskStmt(env, n.server_id, n.id, trafficTask(n)),
      await taskStmt(env, n.server_id, n.id, { kind: 'node.export', core: n.engine, protocol: n.psm_protocol, tag: n.name, server: n.address, format: linkFormat(n) }),
    ])
  },
}
registerRoomkey(app, deps)

app.all('/api/*', (c) => c.json(fail('not_found', 'no such endpoint'), 404))
// everything else is the panel's pages (the Worker runs first for every path,
// so the admin-host rule above covers them too)
// the install bundle only through /api/agent/bundle/ (a token checked)
app.all('/_install/*', (c) => c.text('not found', 404))
app.all('*', (c) => c.env.ASSETS.fetch(c.req.raw))

export default {
  fetch: app.fetch,
  // the cron trigger (wrangler.jsonc): the daily housekeeping
  // and, every five minutes, roomkey's periods, device pauses, user lists and alerts
  scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil((async () => {
      await ensureSchema(env.DB)
      if (!env.TOKEN_KEY) env.TOKEN_KEY = panelKey ??= await storedTokenKey(env.DB)
      await housekeeping(env).catch((e) => console.error('housekeeping', e))
      await roomkeyCron(env, deps).catch((e) => console.error('roomkey cron', e))
    })())
  },
} satisfies ExportedHandler<Env>
