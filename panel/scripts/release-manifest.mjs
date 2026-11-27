// The files of a panel release, for a running panel to update itself with
// (worker/src/updates.ts). Run after `npm run build` (with the install bundle)
// and `wrangler deploy --dry-run --outdir <worker dir>`:
//
//   node scripts/release-manifest.mjs <worker dir> <out dir> [tag]
//
// writes into <out dir>:
//   roomkey-release.json   the manifest: version, Worker settings, every static
//                          file's path, Cloudflare content hash, size and type
//   worker-modules.json    the Worker's code (its modules, as text)
//   a-<hash>, a-<hash>.b64 each static file, as it is and in base64 (the
//                          API's bulk upload takes base64: the panel never
//                          encodes a file itself)
//   SHA256SUMS
// The hash is Wrangler's (BLAKE3 of the base64 content and the extension, 32
// hex characters), so Cloudflare sees the same files a `wrangler deploy` sends.
import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { extname, join, relative, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createBLAKE3 } from 'hash-wasm'

const [workerDir, outDir, tagArg] = process.argv.slice(2)
if (!workerDir || !outDir) { console.error('usage: release-manifest.mjs <worker dir> <out dir> [tag]'); process.exit(2) }
const panel = fileURLToPath(new URL('..', import.meta.url))
const src = readFileSync(join(panel, 'worker/src/index.ts'), 'utf8')
const constant = (name) => new RegExp(`const ${name} = '([^']+)'`).exec(src)?.[1]
const version = constant('PANEL_VERSION'), agentVersion = constant('AGENT_VERSION')
if (!/^\d+\.\d+\.\d+$/.test(version ?? '')) throw new Error(`PANEL_VERSION is not x.y.z: ${version}`)
const tag = tagArg || `v${version}`
if (tag !== `v${version}`) throw new Error(`tag ${tag}, but PANEL_VERSION is ${version}`)
const wrangler = JSON.parse(readFileSync(join(panel, 'wrangler.jsonc'), 'utf8').replace(/^\s*\/\/.*$/gm, '').replace(/\/\/[^"\n]*$/gm, ''))
let psmVersion
try { psmVersion = readFileSync(join(panel, 'install-bundle/VERSION'), 'utf8').trim() } catch { psmVersion = undefined }
const dist = join(panel, 'web/dist')
if (!statSync(join(dist, '_install/SHA256SUMS'), { throwIfNoEntry: false }))
  throw new Error('web/dist has no install bundle: run scripts/bundle.sh, then npm run build')

mkdirSync(outDir, { recursive: true })
const TYPES = { '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.ico': 'image/x-icon', '.json': 'application/json', '.txt': 'text/plain', '.map': 'application/json', '.woff2': 'font/woff2', '.tgz': 'application/gzip' }
const IGNORED = new Set(['.assetsignore', '_headers', '_redirects'])
const blake = await createBLAKE3()
const walk = (d) => readdirSync(d, { withFileTypes: true }).flatMap((e) => e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)])
const files = {}
const sums = []
const put = (name, data) => { writeFileSync(join(outDir, name), data); sums.push(`${createHash('sha256').update(data).digest('hex')}  ${name}`) }
for (const f of walk(dist).sort()) {
  const rel = relative(dist, f).split(sep).join('/')
  if (IGNORED.has(rel)) continue
  const data = readFileSync(f)
  if (data.length > 25 * 1024 * 1024) throw new Error(`${rel} is over Cloudflare's 25 MiB asset limit`)
  const b64 = data.toString('base64')
  const hash = blake.init().update(b64).update(extname(f).slice(1)).digest('hex').slice(0, 32)
  if (!files[`/${rel}`]) {
    put(`a-${hash}`, data)
    put(`a-${hash}.b64`, b64)
  }
  files[`/${rel}`] = { hash, size: data.length, type: TYPES[extname(f)] ?? 'application/null', raw: `a-${hash}`, b64: `a-${hash}.b64` }
}

// the Worker: index.js and the modules it imports (the migrations, as text)
const MODULE_TYPES = { '.js': 'application/javascript+module', '.mjs': 'application/javascript+module', '.sql': 'text/plain', '.txt': 'text/plain', '.html': 'text/plain' }
const modules = readdirSync(workerDir).filter((n) => MODULE_TYPES[extname(n)] && n !== 'README.md').sort()
  .map((name) => ({ name, type: MODULE_TYPES[extname(name)], text: readFileSync(join(workerDir, name), 'utf8') }))
if (!modules.some((m) => m.name === 'index.js')) throw new Error(`${workerDir} has no index.js (wrangler deploy --dry-run --outdir ${workerDir})`)
put('worker-modules.json', JSON.stringify({ main_module: 'index.js', modules }))

const manifest = {
  version, tag, agent_version: agentVersion, ...(psmVersion ? { psm_version: psmVersion } : {}),
  published_at: new Date().toISOString(),
  worker: { compatibility_date: wrangler.compatibility_date, ...(wrangler.compatibility_flags ? { compatibility_flags: wrangler.compatibility_flags } : {}), modules_asset: 'worker-modules.json' },
  assets: { config: { run_worker_first: wrangler.assets?.run_worker_first ?? false }, files },
}
put('roomkey-release.json', JSON.stringify(manifest, null, 1))
writeFileSync(join(outDir, 'SHA256SUMS'), sums.join('\n') + '\n')
console.log(`release ${tag}: ${Object.keys(files).length} static files, ${modules.length} modules → ${outDir}`)
