// Design-parity screenshot harness.
// Usage: node design-parity-shot.mjs <label> <baseUrlTemplate> <outDir> <surface[,surface...]>
//   baseUrlTemplate contains {s}, replaced by the surface id.
//
// The prototype is a live mock, not a static page: `alarm.jsx` fires an ambient
// notification five seconds after load and every sixteen after that, and
// `shell.jsx` re-rolls a random tok/s figure every 1.1s. Either can land inside
// the capture window — and does so more often on the parity page, whose single
// compiled stylesheet delays first paint — which moved a keepers measurement by
// 15pp between runs of the same page. So: the notification channel is switched
// off through the prototype's own `window.MASC_NOTIFY` knob before any script
// runs, and a frame is only accepted once two consecutive captures are
// byte-identical. Both sides then reproduce exactly.
import { chromium } from 'playwright'
import { mkdirSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'

const [label, tmpl, outDir, surfaceCsv] = process.argv.slice(2)
if (!label || !tmpl || !outDir || !surfaceCsv) {
  console.error('usage: node design-parity-shot.mjs <label> <urlTemplate{s}> <outDir> <surfaces,csv>')
  process.exit(2)
}
const surfaces = surfaceCsv.split(',').filter(Boolean)
mkdirSync(outDir, { recursive: true })

const VIEWPORT = { width: Number(process.env.PARITY_W || 1600), height: Number(process.env.PARITY_H || 1000) }
const FREEZE = '*,*::before,*::after{animation:none !important;transition:none !important;caret-color:transparent !important}'
const MAX_SETTLE_ATTEMPTS = 12

const browser = await chromium.launch()
const ctx = await browser.newContext({ viewport: VIEWPORT, deviceScaleFactor: 1, colorScheme: 'dark' })
await ctx.addInitScript(() => {
  // The prototype reads this on every alarm tick; '없음' is its own "no channel".
  window.MASC_NOTIFY = { channel: '없음', on: {} }
  // Stop the repeating simulation. `shell.jsx` re-rolls a random tok/s figure
  // every 1.1s, so the page never reaches a state it can be compared in. The
  // one-shot timers stay: the FSM phase advance (`act.ms || 1500`) is part of
  // the state the design settles into, and the capture waits past it.
  const SIM_TIMER_MS = 1000
  const interval = window.setInterval.bind(window)
  window.setInterval = (fn, ms, ...rest) => (Number(ms) >= SIM_TIMER_MS ? 0 : interval(fn, ms, ...rest))
})
const page = await ctx.newPage()
const errors = []
page.on('pageerror', e => errors.push(String(e).slice(0, 200)))

const digest = buf => createHash('sha1').update(buf).digest('hex')

for (const s of surfaces) {
  const url = tmpl.replaceAll('{s}', s)
  try {
    await page.goto(url, { waitUntil: 'load', timeout: 45000 })
    await page.waitForSelector('.v2-app, #app > *, #root > *', { timeout: 30000 })
    // Cinzel and Noto Sans KR change every metric on the page. On a cold cache
    // they land after the capture window and the page settles on fallback
    // metrics instead — which is what made the first run of a session score
    // 4pp apart from every run after it.
    await page.evaluate(() => document.fonts.ready)
    await page.waitForTimeout(2500)
    await page.addStyleTag({ content: FREEZE })
    // The chat thread is bottom-anchored, and its scroll-to-bottom races the
    // layout: it settles at the bottom (scrollTop 1907 of 1907) or at an earlier
    // anchor (185), and nothing after that moves it. Those two states differ by
    // the height of the visible column, which put 4pp between two runs of the
    // identical page. Pin it where the app means it to sit.
    await page.evaluate(() => {
      for (const el of document.querySelectorAll('.thread')) {
        el.scrollTop = el.scrollHeight
      }
    })

    let prev = null, shot = null, settled = 0
    for (let i = 0; i < MAX_SETTLE_ATTEMPTS; i++) {
      await page.waitForTimeout(500)
      shot = await page.screenshot()
      if (prev && digest(prev) === digest(shot)) { settled = i + 1; break }
      prev = shot
    }
    if (!settled) {
      console.log(`WARN ${label}/${s}: never produced two identical consecutive frames in ${MAX_SETTLE_ATTEMPTS} tries`)
    }
    writeFileSync(`${outDir}/${label}-${s}.png`, shot)
    console.log(`ok   ${label}/${s}${settled ? '' : ' (unsettled)'}`)
  } catch (e) {
    console.log(`FAIL ${label}/${s}: ${String(e).split('\n')[0].slice(0, 160)}`)
  }
}
if (errors.length) console.log(`pageerrors(${errors.length}): ${errors.slice(0, 3).join(' | ')}`)
await browser.close()
