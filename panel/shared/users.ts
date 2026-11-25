// Users (roomkey): the people who use the nodes. Each has one UUID and one
// password, used on every node they may reach; a traffic quota in total and/or
// per server; an expiry date (fixed, or counted from their first traffic); a
// device limit; and a subscription of their own. The panel decides who is
// active; each server gets its list (user.sync → psm user import) and also
// enforces expiry and its own per-server quota by itself.
//
// Everything here is pure (no D1, no fetch) so it can be tested on its own, and
// shared: the Worker and the user dialog apply the same eligibility rules.

export type Period = 'daily' | 'weekly' | 'monthly' | 'never'
export const PERIODS: Period[] = ['daily', 'weekly', 'monthly', 'never']
export const PERIOD_LABELS: Record<Period, string> = { daily: '每天', weekly: '每周', monthly: '每月', never: '不重置' }

/** PSM protocols whose nodes take a user's credentials. SS2022, Snell, WireGuard and SOCKS stay single-key. */
export const USER_PROTOCOLS = new Set(['reality', 'vision', 'xhttp', 'vless', 'vmess', 'trojan', 'hysteria2', 'anytls', 'tuic'])
/** Per-user traffic is counted by Xray only (psm user usage): other cores' nodes are not metered per user. */
export const isMetered = (engine: string) => engine === 'xray'

export type UserRow = {
  id: number; name: string; note: string; uuid_enc: string; password_enc: string; enabled: number
  expires_at: string | null; first_use_days: number | null; quota_total_bytes: number | null
  reset_period: string; reset_day: number; period_start: string | null; period_seq: number; used_total_bytes: number
  alerted_state: string
  device_limit: number; unmetered: number; blocked_until: string | null; blocked_reason: string | null
  cred_rev: number
  sub_token_hash: string; sub_token_enc: string; last_sub_at: string | null; first_used_at: string | null
  created_at: string
}

export type UserServerRow = {
  user_id: number; server_id: number; quota_bytes: number | null
  /** this period's use on the server: what PSM counted for the period, plus period_base */
  used_bytes: number
  /** the lifetime counter's last reading (for the history), and its generation (a newer one sorts after an older one) */
  last_counter: number; counter_epoch: string | null
  /** this period's use banked from an earlier counter generation (PSM's store was lost mid-period) */
  period_base: number
  /** the credentials revision and the nodes (JSON array of names) the server took for this user; null: it has not */
  synced_cred_rev: number | null; synced_nodes: string | null
  /** the server's local page paused the user there */
  local_paused: number
  /** the counter generation this period's use belongs to */
  used_epoch: string | null
  /** whether the list the server took let the user in */
  synced_enabled: number
}

/**
 * A counter generation as stored and compared: "<10-digit time>-<suffix>"
 * (PSM since 0.14). An older store's random epoch sorts before every new one.
 */
export function normEpoch(e: unknown): string | null {
  if (typeof e !== 'string') return null
  if (/^\d{10}-[A-Za-z0-9]{1,16}$/.test(e)) return e
  return /^[A-Za-z0-9]{1,32}$/.test(e) ? `0000000000-${e}` : null
}

/**
 * The panel's clock for days: Beijing time (UTC+8, no daylight saving) — when
 * friends' days, months and expiry dates start and end.
 */
export const TZ_OFFSET_MS = 8 * 3600_000
/** YYYY-MM-DD of an instant, in UTC. */
export const ymd = (d: Date) => d.toISOString().slice(0, 10)
/** YYYY-MM-DD of an instant, in Beijing time. */
export const localYmd = (d: Date) => ymd(new Date(d.getTime() + TZ_OFFSET_MS))
/** A Beijing date and time ("YYYY-MM-DD HH:MM:SS") as D1's UTC text. */
export function localToSql(local: string): string | null {
  const t = Date.parse(local.replace(' ', 'T') + 'Z')
  return Number.isFinite(t) ? new Date(t - TZ_OFFSET_MS).toISOString().replace('T', ' ').slice(0, 19) : null
}

/**
 * The first day (Beijing time) of the period `now` is in, or null for 'never'.
 * weekly: resetDay 1–7 is the weekday it starts on (1 = Monday);
 * monthly: resetDay 1–28 is the day of the month.
 */
