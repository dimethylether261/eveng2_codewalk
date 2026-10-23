// Bump the version, compile the Dart core, type-check, build and pack codewalk.ehpk for Even Hub (Private builds).
//
// Usage: node scripts/release.mjs [patch|minor|major]   (default: patch, e.g. 0.1.0 -> 0.1.1)
// Then upload codewalk.ehpk in the dev portal and tap Install in the Even app
// (Even Hub > Me > Apps > Private builds).
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'
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

// Build first with the new version written, and roll back if anything fails.
const before = { app: app.version, pkg: pkg.version }
writeJson('app.json', { ...app, version: next })
writeJson('package.json', { ...pkg, version: next })
try {
  run('node', [join(root, 'scripts', 'build_core.mjs')])
  run(bin('tsc'), ['--noEmit'])
  run(bin('vite'), ['build'])
  run(bin('evenhub'), ['pack', 'app.json', 'dist', '-o', 'codewalk.ehpk'])
} catch (e) {
  writeJson('app.json', { ...app, version: before.app })
  writeJson('package.json', { ...pkg, version: before.pkg })
  console.error(`\nbuild failed: version stays ${before.app}`)
  process.exit(1)
}
console.log(`\ncodewalk.ehpk ${before.app} -> ${next}`)
console.log('Upload it in the Even Hub dev portal (Private builds), then Install in the Even app.')
