// roomkey: what the panel adds to PSM Panel — users (quotas in total and per
// server, expiry, device limits, a subscription each), node host names kept on
// their server's address, the one-time code for a server's local page, what
// that page reports, Telegram alerts, the self-service subscription page and a
// backup. The pure rules live in shared/users.ts; this file is the D1 and HTTP
// side.
//
// How a server's users stay right:
// - reconcileUsers() builds each server's complete list. When it differs from
//   the last one queued, it is queued under the next revision (servers.
//   users_rev). PSM ignores a list older than the one it holds, so a task that
//   arrives late cannot undo a newer one.
// - The task's result records the revision the server took (users_acked_rev)
//   and, per user, the credentials it took (user_servers.synced_cred_rev). A
//   subscription only lists a server's nodes for a user that server has.
// - Each sync carries the revision PSM holds (users_rev): a server that lost
//   its store, or never got a list, is sent it again.
// - A list is never sent while any user's credentials fail to decrypt (a wrong
//   TOKEN_KEY must not empty every server).
//
// The main module (index.ts) passes in its helpers (Deps): a Worker's main
// module cannot export anything but its entrypoints.

import type { Context, Hono } from 'hono'
import type { Env } from './index'
import { decrypt, encrypt } from './crypto'
import { buildSubscription, pickFormat, type SubNode } from './subscription'
import {
  activeOn, localCode, localToSql, localYmd, needsMetering, normEpoch, PERIODS, periodEnd, periodId, periodStart, proxyFor, linkFor, sqlTime, STATE_LABELS,
  USER_NAME_RE, userinfoHeader, userNodes, userState, validCredentials,
  type Access, type UserRow, type UserServerRow, type UserState,
} from '../../shared/users'

/** A node restored from a backup with work that had not reached its server: saving it sends it again, even unchanged. */
export const RESTORE_NOTE = '从备份恢复时还有改动没下发完：检查后重新保存一次（会重新下发）'

type C = Context<{ Bindings: Env }>
type App = Hono<{ Bindings: Env }>

export type Deps = {
  audit: (env: Env, action: string, target?: string, detail?: string, actor?: string) => Promise<void>
  taskStmt: (env: Env, serverId: number, nodeId: number | null, task: Record<string, unknown>) => Promise<D1PreparedStatement>
  enqueue: (env: Env, serverId: number, nodeId: number | null, task: Record<string, unknown>) => Promise<number>
  panelUrl: (c: C) => Promise<string>
  randomToken: (bytes?: number) => string
  sha256Hex: (s: string) => Promise<string>
  idOf: (v: unknown) => number | null
  fail: (code: string, message: string, extra?: Record<string, unknown>) => unknown
  versionAtLeast: (v: string | null, want: string) => boolean
  syncInterval: (env: Env) => number
  /** a node's port changed on its server (the local page): metering and links follow, as for an edit in the panel */
  nodePortChanged: (env: Env, nodeId: number) => Promise<void>
}

/**
 * The psm-agent (with its PSM) that knows user.sync with revisions, own-site
 * REALITY checked against psm caps, local.code with deadlines, and events.
 */
export const USERS_AGENT = '0.14.0'
const GB = 1024 ** 3
const DEVICE_WINDOW_MIN = 15      // client IPs seen within this many minutes count as devices
const DEVICE_BLOCK_MIN = 15       // a user over their device limit is paused this long
const LOCAL_CODE_TTL = 600        // seconds a local page code works, from when it is issued
const OFFLINE_ALERT_MIN = 5
const DNS_RETRY_MIN = 10          // after a failed DNS update, wait this long before the next try

type ServerLite = {
  id: number; name: string; agent_token_hash: string | null; agent_version: string | null; users_hash: string | null
  users_rev: number; users_acked_rev: number; users_error: string | null; users_retry_at: string | null
  users_failed_hash: string | null; hostname: string | null; last_ip: string | null; dns_name: string | null
}
type NodeLite = { id: number; server_id: number; name: string; labels: string; psm_protocol: string; engine: string; status: string }

const json = (v: unknown) => JSON.stringify(v)
const nowSql = () => new Date().toISOString().replace('T', ' ').slice(0, 19)
const sqlAt = (ms: number) => new Date(ms).toISOString().replace('T', ' ').slice(0, 19)
const HOST_RE = /^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$|^\d{1,3}(\.\d{1,3}){3}$|^[0-9a-fA-F:]{2,45}$/

/** The period id a user's counts belong to now. */
const currentPeriod = (u: Pick<UserRow, 'reset_period' | 'period_start' | 'period_seq'>) => periodId(u.reset_period, u.period_start, u.period_seq)

// ── helpers over D1 ──────────────────────────────────────────────────────────

async function loadAccess(env: Env, userId?: number): Promise<Map<number, Access[]>> {
  const q = userId === undefined
    ? env.DB.prepare('SELECT user_id, kind, value FROM user_access')
    : env.DB.prepare('SELECT user_id, kind, value FROM user_access WHERE user_id = ?').bind(userId)
  const { results } = await q.all<{ user_id: number; kind: Access['kind']; value: string }>()
  const m = new Map<number, Access[]>()
  for (const r of results) m.set(r.user_id, [...(m.get(r.user_id) ?? []), { kind: r.kind, value: r.value }])
  return m
}

async function loadUserServers(env: Env): Promise<Map<string, UserServerRow>> {
  const { results } = await env.DB.prepare('SELECT * FROM user_servers').all<UserServerRow>()
  return new Map(results.map((r) => [`${r.user_id}:${r.server_id}`, r]))
}

const serverQuotas = (userId: number, perServer: Map<string, UserServerRow>) =>
  [...perServer.values()].some((r) => r.user_id === userId && !!r.quota_bytes)

async function liveNodes(env: Env): Promise<(NodeLite & { labelList: string[] })[]> {
  const { results } = await env.DB.prepare(
    `SELECT id, server_id, name, labels, psm_protocol, engine, status FROM nodes WHERE engine != 'standalone' AND status IN ('applied', 'queued') AND owned = 1`)
    .all<NodeLite>()
  return results.map((n) => ({ ...n, labelList: JSON.parse(n.labels) as string[] }))
}

/**
 * Brings every period up to date: a user whose period moved on starts their
 * usage over, here and (through the new period id) on every server. Each
 * change is conditional on the period it moves from, so two isolates rolling
 * at once roll once (the second's update matches nothing, and its per-server
 * reset is skipped with it: changes() is the previous statement's count).
 */
async function rollPeriods(env: Env, now = new Date()): Promise<boolean> {
  const { results } = await env.DB.prepare('SELECT id, reset_period, reset_day, period_start FROM users').all<Pick<UserRow, 'id' | 'reset_period' | 'reset_day' | 'period_start'>>()
  const stmts: D1PreparedStatement[] = []
  for (const u of results) {
    const start = periodStart(now, u.reset_period, u.reset_day)
    if (start === u.period_start) continue
    stmts.push(env.DB.prepare(`UPDATE users SET period_start = ?, period_seq = 0, used_total_bytes = 0, period_retired_bytes = 0
        WHERE id = ? AND period_start IS ? AND reset_period = ? AND reset_day = ?`).bind(start, u.id, u.period_start, u.reset_period, u.reset_day))
    stmts.push(env.DB.prepare('UPDATE user_servers SET used_bytes = 0, period_base = 0, used_epoch = NULL WHERE user_id = ? AND changes() = 1').bind(u.id))
  }
  if (stmts.length) await env.DB.batch(stmts)
  return stmts.length > 0
}

// ── each server's list ───────────────────────────────────────────────────────

export async function reconcileUsers(env: Env, deps: Deps, onlyServer?: number, attempt = 0): Promise<number> {
  const { results: servers } = await env.DB.prepare(
    `SELECT id, name, agent_token_hash, agent_version, users_hash, users_rev, users_acked_rev, users_error, users_retry_at, users_failed_hash,
            hostname, last_ip, dns_name
       FROM servers WHERE agent_token_hash IS NOT NULL AND leaving = 0`).all<ServerLite>()
  const { results: users } = await env.DB.prepare('SELECT * FROM users ORDER BY name').all<UserRow>()
  const access = await loadAccess(env)
  const perServer = await loadUserServers(env)
  const nodes = (await liveNodes(env)).map((n) => ({ ...n, labels: n.labelList }))
  const now = Date.now()
  const eligible = (u: UserRow, here: typeof nodes) => userNodes(access.get(u.id) ?? [], here,
    { needsMetering: needsMetering(u, serverQuotas(u.id, perServer)), unmetered: !!u.unmetered })

  // a server whose psm-agent cannot take users: said on the server, so it is not a mystery
  const TOO_OLD = `psm-agent 版本太旧（要 ${USERS_AGENT} 以上）：这台服务器的节点不会出现在用户的订阅里，请在 ⋯ 里升级 psm-agent`
  for (const s of servers) {
    if (deps.versionAtLeast(s.agent_version, USERS_AGENT)) continue
    const wanted = users.some((u) => eligible(u, nodes.filter((n) => n.server_id === s.id)).length > 0)
    const msg = wanted ? TOO_OLD : null
    if (msg !== s.users_error) await env.DB.prepare('UPDATE servers SET users_error = ? WHERE id = ?').bind(msg, s.id).run()
  }
  const targets = servers.filter((s) => (onlyServer === undefined || s.id === onlyServer) && deps.versionAtLeast(s.agent_version, USERS_AGENT))
  if (!targets.length) return 0

  // every credential, or no list at all: one that cannot be read would
  // otherwise drop its user from every server
  const creds = new Map<number, { uuid: string; password: string }>()
  const unreadable: string[] = []
  for (const u of users) {
    try {
      creds.set(u.id, { uuid: await decrypt(env.TOKEN_KEY, u.uuid_enc), password: await decrypt(env.TOKEN_KEY, u.password_enc) })
    } catch {
      unreadable.push(u.name)
    }
  }
  if (unreadable.length) {
    const msg = `面板解不开 ${unreadable.length} 个用户的密钥（${unreadable.slice(0, 5).join('、')}；TOKEN_KEY 换过？），用户列表暂停下发，服务器上的用户保持原样`
    console.error(msg)
    await env.DB.batch(targets.map((s) => env.DB.prepare('UPDATE servers SET users_error = ? WHERE id = ?').bind(msg, s.id)))
    return 0
  }

  let queued = 0
  for (const s of targets) {
    const here = nodes.filter((n) => n.server_id === s.id)
    const list: Record<string, unknown>[] = []
    const meta: { id: number; cred_rev: number; nodes: string[]; enabled: boolean }[] = []
    for (const u of users) {
      const mine = eligible(u, here)
      if (!mine.length) continue
      const cred = creds.get(u.id)!
      const us = perServer.get(`${u.id}:${s.id}`)
      const exp = sqlTime(u.expires_at)
      const enabled = activeOn(userState(u, now), us)
      list.push({
        // core/tag: PSM grants a node by its tag, and a node of the same name on
        // another core (made by hand there) must not get the user too
        name: u.name, uuid: cred.uuid, password: cred.password, nodes: mine.map((n) => `${n.engine}/${n.name}`),
        enabled, expires_at: exp === null ? null : Math.floor(exp / 1000),
        quota_bytes: us?.quota_bytes ?? null, period: currentPeriod(u),
      })
      meta.push({ id: u.id, cred_rev: u.cred_rev, nodes: mine.map((n) => n.name), enabled })
    }
    const hash = await deps.sha256Hex(json({ users: list }))
    if (hash === s.users_hash) continue
    // Only another try at the very list that failed waits (each try restarts
    // the server's cores); a different list — a revocation, say — goes now.
    if (hash === s.users_failed_hash && (sqlTime(s.users_retry_at) ?? 0) > now) continue
    // One transaction: the next revision is taken against the server row as
    // read, and only then does this list replace a queued one. A Worker that
    // lost the race changes nothing and builds again from what is there now
    // (each number names one list, and a newer list is never deleted by an older).
    const rev = s.users_rev + 1
    const payload = await encrypt(env.TOKEN_KEY, json({ kind: 'user.sync', uid: crypto.randomUUID(), data: { revision: rev, users: list }, meta: { revision: rev, users: meta } }))
    await env.DB.batch([
      env.DB.prepare('UPDATE servers SET users_rev = ?, users_hash = ? WHERE id = ? AND users_rev = ? AND users_hash IS ? AND leaving = 0')
        .bind(rev, hash, s.id, s.users_rev, s.users_hash),
      env.DB.prepare(`DELETE FROM tasks WHERE server_id = ? AND kind = 'user.sync' AND status = 'queued' AND changes() = 1`).bind(s.id),
      // inserted only by the Worker that reserved the number: after its own
      // delete no list is queued, while a Worker that lost finds the winner's
      env.DB.prepare(`INSERT INTO tasks (server_id, node_id, kind, payload_enc)
          SELECT ?, NULL, 'user.sync', ? WHERE EXISTS (SELECT 1 FROM servers WHERE id = ? AND users_rev = ? AND users_hash = ? AND leaving = 0)
            AND NOT EXISTS (SELECT 1 FROM tasks WHERE server_id = ? AND kind = 'user.sync' AND status = 'queued')`)
        .bind(s.id, payload, s.id, rev, hash, s.id),
    ])
    const won = await env.DB.prepare('SELECT 1 FROM servers WHERE id = ? AND users_rev = ? AND users_hash = ? AND leaving = 0').bind(s.id, rev, hash).first()
    if (won) { queued++; continue }
    if (attempt < 3) queued += await reconcileUsers(env, deps, s.id, attempt + 1)   // this server again; the loop goes on
  }
  return queued
}

