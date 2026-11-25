import { execFileSync } from 'node:child_process'
// `npm run e2e` (e2e/run.sh).
// End-to-end against `wrangler dev` (local D1) and a mock of Cloudflare's and
// Telegram's APIs: admin API, a fake psm-agent that joins and syncs, users,
// revisions and acknowledgements, quotas, races, subscriptions, the local page
// code and events, DNS, alerts, the admin-host rule, the cron.
const BASE = process.env.BASE ?? 'http://localhost:58384'   // ADMIN_HOSTS=localhost
const PUBLIC = BASE.replace('localhost', '127.0.0.1')      // the same Worker under another name
let cookie = ''
let passed = 0
const ok = (cond, what, extra = '') => {
  if (!cond) { console.error(`✗ ${what}`, extra); process.exit(1) }
  passed++
  console.log(`✓ ${what}`)
}
async function admin(method, path, body) {
  const r = await fetch(BASE + path, { method, headers: { 'content-type': 'application/json', cookie }, body: body ? JSON.stringify(body) : undefined })
  const sc = r.headers.get('set-cookie')
  if (sc) cookie = sc.split(';')[0]
  const text = await r.text()
  let data
  try { data = JSON.parse(text) } catch { data = text }
  return { status: r.status, data, headers: r.headers }
}
let agentToken = ''
const inbox = []
let lastAcked = []
const uids = new Map()   // task id → uid, as psm-agent echoes it in each result
async function sync(body = {}, ip = '203.0.113.7') {
  if (Array.isArray(body.results)) body = { ...body, results: body.results.map((x) => ({ uid: uids.get(x.task_id), ...x })) }
  const r = await fetch(PUBLIC + '/api/agent/sync', {
    method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${agentToken}`, 'CF-Connecting-IP': ip },
    body: JSON.stringify({ agent_version: '0.14.0', hostname: 'hk1', psm_version: '2026-11-24 test', results: [], ...body }),
  })
  const j = await r.json()
  for (const t of j.tasks ?? []) uids.set(t.id, t.uid)
  inbox.push(...(j.tasks ?? []))
  lastAcked = j.events_acked ?? []
  return j
}
/** The newest task of a kind handed out so far (syncing once more first), taken out of the inbox. */
async function take(kind) {
  await sync()
  let i = -1
  for (let k = inbox.length - 1; k >= 0; k--) if (inbox[k].kind === kind) { i = k; break }
  if (i < 0) return undefined
  const t = inbox[i]
  for (let k = inbox.length - 1; k >= 0; k--) if (inbox[k].kind === kind) inbox.splice(k, 1)
  return t
}
/** The tags of the metering tasks handed out so far (syncing once more first), taken out of the inbox. */
async function metered() {
  await sync()
  const tags = inbox.filter((t) => t.kind === 'traffic.set').map((t) => String(t.tag))
  for (let k = inbox.length - 1; k >= 0; k--) if (inbox[k].kind === 'traffic.set') inbox.splice(k, 1)
  return tags
}
/** What PSM answers to a user.sync it took. */
const took = (t, extra = {}) => sync({ results: [{ task_id: t.id, ok: true, output: { status: 'imported', revision: t.data.revision, applied: true, ok: true, conflicts: [], ...extra } }] })
const GB = 1024 ** 3, MB = 1024 ** 2
/** A statement against the local D1 of the running dev server (tests only). */
const d1 = (sql) => execFileSync('npx', ['wrangler', 'd1', 'execute', 'psm-panel', '--local', '--persist-to', new URL('./state', import.meta.url).pathname, '--command', sql, '--json'],
  { cwd: new URL('..', import.meta.url).pathname, stdio: 'pipe' })
const users = async () => Object.fromEntries((await admin('GET', '/api/users')).data.map((u) => [u.name, u]))
const subOf = async (id) => (await admin('GET', `/api/users/${id}`)).data.subscription.split('/sub/')[1]
const uri = async (token) => Buffer.from(await (await fetch(`${PUBLIC}/sub/${token}`, { headers: { 'User-Agent': 'Shadowrocket/2070' } })).text(), 'base64').toString()

// ── the admin host rule: the public name serves subscriptions and agents only ──
ok((await fetch(`${PUBLIC}/api/session`)).status === 404, 'the public host name does not serve the admin API')
ok((await fetch(`${PUBLIC}/`)).status === 404, 'nor the admin page')
ok((await fetch(`${BASE}/`)).status === 200, 'the admin host name serves the page')

// ── sign in, a server, its agent ──
ok((await admin('POST', '/api/login', { password: 'roomkey-e2e-pass' })).status === 200, 'admin signs in')
const srv = await admin('POST', '/api/servers', { name: 'hk1' })
ok(srv.status === 201 && /--repo https:\/\/github\.com\/example\/roomkey-stack/.test(srv.data.install_command), 'install command carries INSTALL_URL and --repo', srv.data.install_command)
const joinToken = /--join (\S+)/.exec(srv.data.install_command)[1]
const join = await fetch(PUBLIC + '/api/agent/join', { method: 'POST', headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ join_token: joinToken, hostname: 'hk1', agent_version: '0.14.0' }) }).then((r) => r.json())
agentToken = join.agent_token
ok(agentToken?.length >= 32, 'fake psm-agent joins (through the public host name)')

// ── nodes: REALITY always on its own site; AnyTLS on sing-box ──
const own = await admin('POST', '/api/nodes', { server_id: srv.data.id, protocol: 'vless', variant: 'vless-reality', engine: 'xray',
  name: 'hk-reality', address: 'n1.myroom.asia', port: 443, labels: ['hk'], params: { server_name: 'n1.myroom.asia', dest: 'www.cloudflare.com:443' } })
ok(own.status === 201, 'REALITY node created', JSON.stringify(own.data))
const ipOwn = await admin('POST', '/api/nodes', { server_id: srv.data.id, protocol: 'vless', variant: 'vless-reality', engine: 'xray',
  name: 'bad-own', address: '203.0.113.7', port: 8443, params: { server_name: '203.0.113.7' } })
ok(ipOwn.status === 400 && /不能是 IP/.test(JSON.stringify(ipOwn.data)), 'REALITY refuses an IP as its own domain')
const layer = await admin('POST', '/api/nodes', { server_id: srv.data.id, protocol: 'vless', variant: 'vless-reality-layer', engine: 'xray',
  name: 'hk-layer', address: 'n1.myroom.asia', port: 2443, labels: ['x'], params: { server_name: 'n1.myroom.asia' } })
ok(layer.status === 201, 'REALITY + XHTTP node created')
const anytls = await admin('POST', '/api/nodes', { server_id: srv.data.id, protocol: 'anytls', variant: 'anytls', engine: 'sing-box',
  name: 'hk-anytls', address: 'n1.myroom.asia', port: 8443, labels: ['hk'], params: {} })
ok(anytls.status === 201, 'AnyTLS node created (sing-box: not metered per user)')

let r = await sync()
inbox.length = 0
ok(!r.tasks.some((t) => t.kind === 'traffic.set'), 'a first create goes alone: no metering until the server confirms the node is the panel\'s')
const add = r.tasks.find((t) => t.kind === 'node.add' && t.data?.tag === 'hk-reality')
ok(add && add.data.own_site === true && add.data.dest === '127.0.0.1:8443', 'REALITY: own_site and the loopback target, whatever dest was sent', JSON.stringify(add?.data))
const addLayer = r.tasks.find((t) => t.kind === 'node.add' && t.data?.tag === 'hk-layer')
ok(addLayer && addLayer.data.own_site === true && addLayer.data.dest === '127.0.0.1:8443' && addLayer.data.mode === 'reality-layer', 'REALITY + XHTTP: own site too')
const owner = '00000000-0000-4000-8000-000000000000'
const results = r.tasks.map((t) => {
  if (t.kind === 'node.add' && t.data.tag === 'hk-reality')
    return { task_id: t.id, ok: true, link: `vless://${owner}@n1.myroom.asia:443?security=reality&sni=n1.myroom.asia&pbk=PUB&sid=01&flow=xtls-rprx-vision#PSM-hk`,
      outbound: { type: 'vless', tag: 'x', server: 'n1.myroom.asia', server_port: 443, uuid: owner }, clash: { type: 'vless', name: 'x', server: 'n1.myroom.asia', port: 443, uuid: owner } }
  if (t.kind === 'node.add' && t.data.tag === 'hk-layer') return { task_id: t.id, ok: true, link: `vless://${owner}@n1.myroom.asia:2443?security=reality&type=xhttp#L` }
  if (t.kind === 'node.add') return { task_id: t.id, ok: true, link: 'anytls://ownerpass@n1.myroom.asia:8443?sni=n1.myroom.asia&insecure=1#PSM-a',
    outbound: { type: 'anytls', tag: 'a', server: 'n1.myroom.asia', server_port: 8443, password: 'ownerpass' } }
  if (t.kind === 'user.sync') return { task_id: t.id, ok: true, output: { status: 'imported', revision: t.data.revision, applied: false, ok: true, conflicts: [] } }
  return { task_id: t.id, ok: true, output: { used_bytes: 0, paused: false } }
})
const confirmed = await sync({ results })
const meters = confirmed.tasks.filter((t) => t.kind === 'traffic.set')
ok(meters.length === 3, 'once each create is confirmed, its metering follows', JSON.stringify(confirmed.tasks.map((t) => t.kind)))
await sync({ results: meters.map((t) => ({ task_id: t.id, ok: true, output: { used_bytes: 0, paused: false } })) })
inbox.length = 0
ok((await admin('GET', '/api/nodes')).data.every((n) => n.status === 'applied'), 'nodes applied')