export function periodStart(nowUtc: Date, period: string, resetDay: number): string | null {
  const now = new Date(nowUtc.getTime() + TZ_OFFSET_MS)
  const y = now.getUTCFullYear(), m = now.getUTCMonth(), d = now.getUTCDate()
  switch (period) {
    case 'daily':
      return ymd(now)
    case 'weekly': {
      const want = Math.min(Math.max(Math.round(resetDay) || 1, 1), 7) % 7   // 0 = Sunday, as getUTCDay
      const back = (now.getUTCDay() - want + 7) % 7
      return ymd(new Date(Date.UTC(y, m, d - back)))
    }
    case 'monthly': {
      const day = Math.min(Math.max(Math.round(resetDay) || 1, 1), 28)
      return ymd(d >= day ? new Date(Date.UTC(y, m, day)) : new Date(Date.UTC(y, m - 1, day)))
    }
    default:
      return null
  }
}

/** When the period that starts on `start` ends (the next one starts), or null for 'never'. */
export function periodEnd(start: string | null, period: string): string | null {
  if (!start) return null
  const [y, m, d] = start.split('-').map(Number)
  const next = period === 'daily' ? new Date(Date.UTC(y, m - 1, d + 1))
    : period === 'weekly' ? new Date(Date.UTC(y, m - 1, d + 7))
      : period === 'monthly' ? new Date(Date.UTC(y, m, d)) : null
  return next ? ymd(next) : null
}

/**
 * The id servers know the period by (psm user import's "period"): a new id
 * starts their usage over. seq: how many times the usage was reset by hand.
 */
export const periodId = (period: string, start: string | null, seq = 0) =>
  (start ? `${period}:${start}` : 'never') + (seq ? `:${seq}` : '')

export type UserState = 'active' | 'disabled' | 'expired' | 'over_quota' | 'devices' | 'not_started'
export const STATE_LABELS: Record<UserState, string> = {
  active: '正常', disabled: '已停用', expired: '已过期', over_quota: '流量用完', devices: '设备超限', not_started: '未开始',
}

/** D1's datetime('now') text ("YYYY-MM-DD HH:MM:SS", UTC) as epoch milliseconds. */
export function sqlTime(s: string | null | undefined): number | null {
  if (!s) return null
  const t = Date.parse(s.includes('T') ? s : s.replace(' ', 'T') + 'Z')
  return Number.isFinite(t) ? t : null
}

/** A user's state everywhere (not counting per-server quotas). */
export function userState(u: Pick<UserRow, 'enabled' | 'expires_at' | 'quota_total_bytes' | 'used_total_bytes' | 'blocked_until'>, now: number): UserState {
  if (!u.enabled) return 'disabled'
  const exp = sqlTime(u.expires_at)
  if (exp !== null && exp <= now) return 'expired'
  if (u.quota_total_bytes && u.used_total_bytes >= u.quota_total_bytes) return 'over_quota'
  const blocked = sqlTime(u.blocked_until)
  if (blocked !== null && blocked > now) return 'devices'
  return 'active'
}

/** Whether a user may use a server now: active everywhere, and under that server's own quota. */
export function activeOn(state: UserState, us: Pick<UserServerRow, 'quota_bytes' | 'used_bytes'> | undefined): boolean {
  return state === 'active' && !(us?.quota_bytes && us.used_bytes >= us.quota_bytes)
}

/**
 * Traffic since the last reading of a counter that only grows. A smaller
 * reading means the counter started over (PSM reinstalled, the user made
 * again): all of it is new.
 */
export const counterDelta = (last: number, now: number) => (now >= last ? now - last : now)

export type Access = { kind: 'all' | 'label' | 'node'; value: string }

/** Whether an access list lets a user onto a node. */
export function canReach(access: Access[], node: { id: number; labels: string[] }): boolean {
  return access.some((a) => a.kind === 'all' || (a.kind === 'label' && node.labels.includes(a.value)) ||
    (a.kind === 'node' && String(node.id) === a.value))
}

/**
 * The nodes a user gets: reachable by their access list, of a protocol that
 * takes per-user credentials, and — for a user whose traffic must be seen (a
 * quota, or a term that starts at first use) and who may not use unmetered
 * nodes — counted per user.
 */
