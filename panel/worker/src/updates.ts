// Updates: a new roomkey release on GitHub, installed during the update window
// (one window, in one time zone, for the panel and every server).
//
// The panel updates itself through Cloudflare's API with a token that can
// edit this Worker (the CF_UPDATE_TOKEN secret, set by setup.sh): it uploads
// the release's static files (the pages and the install bundle servers get
// PSM and psm-agent from), then the release's Worker code, keeping this
// Worker's bindings, secrets and settings as they are. The work goes in small
// steps saved in D1 (a step is one cron run, or one request from the 系统设置
// page), so no single run needs more than a few dozen requests; nothing goes
// live until the last step uploads the code.
//
// Servers update after the panel: a server whose psm-agent or PSM is older
// than what this panel carries gets agent.update (psm agent upgrade), a few
// servers per run, once per version.
import type { Context, Hono } from 'hono'
import type { Env } from './index'

type C = Context<{ Bindings: Env }>
type App = Hono<{ Bindings: Env }>

export type UpdateDeps = {
  audit: (env: Env, action: string, target?: string, detail?: string, actor?: string) => Promise<void>
  enqueue: (env: Env, serverId: number, nodeId: number | null, task: Record<string, unknown>) => Promise<number>
  fail: (code: string, message: string, extra?: Record<string, unknown>) => unknown
  versionAtLeast: (v: string | null, want: string) => boolean
  panelVersion: string
  agentVersion: string
}

/** The release manifest (scripts/release-manifest.mjs writes it). */
export type Manifest = {
  version: string
  tag: string
  agent_version: string
  psm_version?: string
  published_at?: string
  notes_url?: string
  /** the Worker's code: one release file, worker-modules.json */
  worker: { compatibility_date: string; compatibility_flags?: string[]; modules_asset: string }
  /** the static files: served path → content hash (Cloudflare's), size, type and the release files holding it */
  assets: { config: Record<string, unknown>; files: Record<string, { hash: string; size: number; type: string; raw: string; b64: string }> }
}
type Modules = { main_module: string; modules: { name: string; type: string; text: string }[] }

export type Window = { start: number; end: number; tz: string }
const DEFAULT_WINDOW: Window = { start: 4, end: 6, tz: 'Asia/Shanghai' }
const DEFAULT_REPO = 'The1UNeed/roomkey-public'
const CHECK_EVERY_H = 6
const FILES_PER_STEP = 6        // asset files uploaded per step (each a download and an upload)
const SERVERS_PER_RUN = 3       // servers asked to upgrade per cron run, so not all restart at once
const SESSION_MAX_MIN = 45      // an asset upload session older than this is started again

type Job = {
  version: string; tag: string; stage: 'assets' | 'script' | 'done' | 'failed'
  started_at: string; jwt?: string; session_at?: number; single?: boolean; pending?: string[]
  completion?: string; error?: string; uploaded?: number; total?: number; finished_at?: string
}
type Latest = { checked_at: string; manifest?: Manifest; error?: string }

// ── settings ─────────────────────────────────────────────────────────────────
async function getJSON<T>(env: Env, key: string): Promise<T | null> {
  const r = await env.DB.prepare('SELECT value FROM settings WHERE key = ?').bind(key).first<{ value: string }>()
  if (!r) return null
  try { return JSON.parse(r.value) as T } catch { return null }
}
const putJSON = (env: Env, key: string, v: unknown) =>
  env.DB.prepare(`INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`).bind(key, JSON.stringify(v)).run()

export async function updateSettings(env: Env): Promise<{ auto: boolean; window: Window }> {
  const [auto, window] = await Promise.all([getJSON<boolean>(env, 'update_auto'), getJSON<Window>(env, 'update_window')])
  return { auto: auto === true, window: { ...DEFAULT_WINDOW, ...(window ?? {}) } }
}

