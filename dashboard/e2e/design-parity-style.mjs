// Style-conformance probe: renders the design page and the parity page (same
// DOM, same mock data) and compares getComputedStyle for every element that
// carries a class, keyed by a stable DOM path. Reports per-property mismatch
// counts so a skin delta is named, not guessed.
import { chromium } from 'playwright'

const [protoUrl, liveUrl, surfaceCsv] = process.argv.slice(2)
const surfaces = (surfaceCsv || 'overview').split(',')

const PROPS = [
  'color', 'background-color', 'border-color', 'border-width', 'border-radius',
  'font-family', 'font-size', 'font-weight', 'letter-spacing', 'line-height',
  'padding', 'margin', 'gap', 'width', 'height', 'box-shadow', 'opacity',
  'text-transform', 'display', 'grid-template-columns', 'max-width',
]

const SNAP = `(() => {
  const out = {}
  const seen = Object.create(null)
  for (const el of document.querySelectorAll('[class]')) {
    const cls = (typeof el.className === 'string' ? el.className : '').trim().split(/\\s+/).slice(0, 3).join('.')
    if (!cls) continue
    const n = (seen[cls] = (seen[cls] || 0) + 1)
    if (n > 3) continue
    const key = cls + '#' + n
    const cs = getComputedStyle(el)
    const rec = {}
    for (const p of ${JSON.stringify(PROPS)}) rec[p] = cs.getPropertyValue(p)
    out[key] = rec
  }
  return out
})()`

const browser = await chromium.launch()
const ctx = await browser.newContext({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 1 })

async function snap(url) {
  const page = await ctx.newPage()
  await page.goto(url, { waitUntil: 'load', timeout: 45000 })
  await page.waitForSelector('.v2-app', { timeout: 30000 })
  await page.waitForTimeout(2000)
  const r = await page.evaluate(SNAP)
  await page.close()
  return r
}

const byProp = new Map()
const examples = []
let total = 0, bad = 0
for (const s of surfaces) {
  const a = await snap(protoUrl.replaceAll('{s}', s))
  const b = await snap(liveUrl.replaceAll('{s}', s))
  for (const key of Object.keys(a)) {
    if (!b[key]) continue
    for (const p of PROPS) {
      total++
      if (a[key][p] !== b[key][p]) {
        bad++
        byProp.set(p, (byProp.get(p) || 0) + 1)
        if (examples.length < 4000) examples.push(`${s} ${key} ${p}: design="${a[key][p]}" live="${b[key][p]}"`)
      }
    }
  }
}
await browser.close()
console.log(`conformance ${(100 * (1 - bad / total)).toFixed(2)}%  (${total - bad}/${total} declarations match)`)
console.log('--- mismatches by property ---')
for (const [p, n] of [...byProp].sort((x, y) => y[1] - x[1])) console.log(`${String(n).padStart(5)}  ${p}`)
if (process.env.PARITY_EXAMPLES) {
  console.log('--- examples ---')
  for (const e of examples.slice(0, Number(process.env.PARITY_EXAMPLES))) console.log(e)
}