// ── users ──
ok((await admin('POST', '/api/users', { name: 'Bad Name' })).status === 400, 'a bad user name is refused')
const stale = await admin('POST', '/api/users', { name: 'ghost', servers: [{ server_id: 999, quota_gb: 1 }] })
ok(stale.status === 400 && !(await users()).ghost, 'a quota on a server that is gone: refused, and no half-made user left')
const alice = await admin('POST', '/api/users', { name: 'alice', note: '小王', quota_total_gb: 1, device_limit: 2, access: [{ kind: 'label', value: 'hk' }] })
ok(alice.status === 201 && alice.data.state === 'active', 'alice created (1 GB total, hk nodes, 2 devices)')
const bob = await admin('POST', '/api/users', { name: 'bob', first_use_days: 30, access: [{ kind: 'label', value: 'hk' }] })
ok(bob.status === 201 && bob.data.expires_at === null, 'bob created (30 days from first use, no quota)')
const carol = await admin('POST', '/api/users', { name: 'carol', access: [{ kind: 'label', value: 'hk' }], servers: [{ server_id: srv.data.id, quota_gb: 0.5 }] })
ok(carol.status === 201, 'carol created (0.5 GB on hk1 only)')
ok((await admin('POST', '/api/users', { name: 'alice' })).status === 400, 'a second alice is refused')

const us1 = await take('user.sync')
ok(us1 && us1.data.revision >= 1 && us1.meta?.revision === us1.data.revision, 'user.sync carries its revision', JSON.stringify({ rev: us1?.data.revision }))
const by1 = Object.fromEntries(us1.data.users.map((u) => [u.name, u]))
ok(JSON.stringify(by1.alice.nodes) === '["xray/hk-reality"]', 'quota user: metered nodes only, named with their core (a same-name node on another core is not granted)')
ok(JSON.stringify(by1.bob.nodes) === '["xray/hk-reality"]', 'first-use user not started: metered nodes only (its start must be seen)')
ok(by1.carol.quota_bytes === Math.round(0.5 * GB) && by1.alice.quota_bytes === null, 'per-server quota goes to the server; the total stays in the panel')

