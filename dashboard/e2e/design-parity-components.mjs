// Which of the design's components the dashboard implements, read from source.
//
// The rendered-vocabulary probe (`design-parity-vocab.mjs`) walks two live pages
// and compares what is on screen. That turned out to measure data as much as
// markup: a badge only renders when some keeper is blocked, so the count moves
// between runs — monitor read 52.8% and 27.5% on two runs an hour apart, and the
// design side moved too. Source is deterministic, and it reaches the surfaces
// behind tabs and drawers that no click recipe covers.
//
// Design vocabulary: className literals in prototypes/keeper-v2/*.jsx, attributed
// to the file that draws them. Live vocabulary: every class token appearing in
// dashboard/src/**/*.ts, tests excluded — a test asserting a class is evidence
// about the test, not about what ships.
//
//   node e2e/design-parity-components.mjs [--list <file>]
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { family } from './design-parity-classes.mjs'

const PROTO_DIR = 'prototypes/keeper-v2'
const SRC_DIR = 'src'

const UTILITY = /^(is-|has-|on$|active|open|flex|grid|items-|justify-|text-|bg-|px-|py-|mx-|my-|mt-|mb-|ml-|mr-|pt-|pb-|pl-|pr-|gap-|w-|h-|min-|max-|rounded|border|shrink|grow|absolute|relative|inline|hidden|overflow|whitespace|font-|leading-|tracking-|truncate|select-|cursor-|transition|group|size-|self-|space-|animate|fade|slide|zoom|duration|delay|ease|fill-mode|sr-only|skip-link|order-|z-|top-|left-|right-|bottom-|opacity-|shadow|ring|outline|pointer-|touch-|scroll-|snap-|list-|align-|place-|col-|row-|basis-|object-|aspect-|backdrop|filter|blur|contrast|invert|saturate|sepia|origin-|rotate-|scale-|translate|skew-|first|last|only|odd|even|visited|checked|disabled|indeterminate|placeholder|before|after|marker|file|selection|caret|accent|appearance|resize|will-change|content-)/

function walk(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else out.push(p)
  }
  return out
}

// className="a b" and className={`a ${x} b`} both contribute their literal parts.
function classLiterals(text) {
  const out = new Set()
  for (const m of text.matchAll(/class(?:Name)?\s*=\s*(?:"([^"]*)"|'([^']*)'|\{`([^`]*)`\}|\{([^}]*)\})/g)) {
    const body = m[1] ?? m[2] ?? m[3] ?? m[4] ?? ''
    for (const tok of body.replace(/\$\{[^}]*\}/g, ' ').split(/[\s"'`+?:()]+/)) {
      const c = tok.trim()
      if (!c || c.length < 4 || UTILITY.test(c)) continue
      // A trailing hyphen is the stub of a stripped ${...} interpolation, not a class.
      if (!/^[a-z][a-z0-9-]*[a-z0-9]$/.test(c)) continue
      out.add(c)
    }
  }
  return out
}

const designByFile = new Map()
for (const f of readdirSync(PROTO_DIR).filter(f => f.endsWith('.jsx'))) {
  const cls = classLiterals(readFileSync(join(PROTO_DIR, f), 'utf8'))
  if (cls.size) designByFile.set(f.replace(/\.jsx$/, ''), cls)
}

// One blob of the dashboard's own markup. A class is "implemented" if the
// dashboard names it anywhere it could render it.
const liveText = walk(SRC_DIR)
  .filter(p => p.endsWith('.ts') && !p.endsWith('.test.ts'))
  .map(p => readFileSync(p, 'utf8'))
  .join('\n')
const has = c => new RegExp(`(^|[^a-z0-9-])${c.replace(/-/g, '\\-')}([^a-z0-9-]|$)`).test(liveText)

const only = process.argv.includes('--list') ? process.argv[process.argv.indexOf('--list') + 1] : null
const rows = []
for (const [file, cls] of [...designByFile].sort()) {
  const missing = [...cls].filter(c => !has(c)).sort()
  rows.push({ file, total: cls.size, missing })
  if (only && file !== only) continue
  if (only) {
    console.log(`\n${file} — ${cls.size - missing.length}/${cls.size} implemented, ${missing.length} missing`)
    const byFamily = new Map()
    for (const m of missing) byFamily.set(family(m), [...(byFamily.get(family(m)) || []), m])
    for (const [fam, members] of [...byFamily].sort((a, b) => b[1].length - a[1].length)) {
      console.log(`    ${fam.padEnd(22)} ${String(members.length).padStart(2)}  ${members.join(' ')}`)
    }
  }
}
if (only) process.exit(0)

console.log('component coverage by design file (source, deterministic)\n')
for (const r of rows.sort((a, b) => (a.total - a.missing.length) / a.total - (b.total - b.missing.length) / b.total)) {
  const cov = (r.total - r.missing.length) / r.total
  console.log(`${r.file.padEnd(20)} ${(cov * 100).toFixed(1).padStart(5)}%  ${String(r.total - r.missing.length).padStart(3)}/${String(r.total).padEnd(3)}  ${r.missing.slice(0, 5).join(' ')}${r.missing.length > 5 ? ' …' : ''}`)
}
const tot = rows.reduce((s, r) => s + r.total, 0)
const miss = rows.reduce((s, r) => s + r.missing.length, 0)
console.log(`\nTOTAL                ${((tot - miss) / tot * 100).toFixed(1).padStart(5)}%  ${tot - miss}/${tot} design components implemented; ${miss} missing`)