/** The hour (0-23) it is now in a time zone. */
export function localHour(now: Date, tz: string): number {
  return Number(new Intl.DateTimeFormat('en-US', { timeZone: tz, hour: 'numeric', hourCycle: 'h23' }).format(now)) % 24
}
/** Whether an hour is in [start, end), across midnight when end < start. */
export function inWindow(hour: number, w: Pick<Window, 'start' | 'end'>): boolean {
  return w.start < w.end ? hour >= w.start && hour < w.end : hour >= w.start || hour < w.end
}
export function windowProblem(w: Partial<Window>): string | null {
  const okHour = (h: unknown) => Number.isInteger(h) && (h as number) >= 0 && (h as number) <= 23
  if (!okHour(w.start) || !okHour(w.end)) return '更新时段：整点，0-23'
  if (w.start === w.end) return '更新时段：开始和结束不能是同一个钟点'
  try { new Intl.DateTimeFormat('en-US', { timeZone: String(w.tz) }) } catch { return `不认识的时区：${w.tz}` }
  if (!/^[A-Za-z_]+(\/[A-Za-z0-9_+-]+)*$/.test(String(w.tz))) return `不认识的时区：${w.tz}`
  return null
}

// ── releases ─────────────────────────────────────────────────────────────────
const repoOf = (env: Env) => env.UPDATE_REPO || DEFAULT_REPO
/** Where releases are downloaded from (UPDATE_BASE: tests only). */
const releasesBase = (env: Env) => (env.UPDATE_BASE || `https://github.com/${repoOf(env)}/releases`).replace(/\/+$/, '')
const assetUrl = (env: Env, tag: string, name: string) => `${releasesBase(env)}/download/${encodeURIComponent(tag)}/${encodeURIComponent(name)}`
const UA = { 'User-Agent': 'roomkey-panel' }

function manifestProblem(m: unknown): string | null {
  const x = m as Manifest
  if (!x || typeof x !== 'object' || typeof x.version !== 'string' || !/^\d+\.\d+\.\d+$/.test(x.version)) return 'no version'
  if (typeof x.tag !== 'string' || !/^v\d+\.\d+\.\d+$/.test(x.tag)) return 'no tag'
  if (!x.worker || typeof x.worker.modules_asset !== 'string' || typeof x.worker.compatibility_date !== 'string') return 'no worker'
  if (!x.assets || typeof x.assets.files !== 'object') return 'no assets'
  for (const [p, f] of Object.entries(x.assets.files))
    if (!p.startsWith('/') || !/^[0-9a-f]{32}$/.test(f?.hash ?? '') || !/^[\w.-]+$/.test(f.raw ?? '') || !/^[\w.-]+$/.test(f.b64 ?? '')) return `bad file ${p}`
  return null
}

/** The newest release (cached CHECK_EVERY_H hours unless `fresh`). */
export async function latestRelease(env: Env, fresh = false): Promise<Latest> {
  const cached = await getJSON<Latest>(env, 'update_latest')
  if (!fresh && cached && Date.now() - Date.parse(cached.checked_at) < CHECK_EVERY_H * 3600_000) return cached
  const out: Latest = { checked_at: new Date().toISOString() }
  try {
    const r = await fetch(`${releasesBase(env)}/latest/download/roomkey-release.json`, { headers: UA })
    if (r.status === 404) out.error = '还没有发布过面板版本'
    else if (!r.ok) out.error = `GitHub 回答 HTTP ${r.status}`
    else {
      const m = await r.json() as Manifest
      const bad = manifestProblem(m)
      if (bad) out.error = `发布文件不完整（${bad}）`
      else out.manifest = m
    }
  } catch (e) {
    out.error = `连不上 GitHub：${(e as Error).message}`
  }
  // a failed check keeps what was known
  if (out.error && cached?.manifest) out.manifest = cached.manifest
  await putJSON(env, 'update_latest', out)
  return out
}