// before the server takes the list, its nodes are not in anyone's subscription
const aliceTok = await subOf(alice.data.id)
let body = await uri(aliceTok)
ok(body.includes('127.0.0.1:1') && !body.includes('n1.myroom.asia'), 'before hk1 takes the list: a "nodes coming" placeholder, not dead nodes', body.slice(0, 80))
await took(us1)
body = await uri(aliceTok)
ok(body.startsWith(`vless://${by1.alice.uuid}@n1.myroom.asia:443`) && !body.includes(owner) && !body.includes('anytls://'), "once taken: alice's own UUID, metered node only")
ok(!(await take('user.sync')), 'nothing changed: no second user.sync')

// a list delivered late cannot undo a newer one (PSM answers "stale"); the panel keeps its numbering
await admin('PATCH', `/api/users/${alice.data.id}`, { note: '小王的手机' })   // no change to the list
ok(!(await take('user.sync')), 'a note change sends no list')

// ── subscriptions in every client ──
let sub = await fetch(`${PUBLIC}/sub/${aliceTok}`, { headers: { 'User-Agent': 'Shadowrocket/2070' } })
ok(/download=0; total=1073741824/.test(sub.headers.get('subscription-userinfo')), 'Subscription-Userinfo carries the quota')
const prov = await fetch(`${PUBLIC}/sub/${aliceTok}?format=provider`).then((x) => x.text())
ok(prov.includes(by1.alice.uuid) && !prov.includes(owner), "Clash Verge's provider: alice's UUID")
const sb = await fetch(`${PUBLIC}/sub/${aliceTok}`, { headers: { 'User-Agent': 'SFI/1.12.0 (sing-box 1.12.0)' } }).then((x) => x.json())
ok(JSON.stringify(sb).includes(by1.alice.uuid) && !JSON.stringify(sb).includes(owner), 'sing-box: alice’s UUID')
const page = await fetch(`${PUBLIC}/sub/${aliceTok}`, { headers: { 'User-Agent': 'Mozilla/5.0 (iPhone) Safari', Accept: 'text/html' } })
ok((await page.text()).includes('shadowrocket://add/sub://') && /script-src 'nonce-/.test(page.headers.get('content-security-policy')), 'browser: self-service page with a strict CSP')
const carolPage = await fetch(`${PUBLIC}/sub/${await subOf(carol.data.id)}`, { headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'text/html' } }).then((x) => x.text())
ok(carolPage.includes('hk1') && carolPage.includes('512.0 MB') && !carolPage.includes('不限流量'), 'a per-server-only user sees that server’s limit, not "unlimited"')
ok((await fetch(`${PUBLIC}/sub/not-a-real-token-but-long-enough-123`)).status === 404, 'an unknown token is 404')

// ── usage: this period's use as the server counts it; the lifetime counter for history ──
const period = by1.alice.period
const E1 = '1795000000-aaaa', E2 = '1795000500-bbbb', E0 = '1794000000-zzzz'
// [name, period use, lifetime counter, epoch, period id]
const report = (entries) => ({ users: { revision: us1.data.revision, users: entries.map(([name, used, counter, epoch = E1, p = period]) =>
  ({ name, managed: true, used_bytes: used, counter_bytes: counter, counter_epoch: epoch, period: p })) } })
await sync(report([['alice', 100 * MB, 100 * MB]]))
ok((await users()).alice.used_total_bytes === 100 * MB, 'alice: 100 MB this period')
await Promise.all([sync(report([['alice', 300 * MB, 300 * MB]])), sync(report([['alice', 300 * MB, 300 * MB]]))])
ok((await users()).alice.used_total_bytes === 300 * MB, 'two racing reports of the same reading count once')
await sync(report([['alice', 250 * MB, 250 * MB]]))
ok((await users()).alice.used_total_bytes === 300 * MB, 'a late, lower reading changes nothing')
await sync(report([['alice', 50 * MB, 50 * MB, E2]]))
ok((await users()).alice.used_total_bytes === 350 * MB, 'a newer counter generation (store lost) adds to what was counted')
await sync(report([['alice', 900 * MB, 900 * MB, E0]]))
ok((await users()).alice.used_total_bytes === 350 * MB, 'a report from an older generation is ignored')
await sync(report([['alice', 80 * MB, 80 * MB, E2]]))
ok((await users()).alice.used_total_bytes === 380 * MB, 'the newer generation keeps counting on top of what it banked')
await sync(report([['alice', 999 * MB, 999 * MB, E2, 'monthly:1999-01-01']]))
ok((await users()).alice.used_total_bytes === 380 * MB, 'use reported under another period id is not this period\'s')
await sync({ users: { users: [{ name: 'ghostly', managed: true, used_bytes: 5 * GB, counter_bytes: 5 * GB, counter_epoch: E1, period }] } })
ok(!(await users()).ghostly, 'a report for an unknown user changes nothing')

await sync(report([['alice', 800 * MB, 2000 * MB, E2], ['bob', 10 * MB, 10 * MB], ['carol', 600 * MB, 600 * MB]]))
let U = await users()
ok(U.alice.state === 'over_quota', 'alice passes 1 GB: over quota')
ok(U.bob.expires_at && U.bob.first_used_at, 'bob’s first traffic starts his 30 days')
const us2 = await take('user.sync')
const by2 = Object.fromEntries(us2.data.users.map((u) => [u.name, u]))
ok(us2.data.revision > us1.data.revision, 'the next list has a higher revision')
ok(by2.alice.enabled === false && by2.carol.enabled === false && typeof by2.bob.expires_at === 'number', 'alice off everywhere, carol off on hk1, bob’s expiry sent')
ok(JSON.stringify(by2.bob.nodes) === '["xray/hk-reality","sing-box/hk-anytls"]', 'bob’s term started: he now gets the unmetered node too', JSON.stringify(by2.bob.nodes))
await took(us2)
body = await uri(aliceTok)
ok(decodeURIComponent(body).includes('流量用完'), 'alice’s subscription says why it stopped')