type SyncMeta = { revision?: unknown; users?: { id?: unknown; cred_rev?: unknown; nodes?: unknown }[] }
const RETRY_MIN = 5

/**
 * A user.sync result. Only the answer of roomkey's PSM to this very revision
 * counts, and nothing older than what the server already confirmed: a late
 * result (success or failure) changes nothing. Taken: the revision, and for
 * each user the credentials and the nodes the server now has (a user deleted
 * meanwhile is skipped). Not taken — the task failed, a core did not accept
 * the accounts, a name clashes with a user made on the server — is shown on
 * the server, and the list goes again after a pause (each try restarts cores).
 */
export async function userSyncResult(env: Env, serverId: number, payload: { meta?: SyncMeta }, ok: boolean, error: string | null, output: unknown) {
  const rev = typeof payload.meta?.revision === 'number' ? payload.meta.revision : -1
  // the list that failed is remembered: only another try at that same list waits
  const later = (problem: string) => env.DB.prepare(
    `UPDATE servers SET users_error = ?, users_failed_hash = users_hash, users_hash = 'retry', users_retry_at = datetime('now', ?)
      WHERE id = ? AND users_acked_rev <= ? AND users_rev = ?`)
    .bind(problem, `+${RETRY_MIN} minutes`, serverId, rev, rev).run()
  try {
    const srv = await env.DB.prepare('SELECT users_rev, users_acked_rev FROM servers WHERE id = ?').bind(serverId).first<{ users_rev: number; users_acked_rev: number }>()
    if (!srv || rev <= srv.users_acked_rev) return   // a result for a revision the server already confirmed (or older)
    const o = output as { status?: unknown; revision?: unknown; conflicts?: unknown; ok?: unknown } | undefined
    if (ok && o?.status === 'stale') {
      // the server holds a newer list, or another list under this number:
      // number above it and send again
      const theirs = typeof o.revision === 'number' ? o.revision : rev
      await env.DB.prepare('UPDATE servers SET users_rev = MAX(users_rev, ?), users_hash = NULL, users_retry_at = NULL WHERE id = ?').bind(theirs, serverId).run()
      return
    }
    if (!ok) return void await later(`用户没有下发成功：${error}`)
    if (o?.status !== 'imported' || o.revision !== rev) return void await later('服务器上的 PSM 太旧，不认识带版本号的用户列表：请升级 psm-agent（会先更新 PSM）')
    if (o.ok !== true) return void await later(`用户已写入，但有内核没有接受新配置（已恢复原配置），${RETRY_MIN} 分钟后重试；详见服务器日志`)
    const conflicts = Array.isArray(o.conflicts) ? o.conflicts.map(String) : []
    const { results: named } = await env.DB.prepare('SELECT id, name FROM users').all<{ id: number; name: string }>()
    const nameOf = new Map(named.map((u) => [u.id, u.name]))
    const taken = (payload.meta?.users ?? []).filter((m) => typeof m.id === 'number' && nameOf.has(m.id) && !conflicts.includes(nameOf.get(m.id)!))
    // One transaction, gated on this revision winning: a newer result that
    // committed first makes every write here a no-op (the acknowledgement and
    // each user's membership never move backwards).
    const isLatest = `(SELECT users_acked_rev FROM servers WHERE id = ${Number(serverId)}) = ${Number(rev)}`
    const conflictRetry = conflicts.length ? new Date(Date.now() + 30 * 60_000).toISOString().replace('T', ' ').slice(0, 19) : null
    await env.DB.batch([
      env.DB.prepare(`UPDATE servers SET users_acked_rev = ?, users_error = ?, users_retry_at = ?,
          users_failed_hash = CASE WHEN ? THEN users_hash ELSE NULL END,
          users_hash = CASE WHEN ? THEN 'retry' ELSE users_hash END WHERE id = ? AND users_acked_rev < ?`)
        .bind(rev, conflicts.length ? `服务器上已有同名的本地用户（psm user add 建的），面板的同名用户没有下发：${conflicts.join('、')}（改名或删掉本地用户后会自动重试）` : null,
          conflictRetry, conflicts.length ? 1 : 0, conflicts.length ? 1 : 0, serverId, rev),
      env.DB.prepare(`UPDATE user_servers SET synced_cred_rev = NULL, synced_nodes = NULL, synced_enabled = 0
          WHERE server_id = ? AND user_id NOT IN (SELECT value FROM json_each(?)) AND ${isLatest}`)
        .bind(serverId, json(taken.map((m) => m.id))),
      ...taken.map((m) => env.DB.prepare(`INSERT INTO user_servers (user_id, server_id, synced_cred_rev, synced_nodes, synced_enabled)
          SELECT ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM users WHERE id = ?) AND ${isLatest}
          ON CONFLICT(user_id, server_id) DO UPDATE SET synced_cred_rev = excluded.synced_cred_rev, synced_nodes = excluded.synced_nodes,
            synced_enabled = excluded.synced_enabled`)
        .bind(m.id, serverId, Number(m.cred_rev) || 0, json(Array.isArray(m.nodes) ? m.nodes.map(String) : []), (m as { enabled?: unknown }).enabled === true ? 1 : 0, m.id)),
    ])
  } catch (e) {
    // the result could not be recorded: the list goes again rather than being taken as delivered
    console.error(`user.sync result on server ${serverId}`, e)
    await later('面板没能记下这次下发的结果，稍后重发').catch(() => undefined)
  }
}

// ── what a server reports ────────────────────────────────────────────────────

type UsageEntry = { name?: unknown; managed?: unknown; counter_bytes?: unknown; counter_epoch?: unknown; period?: unknown }
type OnlineEntry = { name?: unknown; ips?: unknown }
type AgentEvent = { id?: unknown; at?: unknown; kind?: unknown; target?: unknown; detail?: unknown }
type ServerRowLite = {
  id: number; name: string; last_ip: string | null; dns_name: string | null; dns_ip: string | null; dns_at: string | null; dns_error: string | null
  alert_offline: number; users_hash: string | null; users_rev: number; users_acked_rev: number; users_retry_at: string | null
  users_failed_hash: string | null; agent_version: string | null
}

/**
 * The roomkey part of a sync: each user's counter (→ usage, first use,
 * quotas), their client IPs (→ device limits), what was done on the local
 * page, the user list revision PSM holds, the server being back online, and
 * its DNS name following its address. Returns the ids of the events recorded.
 */
export async function onSync(env: Env, deps: Deps, server: ServerRowLite,
  body: { users?: unknown; online?: unknown; events?: unknown; users_rev?: unknown },
  ip: string | null, waitUntil: (p: Promise<unknown>) => void): Promise<{ eventsAcked: string[] }> {
  let changed = false
  const usage = (body.users as { users?: unknown } | undefined)?.users
  if (Array.isArray(usage)) changed = (await applyUsage(env, server.id, usage as UsageEntry[])) || changed
  const online = (body.online as { users?: unknown } | undefined)?.users
  if (Array.isArray(online)) changed = (await applyOnline(env, deps, server, online as OnlineEntry[])) || changed
  const eventsAcked = Array.isArray(body.events) ? await applyEvents(env, deps, server, (body.events as AgentEvent[]).slice(0, 100)) : []
  if (server.alert_offline) {
    if ((await notify(env, `✅ 服务器 ${server.name} 恢复在线`)) !== 'failed')
      await env.DB.prepare('UPDATE servers SET alert_offline = 0 WHERE id = ?').bind(server.id).run()
  }
  // the list PSM holds: behind (rebuilt, or a list lost on the way) and none on
  // its way → send it again; ahead (this panel restored from a backup) → number above it
  let resend = server.users_hash === null
  const pausing = (sqlTime(server.users_retry_at) ?? 0) > Date.now()   // a list that failed waits before it goes again
  // a psm-agent too old for user lists (downgraded): nobody has anything there any more
  if (!deps.versionAtLeast(server.agent_version, USERS_AGENT) && server.users_acked_rev > 0) {
    await env.DB.batch([
      env.DB.prepare('UPDATE user_servers SET synced_cred_rev = NULL, synced_nodes = NULL, synced_enabled = 0 WHERE server_id = ?').bind(server.id),
      env.DB.prepare('UPDATE servers SET users_acked_rev = 0 WHERE id = ?').bind(server.id),
    ])
  }
  if (typeof body.users_rev === 'number' && Number.isInteger(body.users_rev) && body.users_rev >= 0) {
    const theirs = body.users_rev
    if (theirs < server.users_acked_rev) {
      // the server lost what it had confirmed (rebuilt, its store gone): no
      // user has anything there until a list is taken again — one
      // transaction, and only while the confirmation is still the one read
      await env.DB.batch([
        env.DB.prepare('UPDATE servers SET users_acked_rev = ? WHERE id = ? AND users_acked_rev = ?').bind(theirs, server.id, server.users_acked_rev),
        env.DB.prepare('UPDATE user_servers SET synced_cred_rev = NULL, synced_nodes = NULL, synced_enabled = 0 WHERE server_id = ? AND changes() = 1').bind(server.id),
      ])
    }
    if (theirs > server.users_rev) {
      await env.DB.prepare('UPDATE servers SET users_rev = ?, users_hash = NULL WHERE id = ?').bind(theirs, server.id).run()
      resend = true
    } else if ((theirs < server.users_rev || (theirs === server.users_rev && server.users_acked_rev < theirs)) && !pausing && !(await env.DB.prepare(
      `SELECT 1 FROM tasks WHERE server_id = ? AND kind = 'user.sync' AND status IN ('queued', 'running') LIMIT 1`).bind(server.id).first())) {
      // behind, or holding the latest list whose result never reached the
      // panel: the list goes again (under a new number), and its result is recorded
      await env.DB.prepare('UPDATE servers SET users_hash = NULL WHERE id = ?').bind(server.id).run()
      resend = true
    }
  }
  if (pausing) resend = false
  if (changed || (resend && deps.versionAtLeast(server.agent_version, USERS_AGENT))) {
    await rollPeriods(env)
    await reconcileUsers(env, deps)
  }
  if (server.dns_name && ip && /^\d{1,3}(\.\d{1,3}){3}$/.test(ip)) {
    // after a failure, wait before trying again (whatever the address)
    const backingOff = !!server.dns_error && (sqlTime(server.dns_at) ?? 0) > Date.now() - DNS_RETRY_MIN * 60_000
    if (!backingOff && (ip !== server.dns_ip || server.dns_error)) waitUntil(updateDns(env, deps, server, ip).catch((e) => console.error('dns', e)))
  }
  return { eventsAcked }
}

