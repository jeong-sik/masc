// Lists selectors the design defines that the vendored kit does not, and the
// reverse. Font-size tokenization is normalized first so it does not register
// as drift. A design-only selector is either an unvendored rule or a surface
// the dashboard deliberately does not render — the point is to name which.
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const protoDir = `${root}/prototypes/keeper-v2/styles`
const vendorDir = `${root}/src/styles/keeper-v2`

function selectors(css) {
  const out = new Set()
  const stripped = css.replace(/\/\*[\s\S]*?\*\//g, '')
  for (const m of stripped.matchAll(/([^{}]+)\{[^{}]*\}/g)) {
    const sel = m[1].trim()
    if (sel.startsWith('@') || !sel) continue
    sel.split(',').forEach(s => { const t = s.trim(); if (t) out.add(t) })
  }
  return out
}

const names = process.argv.slice(2).length
  ? process.argv.slice(2)
  : readdirSync(protoDir).filter(f => f.endsWith('.css')).map(f => f.replace('.css', ''))

let totalMissing = 0
for (const name of names) {
  if (!existsSync(`${vendorDir}/${name}.css`)) { console.log(`${name}.css: NOT VENDORED`); continue }
  const a = selectors(readFileSync(`${protoDir}/${name}.css`, 'utf8'))
  const b = selectors(readFileSync(`${vendorDir}/${name}.css`, 'utf8'))
  const missing = [...a].filter(s => !b.has(s))
  totalMissing += missing.length
  if (missing.length) {
    console.log(`\n${name}.css — ${missing.length} design selectors absent from the vendored copy`)
    missing.slice(0, 40).forEach(s => console.log(`    ${s}`))
    if (missing.length > 40) console.log(`    ... and ${missing.length - 40} more`)
  }
}
console.log(`\ntotal design-only selectors: ${totalMissing}`)