// reset usage: a new period id
const reset = await admin('POST', `/api/users/${alice.data.id}/reset-usage`)
ok(reset.data.state === 'active' && reset.data.used_total_bytes === 0, 'reset usage: alice active again')
const us3 = await take('user.sync')
const a3 = us3.data.users.find((u) => u.name === 'alice')
ok(a3.enabled === true && a3.period.endsWith(':1') && us3.data.revision > us2.data.revision, 'servers get a new period id, under a newer revision', a3.period)
await took(us3)

// a changed reset schedule starts a new period
const sched = await admin('PATCH', `/api/users/${carol.data.id}`, { reset_period: 'weekly', reset_day: 1 })
ok(sched.data.used_total_bytes === 0 && sched.data.servers.every((s) => s.used_bytes === 0), 'a new reset schedule starts the period over')
const us4 = await take('user.sync')
ok(us4.data.users.find((u) => u.name === 'carol').period.startsWith('weekly:'), 'and the servers get the new period')
await took(us4)

// new credentials: the old ones leave the subscription until the server has the new ones
await admin('POST', `/api/users/${alice.data.id}/reset-credentials`)
body = await uri(aliceTok)
ok(!body.includes(by1.alice.uuid) && body.includes('127.0.0.1:1'), 'new credentials: no node until hk1 has them (no dead links)')
const us5 = await take('user.sync')
await took(us5)
body = await uri(aliceTok)
ok(body.includes(us5.data.users.find((u) => u.name === 'alice').uuid), 'once hk1 took them: the new UUID')

// ── a pause made on the server's local page: its nodes leave that user's subscription ──
const usNow = us5.data.users.find((u) => u.name === 'alice')
await sync({ users: { users: [{ name: 'alice', managed: true, used_bytes: 0, counter_bytes: 2000 * MB, counter_epoch: E2, period: usNow.period, local_paused: true }] } })
body = await uri(aliceTok)
ok(!body.includes(usNow.uuid) && body.includes('127.0.0.1:1'), 'paused on hk1’s local page: hk1’s nodes leave alice’s subscription')
await sync({ users: { users: [{ name: 'alice', managed: true, used_bytes: 0, counter_bytes: 2000 * MB, counter_epoch: E2, period: usNow.period, local_paused: false }] } })
ok((await uri(aliceTok)).includes(usNow.uuid), 'and come back when the pause is lifted')

// ── a late result (older revision) cannot undo a newer acknowledgement ──
await admin('PATCH', `/api/users/${carol.data.id}`, { access: [{ kind: 'label', value: 'nothing-matches' }] })
const usLate = await take('user.sync')
await took(usLate)
await sync({ results: [{ task_id: us5.id, ok: true, output: { status: 'imported', revision: us5.data.revision, applied: true, ok: true, conflicts: [] } }] })
const cs = (await admin('GET', `/api/users/${carol.data.id}`)).data.servers
ok(!cs.some((x) => x.synced), 'a result for an older revision, delivered late, does not bring back what the newer one removed', JSON.stringify(cs))
await admin('PATCH', `/api/users/${carol.data.id}`, { access: [{ kind: 'label', value: 'hk' }] })
await took(await take('user.sync'))

// ── two edits at once: each list has its own number, the last has both changes ──
const before = (await admin('GET', '/api/servers')).data[0]
await Promise.all([admin('PATCH', `/api/users/${bob.data.id}`, { device_limit: 3 }), admin('PATCH', `/api/users/${carol.data.id}`, { enabled: false })])
const both = await take('user.sync')
ok(both && both.data.users.find((u) => u.name === 'carol').enabled === false && both.data.revision > usLate.data.revision, 'concurrent edits: the newest list carries both, under a new revision')
await took(both)
await admin('PATCH', `/api/users/${carol.data.id}`, { enabled: true })
await took(await take('user.sync'))
void before

// ── the server's revision: rebuilt (behind) → the list again ──
await sync({ users_rev: 0 })
body = await uri(aliceTok)
ok(body.includes('127.0.0.1:1'), 'a rebuilt server (older revision than it confirmed): its nodes leave subscriptions until it takes the list again')
const again = await take('user.sync')
ok(again && again.data.revision > us5.data.revision, 'a server reporting an older revision (rebuilt) gets the list again, numbered higher', again?.data.revision)
await took(again)
await sync({ users_rev: again.data.revision })
ok(!(await take('user.sync')), 'up to date: nothing more')

// ── a failed import shows, and is retried by the cron (not every sync) ──
await admin('PATCH', `/api/users/${bob.data.id}`, { device_limit: 5 })
await admin('PATCH', `/api/users/${bob.data.id}`, { enabled: false })
const us7 = await take('user.sync')
await sync({ results: [{ task_id: us7.id, ok: true, output: { status: 'imported', revision: us7.data.revision, applied: true, ok: false, conflicts: [] } }] })
ok(/没有接受/.test((await admin('GET', '/api/servers')).data[0].users_error ?? ''), 'a core that rolled back shows on the server')
ok(!(await take('user.sync')), 'not resent on the next sync (each try restarts the cores)')
await sync({ users_rev: us7.data.revision - 1 })
ok(!(await take('user.sync')), 'not even when the server reports it is behind: the retry waits its turn')
await fetch(`${BASE}/__scheduled?cron=*/5+*+*+*+*`)
ok(!(await take('user.sync')), 'nor on a cron within the pause')
await admin('PATCH', `/api/users/${bob.data.id}`, { note: 'retry now' })   // an admin change does not override the pause either
// the five minutes pass (moved into the past in the local D1)
d1(`UPDATE servers SET users_retry_at = '2000-01-01 00:00:00'`)
await fetch(`${BASE}/__scheduled?cron=*/5+*+*+*+*`)
const retry = await take('user.sync')
ok(retry && retry.data.revision > us7.data.revision, 'after the pause the cron sends it again, under a newer revision')
await took(retry)
ok(!(await admin('GET', '/api/servers')).data[0].users_error, 'taken: the error clears')