/**
 * Each user's use on this server, for users this server has (synced) only.
 * - This period's use is what PSM counted for the period (it starts over when
 *   PSM gets a new period id), taken as it is, not added up: a report seen
 *   twice, or two racing, changes nothing; a report under any other period id
 *   is not this period's. A newer counter generation (PSM lost its store mid-
 *   period) banks what was counted before (period_base); an older one is a
 *   late report and is ignored.
 * - The lifetime counter, compare-and-swapped, feeds the daily history and
 *   starts a "from first use" term.
 * Returns whether anyone's use went up.
 */
/** A leaving server's last readings, taken just before its users were purged. */
export const applyLeaveUsage = (env: Env, serverId: number, entries: unknown[]) => applyUsage(env, serverId, entries.slice(0, 1000) as UsageEntry[])

async function applyUsage(env: Env, serverId: number, entries: UsageEntry[]): Promise<boolean> {
  const { results: users } = await env.DB.prepare('SELECT * FROM users').all<UserRow>()
  const byName = new Map(users.map((u) => [u.name, u]))
  const { results: rows } = await env.DB.prepare('SELECT * FROM user_servers WHERE server_id = ? AND synced_cred_rev IS NOT NULL').bind(serverId).all<UserServerRow>()
  const here = new Map(rows.map((r) => [r.user_id, r]))
  const stmts: D1PreparedStatement[] = []
  const touched = new Set<number>()
  let added = false
  const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? Math.max(0, Math.floor(v)) : null)
  for (const e of entries.slice(0, 5000)) {
    const u = typeof e.name === 'string' ? byName.get(e.name) : undefined
    const r = u ? here.get(u.id) : undefined
    const counter = num(e.counter_bytes), used = num((e as { used_bytes?: unknown }).used_bytes)
    const epoch = normEpoch(e.counter_epoch)
    if (!u || !r || e.managed !== true || counter === null || !epoch) continue
    const paused = (e as { local_paused?: unknown }).local_paused === true ? 1 : 0
    if (paused !== r.local_paused) stmts.push(env.DB.prepare('UPDATE user_servers SET local_paused = ? WHERE user_id = ? AND server_id = ?').bind(paused, u.id, serverId))
    // This period's use, as the server counted it, under this exact period
    // (checked in the same statement: a reset or rollover that committed
    // meanwhile makes it a no-op). A newer counter generation banks what was
    // counted before it; an older one is a late report.
    if (used !== null && e.period === currentPeriod(u) && !(r.used_epoch && epoch < r.used_epoch)) {
      const newer = epoch !== r.used_epoch
      const base = newer ? r.used_bytes : r.period_base
      const total = base + used
      if (newer || total > r.used_bytes) {
        stmts.push(env.DB.prepare(`UPDATE user_servers SET period_base = ?, used_bytes = MAX(used_bytes, ?), used_epoch = ?
            WHERE user_id = ? AND server_id = ? AND used_epoch IS ? AND used_bytes = ?
              AND EXISTS (SELECT 1 FROM users WHERE id = ? AND reset_period = ? AND period_start IS ? AND period_seq = ?)`)
          .bind(base, total, epoch, u.id, serverId, r.used_epoch, r.used_bytes, u.id, u.reset_period, u.period_start, u.period_seq))
        touched.add(u.id)
        if (total > r.used_bytes) added = true
      }
    }
    // the lifetime counter: the history, and the first use
    const cur = normEpoch(r.counter_epoch)
    if (cur && epoch < cur) continue
    const newerCounter = epoch !== cur
    if (!newerCounter && counter <= r.last_counter) continue
    const delta = newerCounter ? counter : counter - r.last_counter
    stmts.push(env.DB.prepare(`UPDATE user_servers SET last_counter = ?, counter_epoch = ?
        WHERE user_id = ? AND server_id = ? AND last_counter = ? AND counter_epoch IS ?`)
      .bind(counter, epoch, u.id, serverId, r.last_counter, r.counter_epoch))
    if (delta <= 0) continue
    stmts.push(env.DB.prepare(`INSERT INTO user_traffic_daily (user_id, server_id, day, bytes) SELECT ?, ?, date('now', '+8 hours'), ? WHERE changes() = 1
        ON CONFLICT(user_id, server_id, day) DO UPDATE SET bytes = bytes + excluded.bytes`).bind(u.id, serverId, delta))
    stmts.push(env.DB.prepare(`UPDATE users SET first_used_at = datetime('now'), expires_at = datetime('now', '+' || first_use_days || ' days')
        WHERE id = ? AND first_use_days IS NOT NULL AND first_used_at IS NULL AND expires_at IS NULL
          AND EXISTS (SELECT 1 FROM user_servers WHERE user_id = ? AND server_id = ? AND last_counter = ? AND counter_epoch IS ?)`)
      .bind(u.id, u.id, serverId, counter, epoch))
    added = true
  }
  // a user's total is the sum over servers of this period's use
  for (const id of touched) {
    // plus what was used this period on servers that have since left the panel
    stmts.push(env.DB.prepare('UPDATE users SET used_total_bytes = period_retired_bytes + (SELECT COALESCE(SUM(used_bytes), 0) FROM user_servers WHERE user_id = ?) WHERE id = ?').bind(id, id))
  }
  if (stmts.length) await env.DB.batch(stmts)
  return added
}

/** Records each user's client IPs here (users this server has); pauses a user for a while over their device limit. */
async function applyOnline(env: Env, deps: Deps, server: ServerRowLite, entries: OnlineEntry[]): Promise<boolean> {
  const { results: users } = await env.DB.prepare(
    `SELECT u.id, u.name, u.device_limit, u.blocked_until FROM users u JOIN user_servers us ON us.user_id = u.id
      WHERE us.server_id = ? AND us.synced_cred_rev IS NOT NULL`).bind(server.id)
    .all<Pick<UserRow, 'id' | 'name' | 'device_limit' | 'blocked_until'>>()
  const byName = new Map(users.map((u) => [u.name, u]))
  const stmts: D1PreparedStatement[] = [env.DB.prepare('DELETE FROM user_online WHERE server_id = ?').bind(server.id)]
  for (const e of entries.slice(0, 5000)) {
    const u = typeof e.name === 'string' ? byName.get(e.name) : undefined
    if (!u || !Array.isArray(e.ips)) continue
    const ips = e.ips.map(String).filter((x) => /^[0-9a-fA-F:.]{2,45}$/.test(x) && !/^127\.|^::1$/.test(x)).slice(0, 128)
    stmts.push(env.DB.prepare('INSERT INTO user_online (user_id, server_id, ips) VALUES (?, ?, ?)').bind(u.id, server.id, json(ips)))
  }
  await env.DB.batch(stmts)
  const { results: limited } = await env.DB.prepare(
    `SELECT id, name, device_limit FROM users WHERE device_limit > 0 AND (blocked_until IS NULL OR blocked_until <= datetime('now'))`)
    .all<Pick<UserRow, 'id' | 'name' | 'device_limit'>>()
  if (!limited.length) return false
  const { results: seen } = await env.DB.prepare(
    `SELECT user_id, ips FROM user_online WHERE at >= datetime('now', ?)`).bind(`-${DEVICE_WINDOW_MIN} minutes`).all<{ user_id: number; ips: string }>()
  let blocked = false
  for (const u of limited) {
    const ips = new Set(seen.filter((r) => r.user_id === u.id).flatMap((r) => JSON.parse(r.ips) as string[]))
    if (ips.size <= u.device_limit) continue
    await env.DB.prepare(`UPDATE users SET blocked_until = datetime('now', ?), blocked_reason = ? WHERE id = ?`)
      .bind(`+${DEVICE_BLOCK_MIN} minutes`, `同时在线 ${ips.size} 个 IP，上限 ${u.device_limit}`, u.id).run()
    await deps.audit(env, 'user.devices', u.name, `同时在线 ${ips.size} 个 IP（上限 ${u.device_limit}），暂停 ${DEVICE_BLOCK_MIN} 分钟`, 'panel')
    blocked = true
  }
  return blocked
}

const EVENT_LABELS: Record<string, string> = {
  'local.login': '登录了本机页面', 'core.restart': '在本机页面重启了内核', 'node.changed': '在本机页面修改了节点',
  'user.disable_here': '在本机页面暂停了用户', 'user.enable_here': '在本机页面解除了用户的本机暂停',
}

/**
 * What was done on a server's local page: into the audit log; a node changed
 * there is read back. Returns the ids recorded (psm-agent keeps the others and
 * sends them again).
 */
