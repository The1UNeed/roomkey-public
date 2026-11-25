// Calls the panel's own API (/api/*), same origin, and the types it answers with.

export class ApiError extends Error {
  constructor(message: string, public errors: string[] = [], public status = 0) {
    super(message)
  }
}

export async function api<T = unknown>(path: string, init: RequestInit = {}): Promise<T> {
  const r = await fetch(path, {
    ...init,
    headers: { 'content-type': 'application/json', ...(init.headers as Record<string, string> | undefined) },
  })
  if (r.status === 204) return undefined as T
  // the session ended (expired, signed out elsewhere, the password changed): back to the sign-in page
  if (r.status === 401 && path !== '/api/login') window.dispatchEvent(new Event('psm:signed-out'))
  const body = await r.json().catch(() => ({}))
  if (!r.ok) throw new ApiError(body?.error?.message ?? `HTTP ${r.status}`, body?.error?.errors ?? [], r.status)
  return body as T
}

/** The message to show for a failed call: the list of problems, or the one message. */
export const errorText = (e: unknown) =>
  e instanceof ApiError && e.errors.length ? e.errors.join('；') : e instanceof Error ? e.message : String(e)

export type ServerStatus = 'pending' | 'online' | 'offline' | 'leaving'
export type Server = {
  id: number; name: string; status: ServerStatus
  hostname: string | null; agent_version: string | null; psm_version: string | null; leave_error: string | null
  /** the psm-agent release the panel expects; a server reporting another can be upgraded */
  agent_latest?: string
  note: string; last_seen: string | null; created_at: string; status_at: string | null
  node_count: number; traffic_used: number
  /** where the agent last synced from, and that network (Cloudflare's view) */
  last_ip: string | null; asn: number | null; country: string | null
  /** roomkey: the host name kept on the server's IPv4 address, and why users did not reach it */
  dns_name: string | null; dns_ip: string | null; dns_error: string | null; users_error: string | null
}

export type NodeStatus = 'waiting' | 'queued' | 'applied' | 'failed' | 'deleting'

/** A node as the list has it (no settings: GET /api/nodes/:id has those). */
export type PanelNode = {
  id: number; server_id: number; protocol: string; variant: string; engine: string; psm_protocol: string
  name: string; address: string; port: number; public_port: number | null; traffic_limit_gb: number
  labels: string[]; status: NodeStatus
  last_error: string | null; created_at: string; has_link: boolean
  /** shares the public 443 by SNI; fixed when the node is created */
  mount_443: boolean
  /** the name in clients; '' = the server's flag and "<server>-<name>" */
  display_name: string
  traffic_used: number; traffic_paused: boolean; traffic_at: string | null; reset_day: number
  params?: Record<string, unknown>
}

export type Subscription = {
  id: number; name: string; labels: string[]; url: string; last_used: string | null; created_at: string
  /** format → one of the user's templates (absent: the built-in one) */
  templates: Record<string, number>
}

export type Template = { id: number; name: string; format: string; body: string; created_at: string; updated_at: string | null }
export type Templates = {
  formats: Record<string, string>
  builtin: { format: string; name: string; body: string }[]
  custom: Template[]
}

export type AuditEntry = { id: number; at: string; actor: string; action: string; target: string; detail: string }

export const GB = 1024 ** 3

/** 1536 → "1.5 KB" */
export function formatBytes(n: number): string {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB']
  let v = Math.max(0, n || 0), i = 0
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
  return `${i ? v.toFixed(v < 10 ? 2 : 1) : v} ${units[i]}`
}

/**
 * The UTC day this month's counts started on ("2026-10-01"), when every node
 * resets on the same day of the month; null when they differ or there are no
 * nodes. (Each server resets at midnight in its own time zone, so the day can
 * be a few hours off.) The days before it in a chart are last month's.
 */
export function cycleStart(resetDays: number[], now = new Date()): string | null {
  const days = [...new Set(resetDays)]
  if (days.length !== 1) return null
  const y = now.getUTCFullYear(), m = now.getUTCMonth()
  return new Date(Date.UTC(y, now.getUTCDate() >= days[0] ? m : m - 1, days[0])).toISOString().slice(0, 10)
}

/** D1's "2026-09-15 08:00:00" (UTC) or an ISO time → a Date */
export function parseTime(t: string | null | undefined): Date | null {
  if (!t) return null
  const d = new Date(/[TZ]/.test(t) ? t : t.replace(' ', 'T') + 'Z')
  return Number.isNaN(d.getTime()) ? null : d
}

/** → local time */
export function localTime(t: string | null | undefined): string {
  const d = parseTime(t)
  return d ? d.toLocaleString('zh-CN', { hour12: false }) : t ? String(t) : '—'
}

/** → "3 分钟前", "2 天后" */
export function ago(t: string | null | undefined): string {
  const d = parseTime(t)
  if (!d) return '—'
  const s = Math.round((Date.now() - d.getTime()) / 1000)
  const a = Math.abs(s), suffix = s >= 0 ? '前' : '后'
  if (a < 45) return s >= 0 ? '刚刚' : '马上'
  if (a < 3600) return `${Math.round(a / 60)} 分钟${suffix}`
  if (a < 86400) return `${Math.round(a / 3600)} 小时${suffix}`
  return `${Math.round(a / 86400)} 天${suffix}`
}

export const NODE_STATUS: Record<string, string> = {
  waiting: '待安装', queued: '下发中', applied: '运行中', failed: '失败', deleting: '删除中', pending: '等待出口', deleted: '已删除',
}

// ── roomkey: users ───────────────────────────────────────────────────────────
export type UserState = 'active' | 'disabled' | 'expired' | 'over_quota' | 'devices' | 'not_started'
export type UserAccess = { kind: 'all' | 'label' | 'node'; value: string }
export type PanelUser = {
  id: number; name: string; note: string; enabled: boolean; state: UserState; state_label: string
  expires_at: string | null; first_use_days: number | null; first_used_at: string | null
  quota_total_bytes: number | null; used_total_bytes: number
  reset_period: 'daily' | 'weekly' | 'monthly' | 'never'; reset_day: number; period_start: string | null; period_end: string | null
  device_limit: number; unmetered: boolean; blocked_until: string | null; blocked_reason: string | null
  last_sub_at: string | null; created_at: string
  access: UserAccess[]
  /** synced: that server has this user's current credentials (its nodes are in the subscription) */
  servers: { server_id: number; name: string; quota_bytes: number | null; used_bytes: number; nodes: number; synced: boolean; paused_here: boolean }[]
  online: number
  /** the detail only */
  subscription?: string
  daily?: { day: string; bytes: number }[]
  online_ips?: { server: string; ips: string[] }[]
}
/** A UTC time from the panel ("YYYY-MM-DD HH:MM:SS") as its Beijing date: the panel's days are Beijing days. */
export const beijingDate = (t: string | null | undefined) =>
  t ? new Date(Date.parse(t.replace(' ', 'T') + 'Z') + 8 * 3600_000).toISOString().slice(0, 10) : ''
export const USER_STATE_CLASS: Record<UserState, string> = {
  active: 'ok', disabled: 'pending', expired: 'err', over_quota: 'err', devices: 'err', not_started: 'pending',
}