// ── a name clash on one user does not hold back another user's revocation ──
await admin('PATCH', `/api/users/${carol.data.id}`, { expires_at: '2028-01-01' })
const usC = await take('user.sync')
await took(usC, { conflicts: ['carol'] })
ok(/同名的本地用户/.test((await admin('GET', '/api/servers')).data[0].users_error ?? ''), 'a clash with a user made on the server shows on the server')
await admin('PATCH', `/api/users/${alice.data.id}`, { enabled: false })
const revoke = await take('user.sync')
ok(revoke && revoke.data.users.find((u) => u.name === 'alice')?.enabled === false, 'disabling another user goes out at once, despite the clash\'s retry pause')
await took(revoke)
await admin('PATCH', `/api/users/${alice.data.id}`, { enabled: true })
await took(await take('user.sync'))

// ── an older psm-agent is not handed user lists or REALITY, whatever is queued ──
await admin('PATCH', `/api/users/${carol.data.id}`, { expires_at: '2028-02-01' })
const oldClaim = await sync({ agent_version: '0.13.0' })
ok(!oldClaim.tasks.some((t) => t.kind === 'user.sync'), 'a list queued before is not handed to an older psm-agent')
await admin('POST', `/api/servers/${srv.data.id}/status`)
ok((await admin('PATCH', `/api/nodes/${anytls.data.id}`, { traffic_limit_gb: 5, port: 8444 })).status === 200, 'a node edited while the server runs an older psm-agent')
const oldClaim2 = await sync({ agent_version: '0.13.0' })
ok(oldClaim2.tasks.length >= 1 && oldClaim2.tasks.every((t) => t.kind === 'status' || t.kind === 'agent.update'),
  'an older psm-agent is handed only its upgrade and status reports', JSON.stringify(oldClaim2.tasks.map((t) => t.kind)))
await sync({ results: oldClaim2.tasks.map((t) => ({ task_id: t.id, ok: true, output: {} })), agent_version: '0.13.0' })
await fetch(`${BASE}/__scheduled?cron=*/5+*+*+*+*`)
await new Promise((res) => setTimeout(res, 800))
ok(/太旧/.test((await admin('GET', '/api/servers')).data[0].users_error ?? ''), 'and the server says the psm-agent is too old (by the next cron)')
const back = await sync()   // back to 0.14
const held = back.tasks.find((t) => t.kind === 'node.update' && t.tag === 'hk-anytls')
ok(held && held.data.port === 8444 && held.data.public_port === 8444, 'the held change goes once the psm-agent is roomkey\'s, with its public port spelled out', JSON.stringify(held?.data))
const heldDone = back.tasks.filter((t) => t.kind !== 'user.sync')
await sync({ results: heldDone.map((t) => ({ task_id: t.id, ok: true, link: t.kind === 'node.update' ? 'anytls://ownerpass@n1.myroom.asia:8443?sni=n1.myroom.asia&insecure=1#PSM-a' : undefined, output: { used_bytes: 0, paused: false } })) })
for (let k = inbox.length - 1; k >= 0; k--) if (heldDone.some((t) => t.id === inbox[k].id)) inbox.splice(k, 1)
d1(`UPDATE servers SET users_retry_at = '2000-01-01 00:00:00'`)
await fetch(`${BASE}/__scheduled?cron=*/5+*+*+*+*`)
const after = await take('user.sync')
ok(after, 'once the psm-agent is current again, the list goes')
await took(after)

// ── relays are off: the panel has no relay API at all ──
ok((await admin('POST', '/api/relays', { server_id: srv.data.id, name: 'x', listen_port: 30001, node_id: own.data.id })).status === 404, 'relays cannot be created')
ok((await admin('GET', '/api/relays')).status === 404, 'and there is no relay list either')

// ── node edits: one on its way can't be deleted; a failed one is sent again on save ──
ok((await admin('PATCH', `/api/nodes/${own.data.id}`, { port: 4443 })).status === 200, 'the node\'s port is edited to 4443')
ok((await admin('DELETE', `/api/nodes/${own.data.id}`)).status === 409, 'a node on its way to its server cannot be deleted')
let upd = await take('node.update')
ok(upd && upd.mount443 === false && upd.recover === true, 'a change of the panel\'s own node carries its shared-443 setting and may recreate it', JSON.stringify(upd))
ok(upd.data.public_port === 4443, 'the public port is always spelled out (PSM would keep an old one otherwise)', JSON.stringify(upd.data))
await sync({ results: [{ task_id: upd.id, ok: false, error: 'port in use' }] })
ok((await admin('PATCH', `/api/nodes/${own.data.id}`, { port: 4443 })).data.status === 'queued', 'saving the failed edit unchanged sends it again')
upd = await take('node.update')
await sync({ results: [{ task_id: upd.id, ok: true, link: 'vless://x@n1.myroom.asia:4443' }] })
ok((await admin('PATCH', `/api/nodes/${own.data.id}`, { port: 443 })).status === 200, 'and back to 443')
upd = await take('node.update')
await sync({ results: [{ task_id: upd.id, ok: true, link: 'vless://x@n1.myroom.asia:443' }] })

// ── a node already on the server, not the panel's: the create is refused and removal never touches it ──
const taken = await admin('POST', '/api/nodes', { server_id: srv.data.id, protocol: 'anytls', variant: 'anytls', engine: 'sing-box',
  name: 'hk-taken', address: 'n1.myroom.asia', port: 9555, params: {} })