async function applyEvents(env: Env, deps: Deps, server: ServerRowLite, events: AgentEvent[]): Promise<string[]> {
  const acked: string[] = []
  for (const e of events) {
    const id = typeof e.id === 'string' && /^[0-9a-f]{1,32}$/.test(e.id) ? e.id : null
    const kind = typeof e.kind === 'string' ? e.kind.slice(0, 40) : ''
    // Claimed in the ledger first: one seen before (an answer that was lost) is
    // acknowledged again and done nothing twice. One whose effects fail lets go
    // of its claim and is done again when sent again (the effects are
    // idempotent: a node update, a pause bit, an audit line).
    if (id) {
      // done before: acknowledged again; under way elsewhere (claimed within
      // the last few minutes): left for that one; claimed long ago and never
      // finished (an interrupted Worker): taken over and done again
      const claim = await env.DB.prepare(`INSERT INTO agent_events (server_id, event_id) VALUES (?, ?)
          ON CONFLICT(server_id, event_id) DO UPDATE SET at = datetime('now') WHERE done = 0 AND at < datetime('now', '-5 minutes')`)
        .bind(server.id, id).run()
      if (!claim.meta.changes) {
        const row = await env.DB.prepare('SELECT done FROM agent_events WHERE server_id = ? AND event_id = ?').bind(server.id, id).first<{ done: number }>()
        if (row?.done) acked.push(id)
        continue
      }
    }
    try {
      if (EVENT_LABELS[kind]) {
        const target = typeof e.target === 'string' ? e.target.slice(0, 64) : ''
        await deps.audit(env, `local.${kind}`, `${server.name}${target ? ' / ' + target : ''}`, EVENT_LABELS[kind], `local:${server.name}`)
        if (kind === 'local.login' || kind === 'user.disable_here') await notify(env, `🔐 ${server.name}：${EVENT_LABELS[kind]}${target ? ` ${target}` : ''}`)
        if (kind === 'node.changed') await nodeChanged(env, deps, server, e.detail)
        // a pause made on the local page counts at once (not at the next usage report)
        if ((kind === 'user.disable_here' || kind === 'user.enable_here') && target) {
          await env.DB.prepare(`UPDATE user_servers SET local_paused = ? WHERE server_id = ? AND user_id = (SELECT id FROM users WHERE name = ?)`)
            .bind(kind === 'user.disable_here' ? 1 : 0, server.id, target).run()
        }
      }
      if (id) {
        await env.DB.prepare('UPDATE agent_events SET done = 1 WHERE server_id = ? AND event_id = ?').bind(server.id, id).run()
        acked.push(id)
      }
    } catch (err) {
      console.error(`event ${kind} from ${server.name}`, err)
      if (id) await env.DB.prepare('DELETE FROM agent_events WHERE server_id = ? AND event_id = ?').bind(server.id, id).run().catch(() => undefined)
    }
  }
  return acked
}

async function nodeChanged(env: Env, deps: Deps, server: ServerRowLite, detail: unknown) {
  const d = detail as { core?: unknown; protocol?: unknown; tag?: unknown; changes?: { port?: unknown; display_name?: unknown } } | undefined
  const tag = typeof d?.tag === 'string' ? d.tag : ''
  const core = typeof d?.core === 'string' ? d.core : ''
  const protocol = typeof d?.protocol === 'string' ? d.protocol : ''
  // the node itself, not another core's node of the same name on that server
  // (and only the panel's own: an edit of a node made by hand there is not the panel's to follow)
  const n = await env.DB.prepare('SELECT id, port, public_port FROM nodes WHERE server_id = ? AND name = ? AND engine = ? AND psm_protocol = ? AND owned = 1').bind(server.id, tag, core, protocol)
    .first<{ id: number; port: number; public_port: number | null }>()
  if (!n) return
  const port = typeof d?.changes?.port === 'number' && Number.isInteger(d.changes.port) && d.changes.port >= 1 && d.changes.port <= 65535 ? d.changes.port : null
  const dn = typeof d?.changes?.display_name === 'string' ? d.changes.display_name.slice(0, 64) : null
  // a public port that followed the listener follows it again (PSM does the same)
  await env.DB.prepare(`UPDATE nodes SET port = COALESCE(?, port),
      public_port = CASE WHEN ? IS NOT NULL AND (public_port IS NULL OR public_port = port) THEN NULL ELSE public_port END,
      display_name = COALESCE(?, display_name) WHERE id = ?`).bind(port, port, dn, n.id).run()
  // metering and links brought to where the node is now (idempotent: safe to do again)
  await deps.nodePortChanged(env, n.id)
}

// ── DNS: a server's host name on its address ─────────────────────────────────

const CF_API = 'https://api.cloudflare.com/client/v4'

async function cf<T>(env: Env, path: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch((env.CF_API_BASE || CF_API) + path, { ...init, headers: { Authorization: `Bearer ${env.CF_DNS_TOKEN}`, 'Content-Type': 'application/json' } })
  const data = await res.json<{ success?: boolean; errors?: { message?: string }[]; result?: T }>().catch(() => ({} as { success?: boolean; errors?: { message?: string }[]; result?: T }))
  if (!res.ok || !data.success) throw new Error(data.errors?.map((e) => e.message).join('; ') || `Cloudflare API ${res.status}`)
  return data.result as T
}

/**
 * Points the server's host name (an A record, DNS only) at its IPv4 address.
 * The zone: CF_ZONE_ID, or found by name (the token then also needs Zone ·
 * Zone · Read).
 */
export async function updateDns(env: Env, deps: Deps, server: Pick<ServerRowLite, 'id' | 'name' | 'dns_name'>, ip: string) {
  const name = server.dns_name!
  const done = (err: string | null, okIp: string | null) => env.DB.prepare(
    `UPDATE servers SET dns_ip = COALESCE(?, dns_ip), dns_at = datetime('now'), dns_error = ? WHERE id = ?`).bind(okIp, err, server.id).run()
  if (!env.CF_DNS_TOKEN) {
    await done('没有设置 CF_DNS_TOKEN（Worker 密钥：Cloudflare API 令牌，权限「区域 · DNS · 编辑」）', null)
    return
  }
  try {
    let zone: string | null = env.CF_ZONE_ID || null
    const labels = name.split('.')
    for (let i = 0; i < labels.length - 1 && !zone; i++) {
      const found = await cf<{ id: string }[]>(env, `/zones?name=${encodeURIComponent(labels.slice(i).join('.'))}`)
      zone = found[0]?.id ?? null
    }
    if (!zone) throw new Error(`${name} 不在这个令牌能管理的任何 Cloudflare 域名下（或令牌没有「区域 · 区域 · 读取」：可以改设 CF_ZONE_ID）`)
    const recs = await cf<{ id: string; content: string; proxied: boolean }[]>(env, `/zones/${zone}/dns_records?type=A&name=${encodeURIComponent(name)}`)
    const rec = { type: 'A', name, content: ip, ttl: 60, proxied: false, comment: 'roomkey: follows the server address' }
    if (recs[0]) await cf(env, `/zones/${zone}/dns_records/${recs[0].id}`, { method: 'PATCH', body: json(rec) })
    else await cf(env, `/zones/${zone}/dns_records`, { method: 'POST', body: json(rec) })
    await done(null, ip)
    await deps.audit(env, 'server.dns', server.name, `${name} → ${ip}`, 'panel')
  } catch (e) {
    await done(String((e as Error).message ?? e).slice(0, 300), null)
  }
}

// ── Telegram ─────────────────────────────────────────────────────────────────

async function setting(env: Env, key: string): Promise<string | null> {
  return (await env.DB.prepare('SELECT value FROM settings WHERE key = ?').bind(key).first<{ value: string }>())?.value ?? null
}

/** Sends a message to the admin's Telegram chat. 'off': none set up. Never throws. */
export async function notify(env: Env, text: string): Promise<'sent' | 'off' | 'failed'> {
  try {
    const tokenEnc = await setting(env, 'telegram_token_enc'), chat = await setting(env, 'telegram_chat')
    if (!tokenEnc || !chat) return 'off'
    const token = await decrypt(env.TOKEN_KEY, tokenEnc)
    const res = await fetch(`${env.TELEGRAM_API_BASE || 'https://api.telegram.org'}/bot${token}/sendMessage`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: json({ chat_id: chat, text: `roomkey · ${text}`, disable_web_page_preview: true }),
    })
    return res.ok ? 'sent' : 'failed'
  } catch (e) {
    console.error('telegram', e)
    return 'failed'
  }
}

// ── the cron: every five minutes ─────────────────────────────────────────────

export async function cron(env: Env, deps: Deps) {
  await rollPeriods(env)
  // device pauses that ran out
  await env.DB.prepare(`UPDATE users SET blocked_until = NULL, blocked_reason = NULL WHERE blocked_until IS NOT NULL AND blocked_until <= datetime('now')`).run()
  await reconcileUsers(env, deps)
  // alerts: recorded as sent only once Telegram took them (or there is none to send to)
  const { results: users } = await env.DB.prepare('SELECT * FROM users').all<UserRow>()
  const now = Date.now()
  for (const u of users) {
    const st = userState(u, now)
    if (st === u.alerted_state) continue
    const res = st !== 'active' && st !== 'disabled' ? await notify(env, `⏸ 用户 ${u.name}：${STATE_LABELS[st]}`)
      : st === 'active' && u.alerted_state !== 'disabled' ? await notify(env, `▶️ 用户 ${u.name} 恢复正常`) : 'off'
    if (res !== 'failed') await env.DB.prepare('UPDATE users SET alerted_state = ? WHERE id = ?').bind(st, u.id).run()
  }
  const quiet = Math.max(deps.syncInterval(env) * 3, OFFLINE_ALERT_MIN * 60)
  const { results: gone } = await env.DB.prepare(
    `SELECT id, name FROM servers WHERE agent_token_hash IS NOT NULL AND leaving = 0 AND alert_offline = 0 AND last_seen < datetime('now', ?)`)
    .bind(`-${quiet} seconds`).all<{ id: number; name: string }>()
  for (const s of gone) {
    if ((await notify(env, `⚠️ 服务器 ${s.name} 已离线超过 ${Math.round(quiet / 60)} 分钟`)) !== 'failed')
      await env.DB.prepare('UPDATE servers SET alert_offline = 1 WHERE id = ?').bind(s.id).run()
  }
  await env.DB.batch([
    env.DB.prepare(`DELETE FROM user_online WHERE at < datetime('now', '-1 day')`),
    env.DB.prepare(`DELETE FROM user_traffic_daily WHERE day < date('now', '-90 days')`),
    env.DB.prepare(`DELETE FROM agent_events WHERE at < datetime('now', '-30 days')`),
  ])
}

// ── the users' subscriptions ─────────────────────────────────────────────────

const PLACEHOLDER = (label: string): SubNode => ({
  server: 'roomkey', name: 'notice', display_name: label,
  link: `trojan://paused@127.0.0.1:1?security=tls&sni=localhost#${encodeURIComponent(label)}`,
  outbound: { type: 'trojan', server: '127.0.0.1', server_port: 1, password: 'paused', tls: { enabled: true, server_name: 'localhost', insecure: true } },
  clash: { type: 'trojan', server: '127.0.0.1', port: 1, password: 'paused', sni: 'localhost', 'skip-cert-verify': true },
})

