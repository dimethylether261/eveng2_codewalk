// Bump the version, compile the Dart core, type-check, build and pack codewalk.ehpk for Even Hub (Private builds).
//
// Usage: node scripts/release.mjs [patch|minor|major]   (default: patch, e.g. 0.1.0 -> 0.1.1)
// Then upload codewalk.ehpk in the dev portal and tap Install in the Even app
// (Even Hub > Me > Apps > Private builds).
//
// Portraits: the package gets the ones in ../private/portraits/ when that folder exists, or in
// CODEWALK_PORTRAITS=<dir>; otherwise the samples in public/characters/. They replace the samples
// in dist/ only, so they are never committed.
import { execFileSync } from 'node:child_process'
import { copyFileSync, existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const part = process.argv[2] ?? 'patch'
if (!['patch', 'minor', 'major'].includes(part)) {
  console.error(`unknown part "${part}" (patch | minor | major)`)
  process.exit(1)
}

export function bump(version, part) {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(version)
  if (!m) throw new Error(`version "${version}" is not x.y.z`)
  let [major, minor, patch] = m.slice(1).map(Number)
  if (part === 'major') [major, minor, patch] = [major + 1, 0, 0]
  else if (part === 'minor') [minor, patch] = [minor + 1, 0]
  else patch += 1
  return `${major}.${minor}.${patch}`
}

const readJson = f => JSON.parse(readFileSync(join(root, f), 'utf8'))
const writeJson = (f, j) => writeFileSync(join(root, f), JSON.stringify(j, null, 2) + '\n')

const app = readJson('app.json')
const pkg = readJson('package.json')
const next = bump(app.version, part)
const bin = name => join(root, 'node_modules', '.bin', name)
const run = (cmd, args) => execFileSync(cmd, args, { cwd: root, stdio: 'inherit' })

const portraits = process.env.CODEWALK_PORTRAITS || join(root, '..', 'private', 'portraits')
const ownPortraits = existsSync(portraits)
if (process.env.CODEWALK_PORTRAITS && !ownPortraits) {
  console.error(`CODEWALK_PORTRAITS: ${portraits} does not exist`)
  process.exit(1)
}

/** Replace the sample portraits in dist/ with the ones in [portraits]: all of them, or stop. */
function usePortraits() {
  const files = readdirSync(join(root, 'public', 'characters')).filter(f => f.endsWith('.png'))
  const missing = files.filter(f => !existsSync(join(portraits, f)))
  if (missing.length) throw new Error(`${portraits} lacks ${missing.join(', ')}`)
  for (const f of files) copyFileSync(join(portraits, f), join(root, 'dist', 'characters', f))
  console.log(`portraits from ${portraits}`)
}

// Build first with the new version written, and roll back if anything fails.
const before = { app: app.version, pkg: pkg.version }
writeJson('app.json', { ...app, version: next })
writeJson('package.json', { ...pkg, version: next })
try {
  run('node', [join(root, 'scripts', 'build_core.mjs')])
  run(bin('tsc'), ['--noEmit'])
  run(bin('vite'), ['build'])
  if (ownPortraits) usePortraits()
  else console.log('portraits: the samples in public/characters/')
  run(bin('evenhub'), ['pack', 'app.json', 'dist', '-o', 'codewalk.ehpk'])
} catch (e) {
  writeJson('app.json', { ...app, version: before.app })
  writeJson('package.json', { ...pkg, version: before.pkg })
  if (e instanceof Error && !('status' in e)) console.error(e.message)
  console.error(`\nbuild failed: version stays ${before.app}`)
  process.exit(1)
}
console.log(`\ncodewalk.ehpk ${before.app} -> ${next}`)
console.log('Upload it in the Even Hub dev portal (Private builds), then Install in the Even app.')