const takenAdd = await take('node.add')
ok(takenAdd && takenAdd.data.tag === 'hk-taken' && !takenAdd.recover, 'a first create is not a recovery', JSON.stringify(takenAdd))
await sync({ results: [{ task_id: takenAdd.id, ok: false, error: 'a node with this tag is already on this server, not made by the panel', output: { conflict: true } }] })
const takenRow = (await admin('GET', '/api/nodes')).data.find((n) => n.id === taken.data.id)
ok(takenRow.status === 'failed' && /已有同名节点/.test(takenRow.last_error), 'the panel marks it as someone else\'s', takenRow.last_error)
ok(!(await metered()).some((t) => t.includes('hk-taken')), 'nothing else is sent for it: no metering')
ok((await admin('PATCH', `/api/nodes/${taken.data.id}`, { port: 9556 })).status === 200, 'saving it again')
const takenAgain = await take('node.add')
ok(takenAgain && !takenAgain.recover && !(await metered()).some((t) => t.includes('hk-taken')), 'is a first create again, still alone', JSON.stringify(takenAgain))
await sync({ results: [{ task_id: takenAgain.id, ok: false, error: 'a node with this tag is already on this server, not made by the panel', output: { conflict: true } }] })
ok((await admin('DELETE', `/api/nodes/${taken.data.id}`)).status === 204, 'deleting it forgets the panel\'s row only')
ok(!(await take('node.delete')), 'and sends no removal to the server')

// a create that failed after PSM wrote the node: the node is the panel's, and removed when deleted
const half = await admin('POST', '/api/nodes', { server_id: srv.data.id, protocol: 'anytls', variant: 'anytls', engine: 'sing-box',
  name: 'hk-half', address: 'n1.myroom.asia', port: 9557, params: {} })
const halfAdd = await take('node.add')
await sync({ results: [{ task_id: halfAdd.id, ok: false, error: 'sing-box did not restart', output: { created: true } }] })
const halfMeters = await metered()
ok(halfMeters.some((t) => t.includes('hk-half')), 'a half-run create makes the node the panel\'s (its metering follows)', JSON.stringify(halfMeters))
ok((await admin('DELETE', `/api/nodes/${half.data.id}`)).status === 202, 'deleting it')
const halfDel = await take('node.delete')
ok(halfDel && halfDel.tag === 'hk-half', 'removes it from the server', JSON.stringify(halfDel))
await sync({ results: [{ task_id: halfDel.id, ok: true }] })

// a conflict that stays: the server's removal must leave it out (and not fail on it)
const other = await admin('POST', '/api/nodes', { server_id: srv.data.id, protocol: 'anytls', variant: 'anytls', engine: 'sing-box',
  name: 'hk-theirs', address: 'n1.myroom.asia', port: 9558, params: {} })
const otherAdd = await take('node.add')
await sync({ results: [{ task_id: otherAdd.id, ok: false, error: 'a node with this tag is already on this server, not made by the panel', output: { conflict: true } }] })
ok(other.status === 201, 'a node refused as a conflict is kept in the list (until deleted)')
// a local edit of that node (it is someone else's) changes nothing in the panel and sends nothing
await sync({ events: [{ id: 'cc00', at: new Date().toISOString(), kind: 'node.changed', target: 'hk-theirs',
  detail: { core: 'sing-box', protocol: 'anytls', tag: 'hk-theirs', changes: { port: 9600 } } }] })
const theirs = await sync()
ok(!theirs.tasks.some((t) => (t.kind === 'traffic.set' && String(t.tag).includes('hk-theirs')) || (t.kind === 'node.export' && t.tag === 'hk-theirs'))
  && (await admin('GET', '/api/nodes')).data.find((n) => n.name === 'hk-theirs').port === 9558,
  'a local edit of a node the panel does not own: no metering, no export, no change', JSON.stringify(theirs.tasks.map((t) => t.kind)))
ok((await admin('GET', `/api/nodes/${other.data.id}/link`)).status === 409, 'and no link for it')

// a result carrying another task's uid (a restored panel numbers tasks from 1 again) is not taken
ok((await admin('PATCH', `/api/nodes/${own.data.id}`, { traffic_limit_gb: 7, labels: ['hk', 'x7'] })).status === 200, 'an edit of the panel\'s node')
const uidTask = await take('node.update')
await sync({ results: [{ task_id: uidTask.id, uid: 'not-this-task', ok: false, error: 'stale' }] })
ok((await admin('GET', '/api/nodes')).data.find((n) => n.id === own.data.id).status === 'queued', 'a result with another uid is ignored')
await sync({ results: [{ task_id: uidTask.id, ok: true, link: 'vless://x@n1.myroom.asia:443' }] })
ok((await admin('GET', '/api/nodes')).data.find((n) => n.id === own.data.id).status === 'applied', 'its own result is taken')

// only the limit changed: only the meter is changed (the node is not installed
// again — for a standalone server that restarted it with a new automatic key)
inbox.length = 0
ok((await admin('PATCH', `/api/nodes/${own.data.id}`, { traffic_limit_gb: 9, reset_day: 3 })).status === 200, 'a quota-only edit')
await sync()
ok(inbox.some((t) => t.kind === 'traffic.set' && t.limit_bytes === 9 * GB && t.reset_day === 3)
  && !inbox.some((t) => t.kind === 'node.update' || t.kind === 'node.add' || t.kind === 'standalone.install')
  && (await admin('GET', '/api/nodes')).data.find((n) => n.id === own.data.id).status === 'applied',
  'a quota-only edit sends only the meter change; the node stays applied', JSON.stringify(inbox.map((t) => t.kind)))
// a standalone SS2022 server made with the method left at its default: the
// edit form spells the default out, and a limit change still sends only the meter
const sa = await admin('POST', '/api/nodes', { server_id: srv.data.id, protocol: 'ss2022', variant: 'ss2022', engine: 'standalone',
  name: 'hk-ss', address: 'n1.myroom.asia', port: 18388, params: {} })
ok(sa.status === 201, 'a standalone SS2022 server with the default method', JSON.stringify(sa.data))
const saAdd = await take('standalone.install')
await sync({ results: [{ task_id: saAdd.id, ok: true, link: 'ss://x@n1.myroom.asia:18388' }] })
await sync(); inbox.length = 0
ok((await admin('PATCH', `/api/nodes/${sa.data.id}`, { traffic_limit_gb: 4, params: { method: '2022-blake3-aes-128-gcm' } })).status === 200, 'its form edit with the default spelled out')
await sync()
ok(inbox.some((t) => t.kind === 'traffic.set' && t.limit_bytes === 4 * GB) && !inbox.some((t) => t.kind === 'standalone.install')
  && (await admin('GET', '/api/nodes')).data.find((n) => n.id === sa.data.id).status === 'applied',
  'a spelled-out default is no change: only the meter, no reinstall (no new key)', JSON.stringify(inbox.map((t) => t.kind)))

