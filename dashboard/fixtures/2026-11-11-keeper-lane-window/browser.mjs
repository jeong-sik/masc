// Drives fixture.html in headless Chromium (#26606).
//
//   cd dashboard && node fixtures/2026-11-11-keeper-lane-window/browser.mjs
//
// LANE_WINDOW_ROWS sets the rows per Keeper (default 5000). Measurements are
// written before any expectation is checked, so the same run also records the
// numbers of a build that fails them.

import assert from 'node:assert/strict'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright'
import { createServer } from 'vite'
import { artifactDirectory } from '../artifact-output.mjs'

const ROWS = Number(process.env.LANE_WINDOW_ROWS ?? 5000)
const REFRESH_SAMPLES = 9
/** The dev server transforms the whole module graph on the first request. */
const COLD_START_TIMEOUT_MS = 120_000
const SELECTORS = {
  list: '[aria-label="대기 나이순 작업 흐름"]',
  row: '[data-testid="keeper-lane-waiting-row"]',
  what: '[data-testid="keeper-lane-waiting-what"]',
}

const out = await artifactDirectory(import.meta.url)
const root = fileURLToPath(new URL('../..', import.meta.url))
const cacheDir = await mkdtemp(join(tmpdir(), 'masc-keeper-lane-window-'))
// The fixture reads no backend; an unroutable proxy target keeps it that way.
process.env.MASC_DASHBOARD_PROXY_TARGET = 'http://127.0.0.1:1'
const server = await createServer({
  root,
  cacheDir,
  configFile: `${root}vite.config.ts`,
  server: { host: '127.0.0.1', port: 0, watch: null },
})
await server.listen()
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
page.setDefaultTimeout(15_000)
const errors = []
page.on('pageerror', error => errors.push(error.message))
page.on('console', message => {
  if (message.type() === 'error') errors.push(message.text())
})

const list = page.locator(SELECTORS.list)
const rowNamed = text => page.locator(SELECTORS.row).filter({
  has: page.locator(SELECTORS.what).filter({ hasText: new RegExp(`^${text}$`) }),
})
const frames = () => page.evaluate(() => new Promise(resolve => {
  requestAnimationFrame(() => requestAnimationFrame(() => resolve(undefined)))
}))
const serials = async () => {
  const first = await page.evaluate(() => window.laneFixture.firstSerial())
  return { first, last: first + ROWS - 1 }
}

/** Scrolls the list to one edge the way an operator keeps scrolling: again
 *  until the list stays there. A windowed list measures rows as they mount,
 *  so its content height, and with it the end, settles over a few scrolls.
 *  Returns how many scrolls it took. */
async function scrollToEdge(edge) {
  const atEdge = () => list.evaluate((element, to) => (to === 'end'
    ? element.scrollHeight - element.clientHeight - element.scrollTop <= 1
    : element.scrollTop === 0), edge)
  for (let scrolls = 1; scrolls <= 40; scrolls += 1) {
    await list.evaluate((element, to) => {
      element.scrollTop = to === 'end' ? element.scrollHeight : 0
    }, edge)
    await frames()
    await frames()
    if (!(await atEdge())) continue
    await frames()
    if (await atEdge()) return scrolls
  }
  throw new Error(`the list did not settle at its ${edge}`)
}

/** Mounted rows, and how many of them sit more than one list height away from
 *  the list's visible box. A windowed list mounts none that far out. */
const mountedRows = () => page.evaluate(({ list: listSelector, row }) => {
  const box = document.querySelector(listSelector).getBoundingClientRect()
  const rows = [...document.querySelectorAll(row)].map(element => element.getBoundingClientRect())
  return {
    mounted: rows.length,
    farFromViewport: rows.filter(rect => rect.bottom < box.top - box.height || rect.top > box.bottom + box.height).length,
  }
}, SELECTORS)

const inView = text => page.evaluate(({ list: listSelector, row, what, text: wanted }) => {
  const box = document.querySelector(listSelector).getBoundingClientRect()
  const cell = [...document.querySelectorAll(what)].find(element => element.textContent === wanted)
  const rect = cell?.closest(row)?.getBoundingClientRect()
  return rect !== undefined && rect.top >= box.top - 1 && rect.top < box.bottom
}, { ...SELECTORS, text })

