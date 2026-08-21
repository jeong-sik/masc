// Compares the rendered box of named selectors between the design page and the
// parity page. `design-parity-style.mjs` says WHICH property differs; this says
// where the element actually landed, which is what a cumulative offset needs.
import { chromium } from 'playwright'

// Port is configurable so a second worktree can serve its own tree alongside.
const BASE = `http://127.0.0.1:${process.env.PARITY_PORT || 8978}/prototypes/keeper-v2`
const [surface, ...sels] = process.argv.slice(2)
const pages = { design: 'Keeper%20Agent%20v5.html', live: '_parity-vendored.html' }
const b = await chromium.launch()
const c = await b.newContext({ viewport: { width: 1600, height: 1000 } })
const res = {}
for (const [k, f] of Object.entries(pages)) {
  const p = await c.newPage()
  await p.goto(`${BASE}/${f}?surface=${surface}`, { waitUntil: 'load', timeout: 45000 })
  await p.waitForSelector('.v2-app', { timeout: 30000 })
  await p.waitForTimeout(1800)
  res[k] = await p.evaluate((sels) => sels.map((sel) => {
    const el = document.querySelector(sel)
    if (!el) return `${sel}: ABSENT`
    const cs = getComputedStyle(el), r = el.getBoundingClientRect()
    return `${sel} h=${r.height.toFixed(2)} w=${r.width.toFixed(2)} x=${r.x.toFixed(1)} y=${r.y.toFixed(1)} pad=${cs.padding} lh=${cs.lineHeight} fs=${cs.fontSize} bg=${cs.backgroundColor} border=${cs.borderWidth}`
  }), sels)
  await p.close()
}
await b.close()
for (let i = 0; i < sels.length; i++) {
  const same = res.design[i] === res.live[i]
  console.log(`${same ? '=' : 'D'} ${res.design[i]}`)
  if (!same) console.log(`L ${res.live[i]}`)
  console.log()
}