// a local edit of another core's node with the same name changes nothing here
await sync({ events: [{ id: 'cc01', at: new Date().toISOString(), kind: 'node.changed', target: 'hk-reality',
  detail: { core: 'sing-box', protocol: 'anytls', tag: 'hk-reality', changes: { port: 7777 } } }] })
ok((await admin('GET', '/api/nodes')).data.find((n) => n.name === 'hk-reality').port === 443, 'a local change is matched on core and protocol, not the name alone')

// ── device limit (users this server has) ──
await sync({ online: { users: [{ name: 'carol', ips: ['198.51.100.1'] }, { name: 'alice', ips: ['198.51.100.1', '198.51.100.2', '198.51.100.3', '127.0.0.1'] }] } })
U = await users()
ok(U.alice.state === 'devices' && /3 个 IP/.test(U.alice.blocked_reason), '3 IPs over a limit of 2 (loopback not counted): paused', U.alice.blocked_reason)

// ── local page: code with a deadline; events acknowledged ──
const code = await admin('POST', `/api/servers/${srv.data.id}/local-code`)
ok(code.status === 200 && /^[A-Z2-9]{4}-[A-Z2-9]{4}$/.test(code.data.code) && code.data.ssh.includes('root@203.0.113.7'), 'a local page code and the SSH command', code.data.ssh)
const lc = await take('local.code')
const now = Math.floor(Date.now() / 1000)
ok(lc && /^[0-9a-f]{64}$/.test(lc.code_hash) && lc.expires_at > now && lc.expires_at <= now + 600 && !JSON.stringify(lc).includes(code.data.code),
  'the server gets the hash and an absolute deadline, never the code')
await sync({ results: [{ task_id: lc.id, ok: true }], events: [
  { id: 'aa01', at: new Date().toISOString(), kind: 'local.login' },
  { id: 'aa02', at: new Date().toISOString(), kind: 'node.changed', target: 'hk-reality', detail: { core: 'xray', protocol: 'reality', tag: 'hk-reality', changes: { port: 8443, display_name: '香港' } } },
] })
ok(JSON.stringify(lastAcked) === '["aa01","aa02"]', 'both events acknowledged by id', JSON.stringify(lastAcked))
const auditCount = async () => (await admin('GET', '/api/audit')).data.filter((a) => a.actor === 'local:hk1').length
const n0 = await auditCount()
await sync({ events: [{ id: 'aa01', at: new Date().toISOString(), kind: 'local.login' }] })
ok(JSON.stringify(lastAcked) === '["aa01"]' && (await auditCount()) === n0, 'an event sent again (lost answer) is acknowledged without being done twice')
const n2 = (await admin('GET', '/api/nodes')).data.find((n) => n.name === 'hk-reality')
ok(n2.port === 8443 && n2.display_name === '香港', 'the node changed on the local page is updated in the panel')
const follow = [await take('traffic.set'), await take('node.export')]
ok(follow[0]?.tag === 'hk-reality' && follow[1]?.tag === 'hk-reality', 'metering and links follow the new port, as for a panel edit')
ok(JSON.stringify((await admin('GET', '/api/audit')).data).includes('local:hk1'), 'local page events are in the audit log')

// ── DNS (mock Cloudflare API): follows the address, backs off after a failure ──
const mockCalls = async () => (await fetch(`http://127.0.0.1:${process.env.E2E_MOCK_PORT ?? 58385}/__calls`)).json()
const d = await admin('PUT', `/api/servers/${srv.data.id}/dns`, { dns_name: 'n1.myroom.asia' })
ok(d.status === 200 && d.data.dns_ip === '203.0.113.7' && !d.data.dns_error, 'DNS: n1.myroom.asia → 203.0.113.7', JSON.stringify(d.data))
let calls = await mockCalls()
ok(calls.some((c) => c.method === 'POST' && c.body?.proxied === false && c.body?.ttl === 60) && !calls.some((c) => c.path.startsWith('/zones?')),
  'an A record, DNS only, TTL 60 — in the zone CF_ZONE_ID names (no zone lookup)')
await sync({}, '198.51.100.99')
await new Promise((res) => setTimeout(res, 500))
calls = await mockCalls()
ok(calls.some((c) => c.method === 'PATCH' && c.body?.content === '198.51.100.99'), 'a new server IP moves the record on the next sync')
ok((await admin('PUT', `/api/servers/${srv.data.id}/dns`, { dns_name: 'vpn.myroom.asia' })).status === 400, 'a host name with "vpn" is refused')

// ── Beijing dates; the friend's page in WeChat ──
const bj = await admin('PATCH', `/api/users/${carol.data.id}`, { expires_at: '2027-01-01' })
ok(bj.data.expires_at === '2027-01-01 15:59:59', 'an expiry date ends at 23:59 Beijing time', bj.data.expires_at)
const wx = await fetch(`${PUBLIC}/sub/${await subOf(carol.data.id)}`, { headers: { 'User-Agent': 'Mozilla/5.0 (iPhone) MicroMessenger/8.0.50', Accept: 'text/html' } }).then((x) => x.text())
ok(wx.includes('请在浏览器中打开') && wx.includes('2027-01-01 23:59（北京时间）') && wx.includes('非中国区'), 'WeChat: an "open in the browser" hint, Beijing date and app guidance')

// ── backup: a node whose creation was on its way restores as failed (saving sends a create) ──
const pend = await admin('POST', '/api/nodes', { server_id: srv.data.id, protocol: 'anytls', variant: 'anytls', engine: 'sing-box',
  name: 'hk-pending', address: 'n1.myroom.asia', port: 9443, params: {} })
