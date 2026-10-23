// Compile the standalone core (app/lib/standalone/js_main.dart, pure Dart) to public/codewalk_core.js.
// Needs the Dart SDK (comes with Flutter): set DART=/path/to/dart if `dart` is not on the PATH.
import { execFileSync } from 'node:child_process'
import { existsSync, rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const app = join(root, '..', 'app')
const out = join(root, 'public', 'codewalk_core.js')

function findDart() {
  if (process.env.DART) return process.env.DART
  for (const name of ['dart', 'flutter']) {
    try {
      const path = execFileSync('which', [name], { encoding: 'utf8' }).trim()
      if (!path) continue
      if (name === 'dart') return path
      const bundled = join(dirname(path), 'dart') // flutter/bin/dart
      if (existsSync(bundled)) return bundled
    } catch {
      // not on the PATH
    }
  }
  const home = join(process.env.HOME ?? '', 'development', 'flutter', 'bin', 'dart')
  if (existsSync(home)) return home
  console.error('Dart SDK not found: install Flutter or set DART=/path/to/dart')
  process.exit(1)
}

execFileSync(findDart(), ['compile', 'js', '-O2', '--no-source-maps', '-o', out, 'lib/standalone/js_main.dart'], {
  cwd: app,
  stdio: 'inherit',
})
// dart2js also writes these; they are not part of the app.
for (const extra of ['.deps', '.map']) rmSync(out + extra, { force: true })
