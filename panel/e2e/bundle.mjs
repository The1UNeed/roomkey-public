// The private install against `wrangler dev` with a stand-in bundle (e2e/run.sh):
// the panel's install command fetches a script made for one join token; the
// bundle goes only to a good join token or agent token; /_install/ is closed.
import { readFileSync } from 'node:fs'
const BASE = process.env.BASE ?? 'http://localhost:58384'
const PUBLIC = BASE.replace('localhost', '127.0.0.1')   // the subscription host (not ADMIN_HOSTS)
const DIR = process.env.BUNDLE_DIR
let cookie = '', passed = 0
const ok = (cond, what, extra = '') => { if (!cond) { console.error(`✗ ${what}`, extra); process.exit(1) } passed++; console.log(`✓ ${what}`) }
async function admin(method, path, body) {
  const r = await fetch(BASE + path, { method, headers: { 'content-type': 'application/json', cookie }, body: body ? JSON.stringify(body) : undefined })
  const sc = r.headers.get('set-cookie'); if (sc) cookie = sc.split(';')[0]
  const t = await r.text(); let data; try { data = JSON.parse(t) } catch { data = t }
  return { status: r.status, data }
}
const get = (path, headers = {}) => fetch(PUBLIC + path, { headers })

ok((await admin('POST', '/api/login', { password: 'roomkey-e2e-pass' })).status === 200, 'admin signs in')
const srv = await admin('POST', '/api/servers', { name: 'vm1' })
const cmd = srv.data.install_command ?? ''
const m = /\/api\/agent\/install\/([A-Za-z0-9_-]+) \|\| wget/.exec(cmd)
ok(srv.status === 201 && m && /\| sh$/.test(cmd) && !cmd.includes('--repo'), 'with a bundle, the install command is the panel\'s own: curl … /api/agent/install/<token> | sh', cmd)
const token = m[1]

const script = await get(`/api/agent/install/${token}`)
const text = await script.text()
ok(script.status === 200 && text.startsWith('#!/bin/sh') && text.includes(`JOIN='${token}'`) && text.includes("PANEL='http://127.0.0.1:")
  && text.includes('bootstrap.sh" --panel "$PANEL" --join "$JOIN" --bundle'), 'the script carries this panel and this token, and hands over to PSM\'s bootstrap', text.slice(0, 300))
ok(script.headers.get('cache-control') === 'no-store', 'the script is never cached')
ok((await get('/api/agent/install/' + 'x'.repeat(43))).status === 404, 'an unknown token gets no script')
ok((await get(`/api/agent/install/${token};rm`)).status === 404, 'a token with anything else in it gets no script')

const sums = readFileSync(`${DIR}/SHA256SUMS`, 'utf8')
ok((await get('/_install/SHA256SUMS')).status === 404 && (await fetch(BASE + '/_install/stack.tgz')).status === 404, 'the bundle cannot be fetched directly, on either host')
ok((await get('/api/agent/bundle/stack.tgz')).status === 401, 'no token, no bundle')
ok((await get('/api/agent/bundle/stack.tgz', { 'X-PSM-Join': 'y'.repeat(43) })).status === 401, 'an unknown join token, no bundle')
const tgz = await get('/api/agent/bundle/stack.tgz', { 'X-PSM-Join': token })
ok(tgz.status === 200 && (await tgz.text()) === 'stack', 'a good join token gets PSM')
ok((await (await get('/api/agent/bundle/SHA256SUMS', { 'X-PSM-Join': token })).text()) === sums, '… and its checksums')
ok((await get('/api/agent/bundle/..%2F..%2Fwrangler.jsonc', { 'X-PSM-Join': token })).status === 404
  && (await get('/api/agent/bundle/index.html', { 'X-PSM-Join': token })).status === 404, 'only the bundle\'s own files')

// joining spends the token: no more script or bundle for it; the agent token gets the bundle
const joined = await fetch(PUBLIC + '/api/agent/join', { method: 'POST', headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ join_token: token, hostname: 'vm1', agent_version: '0.14.0' }) }).then((r) => r.json())
ok(!!joined.agent_token, 'the server joins with the token')
ok((await get(`/api/agent/install/${token}`)).status === 404 && (await get('/api/agent/bundle/stack.tgz', { 'X-PSM-Join': token })).status === 401,
  'a used join token gets nothing more')
const agentGet = await get('/api/agent/bundle/psm-agent-linux-arm64', { Authorization: `Bearer ${joined.agent_token}` })
ok(agentGet.status === 200 && (await agentGet.text()) === 'agent-arm64', 'the agent token gets the bundle (upgrades)')

console.log(`\n${passed} private-install checks passed`)
