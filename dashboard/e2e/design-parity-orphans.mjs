// Vendored CSS with nothing to style.
//
// The mirror of `design-parity-components.mjs`. That probe asks which design
// components the dashboard never renders; this one asks what the vendored kit
// paints for them anyway. A stylesheet copied from the design scores perfectly
// on the parity page — which renders the design's DOM — while landing on nothing
// in the app. `lanes.css` is the case that prompted this: 0.959 SSIM, and not one
// `dl-` class anywhere in src.
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

const KIT = 'src/styles/keeper-v2'
const SRC = 'src'

function walk(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else out.push(p)
  }
  return out
}
const liveText = walk(SRC).filter(p => p.endsWith('.ts') && !p.endsWith('.test.ts'))
  .map(p => readFileSync(p, 'utf8')).join('\n')
const has = c => new RegExp(`(^|[^a-z0-9-])${c}([^a-z0-9-]|$)`).test(liveText)

const rows = []
for (const f of readdirSync(KIT).filter(f => f.endsWith('.css'))) {
  const css = readFileSync(join(KIT, f), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
  const classes = new Set([...css.matchAll(/\.([a-z][a-z0-9-]{2,})/g)].map(m => m[1]))
  if (!classes.size) continue
  const orphan = [...classes].filter(c => !has(c)).sort()
  rows.push({ f, total: classes.size, orphan })
}
console.log('vendored kit selectors with no consumer in src\n')
for (const r of rows.sort((a, b) => b.orphan.length / b.total - a.orphan.length / a.total)) {
  console.log(`${r.f.padEnd(20)} ${(r.orphan.length / r.total * 100).toFixed(0).padStart(3)}% orphan  ${String(r.orphan.length).padStart(3)}/${String(r.total).padEnd(3)}  ${r.orphan.slice(0, 4).join(' ')}${r.orphan.length > 4 ? ' …' : ''}`)
}
const t = rows.reduce((s, r) => s + r.total, 0), o = rows.reduce((s, r) => s + r.orphan.length, 0)
console.log(`\nTOTAL                ${(o / t * 100).toFixed(0).padStart(3)}% orphan  ${o}/${t}`)