/** A user's own subscription, or null when the token is not a user's. */
export async function userSubscription(c: C, deps: Deps, token: string): Promise<Response | null> {
  const env = c.env
  const u0 = await env.DB.prepare('SELECT id FROM users WHERE sub_token_hash = ?').bind(await deps.sha256Hex(token)).first<{ id: number }>()
  if (!u0) return null
  await rollPeriods(env)
  const u = (await env.DB.prepare('SELECT * FROM users WHERE id = ?').bind(u0.id).first<UserRow>())!
  const now = Date.now()
  const state = userState(u, now)
  const access = (await loadAccess(env, u.id)).get(u.id) ?? []
  const perServer = await loadUserServers(env)
  const { results: rows } = await env.DB.prepare(
    `SELECT n.id, n.server_id, n.name, n.display_name, n.labels, n.psm_protocol, n.engine, n.status, n.link_enc, n.outbound_enc, n.clash_enc,
            s.name AS server, s.country, s.agent_version
       FROM nodes n JOIN servers s ON s.id = n.server_id
      WHERE n.status = 'applied' AND n.traffic_paused = 0 AND n.engine != 'standalone' ORDER BY s.id, n.id`)
    .all<NodeLite & { display_name: string; link_enc: string | null; outbound_enc: string | null; clash_enc: string | null; server: string; country: string | null; agent_version: string | null }>()
  // A node only once its server took this user's current credentials for that
  // very node, from a psm-agent that can (not one downgraded since), and the
  // server's local page has not paused the user there.
  const mine = userNodes(access, rows.map((r) => ({ ...r, labels: JSON.parse(r.labels) as string[] })),
    { needsMetering: needsMetering(u, serverQuotas(u.id, perServer)), unmetered: !!u.unmetered })
    .filter((n) => {
      const us = perServer.get(`${u.id}:${n.server_id}`)
      const nodes = us?.synced_nodes ? JSON.parse(us.synced_nodes) as string[] : []
      return us?.synced_cred_rev === u.cred_rev && us.synced_enabled === 1 && nodes.includes(n.name) && !us.local_paused &&
        deps.versionAtLeast(n.agent_version, USERS_AGENT) && activeOn(state, us)
    })
  const cred = { uuid: await decrypt(env.TOKEN_KEY, u.uuid_enc), password: await decrypt(env.TOKEN_KEY, u.password_enc) }
  const nodes: SubNode[] = []
  if (state !== 'active') {
    // the client shows only this line: what happened, and whether it lifts by itself
    nodes.push(PLACEHOLDER(`⛔ ${STATE_LABELS[state]}：${state === 'devices' ? '约 15 分钟后自动恢复' : state === 'over_quota' ? '重置后自动恢复' : '请联系管理员'}`))
  } else {
    for (const n of mine) {
      const link = n.link_enc ? linkFor(await decrypt(env.TOKEN_KEY, n.link_enc), cred) : null
      if (!link) continue
      const own: SubNode = {
        server: n.server, name: n.name, country: n.country, display_name: n.display_name, link,
        outbound: proxyFor(n.outbound_enc ? JSON.parse(await decrypt(env.TOKEN_KEY, n.outbound_enc)) : null, cred),
        clash: proxyFor(n.clash_enc ? JSON.parse(await decrypt(env.TOKEN_KEY, n.clash_enc)) : null, cred),
      }
      nodes.push(own)
    }
    if (!nodes.length) nodes.push(PLACEHOLDER('⏳ 节点准备中：过几分钟再更新订阅'))
  }
  await env.DB.prepare(`UPDATE users SET last_sub_at = datetime('now') WHERE id = ?`).bind(u.id).run()
  const url = new URL(c.req.url)
  const selfUrl = `${await deps.panelUrl(c)}/sub/${token}`
  const ua = c.req.header('User-Agent') ?? ''
  // a person opening the link in a browser gets their page, not a file
  if (!url.searchParams.get('format') && /mozilla/i.test(ua) && /text\/html/.test(c.req.header('Accept') ?? '') &&
      !/clash|mihomo|verge|shadowrocket|sing-box|stash|surge|quantumult|loon|v2ray|hiddify|nekobox|throne/i.test(ua)) {
    const { results: limits } = await env.DB.prepare(
      `SELECT s.name, us.quota_bytes, us.used_bytes FROM user_servers us JOIN servers s ON s.id = us.server_id
        WHERE us.user_id = ? AND us.quota_bytes IS NOT NULL ORDER BY s.id`).bind(u.id).all<{ name: string; quota_bytes: number; used_bytes: number }>()
    return selfPage(c, u, state, selfUrl, mine.map((n) => n.display_name || `${n.server}-${n.name}`), limits)
  }
  const format = pickFormat(url.searchParams.get('format'), ua)
  const out = buildSubscription(format, nodes, selfUrl, { name: u.name })
  return c.body(out.body, 200, {
    'Content-Type': out.type,
    'Content-Disposition': `attachment; filename*=UTF-8''${encodeURIComponent(u.name)}.${out.ext}`,
    // hours between client updates: a moved node or new key reaches people within a few hours
    'Profile-Update-Interval': '3',
    'Subscription-Userinfo': userinfoHeader(u.used_total_bytes, u.quota_total_bytes, u.expires_at),
    'Cache-Control': 'no-store',
  })
}

const esc = (s: string) => s.replace(/[&<>"']/g, (ch) => `&#${ch.charCodeAt(0)};`)
function fmtBytes(n: number): string {
  if (!n) return '0'
  const u = ['B', 'KB', 'MB', 'GB', 'TB']
  let i = 0
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++ }
  return `${n.toFixed(i >= 3 ? 2 : i ? 1 : 0)} ${u[i]}`
}

/** The page a user sees when they open their link in a browser: their state, usage, expiry and one-tap imports. */
function selfPage(c: C, u: UserRow, state: UserState, url: string, nodeNames: string[],
  limits: { name: string; quota_bytes: number; used_bytes: number }[]): Response {
  // WeChat's own browser will not open other apps: the import buttons would do nothing there
  const wechat = /MicroMessenger/i.test(c.req.header('User-Agent') ?? '')
  const quota = u.quota_total_bytes
  const pct = quota ? Math.min(100, Math.round((u.used_total_bytes / quota) * 100)) : 0
  const exp = sqlTime(u.expires_at)
  const end = periodEnd(u.period_start, u.reset_period)
  const b64 = btoa(url)
  const name = encodeURIComponent(u.name)
  const enc = encodeURIComponent(url)
  const imports: [string, string, string][] = [
    ['Shadowrocket', `shadowrocket://add/sub://${b64}?remark=${name}`, 'iPhone / iPad'],
    ['Clash Verge', `clash://install-config?url=${enc}&name=${name}`, 'Windows / macOS'],
    ['sing-box', `sing-box://import-remote-profile?url=${enc}#${name}`, 'sing-box 客户端'],
  ]
  const nonce = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(12))))
  const ok = state === 'active'
  // what a pause means for the friend reading it, and when it lifts
  const blockedUntil = sqlTime(u.blocked_until)
  const bj = (t: number) => new Date(t + 8 * 3600_000).toISOString().slice(0, 16).replace('T', ' ')
  const why = state === 'devices'
    ? `同时在线的设备超过了 ${u.device_limit} 台，暂时停用${blockedUntil ? `，${esc(bj(blockedUntil).slice(11))}（北京时间）左右自动恢复` : '，约 15 分钟后自动恢复'}。请关掉多余的设备（换网络也算一台新设备）。`
    : state === 'over_quota' ? `本周期的流量用完了${end ? `，${esc(end)} 重置后自动恢复` : ''}；急用请联系管理员。`
    : state === 'expired' ? '订阅已到期，续期请联系管理员。'
    : state === 'disabled' ? '这个订阅被管理员停用了，有问题请联系管理员。'
    : limits.some((l) => l.used_bytes >= l.quota_bytes) ? '有服务器的流量用完了，那台暂时用不了，其他服务器照常。'
    : ''
  const usageText = quota
    ? `<div class="bar"><i></i></div><div class="muted">已用 ${fmtBytes(u.used_total_bytes)} / ${fmtBytes(quota)}${end ? `，${end} 重置` : ''}</div>`
    : limits.length ? `<p class="muted">本周期共用了 ${fmtBytes(u.used_total_bytes)}；下面的服务器各有上限${end ? `，${end} 重置` : ''}</p>`
      : `<p class="muted">本周期已用 ${fmtBytes(u.used_total_bytes)}，不限流量</p>`
  const perServer = limits.map((l) => `<div class="row"><span>${esc(l.name)}</span><span>${fmtBytes(l.used_bytes)} / ${fmtBytes(l.quota_bytes)}${
    l.used_bytes >= l.quota_bytes ? '（已用完）' : ''}</span></div>`).join('')
  const html = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>${esc(u.name)} 的订阅</title>
<style nonce="${nonce}">
:root{--bg:#f6f7f9;--card:#fff;--text:#1b1f24;--muted:#6b7280;--line:#e5e7eb;--accent:#2f6fed;--ok:#1f8b4c;--bad:#c2410c;color-scheme:light dark;font-family:system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif}
@media (prefers-color-scheme:dark){:root{--bg:#111317;--card:#1a1d23;--text:#e6e8eb;--muted:#9aa1ab;--line:#2a2e36;--accent:#5b8cff;--ok:#4ade80;--bad:#fb923c}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);line-height:1.55}
main{max-width:560px;margin:0 auto;padding:28px 16px 48px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px 20px;margin-bottom:14px}
.card.warn{border-color:var(--bad)}li{margin:4px 0}
h1{font-size:20px;margin:0 0 4px}.muted{color:var(--muted);font-size:13px}
.state{display:inline-block;padding:2px 10px;border-radius:999px;font-size:13px;background:${ok ? 'color-mix(in srgb,var(--ok) 14%,transparent)' : 'color-mix(in srgb,var(--bad) 14%,transparent)'};color:${ok ? 'var(--ok)' : 'var(--bad)'}}
.bar{height:8px;background:var(--line);border-radius:999px;overflow:hidden;margin:10px 0 6px}.bar>i{display:block;height:100%;background:${pct >= 90 ? 'var(--bad)' : 'var(--accent)'};width:${pct}%}
.row{display:flex;justify-content:space-between;gap:12px;font-size:14px;padding:6px 0;border-bottom:1px solid var(--line)}.row:last-child{border:0}
a.btn{display:flex;justify-content:space-between;align-items:center;text-decoration:none;color:var(--text);border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin-top:8px}
a.btn:hover{border-color:var(--accent)}a.btn b{color:var(--accent);font-weight:600}
button{font:inherit;width:100%;margin-top:10px;padding:10px;border-radius:10px;border:1px solid var(--accent);background:transparent;color:var(--accent);cursor:pointer}
ul{margin:6px 0 0;padding-left:18px;font-size:14px}
</style></head><body><main>
${wechat ? `<div class="card warn"><strong>请在浏览器中打开</strong><p class="muted">微信里点「导入」不会有反应：点右上角「⋯」，选「在浏览器打开」（iPhone 选「在 Safari 中打开」）。</p></div>` : ''}
<div class="card"><h1>${esc(u.name)}</h1><span class="state">${esc(STATE_LABELS[state])}</span>
${why ? `<p class="muted">${why}</p>` : ''}
${usageText}${perServer ? `<div style="margin-top:8px">${perServer}</div>` : ''}
</div>
<div class="card">
<div class="row"><span>到期时间</span><span>${exp ? `${new Date(exp + 8 * 3600_000).toISOString().slice(0, 16).replace('T', ' ')}（北京时间）` : u.first_use_days && !u.expires_at ? `首次使用后 ${u.first_use_days} 天` : '长期有效'}</span></div>
<div class="row"><span>可用节点</span><span>${nodeNames.length}</span></div>
${u.device_limit ? `<div class="row"><span>同时在线设备</span><span>最多 ${u.device_limit} 台</span></div>` : ''}
</div>
<div class="card"><strong>一键导入</strong>
${imports.map(([n, href, sub]) => `<a class="btn" href="${esc(href)}"><span>${n}<br><span class="muted">${sub}</span></span><b>导入 →</b></a>`).join('')}
<button id="copy" type="button">复制订阅链接（Throne 等其他客户端）</button>
<p class="muted">这个链接就是你的钥匙，不要分享给别人。</p></div>
${nodeNames.length ? `<div class="card"><strong>节点</strong><ul>${nodeNames.map((n) => `<li>${esc(n)}</li>`).join('')}</ul></div>` : ''}
<div class="card"><strong>使用说明</strong><ul>
<li>iPhone / iPad：在 App Store 用<strong>非中国区</strong>的 Apple ID 下载 Shadowrocket，然后点上面的「导入」。</li>
<li>电脑：Windows / macOS 装 Clash Verge Rev 或 Throne；Throne 在「订阅」里粘贴复制的链接。</li>
<li>连不上时，先在客户端里<strong>更新订阅</strong>；还不行再联系管理员。</li>
<li>订阅每 3 小时自动更新一次；不要把这个链接发给别人。</li>
</ul></div>
</main><script nonce="${nonce}">
document.getElementById('copy').addEventListener('click',async function(){try{await navigator.clipboard.writeText(${JSON.stringify(url)});this.textContent='已复制'}catch(e){prompt('复制这个链接',${JSON.stringify(url)})}})
</script></body></html>`
  return c.body(html, 200, {
    'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'X-Frame-Options': 'DENY', 'Referrer-Policy': 'no-referrer',
    'Content-Security-Policy': `default-src 'none'; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
  })
}