// ── the panel updating itself ────────────────────────────────────────────────
/** What the panel needs before it can update itself, in words for the page. */
export function selfUpdateMissing(env: Env): string[] {
  const miss: string[] = []
  if (!env.CF_UPDATE_TOKEN) miss.push('CF_UPDATE_TOKEN（Workers 脚本 · 编辑 权限的 Cloudflare token）')
  if (!env.CF_ACCOUNT_ID) miss.push('CF_ACCOUNT_ID')
  if (!env.WORKER_NAME) miss.push('WORKER_NAME')
  return miss
}
const cfBase = (env: Env) => (env.CF_API_BASE || 'https://api.cloudflare.com/client/v4').replace(/\/+$/, '')
async function cf<T>(env: Env, path: string, init: RequestInit & { bearer?: string } = {}): Promise<T> {
  const { bearer, ...rest } = init
  const r = await fetch(`${cfBase(env)}${path}`, { ...rest, headers: { Authorization: `Bearer ${bearer ?? env.CF_UPDATE_TOKEN}`, ...(rest.headers ?? {}) } })
  const j = await r.json().catch(() => null) as { success?: boolean; result?: T; errors?: { code: number; message: string }[] } | null
  if (!r.ok || !j?.success) {
    const why = j?.errors?.map((e) => `${e.message} (${e.code})`).join('; ') || `HTTP ${r.status}`
    throw new Error(`Cloudflare：${why}`)
  }
  return j.result as T
}
const scriptPath = (env: Env) => `/accounts/${env.CF_ACCOUNT_ID}/workers/scripts/${env.WORKER_NAME}`
function jwtPayload(jwt: string): Record<string, unknown> {
  try { return JSON.parse(atob(jwt.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))) } catch { return {} }
}

export async function updateJob(env: Env): Promise<Job | null> { return getJSON<Job>(env, 'update_job') }

/** Start updating the panel to a release (a job already on that version goes on). */
export async function startSelfUpdate(env: Env, m: Manifest): Promise<Job> {
  const cur = await updateJob(env)
  if (cur && cur.version === m.version && (cur.stage === 'assets' || cur.stage === 'script')) return cur
  const job: Job = { version: m.version, tag: m.tag, stage: 'assets', started_at: new Date().toISOString() }
  await putJSON(env, 'update_job', job)
  return job
}

/** One step of the panel's update; returns the job as it is after it. */
export async function selfUpdateStep(env: Env, deps: UpdateDeps, m: Manifest): Promise<Job | null> {
  const job = await updateJob(env)
  if (!job || job.stage === 'done' || job.stage === 'failed' || job.version !== m.version) return job
  try {
    if (job.stage === 'assets') await assetsStep(env, job, m)
    else if (job.stage === 'script') {
      await scriptStep(env, m)
      job.stage = 'done'
      job.finished_at = new Date().toISOString()
      delete job.jwt; delete job.completion; delete job.pending
      await deps.audit(env, 'panel.update', `${deps.panelVersion} → ${m.version}`, '面板已更新', 'updater')
    }
  } catch (e) {
    job.stage = 'failed'
    job.error = (e as Error).message.slice(0, 500)
    job.finished_at = new Date().toISOString()
    await deps.audit(env, 'panel.update', `${deps.panelVersion} → ${m.version}`, `失败：${job.error}`, 'updater')
  }
  await putJSON(env, 'update_job', job)
  return job
}

