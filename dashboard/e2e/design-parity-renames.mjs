// Design components the dashboard already built under another name.
//
// `design-parity-components.mjs` reports what is missing; most of it is genuinely
// unbuilt. This separates the cheap subset: the dashboard renders the component,
// spells it differently, and the vendored CSS therefore lands on nothing. Those
// are renames — the same move already made for `.chip` → `.tag-chip` and
// `.ide-v2-rail-tab` → `.ide-rail-tab` — and each one activates stylesheet rules
// that are already in the bundle.
//
// The match test is subsequence-either-way on the de-hyphenated name, which is
// what abbreviation and expansion look like: `ap-hist-row` → `aphistrow` is a
// subsequence of `ap-history-row` → `aphistoryrow`. Proposals, not conclusions —
// each pair still has to be read.
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

const UTILITY = /^(is-|has-|on$|active|open|flex|grid|items-|justify-|text-|bg-|px-|py-|mx-|my-|mt-|mb-|ml-|mr-|pt-|pb-|pl-|pr-|gap-|w-|h-|min-|max-|rounded|border|shrink|grow|absolute|relative|inline|hidden|overflow|whitespace|font-|leading-|tracking-|truncate|select-|cursor-|transition|group|size-|self-|space-|animate|fade|slide|zoom|duration|delay|ease|fill-mode|sr-only|skip-link|order-|z-|top-|left-|right-|bottom-|opacity-|shadow|ring|outline|pointer-|touch-|scroll-|snap-|list-|align-|place-|col-|row-|basis-|object-|aspect-|backdrop|filter|blur|contrast|invert|saturate|sepia|origin-|rotate-|scale-|translate|skew-|first|last|only|odd|even|visited|checked|disabled|indeterminate|placeholder|before|after|marker|file|selection|caret|accent|appearance|resize|will-change|content-)/

function walk(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p, out); else out.push(p)
  }
  return out
}
function classLiterals(text) {
  const out = new Set()
  for (const m of text.matchAll(/class(?:Name)?\s*=\s*(?:"([^"]*)"|'([^']*)'|\{`([^`]*)`\}|\{([^}]*)\}|`([^`]*)`)/g)) {
    const body = m[1] ?? m[2] ?? m[3] ?? m[4] ?? m[5] ?? ''
    for (const tok of body.replace(/\$\{[^}]*\}/g, ' ').split(/[\s"'`+?:()]+/)) {
      const c = tok.trim()
      if (!c || c.length < 4 || UTILITY.test(c)) continue
      if (!/^[a-z][a-z0-9-]*[a-z0-9]$/.test(c)) continue
      out.add(c)
    }
  }
  return out
}

const design = new Map()
for (const f of readdirSync('prototypes/keeper-v2').filter(f => f.endsWith('.jsx'))) {
  for (const c of classLiterals(readFileSync(join('prototypes/keeper-v2', f), 'utf8'))) {
    if (!design.has(c)) design.set(c, f.replace(/\.jsx$/, ''))
  }
}
const liveFiles = walk('src').filter(p => p.endsWith('.ts') && !p.endsWith('.test.ts'))
const liveText = liveFiles.map(p => readFileSync(p, 'utf8')).join('\n')
const live = new Map()
for (const p of liveFiles) for (const c of classLiterals(readFileSync(p, 'utf8'))) if (!live.has(c)) live.set(c, p)
const has = c => new RegExp(`(^|[^a-z0-9-])${c}([^a-z0-9-]|$)`).test(liveText)

const flat = s => s.replace(/-/g, '')
const isSub = (a, b) => { let i = 0; for (const ch of b) if (ch === a[i]) i++; return i === a.length }

const pairs = []
for (const [d, file] of design) {
  if (has(d)) continue
  const fd = flat(d)
  for (const [l] of live) {
    const fl = flat(l)
    if (fd === fl) continue
    const ratio = fd.length / fl.length
    if (ratio < 0.5 || ratio > 2) continue
    if (!(isSub(fd, fl) || isSub(fl, fd))) continue
    pairs.push({ d, l, file, where: live.get(l) })
  }
}
const byDesign = new Map()
for (const p of pairs) byDesign.set(p.d, [...(byDesign.get(p.d) || []), p])
console.log(`${byDesign.size} missing design components have a plausible live counterpart\n`)
const byFile = new Map()
for (const [d, ps] of byDesign) byFile.set(ps[0].file, [...(byFile.get(ps[0].file) || []), [d, ps]])
for (const [file, entries] of [...byFile].sort((a, b) => b[1].length - a[1].length)) {
  console.log(`\n${file} (${entries.length})`)
  for (const [d, ps] of entries.sort()) {
    console.log(`  .${d.padEnd(22)} ← ${ps.slice(0, 3).map(p => '.' + p.l).join(' | ')}`)
  }
}