export function userNodes<N extends { id: number; labels: string[]; psm_protocol: string; engine: string }>(
  access: Access[], nodes: N[], opts: { needsMetering: boolean; unmetered: boolean }): N[] {
  return nodes.filter((n) => USER_PROTOCOLS.has(n.psm_protocol) && canReach(access, n) &&
    (isMetered(n.engine) || !opts.needsMetering || opts.unmetered))
}

/**
 * Whether a user's traffic must be counted to enforce what was set: a total
 * or per-server quota, or a term that starts with the first traffic (and has
 * not started yet). Such a user only gets nodes that count per user.
 */
export const needsMetering = (u: { quota_total_bytes: number | null; first_use_days: number | null; first_used_at: string | null },
  serverQuotas: boolean) => !!u.quota_total_bytes || serverQuotas || (!!u.first_use_days && !u.first_used_at)

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

function b64decode(s: string): string {
  const std = s.replace(/-/g, '+').replace(/_/g, '/')
  const padded = std + '='.repeat((4 - (std.length % 4)) % 4)
  return new TextDecoder().decode(Uint8Array.from(atob(padded), (ch) => ch.charCodeAt(0)))
}
function b64encode(s: string): string {
  let bin = ''
  for (const byte of new TextEncoder().encode(s)) bin += String.fromCharCode(byte)
  return btoa(bin)
}

/**
 * A node's share link with a user's credentials in place of the owner's:
 * VLESS / VMess take the UUID, Trojan / Hysteria2 / AnyTLS the password,
 * TUIC both. Null when the link is not of a protocol users can have.
 */
export function linkFor(link: string, cred: { uuid: string; password: string }): string | null {
  const m = /^([a-z0-9]+):\/\//i.exec(link)
  if (!m) return null
  const scheme = m[1].toLowerCase()
  const rest = link.slice(m[0].length)
  if (scheme === 'vmess') {
    try {
      const j = JSON.parse(b64decode(rest.split('#')[0]))
      j.id = cred.uuid
      return 'vmess://' + b64encode(JSON.stringify(j))
    } catch {
      return null
    }
  }
  // the credentials end at the last @ before the path, query or name
  const end = rest.search(/[/?#]/)
  const at = rest.slice(0, end < 0 ? rest.length : end).lastIndexOf('@')
  if (at <= 0) return null
  const host = rest.slice(at)
  const enc = encodeURIComponent
  switch (scheme) {
    case 'vless': return `vless://${cred.uuid}${host}`
    case 'trojan': return `trojan://${enc(cred.password)}${host}`
    case 'hysteria2': case 'hy2': return `${scheme}://${enc(cred.password)}${host}`
    case 'anytls': return `anytls://${enc(cred.password)}${host}`
    case 'tuic': return `tuic://${cred.uuid}:${enc(cred.password)}${host}`
    default: return null
  }
}

/** A sing-box outbound or a mihomo proxy with a user's credentials. Null when its type takes none. */
export function proxyFor(p: Record<string, unknown> | null, cred: { uuid: string; password: string }): Record<string, unknown> | null {
  if (!p || typeof p !== 'object') return null
  const type = String(p.type ?? '')
  switch (type) {
    case 'vless': case 'vmess': return { ...p, uuid: cred.uuid }
    case 'trojan': case 'hysteria2': case 'anytls': return { ...p, password: cred.password }
    case 'tuic': return { ...p, uuid: cred.uuid, password: cred.password }
    default: return null
  }
}

export function validCredentials(c: { uuid: string; password: string }): boolean {
  return UUID_RE.test(c.uuid) && /^[A-Za-z0-9_-]{8,64}$/.test(c.password)
}

/** The Subscription-Userinfo header clients show as remaining traffic and expiry. */
export function userinfoHeader(used: number, total: number | null, expiresAt: string | null): string {
  const exp = sqlTime(expiresAt)
  return `upload=0; download=${Math.max(0, Math.floor(used))}; total=${total ? Math.floor(total) : 0}` +
    (exp ? `; expire=${Math.floor(exp / 1000)}` : '')
}

/** A user name: what PSM accepts (psm user import), lowercase. */
export const USER_NAME_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/

/** A one-time code for a server's local page: 8 characters from an alphabet without look-alikes, as XXXX-XXXX. */
export function localCode(random: Uint8Array): string {
  const abc = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
  const chars = [...random.slice(0, 8)].map((b) => abc[b % abc.length])
  return `${chars.slice(0, 4).join('')}-${chars.slice(4).join('')}`
}