async function assetsStep(env: Env, job: Job, m: Manifest) {
  const files = m.assets.files
  const byHash = new Map(Object.values(files).map((f) => [f.hash, f]))
  if (!job.jwt || !job.session_at || Date.now() - job.session_at > SESSION_MAX_MIN * 60_000) {
    // Cloudflare answers with the files it does not have yet, in buckets
    const manifest = Object.fromEntries(Object.entries(files).map(([p, f]) => [p, { hash: f.hash, size: f.size }]))
    const s = await cf<{ jwt: string; buckets: string[][] }>(env, `${scriptPath(env)}/assets-upload-session`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ manifest }),
    })
    const pending = s.buckets.flat()
    if (pending.some((h) => !byHash.has(h))) throw new Error('Cloudflare 要的文件不在发布里')
    job.session_at = Date.now()
    job.single = jwtPayload(s.jwt).wrangler_single_asset_uploads === true
    job.total = pending.length
    job.uploaded = 0
    if (!pending.length) { job.completion = s.jwt; job.stage = 'script'; delete job.jwt; return }
    job.jwt = s.jwt
    job.pending = pending
  }
  const batch = (job.pending ?? []).slice(0, FILES_PER_STEP)
  let completion: string | undefined
  const download = async (name: string) => {
    const r = await fetch(assetUrl(env, m.tag, name), { headers: UA })
    if (!r.ok) throw new Error(`下载 ${name} 失败：HTTP ${r.status}`)
    return r
  }
  if (job.single) {
    // one file per request, its bytes passed straight through
    for (const h of batch) {
      const f = byHash.get(h)!
      const body = (await download(f.raw)).body
      const res = await cf<{ jwt?: string } | null>(env, `/accounts/${env.CF_ACCOUNT_ID}/workers/assets/upload/${h}`, {
        method: 'POST', bearer: job.jwt, headers: { 'Content-Type': f.type || 'application/null' }, body,
      })
      if (res?.jwt) completion = res.jwt
    }
  } else {
    // several files per request, base64 as the API takes them (the release
    // has each file in base64 already: nothing is encoded here)
    const form = new FormData()
    for (const h of batch) {
      const f = byHash.get(h)!
      form.append(h, new File([await (await download(f.b64)).blob()], h, { type: f.type || 'application/null' }), h)
    }
    const res = await cf<{ jwt?: string } | null>(env, `/accounts/${env.CF_ACCOUNT_ID}/workers/assets/upload?base64=true`, {
      method: 'POST', bearer: job.jwt, body: form,
    })
    if (res?.jwt) completion = res.jwt
  }
  job.pending = (job.pending ?? []).slice(batch.length)
  job.uploaded = (job.uploaded ?? 0) + batch.length
  if (!job.pending.length) {
    if (!completion) throw new Error('Cloudflare 没有确认文件已全部上传')
    job.completion = completion
    job.stage = 'script'
    delete job.jwt
  }
}

async function scriptStep(env: Env, m: Manifest) {
  const job = (await updateJob(env))!
  const mr = await fetch(assetUrl(env, m.tag, m.worker.modules_asset), { headers: UA })
  if (!mr.ok) throw new Error(`下载 ${m.worker.modules_asset} 失败：HTTP ${mr.status}`)
  const mods = await mr.json() as Modules
  if (!mods?.main_module || !Array.isArray(mods.modules) || !mods.modules.some((x) => x.name === mods.main_module))
    throw new Error('发布里的 Worker 代码不完整')
  // this Worker's bindings and settings stay as they are: the secrets are kept
  // by type (their values are never read), everything else is sent back as is
  const cur = await cf<{ bindings?: Record<string, unknown>[]; placement?: unknown; observability?: unknown; logpush?: boolean; tail_consumers?: unknown }>(
    env, `${scriptPath(env)}/settings`)
  const bindings = (cur.bindings ?? []).filter((b) => b.type !== 'secret_text' && b.type !== 'secret_key')
  const metadata: Record<string, unknown> = {
    main_module: mods.main_module,
    bindings,
    keep_bindings: ['secret_text', 'secret_key'],
    compatibility_date: m.worker.compatibility_date,
    ...(m.worker.compatibility_flags?.length ? { compatibility_flags: m.worker.compatibility_flags } : {}),
    assets: { jwt: job.completion, config: m.assets.config },
    ...(cur.placement ? { placement: cur.placement } : {}),
    ...(cur.observability ? { observability: cur.observability } : {}),
    ...(cur.logpush !== undefined ? { logpush: cur.logpush } : {}),
    ...(cur.tail_consumers ? { tail_consumers: cur.tail_consumers } : {}),
  }
  const form = new FormData()
  form.set('metadata', JSON.stringify(metadata))
  for (const x of mods.modules) form.set(x.name, new File([x.text], x.name, { type: x.type }))
  await cf(env, scriptPath(env), { method: 'PUT', body: form })
}