// ── the admin API ────────────────────────────────────────────────────────────

type UserInput = {
  name?: unknown; note?: unknown; enabled?: unknown; expires_at?: unknown; first_use_days?: unknown
  quota_total_gb?: unknown; reset_period?: unknown; reset_day?: unknown; device_limit?: unknown; unmetered?: unknown
  access?: unknown; servers?: unknown
}

type CleanUser = {
  name: string; note: string; enabled: number; expires_at: string | null; first_use_days: number | null
  quota_total_bytes: number | null; reset_period: string; reset_day: number; device_limit: number; unmetered: number
  access: Access[]; servers: { server_id: number; quota_bytes: number | null }[]
}

/** A user as entered, checked; `old`: the stored user an edit starts from. */
function cleanUser(b: UserInput, old?: CleanUser): { user?: CleanUser; errors: string[] } {
  const errors: string[] = []
  const pick = <K extends keyof CleanUser>(k: K, v: unknown, f: (v: unknown) => CleanUser[K] | undefined, msg: string): CleanUser[K] => {
    if (v === undefined && old) return old[k]
    const out = f(v)
    if (out === undefined) { errors.push(msg); return (old?.[k] ?? null) as CleanUser[K] }
    return out
  }
  const num = (v: unknown) => (v === '' || v === null || v === undefined ? null : Number(v))
  // a field left out keeps its stored value (an edit) or takes its default (a new user); null clears it
  const given = (k: keyof UserInput, def: unknown) => (k in b ? b[k] : old ? undefined : def)
  const name = pick('name', b.name, (v) => (typeof v === 'string' && USER_NAME_RE.test(v.trim()) ? v.trim() : undefined),
    '用户名：小写字母、数字、- 和 _，最多 32 位，以字母或数字开头')
  const note = pick('note', given('note', ''), (v) => (typeof v === 'string' ? v.slice(0, 500) : undefined), '备注：要是文字')
  const enabled = pick('enabled', given('enabled', true), (v) => (typeof v === 'boolean' ? (v ? 1 : 0) : undefined), '启用：是或否')
  const expires_at = pick('expires_at', given('expires_at', null), (v) => {
    if (v === null || v === '') return null
    if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}(:\d{2})?)?$/.test(v)) return undefined
    // a date is the end of that day in Beijing time
    return localToSql(v.length === 10 ? `${v} 23:59:59` : v.length === 16 ? `${v}:00` : v) ?? undefined
  }, '到期时间：YYYY-MM-DD')
  const first_use_days = pick('first_use_days', given('first_use_days', null), (v) => {
    const n = num(v)
    return n === null ? null : Number.isInteger(n) && n >= 1 && n <= 3650 ? n : undefined
  }, '首次使用后天数：1-3650')
  const quota_total_bytes = pick('quota_total_bytes', given('quota_total_gb', null), (v) => {
    const n = num(v)
    return n === null || n === 0 ? null : Number.isFinite(n) && n > 0 && n <= 1_000_000 ? Math.max(1, Math.round(n * GB)) : undefined
  }, '总流量：0-1000000 GB（0 或留空不限）')
  const reset_period = pick('reset_period', given('reset_period', 'monthly'),
    (v) => (typeof v === 'string' && (PERIODS as string[]).includes(v) ? v : undefined), '重置周期：每天、每周、每月或不重置')
  const reset_day = pick('reset_day', given('reset_day', 1), (v) => {
    const n = num(v)
    return n !== null && Number.isInteger(n) && n >= 1 && n <= 28 ? n : undefined
  }, '重置日：每周 1-7（周一为 1），每月 1-28')
  if (reset_period === 'weekly' && reset_day > 7) errors.push('重置日：每周重置时填 1-7（周一为 1）')
  const device_limit = pick('device_limit', given('device_limit', 0), (v) => {
    const n = num(v) ?? 0
    return Number.isInteger(n) && n >= 0 && n <= 100 ? n : undefined
  }, '设备数：0-100（0 不限）')
  const unmetered = pick('unmetered', given('unmetered', false), (v) => (typeof v === 'boolean' ? (v ? 1 : 0) : undefined), '不计量节点：是或否')
  const access = pick('access', given('access', [{ kind: 'all', value: '' }]), (v) => {
    if (!Array.isArray(v) || v.length > 100) return undefined
    const out: Access[] = []
    for (const a of v as { kind?: unknown; value?: unknown }[]) {
      if (a?.kind === 'all') out.push({ kind: 'all', value: '' })
      else if (a?.kind === 'label' && typeof a.value === 'string' && a.value.trim()) out.push({ kind: 'label', value: a.value.trim().slice(0, 24) })
      else if (a?.kind === 'node' && /^[1-9]\d{0,15}$/.test(String(a.value ?? ''))) out.push({ kind: 'node', value: String(a.value) })
      else return undefined
    }
    return out.filter((a, i) => out.findIndex((x) => x.kind === a.kind && x.value === a.value) === i)
  }, '可用节点：全部、按标签或指定节点')
  const servers = pick('servers', given('servers', []), (v) => {
    if (!Array.isArray(v) || v.length > 200) return undefined
    const out: CleanUser['servers'] = []
    for (const s of v as { server_id?: unknown; quota_gb?: unknown }[]) {
      const id = Number(s?.server_id), q = num(s?.quota_gb)
      if (!Number.isInteger(id) || id < 1) return undefined
      if (q !== null && !(Number.isFinite(q) && q >= 0 && q <= 1_000_000)) return undefined
      out.push({ server_id: id, quota_bytes: q ? Math.max(1, Math.round(q * GB)) : null })
    }
    return out
  }, '单台服务器流量：0-1000000 GB')
  if (!access.length && !errors.length) errors.push('可用节点：至少选一个标签或节点')
  return errors.length ? { errors } : {
    errors, user: { name, note, enabled, expires_at, first_use_days, quota_total_bytes, reset_period, reset_day, device_limit, unmetered, access, servers },
  }
}

/** The servers a user's per-server quotas name that do not exist (any more). */
async function missingServers(env: Env, u: CleanUser): Promise<number[]> {
  const ids = [...new Set(u.servers.filter((s) => s.quota_bytes).map((s) => s.server_id))]
  if (!ids.length) return []
  const { results } = await env.DB.prepare(`SELECT id FROM servers WHERE id IN (SELECT value FROM json_each(?))`).bind(json(ids)).all<{ id: number }>()
  const have = new Set(results.map((r) => r.id))
  return ids.filter((id) => !have.has(id))
}

async function storedUser(env: Env, u: UserRow): Promise<CleanUser> {
  const access = (await loadAccess(env, u.id)).get(u.id) ?? []
  const { results } = await env.DB.prepare('SELECT server_id, quota_bytes FROM user_servers WHERE user_id = ? AND quota_bytes IS NOT NULL').bind(u.id).all<{ server_id: number; quota_bytes: number }>()
  return {
    name: u.name, note: u.note, enabled: u.enabled, expires_at: u.expires_at, first_use_days: u.first_use_days,
    quota_total_bytes: u.quota_total_bytes, reset_period: u.reset_period, reset_day: u.reset_day, device_limit: u.device_limit,
    unmetered: u.unmetered, access, servers: results,
  }
}

/** The statements that store a user's access list and per-server quotas; `idSql` finds the user's id. */
function accessStmts(env: Env, idSql: { sql: string; arg: number | string }, u: CleanUser): D1PreparedStatement[] {
  return [
    env.DB.prepare(`DELETE FROM user_access WHERE user_id = ${idSql.sql}`).bind(idSql.arg),
    ...u.access.map((a) => env.DB.prepare(`INSERT INTO user_access (user_id, kind, value) VALUES (${idSql.sql}, ?, ?)`).bind(idSql.arg, a.kind, a.value)),
    env.DB.prepare(`UPDATE user_servers SET quota_bytes = NULL WHERE user_id = ${idSql.sql}`).bind(idSql.arg),
    ...u.servers.filter((s) => s.quota_bytes).map((s) => env.DB.prepare(
      `INSERT INTO user_servers (user_id, server_id, quota_bytes) VALUES (${idSql.sql}, ?, ?)
         ON CONFLICT(user_id, server_id) DO UPDATE SET quota_bytes = excluded.quota_bytes`).bind(idSql.arg, s.server_id, s.quota_bytes)),
  ]
}

/**
 * The users as the page shows them, in four queries whatever their number
 * (D1's free plan allows 50 per request).
 */
