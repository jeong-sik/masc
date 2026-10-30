// Diffs a vendored stylesheet against its prototype original with the repo's
// own font-size tokenization normalized away, so only real value drift shows.
// Without this every `var(--fs-11)` reads as a change and buries the signal.
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const norm = (s) => s.replace(/font-size:\s*var\(--fs-(\d+)\)/g, 'font-size: $1px')

for (const name of process.argv.slice(2)) {
  const proto = readFileSync(`${root}/prototypes/keeper-v2/styles/${name}.css`, 'utf8')
  const vendor = norm(readFileSync(`${root}/src/styles/keeper-v2/${name}.css`, 'utf8'))
  writeFileSync('/tmp/_dp_proto.css', proto)
  writeFileSync('/tmp/_dp_vendor.css', vendor)
  console.log(`\n═══ ${name}.css ═══  (< design, > vendored)`)
  try {
    execFileSync('diff', ['-u', '/tmp/_dp_proto.css', '/tmp/_dp_vendor.css'], { stdio: 'inherit' })
    console.log('  identical after tokenization')
  } catch { /* diff exits 1 when files differ; output already streamed */ }
}
