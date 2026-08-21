// Design-parity screenshot harness.
// Usage: node shot.mjs <label> <baseUrlTemplate> <outDir> <surface[,surface...]>
//   baseUrlTemplate contains {s}, replaced by the surface id.
import { chromium } from 'playwright'
import { mkdirSync } from 'node:fs'

const [label, tmpl, outDir, surfaceCsv] = process.argv.slice(2)
if (!label || !tmpl || !outDir || !surfaceCsv) {
  console.error('usage: node shot.mjs <label> <urlTemplate{s}> <outDir> <surfaces,csv>')
  process.exit(2)
}
const surfaces = surfaceCsv.split(',').filter(Boolean)
mkdirSync(outDir, { recursive: true })

const VIEWPORT = { width: 1600, height: 1000 }
const browser = await chromium.launch()
const ctx = await browser.newContext({ viewport: VIEWPORT, deviceScaleFactor: 1, colorScheme: 'dark' })
const page = await ctx.newPage()
const errors = []
page.on('pageerror', e => errors.push(String(e).slice(0, 200)))

for (const s of surfaces) {
  const url = tmpl.replaceAll('{s}', s)
  try {
    await page.goto(url, { waitUntil: 'load', timeout: 45000 })
    // The shell root differs between the two apps; wait for whichever appears.
    await page.waitForSelector('.v2-app, #app > *, #root > *', { timeout: 30000 })
    await page.waitForTimeout(2500)
    // Freeze animations so repeat runs are byte-stable.
    await page.addStyleTag({ content: '*,*::before,*::after{animation:none !important;transition:none !important;caret-color:transparent !important}' })
    await page.waitForTimeout(400)
    await page.screenshot({ path: `${outDir}/${label}-${s}.png` })
    console.log(`ok   ${label}/${s}`)
  } catch (e) {
    console.log(`FAIL ${label}/${s}: ${String(e).split('\n')[0].slice(0, 160)}`)
  }
}
if (errors.length) console.log(`pageerrors(${errors.length}): ${errors.slice(0, 3).join(' | ')}`)
await browser.close()