async function userViews(c: C, deps: Deps, users: UserRow[], detail = false) {
  const env = c.env
  const now = Date.now()
  const [accessRows, perRows, onRows, nodeRows, serverRows] = await env.DB.batch([
    env.DB.prepare('SELECT user_id, kind, value FROM user_access'),
    env.DB.prepare(`SELECT us.user_id, us.server_id, s.name, us.quota_bytes, us.used_bytes, us.synced_cred_rev, us.synced_nodes, us.local_paused
                      FROM user_servers us JOIN servers s ON s.id = us.server_id ORDER BY s.id`),
    env.DB.prepare(`SELECT o.user_id, s.name, o.ips FROM user_online o JOIN servers s ON s.id = o.server_id WHERE o.at >= datetime('now', ?)`)
      .bind(`-${DEVICE_WINDOW_MIN} minutes`),
    env.DB.prepare(`SELECT id, server_id, name, labels, psm_protocol, engine, status FROM nodes WHERE engine != 'standalone' AND status = 'applied'`),
    env.DB.prepare('SELECT id, name FROM servers ORDER BY id'),
  ])
  const liveNodeList = (nodeRows.results as NodeLite[]).map((n) => ({ ...n, labels: JSON.parse(n.labels) as string[] }))
  const serverName = new Map((serverRows.results as { id: number; name: string }[]).map((s) => [s.id, s.name]))
  const by = <T extends { user_id: number }>(rows: T[]) => {
    const m = new Map<number, T[]>()
    for (const r of rows) m.set(r.user_id, [...(m.get(r.user_id) ?? []), r])
    return m
  }
  const access = by(accessRows.results as { user_id: number; kind: Access['kind']; value: string }[])
  const per = by(perRows.results as { user_id: number; server_id: number; name: string; quota_bytes: number | null; used_bytes: number
    synced_cred_rev: number | null; synced_nodes: string | null; local_paused: number }[])
  const online = by(onRows.results as { user_id: number; name: string; ips: string }[])
  const out = []
  for (const u of users) {
    const state = userState(u, now)
    const on = online.get(u.id) ?? []
    const ips = [...new Set(on.flatMap((r) => JSON.parse(r.ips) as string[]))]
    // every server the user should be on (by their nodes), and every one with use or a limit; each says whether it has them
    const rowsOf = new Map((per.get(u.id) ?? []).map((s) => [s.server_id, s]))
    const wanted = new Map<number, string[]>()
    const quotasOn = (per.get(u.id) ?? []).some((s) => !!s.quota_bytes)
    for (const n of userNodes((access.get(u.id) ?? []) as Access[], liveNodeList, { needsMetering: needsMetering(u, quotasOn), unmetered: !!u.unmetered }))
      wanted.set(n.server_id, [...(wanted.get(n.server_id) ?? []), n.name])
    const ids = [...new Set([...wanted.keys(), ...[...rowsOf.values()].filter((s) => s.quota_bytes || s.used_bytes).map((s) => s.server_id)])].sort((a, b) => a - b)
    const servers = ids.map((sid) => {
      const s = rowsOf.get(sid)
      const want = wanted.get(sid) ?? []
      const have = s?.synced_nodes && s.synced_cred_rev === u.cred_rev ? JSON.parse(s.synced_nodes) as string[] : []
      return { server_id: sid, name: serverName.get(sid) ?? `#${sid}`, quota_bytes: s?.quota_bytes ?? null, used_bytes: s?.used_bytes ?? 0,
        nodes: want.length, synced: want.length > 0 && want.every((n) => have.includes(n)), paused_here: !!s?.local_paused }
    })
    const base = {
      id: u.id, name: u.name, note: u.note, enabled: !!u.enabled, state, state_label: STATE_LABELS[state],
      expires_at: u.expires_at, first_use_days: u.first_use_days, first_used_at: u.first_used_at,
      quota_total_bytes: u.quota_total_bytes, used_total_bytes: u.used_total_bytes,
      reset_period: u.reset_period, reset_day: u.reset_day, period_start: u.period_start, period_end: periodEnd(u.period_start, u.reset_period),
      device_limit: u.device_limit, unmetered: !!u.unmetered, blocked_until: u.blocked_until, blocked_reason: u.blocked_reason,
      last_sub_at: u.last_sub_at, created_at: u.created_at, access: (access.get(u.id) ?? []).map(({ kind, value }) => ({ kind, value })),
      servers, online: ips.length,
    }
    if (!detail) { out.push(base); continue }
    const { results: daily } = await env.DB.prepare(
      `SELECT day, SUM(bytes) AS bytes FROM user_traffic_daily WHERE user_id = ? AND day >= date('now', '-29 days') GROUP BY day ORDER BY day`)
      .bind(u.id).all<{ day: string; bytes: number }>()
    const token = await decrypt(env.TOKEN_KEY, u.sub_token_enc)
    out.push({ ...base, subscription: `${await deps.panelUrl(c)}/sub/${token}`, daily, online_ips: on.map((r) => ({ server: r.name, ips: JSON.parse(r.ips) })) })
  }
  return out
}
const userView = async (c: C, deps: Deps, u: UserRow) => (await userViews(c, deps, [u], true))[0]

const getUser = (env: Env, deps: Deps, id: unknown) => {
  const n = deps.idOf(id)
  return n === null ? Promise.resolve(null) : env.DB.prepare('SELECT * FROM users WHERE id = ?').bind(n).first<UserRow>()
}

function uuidV4(): string {
  const b = crypto.getRandomValues(new Uint8Array(16))
  b[6] = (b[6] & 0x0f) | 0x40
  b[8] = (b[8] & 0x3f) | 0x80
  const h = [...b].map((x) => x.toString(16).padStart(2, '0')).join('')
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}
function password24(): string {
  // 56 symbols: a byte below 224 (4 × 56) maps without bias; the rest are drawn again
  const abc = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
  let out = ''
  while (out.length < 24) for (const b of crypto.getRandomValues(new Uint8Array(32))) if (b < 224 && out.length < 24) out += abc[b % abc.length]
  return out
}

/** A SQL literal for the backup. */
function sqlLit(v: unknown): string {
  if (v === null || v === undefined) return 'NULL'
  if (typeof v === 'number') return Number.isFinite(v) ? String(v) : 'NULL'
  if (typeof v === 'boolean') return v ? '1' : '0'
  return `'${String(v).replace(/'/g, "''")}'`
}