// ── servers ──────────────────────────────────────────────────────────────────
/** The PSM version in this panel's install bundle ("2026-11-26 abc1234"), if it has one. */
export async function bundlePsmVersion(env: Env): Promise<string | null> {
  try {
    const r = await env.ASSETS.fetch(new Request('https://assets.invalid/_install/VERSION'))
    if (!r.ok) return null
    const v = (await r.text()).trim()
    return /^\d{4}-\d{2}-\d{2} [0-9a-f]{4,40}$/.test(v) ? v : null
  } catch { return null }
}
type ServerLite = { id: number; name: string; agent_version: string | null; psm_version: string | null; last_seen: string | null; update_tried: string | null }
/** Joined servers older than what this panel carries. */
export async function outdatedServers(env: Env, deps: UpdateDeps): Promise<(ServerLite & { online: boolean; target: string })[]> {
  const psm = await bundlePsmVersion(env)
  const { results } = await env.DB.prepare(
    `SELECT id, name, agent_version, psm_version, last_seen, update_tried,
            last_seen > datetime('now', '-10 minutes') AS online
       FROM servers WHERE agent_token_hash IS NOT NULL AND leaving = 0 ORDER BY id`).all<ServerLite & { online: number }>()
  const target = `${deps.agentVersion}/${psm ?? ''}`
  return results
    .filter((s) => !deps.versionAtLeast(s.agent_version, deps.agentVersion) || (psm !== null && (s.psm_version ?? '') !== psm))
    .map((s) => ({ ...s, online: !!s.online, target }))
}
async function upgradeServer(env: Env, deps: UpdateDeps, s: { id: number; name: string; agent_version: string | null; target: string }, actor: string) {
  if (await env.DB.prepare(`SELECT 1 FROM tasks WHERE server_id = ? AND kind = 'agent.update' AND status IN ('queued', 'running')`).bind(s.id).first()) return false
  await deps.enqueue(env, s.id, null, { kind: 'agent.update' })
  await env.DB.prepare('UPDATE servers SET update_tried = ? WHERE id = ?').bind(s.target, s.id).run()
  await deps.audit(env, 'server.upgrade-agent', s.name, `${s.agent_version ?? '未知'} → ${deps.agentVersion}（${actor === 'updater' ? '更新时段自动' : '全部更新'}）`, actor)
  return true
}

// ── the cron: in the window, the panel first, then the servers ─────────────
export async function updateCron(env: Env, deps: UpdateDeps, now = new Date()) {
  const { auto, window } = await updateSettings(env)
  const latest = await latestRelease(env)
  if (!auto || !inWindow(localHour(now, window.tz), window)) return
  const m = latest.manifest
  if (m && !deps.versionAtLeast(deps.panelVersion, m.version) && !selfUpdateMissing(env).length) {
    const job = await updateJob(env)
    // a failed attempt at this version is not retried by itself (the page
    // shows why), nor one that finished while this code still runs (the new
    // code is live for new requests: this run is the old one finishing)
    if (!(job?.version === m.version && (job.stage === 'failed' || job.stage === 'done'))) {
      await startSelfUpdate(env, m)
      await selfUpdateStep(env, deps, m)
      return   // the servers follow once the new panel runs
    }
  }
  let asked = 0
  for (const s of await outdatedServers(env, deps)) {
    if (asked >= SERVERS_PER_RUN) break
    if (!s.online || s.update_tried === s.target) continue
    if (await upgradeServer(env, deps, s, 'updater')) asked++
  }
}

// ── the 系统设置 page ────────────────────────────────────────────────────────
/** A job as the page sees it: without the upload session's tokens. */
const publicJob = (j: Job | null) => j && ({ version: j.version, tag: j.tag, stage: j.stage, started_at: j.started_at,
  uploaded: j.uploaded, total: j.total, error: j.error, finished_at: j.finished_at })

