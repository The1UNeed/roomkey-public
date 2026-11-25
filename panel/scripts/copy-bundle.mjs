// After `vite build`: the install bundle (scripts/bundle.sh) into the Worker's
// assets, under /_install/ (the Worker serves it only for a good token).
// BUNDLE_DIR names another bundle (tests); NO_BUNDLE=1 builds without one.
import { cpSync, existsSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
const panel = fileURLToPath(new URL('..', import.meta.url))
const from = resolve(panel, process.env.BUNDLE_DIR ?? 'install-bundle')
const to = resolve(panel, 'web/dist/_install')
if (process.env.NO_BUNDLE !== '1' && existsSync(resolve(from, 'SHA256SUMS'))) {
  cpSync(from, to, { recursive: true })
  console.log(`install bundle copied into web/dist/_install (from ${from})`)
}