ok(pend.status === 201, 'a node whose creation is on its way', JSON.stringify(pend.data))
const pendAdd = await take('node.add')   // handed out, no answer yet
ok(pendAdd && pendAdd.data.tag === 'hk-pending', 'its create is out on the server')
const busyLeave = await admin('DELETE', `/api/servers/${srv.data.id}`)
ok(busyLeave.status === 409, 'a server with a create out can\'t start its removal (the plan would not know what is the panel\'s)', JSON.stringify(busyLeave.data))
const bkp = (await admin('GET', '/api/backup')).data.split('\n').find((l) => l.startsWith('INSERT OR REPLACE INTO nodes') && l.includes("'hk-pending'"))
ok(bkp && bkp.includes("'failed'") && bkp.includes('会重新下发'), 'backup: it restores as failed with the restore note', bkp?.slice(0, 200))
await admin('DELETE', `/api/nodes/${pend.data.id}?force=1`)
inbox.length = 0

// ── settings, Telegram, backup, cron alerts ──
ok((await admin('PUT', '/api/roomkey/settings', { telegram_token: 'nope' })).status === 400, 'a malformed Telegram token is refused')
ok((await admin('PUT', '/api/roomkey/settings', { telegram_token: '123456789:AAEabcdefghijklmnopqrstuvwxyz012345', telegram_chat: '42' })).status === 200, 'Telegram bot saved')
ok((await admin('POST', '/api/roomkey/telegram-test')).status === 200, 'the test message goes out')
const rk = (await admin('GET', '/api/roomkey/settings')).data
ok(rk.telegram_token_set && rk.dns_token_set && rk.install_ready && rk.admin_hosts[0] === 'localhost' && !JSON.stringify(rk).includes('AAEabc'), 'settings say what is set, never the token')
const bk = await admin('GET', '/api/backup')
ok(!bk.data.split('\n').some((l) => l.startsWith('INSERT OR REPLACE INTO servers') && l.includes('status_enc')), 'backup: no status reports (large, refreshed by the servers)')
ok(bk.data.split('\n').filter((l) => l.startsWith('INSERT OR REPLACE INTO user_servers')).every((l) => !/\["hk-/.test(l)), 'backup: nobody counts as delivered after a restore')
ok(bk.status === 200 && /application\/sql/.test(bk.headers.get('content-type')) && /INSERT OR REPLACE INTO users /.test(bk.data)
  && !/'token_key'|'admin_pw'/.test(bk.data) && /users_hash.*NULL/.test(bk.data.split('\n').find((l) => l.startsWith('INSERT OR REPLACE INTO servers')) ?? ''),
  'backup: restorable SQL with the users, no key or password, user lists resent after restore')
ok((await admin('PATCH', `/api/users/${carol.data.id}`, { expires_at: '2020-01-01' })).data.state === 'expired', 'carol set to have expired')
await fetch(`${BASE}/__scheduled?cron=*/5+*+*+*+*`)
await new Promise((res) => setTimeout(res, 800))
calls = await mockCalls()
ok(calls.some((c) => c.path.includes('sendMessage') && /carol：已过期/.test(c.body?.text ?? '')), 'the cron tells Telegram carol expired')

// ── guards ──
ok((await fetch(`${BASE}/api/users`)).status === 401, 'the users API needs a session')
const xs = await fetch(`${BASE}/api/users`, { method: 'POST', headers: { 'content-type': 'application/json', cookie, 'Sec-Fetch-Site': 'cross-site' }, body: '{"name":"eve"}' })
ok(xs.status === 403, 'a cross-site change is refused')

ok((await admin('DELETE', `/api/users/${bob.data.id}`)).status === 204, 'bob deleted')
const lastList = await take('user.sync')
ok(lastList && !lastList.data.users.some((u) => u.name === 'bob'), 'the next list no longer has bob')
await took(lastList)

// ── removing the server: the panel's users go first, or the server stays ──
const aliceList = lastList.data.users.find((u) => u.name === 'alice')
await sync({ users: { revision: lastList.data.revision, users: [{ name: 'alice', managed: true, used_bytes: 70 * MB, counter_bytes: 9000 * MB, counter_epoch: E2, period: aliceList.period }] } })
const totalBefore = (await users()).alice.used_total_bytes
ok(totalBefore > 0, 'alice has use on hk1 this period', totalBefore)
ok((await admin('DELETE', `/api/servers/${srv.data.id}`)).status === 202, 'remove hk1')
let leave = await take('agent.leave')
ok(leave, 'hk1 is asked to leave')
const planned = leave.data.nodes.map((n) => n.tag)
ok(!planned.includes('hk-theirs') && planned.includes('hk-reality') && JSON.stringify(leave.data.relays) === '[]',
  'its plan lists only the panel\'s nodes (not the one refused as a conflict), and no relays', JSON.stringify(leave.data))
await sync({ results: [{ task_id: leave.id, ok: true, output: { removed: ['hk-reality'], failed: [] } }] })
let s9 = (await admin('GET', '/api/servers')).data[0]
ok(s9 && s9.leave_error && /面板用户/.test(s9.leave_error), 'a leave that did not confirm the users were removed keeps the server, with the reason', s9?.leave_error)
ok((await admin('DELETE', `/api/servers/${srv.data.id}`)).status === 202, 'remove again')
leave = await take('agent.leave')
// the leave carries each user's last reading, taken just before the purge
await sync({ results: [{ task_id: leave.id, ok: true, output: { removed: ['panel users', 'hk-reality'], failed: [],
  usage: { users: [{ name: 'alice', managed: true, used_bytes: 90 * MB, counter_bytes: 9020 * MB, counter_epoch: E2, period: aliceList.period }] } } }] })
ok((await admin('GET', '/api/servers')).data.length === 0, 'with the users confirmed removed, the server leaves the panel')
const aliceAfter = (await users()).alice
ok(aliceAfter.used_total_bytes === totalBefore + 20 * MB, 'use on the retired server, its last reading included, still counts toward alice\'s total', `${aliceAfter.used_total_bytes} vs ${totalBefore}`)


console.log(`\n${passed} checks passed`)
