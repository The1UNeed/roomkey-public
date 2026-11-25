// Stand-ins for Cloudflare's DNS API and Telegram's Bot API; records every call.
import http from 'node:http'
const calls = []
const records = new Map()   // name → {id, content, proxied}
http.createServer(async (req, res) => {
  let body = ''
  for await (const c of req) body += c
  const url = new URL(req.url, 'http://x')
  calls.push({ method: req.method, path: url.pathname + url.search, auth: req.headers.authorization ?? '', body: body ? JSON.parse(body) : null })
  const send = (o, code = 200) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)) }
  if (url.pathname === '/__calls') return send(calls)
  if (url.pathname === '/zones') return send({ success: true, result: url.searchParams.get('name') === 'myroom.asia' ? [{ id: 'zone1' }] : [] })
  if (url.pathname === '/zones/zone1/dns_records' && req.method === 'GET') {
    const r = records.get(url.searchParams.get('name'))
    return send({ success: true, result: r ? [r] : [] })
  }
  if (url.pathname === '/zones/zone1/dns_records' && req.method === 'POST') {
    const b = JSON.parse(body); const r = { id: 'rec' + (records.size + 1), content: b.content, proxied: b.proxied }
    records.set(b.name, r); return send({ success: true, result: r })
  }
  if (url.pathname.startsWith('/zones/zone1/dns_records/') && req.method === 'PATCH') {
    const b = JSON.parse(body); records.set(b.name, { ...records.get(b.name), content: b.content, proxied: b.proxied }); return send({ success: true, result: {} })
  }
  if (/^\/bot[^/]+\/sendMessage$/.test(url.pathname)) return send({ ok: true })
  send({ success: false, errors: [{ message: 'not found' }] }, 404)
}).listen(Number(process.env.E2E_MOCK_PORT ?? 58385), '127.0.0.1')