const measurements = { rowsPerKeeper: ROWS }
const checks = []
try {
  await page.goto(
    `${server.resolvedUrls.local[0]}fixtures/2026-11-11-keeper-lane-window/fixture.html?rows=${ROWS}`,
    { timeout: COLD_START_TIMEOUT_MS },
  )
  await list.waitFor()
  await frames()

  measurements.initial = {
    ...(await mountedRows()),
    listClientHeightPx: await list.evaluate(element => element.clientHeight),
    listScrollHeightPx: await list.evaluate(element => element.scrollHeight),
    // Distance between the tops of the first two collapsed rows: row plus gap.
    collapsedRowPitchPx: await page.evaluate(row => {
      const [first, second] = document.querySelectorAll(row)
      return second.getBoundingClientRect().top - first.getBoundingClientRect().top
    }, SELECTORS.row),
  }

  const samplesMs = []
  for (let sample = 0; sample < REFRESH_SAMPLES; sample += 1) {
    samplesMs.push(await page.evaluate(() => window.laneFixture.refresh()))
    await frames()
  }
  const sorted = [...samplesMs].sort((left, right) => left - right)
  measurements.refresh = { samplesMs, medianMs: sorted[Math.floor(sorted.length / 2)] }

  const alpha = await serials()
  const scrollsToSettle = await scrollToEdge('end')
  measurements.end = {
    scrollsToSettle,
    ...(await mountedRows()),
    lastRowInView: await inView(`alpha 작업 ${alpha.last}`),
    firstRowMounted: await rowNamed(`alpha 작업 ${alpha.first}`).count() > 0,
  }
  const last = rowNamed(`alpha 작업 ${alpha.last}`)
  await last.locator('summary').click()
  await last.getByRole('button', { name: 'normal', exact: true }).click()
  measurements.end.operatedSourceIncarnation = await page.evaluate(
    () => window.laneFixture.operations.at(-1)?.operation.sourceIncarnation ?? null,
  )
  await page.screenshot({ path: `${out}list-end.png`, fullPage: true })

  await scrollToEdge('start')
  const first = rowNamed(`alpha 작업 ${alpha.first}`)
  await first.locator('summary').click()
  await first.getByRole('button', { name: 'normal', exact: true }).focus()
  await scrollToEdge('end')
  measurements.focus = {
    afterFocusedRowLeft: await page.evaluate(({ list: listSelector, row }) => {
      const active = document.activeElement
      if (active === null || active === document.body) return 'body'
      if (active.matches(listSelector)) return 'list'
      return active.closest(row) ? 'row' : active.tagName.toLowerCase()
    }, SELECTORS),
  }
  await scrollToEdge('start')
  measurements.expansion = {
    firstRowOpenAfterReturn: await rowNamed(`alpha 작업 ${alpha.first}`).evaluate(element => element.open),
  }

  await scrollToEdge('end')
  const scrollTopBeforePx = await list.evaluate(element => element.scrollTop)
  await page.getByTestId('fixture-keeper-beta').click()
  await frames()
  const beta = await serials()
  measurements.keeperSwitch = {
    scrollTopBeforePx,
    scrollTopAfterPx: await list.evaluate(element => element.scrollTop),
    firstRowInView: await inView(`beta 작업 ${beta.first}`),
    openRows: await page.locator(`${SELECTORS.row}[open]`).count(),
  }
  await page.screenshot({ path: `${out}keeper-switch.png`, fullPage: true })

  measurements.errors = errors
  await writeFile(`${out}measurements.json`, `${JSON.stringify(measurements, null, 2)}\n`)

  assert.equal(measurements.initial.farFromViewport, 0)
  assert.ok(measurements.initial.mounted < ROWS)
  checks.push('a large inventory mounts only the rows near the list viewport')
  assert.equal(measurements.end.farFromViewport, 0)
  assert.equal(measurements.end.lastRowInView, true)
  assert.equal(measurements.end.firstRowMounted, false)
  assert.equal(measurements.end.operatedSourceIncarnation, String(alpha.last + 1))
  checks.push('the last server row is reachable by scrolling and acts on its own address')
  assert.equal(measurements.focus.afterFocusedRowLeft, 'list')
  checks.push('keyboard focus moves to the list when the focused row leaves the window')
  assert.equal(measurements.expansion.firstRowOpenAfterReturn, true)
  checks.push('a row opened by the operator is still open after it leaves the window and returns')
  assert.equal(measurements.keeperSwitch.scrollTopAfterPx, 0)
  assert.equal(measurements.keeperSwitch.firstRowInView, true)
  assert.equal(measurements.keeperSwitch.openRows, 0)
  checks.push('another Keeper starts at its first row with nothing open')
  assert.deepEqual(errors, [])

  const result = {
    passed: true,
    scope: 'Actual styled KeeperLaneStrip over a synthetic inventory in headless Chromium. No backend, live Keeper, inventory store, or SSE refresh.',
    browser: browser.version(),
    checks,
    measurements,
  }
  await writeFile(`${out}browser-result.json`, `${JSON.stringify(result, null, 2)}\n`)
  console.log(JSON.stringify({ passed: true, checks, measurements }))
} catch (error) {
  await writeFile(`${out}browser-failure.json`, `${JSON.stringify({ error: String(error), checks, measurements, errors }, null, 2)}\n`)
  await page.screenshot({ path: `${out}browser-failure.png`, fullPage: true })
  throw error
} finally {
  await browser.close()
  await server.close()
  await rm(cacheDir, { recursive: true, force: true })
}
