// Custom properties the stylesheets read and nothing ever defines.
//
// An undefined `var()` fails silently and in two different ways. As a plain
// value it falls back to inheritance, so a status colour becomes body text. As
// an argument to `color-mix()` it is invalid at computed-value time, which
// unsets the whole property — a card loses its background and the console says
// nothing. `--color-status-bad` was referenced ten times in work-v2.css and
// defined nowhere, so Work's blocked state had never once rendered red.
//
// A source scan alone over-reports: Tailwind's theme defines `--text-sm` and
// friends outside these files. So the scan only proposes, and the browser
// decides — an empty `getPropertyValue` is the proof.
//
//   node e2e/design-parity-tokens.mjs
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { chromium } from 'playwright'

const LIVE = process.env.LIVE_BASE || 'http://localhost:5181/dashboard/#workspace'

function walk(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p, out); else if (p.endsWith('.css')) out.push(p)
  }
  return out
}

const files = walk('src')
const used = new Map()
const defined = new Set()
for (const p of files) {
  const t = readFileSync(p, 'utf8')
  // Only a bare `var(--x)` can fail. `var(--x, fallback)` is how this repo
  // records a rename in progress — work-v2.css maps every `--volt*` to
  // `var(--color-volt*, var(--color-accent))` on purpose — and the fallback
  // renders, so it is not a defect and must not be reported as one.
  for (const m of t.matchAll(/var\(\s*(--[a-z0-9-]+)\s*\)/g)) used.set(m[1], [...(used.get(m[1]) || []), p])
  for (const m of t.matchAll(/(--[a-z0-9-]+)\s*:/g)) defined.add(m[1])
}
// Two names survive a CSS-only scan without being dead. A name built by
// interpolation (`--fs-${n}`) leaves a stub ending in `-`. A name the components
// set per element (`style="--w: 40%"`, `setProperty('--dock-w', …)`) is real but
// lives on the element, so the root check below would call it undefined. Scan the
// components for assignments and drop both before asking the browser.
function walkTs(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) walkTs(p, out)
    else if (p.endsWith('.ts') && !p.endsWith('.test.ts')) out.push(p)
  }
  return out
}
const tsText = walkTs('src').map(p => readFileSync(p, 'utf8')).join('\n')
const assignedInTs = new Set(
  [...tsText.matchAll(/(--[a-z0-9-]+)\s*(?::|['"`]\s*,)/g)].map(m => m[1]),
)
const candidates = [...used.keys()].filter(
  n => !defined.has(n) && !n.endsWith('-') && !assignedInTs.has(n),
)

const b = await chromium.launch()
const p = await (await b.newContext()).newPage()
await p.goto(LIVE, { waitUntil: 'load', timeout: 60000 })
await p.waitForSelector('.v2-app', { timeout: 30000 })
await p.waitForTimeout(2500)
const values = await p.evaluate((names) => {
  const cs = getComputedStyle(document.documentElement)
  return names.map(n => [n, cs.getPropertyValue(n).trim()])
}, candidates)
await b.close()

const dead = values.filter(([, v]) => v === '').map(([n]) => n)
console.log(`${candidates.length} candidates from source; ${dead.length} confirmed undefined in the browser\n`)
const byFile = new Map()
for (const n of dead) for (const f of new Set(used.get(n))) byFile.set(f, [...(byFile.get(f) || []), n])
for (const [f, names] of [...byFile].sort((a, b) => b[1].length - a[1].length)) {
  console.log(`${f}\n    ${names.sort().join(' ')}`)
}
process.exit(dead.length ? 1 : 0)
