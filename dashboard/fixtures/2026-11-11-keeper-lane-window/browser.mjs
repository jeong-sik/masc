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
/** Idle time after a refresh in which the work it scheduled finishes. */
const REFRESH_SETTLE_MS = 100
/** Rows the Keeper consumes in one batch while the list sits at its end. */
const CONSUMED_ROWS = 200
/** Few enough rows that the list keeps every one of them mounted. */
const SHORT_LIST_ROWS = 5
/** Which row of the short list takes keyboard focus, counted from 0. The
 *  second row stands for every row below the first: the first starts at the
 *  list's top edge, which cuts the top of its focus ring whether or not the
 *  list windows. */
const SHORT_LIST_FOCUSED_ROW = 1
/** The row bars are the tab stops after the 기술 상세 toggle. A row left open
 *  above the focused one adds its five action buttons to the walk; this bounds
 *  the walk if something else takes focus first. */
const MAX_TAB_PRESSES = 10
if (ROWS <= CONSUMED_ROWS + SHORT_LIST_ROWS) {
  throw new Error(
    `LANE_WINDOW_ROWS must be above ${CONSUMED_ROWS + SHORT_LIST_ROWS}, and large enough that the list still windows after ${CONSUMED_ROWS} rows leave`,
  )
}
/** The dev server transforms the whole module graph on the first request. */
const COLD_START_TIMEOUT_MS = 120_000
const SELECTORS = {
  list: '[aria-label="대기 나이순 작업 흐름"]',
  axis: '[data-testid="keeper-lane-age-axis"]',
  axisLabel: '[data-axis-tick]',
  /** What VirtualList wraps the rows of a windowed list in. */
  windowedRows: '.virtual-list-spacer',
  row: '[data-testid="keeper-lane-waiting-row"]',
  bar: '[data-testid="keeper-lane-waiting-bar"]',
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

// Seconds the page's main thread has spent in tasks since it started.
const devtools = await page.context().newCDPSession(page)
await devtools.send('Performance.enable')
const mainThreadTaskSeconds = async () => {
  const { metrics } = await devtools.send('Performance.getMetrics')
  return metrics.find(metric => metric.name === 'TaskDuration').value
}

const list = page.locator(SELECTORS.list)
const rowNamed = text => page.locator(SELECTORS.row).filter({
  has: page.locator(SELECTORS.what).filter({ hasText: new RegExp(`^${text}$`) }),
})
const frames = () => page.evaluate(() => new Promise(resolve => {
  requestAnimationFrame(() => requestAnimationFrame(() => resolve(undefined)))
}))
const serials = async () => {
  const { first, count } = await page.evaluate(() => ({
    first: window.laneFixture.firstSerial(),
    count: window.laneFixture.rowCount(),
  }))
  return { first, last: first + count - 1 }
}
const operationsSent = () => page.evaluate(() => window.laneFixture.operations.length)

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

/** Where keyboard focus is: in a waiting row, on the list, or elsewhere. */
const focusPlace = () => page.evaluate(({ list: listSelector, row }) => {
  const active = document.activeElement
  if (active === null || active === document.body) return 'body'
  if (active.matches(listSelector)) return 'list'
  return active.closest(row) ? 'row' : active.tagName.toLowerCase()
}, SELECTORS)

const median = values => [...values].sort((left, right) => left - right)[Math.floor(values.length / 2)]

const measurements = { rowsPerKeeper: ROWS }
const checks = []
try {
  await page.goto(
    `${server.resolvedUrls.local[0]}fixtures/2026-11-11-keeper-lane-window/fixture.html?rows=${ROWS}`,
    { timeout: COLD_START_TIMEOUT_MS },
  )
  await list.waitFor()
  await page.evaluate(() => document.fonts.ready)
  await frames()

  measurements.initial = {
    ...(await mountedRows()),
    listClientHeightPx: await list.evaluate(element => element.clientHeight),
    listScrollHeightPx: await list.evaluate(element => element.scrollHeight),
    // A row scrolled past the list's top is cut at the list's top edge. The
    // age axis above it draws its labels below its own box, so this distance
    // is what keeps a cut row clear of them.
    listTopBelowAxisPx: await page.evaluate(({ list: listSelector, axis }) => (
      document.querySelector(listSelector).getBoundingClientRect().top
      - document.querySelector(axis).getBoundingClientRect().bottom
    ), SELECTORS),
    // How far below the axis box the ink of its labels reaches: the text
    // baseline of each label plus the descent of its glyphs.
    axisLabelInkBelowAxisPx: await page.evaluate(({ axis, axisLabel }) => {
      const context = document.createElement('canvas').getContext('2d')
      const inkBottoms = [...document.querySelectorAll(axisLabel)].map(label => {
        // An empty inline block sits on the text baseline of its line.
        const mark = document.createElement('span')
        mark.style.cssText = 'display:inline-block;width:0;height:0'
        label.append(mark)
        const baseline = mark.getBoundingClientRect().bottom
        mark.remove()
        const style = getComputedStyle(label)
        context.font = `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`
        return baseline + context.measureText(label.textContent).actualBoundingBoxDescent
      })
      return Math.max(...inkBottoms) - document.querySelector(axis).getBoundingClientRect().bottom
    }, SELECTORS),
    // Distance between the tops of the first two collapsed rows: row plus gap.
    collapsedRowPitchPx: await page.evaluate(row => {
      const [first, second] = document.querySelectorAll(row)
      return second.getBoundingClientRect().top - first.getBoundingClientRect().top
    }, SELECTORS.row),
  }

  // Two costs of one refresh. renderAndLayoutMs is what the fixture times:
  // the synchronous render and the layout it forces. mainThreadMs is every
  // task the page ran until it went idle again, which adds the effects, row
  // measurement and paint that follow the render. The same wait without a
  // refresh gives what this script itself adds to mainThreadMs.
  const mainThreadMsOf = async step => {
    const before = await mainThreadTaskSeconds()
    const result = await step()
    await frames()
    await page.waitForTimeout(REFRESH_SETTLE_MS)
    return { result, mainThreadMs: (await mainThreadTaskSeconds() - before) * 1000 }
  }
  const idle = []
  const samples = []
  for (let sample = 0; sample < REFRESH_SAMPLES; sample += 1) {
    idle.push((await mainThreadMsOf(() => page.evaluate(() => 0))).mainThreadMs)
    const refreshed = await mainThreadMsOf(() => page.evaluate(() => window.laneFixture.refresh()))
    samples.push({ renderAndLayoutMs: refreshed.result, mainThreadMs: refreshed.mainThreadMs })
  }
  measurements.refresh = {
    samples,
    medianRenderAndLayoutMs: median(samples.map(sample => sample.renderAndLayoutMs)),
    medianMainThreadMs: median(samples.map(sample => sample.mainThreadMs)),
    medianIdleMainThreadMs: median(idle),
  }

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
  measurements.focus = { afterFocusedRowLeft: await focusPlace() }
  await scrollToEdge('start')
  measurements.expansion = {
    firstRowOpenAfterReturn: await first.evaluate(element => element.open),
  }

  // The queue gives every pending event a new address while the operator has
  // a row open with focus on one of its buttons.
  await first.getByRole('button', { name: 'normal', exact: true }).focus()
  await page.evaluate(() => window.laneFixture.readdress())
  await frames()
  measurements.readdress = {
    rowOpen: await first.evaluate(element => element.open),
    focus: await focusPlace(),
    currentSourceIncarnation: await page.evaluate(
      serial => window.laneFixture.incarnationOf(serial), alpha.first,
    ),
  }
  const sentBefore = await operationsSent()
  await page.keyboard.press('Enter')
  measurements.readdress.operationsSent = await operationsSent() - sentBefore
  measurements.readdress.operatedSourceIncarnation = await page.evaluate(
    () => window.laneFixture.operations.at(-1)?.operation.sourceIncarnation ?? null,
  )

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

  // The Keeper consumes a batch while the list sits at its end. What the next
  // frame shows is read inside the first animation frame after the change,
  // before anything scheduled for after the paint has run. Work the list
  // queued for this same frame runs after this reading, so the reading can
  // only show the frame emptier than it is painted, never fuller.
  await scrollToEdge('end')
  measurements.consumedBatch = await page.evaluate(({ count, list: listSelector, row, windowedRows }) => new Promise(resolve => {
    window.laneFixture.consume(count)
    requestAnimationFrame(() => {
      const element = document.querySelector(listSelector)
      const top = element.getBoundingClientRect().top + element.clientTop
      const bottom = top + element.clientHeight
      const shown = [...document.querySelectorAll(row)]
        .map(mounted => mounted.getBoundingClientRect())
        .filter(rect => rect.bottom > top && rect.top < bottom)
      resolve({
        consumedRows: count,
        // This step is about the windowed list; a list short enough to mount
        // every row takes another path through VirtualList.
        windowed: element.querySelector(windowedRows) !== null,
        rowsInViewNextFrame: shown.length,
        emptyAbovePx: shown.length === 0 ? bottom - top : Math.max(0, Math.min(...shown.map(rect => rect.top)) - top),
        emptyBelowPx: shown.length === 0 ? 0 : Math.max(0, bottom - Math.max(...shown.map(rect => rect.bottom))),
      })
    })
  }), { count: CONSUMED_ROWS, ...SELECTORS })

  // Consume down to a list short enough to keep every row mounted. Such a list
  // clips each row to its own box, so a row's keyboard focus ring has to fit
  // inside that box.
  const left = await page.evaluate(() => window.laneFixture.rowCount())
  await page.evaluate(count => window.laneFixture.consume(count), left - SHORT_LIST_ROWS)
  await frames()
  await page.getByTestId('keeper-lane-dev-toggle').focus()
  const barFocused = () => page.evaluate(
    ({ bar, index }) => document.activeElement === document.querySelectorAll(bar)[index],
    { bar: SELECTORS.bar, index: SHORT_LIST_FOCUSED_ROW },
  )
  for (let presses = 0; presses < MAX_TAB_PRESSES && !(await barFocused()); presses += 1) {
    await page.keyboard.press('Tab')
  }
  measurements.shortList = await page.evaluate(({ list: listSelector, row, bar, index }) => {
    const bars = [...document.querySelectorAll(bar)]
    const element = bars[index]
    const style = getComputedStyle(element)
    const listBox = document.querySelector(listSelector).getBoundingClientRect()
    // What clips the row: its own box in a short list, else the scroll list.
    const box = element.closest('.virtual-list-fallback-row')?.getBoundingClientRect() ?? listBox
    const barBox = element.getBoundingClientRect()
    return {
      rows: bars.length,
      focusedRow: index + 1,
      keyboardFocused: document.activeElement === element && element.matches(':focus-visible'),
      focusRingReachPx: Number.parseFloat(style.outlineWidth) + Number.parseFloat(style.outlineOffset),
      roomAbovePx: barBox.top - box.top,
      // The bar of the longest wait is as wide as its row, so the row's edge
      // stands for the widest bar.
      roomRightPx: box.right - element.closest(row).getBoundingClientRect().right,
      roomBelowPx: box.bottom - barBox.bottom,
      firstRowRoomAbovePx: bars[0].getBoundingClientRect().top - listBox.top,
    }
  }, { ...SELECTORS, index: SHORT_LIST_FOCUSED_ROW })

  measurements.errors = errors
  await writeFile(`${out}measurements.json`, `${JSON.stringify(measurements, null, 2)}\n`)

  assert.equal(measurements.initial.farFromViewport, 0)
  assert.ok(measurements.initial.mounted < ROWS)
  checks.push('a large inventory mounts only the rows near the list viewport')
  // With no label found the ink reaches -Infinity, and any distance clears that.
  assert.ok(Number.isFinite(measurements.initial.axisLabelInkBelowAxisPx), 'the age axis has no label to measure')
  assert.ok(measurements.initial.listTopBelowAxisPx >= measurements.initial.axisLabelInkBelowAxisPx)
  checks.push('a row cut at the top of the list stays clear of the age axis labels')
  assert.equal(measurements.end.farFromViewport, 0)
  assert.equal(measurements.end.scrollsToSettle, 1)
  assert.equal(measurements.end.lastRowInView, true)
  assert.equal(measurements.end.firstRowMounted, false)
  assert.equal(measurements.end.operatedSourceIncarnation, String(alpha.last + 1))
  checks.push('the last server row is reachable by scrolling and acts on its own address')
  assert.equal(measurements.focus.afterFocusedRowLeft, 'list')
  checks.push('keyboard focus moves to the list when the focused row leaves the window')
  assert.equal(measurements.expansion.firstRowOpenAfterReturn, true)
  checks.push('a row opened by the operator is still open after it leaves the window and returns')
  assert.equal(measurements.readdress.rowOpen, true)
  assert.equal(measurements.readdress.focus, 'row')
  assert.equal(measurements.readdress.operationsSent, 1)
  assert.equal(
    measurements.readdress.operatedSourceIncarnation,
    measurements.readdress.currentSourceIncarnation,
  )
  checks.push('a row stays open and focused when the queue re-addresses its event, and acts on the new address')
  assert.equal(measurements.keeperSwitch.scrollTopAfterPx, 0)
  assert.equal(measurements.keeperSwitch.firstRowInView, true)
  assert.equal(measurements.keeperSwitch.openRows, 0)
  checks.push('another Keeper starts at its first row with nothing open')
  // Less than one row's height may be empty at either edge: the gap between
  // rows is, a missing row is not.
  assert.equal(measurements.consumedBatch.windowed, true, 'raise LANE_WINDOW_ROWS: the list stopped windowing once the batch was gone')
  assert.ok(measurements.consumedBatch.emptyAbovePx < measurements.initial.collapsedRowPitchPx)
  assert.ok(measurements.consumedBatch.emptyBelowPx < measurements.initial.collapsedRowPitchPx)
  checks.push('the frame after the Keeper consumes a batch shows rows across the list')
  assert.equal(measurements.shortList.rows, SHORT_LIST_ROWS)
  assert.equal(measurements.shortList.keyboardFocused, true)
  for (const room of ['roomAbovePx', 'roomRightPx', 'roomBelowPx']) {
    assert.ok(measurements.shortList[room] >= measurements.shortList.focusRingReachPx, room)
  }
  checks.push("a short list leaves room for a row's keyboard focus ring above, beside and below it")
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