export function registerRoutes(app: App, deps: Deps) {
  const { fail, audit } = deps
  const bad = (c: C, errors: string[]) => c.json(fail('invalid', errors.join('；'), { errors }), 400)

  app.get('/api/users', async (c) => {
    await rollPeriods(c.env)
    const { results } = await c.env.DB.prepare('SELECT * FROM users ORDER BY name').all<UserRow>()
    return c.json(await userViews(c, deps, results))
  })

  app.get('/api/users/:id', async (c) => {
    const u = await getUser(c.env, deps, c.req.param('id'))
    if (!u) return c.json(fail('not_found', 'no such user'), 404)
    return c.json(await userView(c, deps, u))
  })

  app.post('/api/users', async (c) => {
    const b = await c.req.json<UserInput>().catch(() => null)
    if (!b || typeof b !== 'object') return bad(c, ['请求体要是 JSON 对象'])
    const { user, errors } = cleanUser(b)
    if (!user) return bad(c, errors)
    if (await c.env.DB.prepare('SELECT 1 FROM users WHERE name = ?').bind(user.name).first()) return bad(c, [`用户名 ${user.name} 已经存在`])
    const gone = await missingServers(c.env, user)
    if (gone.length) return bad(c, ['单台服务器流量：有服务器已经不存在了，刷新页面再设'])
    const cred = { uuid: uuidV4(), password: password24() }
    if (!validCredentials(cred)) throw new Error('generated credentials do not validate')
    const token = deps.randomToken(24)
    const start = periodStart(new Date(), user.reset_period, user.reset_day)
    // the user, their access and their quotas in one transaction: all or nothing
    try {
      await c.env.DB.batch([
        c.env.DB.prepare(
          `INSERT INTO users (name, note, uuid_enc, password_enc, enabled, expires_at, first_use_days, quota_total_bytes, reset_period, reset_day,
                              period_start, device_limit, unmetered, sub_token_hash, sub_token_enc)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
          .bind(user.name, user.note, await encrypt(c.env.TOKEN_KEY, cred.uuid), await encrypt(c.env.TOKEN_KEY, cred.password), user.enabled,
            user.expires_at, user.first_use_days, user.quota_total_bytes, user.reset_period, user.reset_day, start, user.device_limit, user.unmetered,
            await deps.sha256Hex(token), await encrypt(c.env.TOKEN_KEY, token)),
        ...accessStmts(c.env, { sql: '(SELECT id FROM users WHERE name = ?)', arg: user.name }, user),
      ])
    } catch (e) {
      if (String(e).includes('UNIQUE')) return bad(c, [`用户名 ${user.name} 已经存在`])
      throw e
    }
    const created = (await c.env.DB.prepare('SELECT * FROM users WHERE name = ?').bind(user.name).first<UserRow>())!
    await audit(c.env, 'user.add', user.name)
    await reconcileUsers(c.env, deps)
    return c.json(await userView(c, deps, created), 201)
  })

  app.patch('/api/users/:id', async (c) => {
    const u = await getUser(c.env, deps, c.req.param('id'))
    if (!u) return c.json(fail('not_found', 'no such user'), 404)
    const b = await c.req.json<UserInput>().catch(() => null)
    if (!b || typeof b !== 'object') return bad(c, ['请求体要是 JSON 对象'])
    if (b.name !== undefined && b.name !== u.name) return bad(c, ['用户名不能改：删掉再建一个'])
    const { user, errors } = cleanUser(b, await storedUser(c.env, u))
    if (!user) return bad(c, errors)
    if ((await missingServers(c.env, user)).length) return bad(c, ['单台服务器流量：有服务器已经不存在了，刷新页面再设'])
    // a "from first use" term that already started keeps counting from that day
    const started = sqlTime(u.first_used_at)
    if (user.first_use_days && started !== null) user.expires_at = sqlAt(started + user.first_use_days * 86_400_000)
    // a new reset schedule starts a new period: usage from zero, here and on the servers
    const periodChanged = user.reset_period !== u.reset_period || user.reset_day !== u.reset_day
    const start = periodChanged ? periodStart(new Date(), user.reset_period, user.reset_day) : u.period_start
    await c.env.DB.batch([
      c.env.DB.prepare(`UPDATE users SET note = ?, enabled = ?, expires_at = ?, first_use_days = ?, quota_total_bytes = ?, reset_period = ?,
          reset_day = ?, period_start = ?, device_limit = ?, unmetered = ?,
          period_seq = CASE WHEN ? THEN 0 ELSE period_seq END, used_total_bytes = CASE WHEN ? THEN 0 ELSE used_total_bytes END,
          period_retired_bytes = CASE WHEN ? THEN 0 ELSE period_retired_bytes END,
          blocked_until = CASE WHEN ? = 0 THEN NULL ELSE blocked_until END WHERE id = ?`)
        .bind(user.note, user.enabled, user.expires_at, user.first_use_days, user.quota_total_bytes, user.reset_period, user.reset_day, start,
          user.device_limit, user.unmetered, periodChanged ? 1 : 0, periodChanged ? 1 : 0, periodChanged ? 1 : 0, user.device_limit, u.id),
      ...(periodChanged ? [c.env.DB.prepare('UPDATE user_servers SET used_bytes = 0, period_base = 0, used_epoch = NULL WHERE user_id = ?').bind(u.id)] : []),
      ...accessStmts(c.env, { sql: '?', arg: u.id }, user),
    ])
    await audit(c.env, 'user.update', u.name)
    await reconcileUsers(c.env, deps)
    return c.json(await userView(c, deps, (await getUser(c.env, deps, u.id))!))
  })

  app.delete('/api/users/:id', async (c) => {
    const u = await getUser(c.env, deps, c.req.param('id'))
    if (!u) return c.json(fail('not_found', 'no such user'), 404)
    await c.env.DB.prepare('DELETE FROM users WHERE id = ?').bind(u.id).run()
    await audit(c.env, 'user.delete', u.name)
    await reconcileUsers(c.env, deps)
    return c.body(null, 204)
  })

  // A new subscription link; the old one stops working.
  app.post('/api/users/:id/reset-link', async (c) => {
    const u = await getUser(c.env, deps, c.req.param('id'))
    if (!u) return c.json(fail('not_found', 'no such user'), 404)
    const token = deps.randomToken(24)
    await c.env.DB.prepare('UPDATE users SET sub_token_hash = ?, sub_token_enc = ? WHERE id = ?')
      .bind(await deps.sha256Hex(token), await encrypt(c.env.TOKEN_KEY, token), u.id).run()
    await audit(c.env, 'user.reset_link', u.name)
    return c.json(await userView(c, deps, (await getUser(c.env, deps, u.id))!))
  })

  // New UUID and password: every client of this user must update its subscription.
  app.post('/api/users/:id/reset-credentials', async (c) => {
    const u = await getUser(c.env, deps, c.req.param('id'))
    if (!u) return c.json(fail('not_found', 'no such user'), 404)
    await c.env.DB.prepare('UPDATE users SET uuid_enc = ?, password_enc = ?, cred_rev = cred_rev + 1 WHERE id = ?')
      .bind(await encrypt(c.env.TOKEN_KEY, uuidV4()), await encrypt(c.env.TOKEN_KEY, password24()), u.id).run()
    await audit(c.env, 'user.reset_credentials', u.name)
    await reconcileUsers(c.env, deps)
    return c.json(await userView(c, deps, (await getUser(c.env, deps, u.id))!))
  })

  // This period's usage back to zero, here and on the servers (a new period id).
  app.post('/api/users/:id/reset-usage', async (c) => {
    const u = await getUser(c.env, deps, c.req.param('id'))
    if (!u) return c.json(fail('not_found', 'no such user'), 404)
    await c.env.DB.batch([
      c.env.DB.prepare('UPDATE users SET used_total_bytes = 0, period_retired_bytes = 0, period_seq = period_seq + 1 WHERE id = ?').bind(u.id),
      c.env.DB.prepare('UPDATE user_servers SET used_bytes = 0, period_base = 0, used_epoch = NULL WHERE user_id = ?').bind(u.id),
    ])
    await audit(c.env, 'user.reset_usage', u.name)
    await reconcileUsers(c.env, deps)
    return c.json(await userView(c, deps, (await getUser(c.env, deps, u.id))!))
  })

  // ── servers: the host name, the local page code ──
  app.put('/api/servers/:id/dns', async (c) => {
    const id = deps.idOf(c.req.param('id'))
    const s = id === null ? null : await c.env.DB.prepare('SELECT id, name, last_ip, dns_name FROM servers WHERE id = ?').bind(id).first<ServerRowLite>()
    if (!s) return c.json(fail('not_found', 'no such server'), 404)
    const b = await c.req.json<{ dns_name?: unknown }>().catch(() => null)
    const name = typeof b?.dns_name === 'string' ? b.dns_name.trim().toLowerCase() : ''
    if (name && !/^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(name)) return bad(c, ['域名格式不正确，例如 n1.myroom.asia'])
    if (name && /(^|[.-])vpn([.-]|$)/.test(name)) return bad(c, ['域名里不要带 vpn：握手里明文可见，容易被关键词封锁'])
    await c.env.DB.prepare('UPDATE servers SET dns_name = ?, dns_ip = NULL, dns_error = NULL, dns_at = NULL WHERE id = ?').bind(name || null, s.id).run()
    await audit(c.env, 'server.dns_name', s.name, name || '（关闭）')
    if (name && s.last_ip && /^\d{1,3}(\.\d{1,3}){3}$/.test(s.last_ip)) await updateDns(c.env, deps, { ...s, dns_name: name }, s.last_ip)
    const row = await c.env.DB.prepare('SELECT dns_name, dns_ip, dns_at, dns_error FROM servers WHERE id = ?').bind(s.id).first()
    return c.json(row)
  })

  app.post('/api/servers/:id/local-code', async (c) => {
    const id = deps.idOf(c.req.param('id'))
    const s = id === null ? null : await c.env.DB.prepare('SELECT * FROM servers WHERE id = ?').bind(id).first<ServerLite>()
    if (!s) return c.json(fail('not_found', 'no such server'), 404)
    if (!s.agent_token_hash) return c.json(fail('not_joined', '这台服务器还没有接入面板'), 409)
    if (!deps.versionAtLeast(s.agent_version, USERS_AGENT))
      return c.json(fail('agent_too_old', `本机页面要 psm-agent ${USERS_AGENT} 以上（${s.name} 是 ${s.agent_version ?? '旧版'}）：先升级 psm-agent`), 409)
    const code = localCode(crypto.getRandomValues(new Uint8Array(8)))
    // the deadline is fixed now: a code that reaches an offline server later does not come back to life
    const expiresAt = Math.floor(Date.now() / 1000) + LOCAL_CODE_TTL
    await deps.enqueue(c.env, s.id, null, { kind: 'local.code', code_hash: await deps.sha256Hex(code), expires_at: expiresAt })
    await audit(c.env, 'server.local_code', s.name)
    // only a literal address or DNS name goes into a command meant for a shell
    const host = [s.dns_name, s.last_ip, s.hostname].find((h): h is string => !!h && HOST_RE.test(h)) ?? null
    return c.json({ code, expires_in: LOCAL_CODE_TTL, url: 'http://127.0.0.1:2096',
      ssh: host ? `ssh -L 2096:127.0.0.1:2096 root@${host.includes(':') ? `[${host}]` : host}` : null })
  })

  // ── settings: Telegram, DNS readiness ──
  app.get('/api/roomkey/settings', async (c) => c.json({
    telegram_chat: (await setting(c.env, 'telegram_chat')) ?? '',
    telegram_token_set: !!(await setting(c.env, 'telegram_token_enc')),
    dns_token_set: !!c.env.CF_DNS_TOKEN,
    dns_zone_set: !!c.env.CF_ZONE_ID,
    admin_hosts: (c.env.ADMIN_HOSTS ?? '').split(',').map((h) => h.trim()).filter(Boolean),
    install_ready: !!c.env.INSTALL_URL && !!c.env.PSM_REPO,
  }))

  app.put('/api/roomkey/settings', async (c) => {
    const b = await c.req.json<{ telegram_token?: unknown; telegram_chat?: unknown }>().catch(() => null)
    if (!b) return bad(c, ['请求体要是 JSON 对象'])
    const stmts: D1PreparedStatement[] = []
    const put = (k: string, v: string) => c.env.DB.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value').bind(k, v)
    if (typeof b.telegram_token === 'string') {
      const t = b.telegram_token.trim()
      if (t && !/^\d{5,16}:[A-Za-z0-9_-]{30,64}$/.test(t)) return bad(c, ['Bot Token 格式不对，应像 123456789:AAE…（从 @BotFather 拿）'])
      stmts.push(t ? put('telegram_token_enc', await encrypt(c.env.TOKEN_KEY, t)) : c.env.DB.prepare(`DELETE FROM settings WHERE key = 'telegram_token_enc'`))
    }
    if (typeof b.telegram_chat === 'string') {
      const chat = b.telegram_chat.trim()
      if (chat && !/^(-?\d{1,20}|@[A-Za-z0-9_]{5,32})$/.test(chat)) return bad(c, ['Chat ID：数字（群组以 - 开头）或 @频道名'])
      stmts.push(chat ? put('telegram_chat', chat) : c.env.DB.prepare(`DELETE FROM settings WHERE key = 'telegram_chat'`))
    }
    if (stmts.length) await c.env.DB.batch(stmts)
    await audit(c.env, 'settings.telegram', '', '')
    return c.json({ ok: true })
  })

  app.post('/api/roomkey/telegram-test', async (c) => {
    const res = await notify(c.env, '测试消息：告警通道正常 ✅')
    if (res === 'sent') return c.json({ ok: true })
    return c.json(fail('telegram_failed', res === 'off' ? '还没有设置 Bot Token 和 Chat ID' : '发送失败：检查 Bot Token 和 Chat ID，并先给机器人发一条消息'), 502)
  })

  // ── backup: restorable SQL (wrangler d1 execute --file), one consistent snapshot ──
  app.get('/api/backup', async (c) => {
    const tables = ['servers', 'nodes', 'subscriptions', 'templates', 'settings', 'users', 'user_access', 'user_servers']
    const snap = await c.env.DB.batch([...tables.map((t) => c.env.DB.prepare(`SELECT * FROM ${t}`)),
      // what each node's work on its way was: the last of its create / change / removal tasks
      c.env.DB.prepare(`SELECT node_id, kind FROM tasks WHERE status IN ('queued', 'running') AND node_id IS NOT NULL
        AND kind IN ('node.add', 'standalone.install', 'node.update', 'node.delete', 'standalone.remove') ORDER BY id`)])
    const lastKind = new Map((snap[tables.length].results as { node_id: number; kind: string }[]).map((r) => [r.node_id, r.kind]))
    const creating = new Set([...lastKind].filter(([, k]) => k === 'node.add' || k === 'standalone.install').map(([id]) => id))
    const lines = [
      `-- roomkey backup, ${nowSql()} UTC.`,
      '-- Restore into a panel whose tables exist (open the new panel once, or wrangler d1 migrations apply):',
      '--   npx wrangler d1 execute psm-panel --remote --file roomkey-backup.sql',
      '-- Encrypted fields (*_enc) need the same TOKEN_KEY. Sign-in secrets, the key itself, tasks and',
      '-- traffic history are not included; every server is sent its user list again after a restore.',
      'PRAGMA defer_foreign_keys = ON;',
    ]
    for (const [i, t] of tables.entries()) {
      let rows = snap[i].results as Record<string, unknown>[]
      // neither the sign-in secrets nor the key: a backup file that leaks must not open the rest
      if (t === 'settings') rows = rows.filter((r) => !['admin_pw', 'session_epoch', 'token_key'].includes(String(r.key)))
      // After a restore every server gets its list again (numbered above what it
      // holds), no user counts as delivered until then, and work that was on its
      // way (no tasks are restored) waits to be saved again. Status reports are
      // left out: large, and refreshed by the servers.
      if (t === 'servers') rows = rows.map(({ status_enc: _s, check_enc: _c, ...r }) => ({ ...r, users_hash: null, users_retry_at: null,
        users_failed_hash: null, leaving: 0, leave_error: r.leaving ? '从备份恢复时正在移除：需要的话再移除一次' : r.leave_error }))
      if (t === 'user_servers') rows = rows.map((r) => ({ ...r, synced_cred_rev: null, synced_nodes: null, synced_enabled: 0 }))
      // Work that was on its way restores as it stood on the server before it
      // ("applied", saving it again sends an update), with a note; a node never
      // sent ("waiting") stays waiting.
      // A node whose creation was on its way restores as failed instead (it may
      // not be on its server). Ownership comes as it was: one psm-agent never
      // confirmed is still not the panel's, so saving sends a first create,
      // which a node of that name already there refuses as a conflict.
      if (t === 'nodes') rows = rows.map((r) => ['queued', 'deleting', 'pending'].includes(String(r.status))
        ? { ...r, status: creating.has(Number(r.id)) ? 'failed' : 'applied', last_error: RESTORE_NOTE } : r)
      for (const r of rows) {
        const cols = Object.keys(r)
        lines.push(`INSERT OR REPLACE INTO ${t} (${cols.join(', ')}) VALUES (${cols.map((k) => sqlLit(r[k])).join(', ')});`)
      }
    }
    await audit(c.env, 'backup.export', '', '')
    return c.body(lines.join('\n') + '\n', 200, {
      'Content-Type': 'application/sql; charset=utf-8',
      'Content-Disposition': `attachment; filename="roomkey-backup-${localYmd(new Date())}.sql"`,
      'Cache-Control': 'no-store',
    })
  })
}
