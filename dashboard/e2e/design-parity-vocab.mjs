// Names the design components the dashboard does not render at all.
//
// The SSIM harness renders the prototype's DOM twice and swaps only the CSS, so
// it measures the skin and nothing else. That is deliberate — it is what removes
// the data variable — but it also means a surface the dashboard rebuilt under
// different markup cannot lower the score, because the parity page never renders
// the dashboard's markup. This probe reads the live app instead and asks the
// question the SSIM number structurally cannot: which of the design's components
// does the dashboard speak, and which did it re-implement under other names.
//
//   node e2e/design-parity-vocab.mjs overview:overview work:workspace …
//
// Coverage is |design ∩ live| / |design| over visible component classes.
import { chromium } from 'playwright'
import { VISIBLE_COMPONENT_CLASSES, family } from './design-parity-classes.mjs'

const PROTO = process.env.PROTO_BASE || 'http://127.0.0.1:8979/prototypes/keeper-v2/Keeper%20Agent%20v5.html?surface='
const LIVE = process.env.LIVE_BASE || 'http://localhost:5181/dashboard/#'

const b = await chromium.launch()
const c = await b.newContext({ viewport: { width: 1600, height: 1000 } })

async function classesAt(url) {
  const p = await c.newPage()
  try {
    await p.goto(url, { waitUntil: 'load', timeout: 60000 })
    await p.waitForSelector('.v2-app', { timeout: 30000 })
    // The live app renders components as data arrives, so a fixed wait samples a
    // half-loaded surface and the count moves between runs. Two consecutive
    // identical samples is the same gate the screenshot harness uses.
    let prev = null
    for (let i = 0; i < 40; i++) {
      await p.waitForTimeout(500)
      const now = await p.evaluate(VISIBLE_COMPONENT_CLASSES)
      const key = now.slice().sort().join(',')
      if (prev === key) return new Set(now)
      prev = key
    }
    throw new Error('component set never settled in 20s')
  } catch (e) {
    console.error(`  ! ${url} — ${e.message.split('\n')[0]}`)
    return null
  } finally { await p.close() }
}

const rows = []
const missingEverywhere = new Map()

for (const [protoSurface, liveSurface] of process.argv.slice(2).map(a => a.split(':'))) {
  const design = await classesAt(PROTO + protoSurface)
  const live = await classesAt(LIVE + (liveSurface || protoSurface))
  if (!design || !live || design.size === 0) { console.log(`${protoSurface}\tSKIPPED`); continue }
  const missing = [...design].filter(x => !live.has(x)).sort()
  const cov = (design.size - missing.length) / design.size
  rows.push({ surface: protoSurface, cov, missing: missing.length, design: design.size })
  console.log(`\n${protoSurface} → ${(cov * 100).toFixed(1)}% of the design's ${design.size} components rendered; ${missing.length} missing`)
  const byFamily = new Map()
  for (const m of missing) {
    byFamily.set(family(m), [...(byFamily.get(family(m)) || []), m])
    missingEverywhere.set(m, [...(missingEverywhere.get(m) || []), protoSurface])
  }
  for (const [fam, members] of [...byFamily].sort((a, b) => b[1].length - a[1].length)) {
    console.log(`    ${fam.padEnd(24)} ${members.length}  ${members.slice(0, 6).join(' ')}${members.length > 6 ? ' …' : ''}`)
  }
}

console.log('\n=== component coverage ===')
for (const r of rows.sort((a, b) => a.cov - b.cov)) {
  console.log(`${r.surface.padEnd(12)} ${(r.cov * 100).toFixed(1).padStart(5)}%   ${r.design - r.missing}/${r.design}`)
}
const totDesign = rows.reduce((s, r) => s + r.design, 0)
const totMissing = rows.reduce((s, r) => s + r.missing, 0)
console.log(`MEAN         ${(rows.reduce((s, r) => s + r.cov, 0) / rows.length * 100).toFixed(1).padStart(5)}%   ${totDesign - totMissing}/${totDesign} across ${rows.length} surfaces`)

// A class the design draws on most surfaces is shell vocabulary: one component,
// counted once per surface. Separating it keeps a single shell decision from
// reading as a dozen independent rewrites.
console.log('\n=== missing on how many surfaces ===')
const spread = [...missingEverywhere].sort((a, b) => b[1].length - a[1].length)
for (const [cls, where] of spread.filter(([, w]) => w.length >= 3)) {
  console.log(`${String(where.length).padStart(2)}x  .${cls.padEnd(22)} ${where.join(' ')}`)
}
const shellWide = new Set(spread.filter(([, w]) => w.length >= rows.length - 2).map(([c]) => c))
console.log(`\nshell-wide (missing on >= ${rows.length - 2} of ${rows.length}): ${shellWide.size} classes`)
console.log(`surface-specific missing: ${totMissing - [...missingEverywhere].filter(([c]) => shellWide.has(c)).reduce((s, [, w]) => s + w.length, 0)} of ${totMissing}`)
await b.close()
