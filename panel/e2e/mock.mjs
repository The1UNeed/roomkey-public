// Stand-ins for Cloudflare's DNS and Workers APIs, Telegram's Bot API and a
// GitHub release (the updater); records every call.
import http from 'node:http'
const calls = []
const records = new Map()   // name → {id, content, proxied}
// a release v0.13.0 with two static files (bulk upload: base64, in a form)
const files = { '/index.html': ['<!doctype html>new panel', 'aa'.repeat(16)], '/_install/VERSION': ['2026-12-01 abcdef1', 'bb'.repeat(16)] }
const release = {
  'roomkey-release.json': JSON.stringify({ version: '0.13.0', tag: 'v0.13.0', agent_version: '0.16.0', psm_version: '2026-12-01 abcdef1',
    worker: { compatibility_date: '2026-09-01', modules_asset: 'worker-modules.json' },
    assets: { config: { run_worker_first: true }, files: Object.fromEntries(Object.entries(files).map(([p, [c, h]]) =>
      [p, { hash: h, size: c.length, type: p.endsWith('.html') ? 'text/html' : 'application/null', raw: `a-${h}`, b64: `a-${h}.b64` }])) } }),
  'worker-modules.json': JSON.stringify({ main_module: 'index.js', modules: [{ name: 'index.js', type: 'application/javascript+module', text: 'export default {}' },
    { name: 'abc-0001_init.sql', type: 'text/plain', text: 'SELECT 1' }] }),
  ...Object.fromEntries(Object.values(files).flatMap(([c, h]) => [[`a-${h}`, c], [`a-${h}.b64`, Buffer.from(c).toString('base64')]])),
}
const uploaded = new Set()
http.createServer(async (req, res) => {
  const chunks = []
  for await (const c of req) chunks.push(c)
  const raw = Buffer.concat(chunks)
  const url = new URL(req.url, 'http://x')
  const type = req.headers['content-type'] ?? ''
  let body = null
  if (type.startsWith('multipart/form-data')) {
    const form = await new Request('http://x', { method: 'POST', headers: { 'content-type': type }, body: raw }).formData()
    body = {}
    for (const [k, v] of form) body[k] = typeof v === 'string' ? v : { file: v.name, type: v.type, text: await v.text() }
  } else if (raw.length) { try { body = JSON.parse(raw.toString()) } catch { body = raw.toString() } }
  calls.push({ method: req.method, path: url.pathname + url.search, auth: req.headers.authorization ?? '', body })
  const send = (o, code = 200) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)) }
  if (url.pathname === '/__calls') return send(calls)
  // the release, as github.com/<repo>/releases serves it
  if (url.pathname === '/__release/latest/download/roomkey-release.json') { res.writeHead(200); return res.end(release['roomkey-release.json']) }
  const dl = /^\/__release\/download\/v0\.13\.0\/(.+)$/.exec(url.pathname)
  if (dl && release[dl[1]] !== undefined) { res.writeHead(200); return res.end(release[dl[1]]) }
  // Workers: the asset upload session, the uploads, the Worker's settings and code
  const W = '/accounts/acc1/workers'
  if (url.pathname === `${W}/scripts/roomkey-test/assets-upload-session` && req.method === 'POST')
    return send({ success: true, result: { jwt: 'upload-jwt', buckets: Object.values(files).map(([, h]) => [h]).filter(([h]) => !uploaded.has(h)) } })
  if (url.pathname === `${W}/assets/upload` && req.method === 'POST') {
    if (req.headers.authorization !== 'Bearer upload-jwt') return send({ success: false, errors: [{ code: 10000, message: 'bad upload token' }] }, 403)
    for (const h of Object.keys(body ?? {})) uploaded.add(h)
    const all = Object.values(files).every(([, h]) => uploaded.has(h))
    return send({ success: true, result: all ? { jwt: 'completion-jwt' } : {} })
  }
  if (url.pathname === `${W}/scripts/roomkey-test/settings` && req.method === 'GET')
    return send({ success: true, result: { bindings: [{ type: 'd1', name: 'DB', id: 'd1-id' }, { type: 'secret_text', name: 'ADMIN_PASSWORD' },
      { type: 'assets', name: 'ASSETS' }, { type: 'plain_text', name: 'ADMIN_HOSTS', text: 'admin.example' }], placement: { mode: 'smart' }, logpush: false } })
  if (url.pathname === `${W}/scripts/roomkey-test` && req.method === 'PUT') return send({ success: true, result: { id: 'roomkey-test' } })
  if (url.pathname === '/zones') return send({ success: true, result: url.searchParams.get('name') === 'myroom.asia' ? [{ id: 'zone1' }] : [] })
  if (url.pathname === '/zones/zone1/dns_records' && req.method === 'GET') {
    const r = records.get(url.searchParams.get('name'))
    return send({ success: true, result: r ? [r] : [] })
  }
  if (url.pathname === '/zones/zone1/dns_records' && req.method === 'POST') {
    const b = body; const r = { id: 'rec' + (records.size + 1), content: b.content, proxied: b.proxied }
    records.set(b.name, r); return send({ success: true, result: r })
  }
  if (url.pathname.startsWith('/zones/zone1/dns_records/') && req.method === 'PATCH') {
    const b = body; records.set(b.name, { ...records.get(b.name), content: b.content, proxied: b.proxied }); return send({ success: true, result: {} })
  }
  if (/^\/bot[^/]+\/sendMessage$/.test(url.pathname)) return send({ ok: true })
  send({ success: false, errors: [{ message: 'not found' }] }, 404)
}).listen(Number(process.env.E2E_MOCK_PORT ?? 58385), '127.0.0.1')
