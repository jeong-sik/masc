// Finds selectors owned by both a legacy dashboard stylesheet and the vendored
// keeper-v2 kit. The kit loads last, so it wins on every property it restates —
// and silently inherits every property it does not. Those leftovers are the
// leaks: values from a superseded hand-port that still shape the surface.
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const stylesDir = resolve(here, '../src/styles')
const GEOMETRY = new Set([
  'padding', 'margin', 'height', 'width', 'min-height', 'min-width', 'max-height',
  'max-width', 'display', 'gap', 'grid-template-columns', 'flex-direction',
  'align-items', 'font-size', 'line-height', 'font-weight', 'border-radius',
])

function rules(css) {
  const map = new Map()
  const t = css.replace(/\/\*[\s\S]*?\*\//g, '')
  for (const m of t.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const sel = m[1].trim()
    if (sel.startsWith('@') || sel.includes('{')) continue
    const props = new Map()
    for (const d of m[2].split(';')) {
      const i = d.indexOf(':')
      if (i < 0) continue
      props.set(d.slice(0, i).trim(), d.slice(i + 1).trim())
    }
    for (const s of sel.split(',')) {
      const k = s.trim()
      if (!k) continue
      const prev = map.get(k) ?? new Map()
      for (const [p, v] of props) prev.set(p, v)
      map.set(k, prev)
    }
  }
  return map
}

const kit = new Map()
for (const f of readdirSync(`${stylesDir}/keeper-v2`).filter(f => f.endsWith('.css'))) {
  for (const [sel, props] of rules(readFileSync(`${stylesDir}/keeper-v2/${f}`, 'utf8'))) {
    const prev = kit.get(sel) ?? new Map()
    for (const [p, v] of props) prev.set(p, v)
    kit.set(sel, prev)
  }
}

const legacy = readdirSync(stylesDir).filter(f => f.endsWith('.css'))
let total = 0
for (const f of legacy) {
  const out = []
  for (const [sel, props] of rules(readFileSync(`${stylesDir}/${f}`, 'utf8'))) {
    const kitProps = kit.get(sel)
    if (!kitProps) continue
    const leaked = [...props.keys()].filter(p => GEOMETRY.has(p) && !kitProps.has(p))
    if (leaked.length) out.push(`    ${sel}  leaks: ${leaked.map(p => `${p}: ${props.get(p)}`).join('; ')}`)
  }
  if (out.length) { total += out.length; console.log(`${f} — ${out.length} shared selectors leak geometry into the kit`); out.slice(0, 12).forEach(l => console.log(l)); if (out.length > 12) console.log(`    ... and ${out.length - 12} more`) }
}
console.log(`\ntotal leaking selectors: ${total}`)