export function registerUpdateRoutes(app: App, deps: UpdateDeps) {
  const { fail, audit } = deps
  const state = async (c: C, fresh = false) => {
    const [settings, latest, job, servers] = await Promise.all([updateSettings(c.env), latestRelease(c.env, fresh), updateJob(c.env), outdatedServers(c.env, deps)])
    const m = latest.manifest
    return {
      auto: settings.auto, window: settings.window,
      local_hour: localHour(new Date(), settings.window.tz),
      in_window: inWindow(localHour(new Date(), settings.window.tz), settings.window),
      panel: {
        version: deps.panelVersion, agent_version: deps.agentVersion,
        latest: m ? { version: m.version, tag: m.tag, published_at: m.published_at ?? null, notes_url: m.notes_url ?? `https://github.com/${repoOf(c.env)}/releases/tag/${m.tag}` } : null,
        newer: !!m && !deps.versionAtLeast(deps.panelVersion, m.version),
        checked_at: latest.checked_at, check_error: latest.error ?? null,
        missing: selfUpdateMissing(c.env),
        job: publicJob(job),
        repo: repoOf(c.env),
      },
      servers: servers.map((s) => ({ id: s.id, name: s.name, agent_version: s.agent_version, psm_version: s.psm_version, online: s.online, asked: s.update_tried === s.target })),
    }
  }
  app.get('/api/updates', async (c) => c.json(await state(c)))
  app.post('/api/updates/check', async (c) => c.json(await state(c, true)))
  app.put('/api/updates/settings', async (c) => {
    const b = await c.req.json<{ auto?: unknown; window?: Partial<Window> }>().catch(() => null)
    if (!b || typeof b !== 'object') return c.json(fail('invalid', 'bad request'), 400)
    if (b.window !== undefined) {
      const w = { start: Number(b.window?.start), end: Number(b.window?.end), tz: String(b.window?.tz ?? '') }
      const problem = windowProblem(w)
      if (problem) return c.json(fail('invalid', problem, { errors: [problem] }), 400)
      await putJSON(c.env, 'update_window', w)
    }
    if (b.auto !== undefined) await putJSON(c.env, 'update_auto', b.auto === true)
    const s = await updateSettings(c.env)
    await audit(c.env, 'settings.update', 'updates', `${s.auto ? '自动更新' : '不自动更新'}，${s.window.start}:00-${s.window.end}:00 ${s.window.tz}`)
    return c.json(await state(c))
  })
  // the admin's 立即更新面板: started now, whatever the window; the page asks
  // for the next step until the job is done (each request is its own run)
  app.post('/api/updates/panel', async (c) => {
    const missing = selfUpdateMissing(c.env)
    if (missing.length) return c.json(fail('not_configured', `面板还不能自己更新：缺 ${missing.join('、')}。重新运行一键脚本并选择让面板自动更新。`), 409)
    const m = (await latestRelease(c.env)).manifest
    if (!m || deps.versionAtLeast(deps.panelVersion, m.version)) return c.json(fail('up_to_date', '面板已经是最新版本'), 409)
    const job = await updateJob(c.env)
    if (!job || job.version !== m.version || job.stage === 'failed' || job.stage === 'done') {
      if (job?.stage === 'failed') await c.env.DB.prepare(`DELETE FROM settings WHERE key = 'update_job'`).run()
      await startSelfUpdate(c.env, m)
      await audit(c.env, 'panel.update', `${deps.panelVersion} → ${m.version}`, '开始更新')
    }
    return c.json(publicJob(await selfUpdateStep(c.env, deps, m)))
  })
  app.post('/api/updates/panel/step', async (c) => {
    const m = (await latestRelease(c.env)).manifest
    if (!m) return c.json(fail('not_found', '没有可装的版本'), 404)
    return c.json(publicJob(await selfUpdateStep(c.env, deps, m)))
  })
  // 全部更新: every outdated server that is online, now
  app.post('/api/updates/servers', async (c) => {
    let asked = 0
    for (const s of await outdatedServers(c.env, deps)) if (s.online && await upgradeServer(c.env, deps, s, 'admin')) asked++
    return c.json({ asked })
  })
}
