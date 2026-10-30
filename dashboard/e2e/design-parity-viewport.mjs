// Lists elements that render differently AND fall inside the captured viewport.
// Only what is on screen moves the SSIM: the capture is 1600x1000, so a block
// at y=1934 can be repaired without the number changing at all.
import { chromium } from 'playwright'
import { VIEW_BY_ID } from './design-parity-views.mjs'

const [surface, limitRaw] = process.argv.slice(2)
const LIMIT = Number(limitRaw || 25)
const BASE = `http://127.0.0.1:${process.env.PARITY_PORT || 8978}/prototypes/keeper-v2`
const VIEWPORT = { width: 1600, height: 1000 }

const SNAP = `(() => {
  const out = {}
  const seen = Object.create(null)
  for (const el of document.querySelectorAll('.v2-app *')) {
    const r = el.getBoundingClientRect()
    if (r.bottom < 0 || r.top > ${VIEWPORT.height} || r.width === 0 || r.height === 0) continue
    const cls = (typeof el.className === 'string' ? el.className : '').trim().split(/\\s+/).slice(0, 3).join('.')
    const key = (cls || el.tagName) + '#' + (seen[cls] = (seen[cls] || 0) + 1)
    out[key] = [r.x, r.y, r.width, r.height].map(v => Math.round(v * 100) / 100)
  }
  return out
})()`

const b = await chromium.launch()
const c = await b.newContext({ viewport: VIEWPORT, deviceScaleFactor: 1 })
await c.addInitScript(() => {
  window.MASC_NOTIFY = { channel: '없음', on: {} }
  const interval = window.setInterval.bind(window)
  window.setInterval = (fn, ms, ...rest) => (Number(ms) >= 1000 ? 0 : interval(fn, ms, ...rest))
})
const snaps = {}
for (const [k, f] of [['design', 'Keeper%20Agent%20v5.html'], ['live', '_parity-vendored.html']]) {
  const p = await c.newPage()
  const view = VIEW_BY_ID.get(surface)
  await p.goto(`${BASE}/${f}?surface=${view ? view.surface : surface}`, { waitUntil: 'load', timeout: 45000 })
  await p.waitForSelector('.v2-app', { timeout: 30000 })
  await p.evaluate(() => document.fonts.ready)
  await p.waitForTimeout(2500)
  for (const selector of view?.clicks ?? []) {
    await p.waitForSelector(selector, { timeout: 15000 })
    await p.click(selector)
    await p.waitForTimeout(900)
  }
  await p.evaluate(() => { for (const el of document.querySelectorAll('.thread')) el.scrollTop = el.scrollHeight })
  await p.waitForTimeout(300)
  snaps[k] = await p.evaluate(SNAP)
  await p.close()
}
await b.close()

const rows = []
for (const key of Object.keys(snaps.design)) {
  const a = snaps.design[key], z = snaps.live[key]
  if (!z) { rows.push([key, 'only on the design page', 0]); continue }
  const d = a.map((v, i) => Math.round((z[i] - v) * 100) / 100)
  const worst = Math.max(...d.map(Math.abs))
  if (worst > 0.6) rows.push([key, `Δx=${d[0]} Δy=${d[1]} Δw=${d[2]} Δh=${d[3]}  (design y=${a[1]})`, worst])
}
rows.sort((p, q) => q[2] - p[2])
console.log(`${surface}: ${rows.length} in-viewport elements differ`)
for (const [k, why] of rows.slice(0, LIMIT)) console.log(`  ${k.padEnd(42)} ${why}`)
