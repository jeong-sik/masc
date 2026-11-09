// Draws the Tools page series panel (`#/lab/tools`) in a real browser against a stubbed server.
//
// The server answers `GET /api/v1/tool-metrics/series` from a fixed clock, so a screenshot and the
// numbers on it do not move between runs. `TOOL_SERIES_RECORDED_JSON` replaces the answer for the
// 24-hour window of every tool with a recorded response of the live endpoint; the checks that
// depend on the synthetic numbers are skipped for it.
import { chromium } from 'playwright'
import { readFileSync } from 'node:fs'

const appUrl = process.env.TOOL_SERIES_APP_URL
if (!appUrl) throw new Error('TOOL_SERIES_APP_URL is required')
const artifactDir = process.env.TOOL_SERIES_ARTIFACT_DIR ?? '/tmp'
const recordedPath = process.env.TOOL_SERIES_RECORDED_JSON
const recorded = recordedPath ? JSON.parse(readFileSync(recordedPath, 'utf8')) : null

const SECONDS_PER_HOUR = 3600
const SECONDS_PER_DAY = 24 * SECONDS_PER_HOUR
const SEOUL_OFFSET_MIN = 540
// 2026-11-06T13:30:00Z. A cut-short bucket sits at each end of an hourly window on purpose.
const NOW = 1_793_971_800

const TOOLS = [
  { name: 'tool_execute', publicNames: ['Execute'], perHour: 140, failShare: 0.04, p50: 380, p95: 5200, maxMs: 41_000 },
  { name: 'keeper_broadcast', publicNames: ['keeper_broadcast'], perHour: 36, failShare: 0.01, p50: 40, p95: 190, maxMs: 900 },
  { name: 'keeper_artifact_read', publicNames: ['keeper_artifact_read'], perHour: 9, failShare: 0.07, p50: 14, p95: 55, maxMs: 210 },
  { name: 'masc_board_list', publicNames: ['masc_board_list'], perHour: 22, failShare: 0, p50: 85, p95: 410, maxMs: 1_300 },
]
const QUIET_BUCKET_FROM_END = 7

const json = (route, body, status = 200) =>
  route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })

/** A repeatable value in [0, 1) for a bucket, so the drawn line has a shape but never changes. */
function wobble(index, salt) {
  const x = Math.sin(index * 12.9898 + salt * 78.233) * 43758.5453
  return x - Math.floor(x)
}

function bucketStarts(sinceHours, bucket, utcOffsetMin) {
  const since = NOW - sinceHours * SECONDS_PER_HOUR
  const length = bucket === 'hour' ? SECONDS_PER_HOUR : SECONDS_PER_DAY
  const shift = bucket === 'hour' ? 0 : utcOffsetMin * 60
  const first = Math.floor((since + shift) / length) * length - shift
  const starts = []
  for (let start = first; start < NOW; start += length) starts.push(start)
  return { since, length, starts }
}

function statOf(tool, index, factor, quiet) {
  if (quiet) return { call_count: 0, failure_count: 0, deferred_count: 0, total_ms: 0, p50_ms: null, p95_ms: null, max_ms: null }
  const calls = Math.round(tool.perHour * factor * (0.45 + 1.1 * wobble(index, tool.perHour)))
  const failures = Math.round(calls * tool.failShare * (0.5 + wobble(index, tool.p50)))
  const p50 = Math.round(tool.p50 * (0.7 + 0.7 * wobble(index, 3)))
  const p95 = Math.round(tool.p95 * (0.6 + 0.9 * wobble(index, 5)))
  return {
    call_count: calls,
    failure_count: failures,
    deferred_count: 0,
    total_ms: Math.round(calls * p50 * 1.6),
    p50_ms: p50,
    p95_ms: p95,
    max_ms: Math.round(tool.maxMs * (0.5 + wobble(index, 9))),
  }
}

function sumStats(rows) {
  const calls = rows.reduce((sum, row) => sum + row.call_count, 0)
  const observed = rows.filter(row => row.call_count > 0)
  const mean = key => (observed.length === 0 ? null : Math.round(observed.reduce((sum, row) => sum + row[key], 0) / observed.length))
  return {
    call_count: calls,
    failure_count: rows.reduce((sum, row) => sum + row.failure_count, 0),
    deferred_count: 0,
    total_ms: rows.reduce((sum, row) => sum + row.total_ms, 0),
    p50_ms: mean('p50_ms'),
    p95_ms: mean('p95_ms'),
    max_ms: observed.length === 0 ? null : Math.max(...observed.map(row => row.max_ms)),
  }
}

function synthesize(query) {
  const sinceHours = Number(query.get('since_hours'))
  const bucket = query.get('bucket')
  const utcOffsetMin = Number(query.get('utc_offset_min'))
  const tool = query.get('tool')
  const picked = tool === null ? TOOLS : TOOLS.filter(entry => entry.name === tool)
  const { since, length, starts } = bucketStarts(sinceHours, bucket, utcOffsetMin)
  const factor = bucket === 'hour' ? 1 : 24
  const quietAt = starts.length - 1 - (bucket === 'hour' ? QUIET_BUCKET_FROM_END : 3)
  const perTool = picked.map(entry => ({
    entry,
    rows: starts.map((_, index) => statOf(entry, index, factor, index === quietAt)),
  }))
  const buckets = starts.map((start, index) => ({ start, ...sumStats(perTool.map(item => item.rows[index])) }))
  return {
    generated_at: NOW,
    window: { since, until: NOW, bucket, bucket_seconds: length, utc_offset_min: utcOffsetMin },
    tool,
    total: sumStats(buckets),
    buckets,
    top_by_time: perTool
      .map(item => ({ name: item.entry.name, public_names: item.entry.publicNames, ...sumStats(item.rows) }))
      .sort((a, b) => b.total_ms - a.total_ms),
  }
}

const requests = []
function answer(url) {
  const query = new URL(url).searchParams
  requests.push(Object.fromEntries(query))
  if (recorded !== null && query.get('tool') === null && query.get('since_hours') === '24') return recorded
  return synthesize(query)
}

const failures = []
function check(ok, message) {
  if (!ok) failures.push(message)
}

const browser = await chromium.launch({ headless: true })
let page
try {
  const context = await browser.newContext({ viewport: { width: 1360, height: 2000 }, timezoneId: 'Asia/Seoul' })
  page = await context.newPage()
  const pageErrors = []
  page.on('pageerror', error => pageErrors.push(String(error)))
  await page.route('**/api/v1/dashboard/dev-token', route => json(route, {
    token: 'fixture-worker-token', actor: 'dashboard', role: 'worker',
  }))
  await page.route('**/api/v1/tool-metrics/series?**', route => json(route, answer(route.request().url())))

  await page.goto(`${appUrl}#/lab/tools`)
  const callChart = page.getByLabel('구간별 호출 수', { exact: true }).first()
  await callChart.waitFor({ timeout: 20_000 })
  const panel = page.locator('.section', { has: page.getByText('도구 실행 통계', { exact: true }) }).last()
  await panel.scrollIntoViewIfNeeded()
  const shot = name => panel.screenshot({ path: `${artifactDir}/${name}.png` })
  await shot('tool-series-24h')

  // textContent: the tiles upper-case their label with CSS, which innerText would return.
  const labels = await page.locator('.kpi-label').allTextContents()
  for (const label of ['호출', '실패', '실패율', '실행 시간 합계', '지연 p50', '지연 p95']) {
    check(labels.includes(label), `stat tile "${label}" is missing, tiles: ${labels.join(' | ')}`)
  }
  for (const label of ['구간별 호출 수', '구간별 실패율', '구간별 실행 시간 합계', '구간별 지연 p50 / p95']) {
    check((await page.getByLabel(label, { exact: true }).count()) >= 1, `chart "${label}" is missing`)
    const polylines = await page.locator(`figure[aria-label="${label}"] polyline`).count()
    check(polylines >= 1, `chart "${label}" draws no line`)
  }
  const firstSeries = requests[0]
  check(firstSeries?.since_hours === '24' && firstSeries?.bucket === 'hour', `first request was ${JSON.stringify(firstSeries)}`)
  check(firstSeries?.utc_offset_min === String(SEOUL_OFFSET_MIN), `utc_offset_min was ${firstSeries?.utc_offset_min}`)

  if (recorded === null) {
    check(await page.getByText('처음과 끝의 덜 찬 구간은 그래프에서 뺐어요').count() === 1, 'the cut-short note is missing')
    // 25 hourly buckets, the first and the last cut short by the window, leave 23 to draw. One of them
    // is quiet: it is a zero in the call chart and a gap, never a zero, in the latency chart.
    const calls = await page.locator('figure[aria-label="구간별 호출 수"] figcaption').innerText()
    check(calls.includes('관측 23/23 · 미관측 0'), `the call chart does not hold 23 observed buckets: ${calls.replace(/\s+/g, ' ')}`)
    const latency = await page.locator('figure[aria-label="구간별 지연 p50 / p95"] figcaption').innerText()
    check(latency.split('관측 22/23 · 미관측 1').length === 3, `the quiet bucket is not a gap in both latency lines: ${latency.replace(/\s+/g, ' ')}`)
    const latencyLines = await page.locator('figure[aria-label="구간별 지연 p50 / p95"] polyline').count()
    check(latencyLines === 4, `a quiet bucket must split each latency line in two, found ${latencyLines} polylines`)
    // The failure rate of the quiet bucket is not 0%: no call ran, so there is nothing to divide.
    const rate = await page.locator('figure[aria-label="구간별 실패율"] figcaption').innerText()
    check(rate.includes('관측 22/23 · 미관측 1'), `the quiet bucket is not a gap in the failure rate: ${rate.replace(/\s+/g, ' ')}`)
    const rateLines = await page.locator('figure[aria-label="구간별 실패율"] polyline').count()
    check(rateLines === 2, `a quiet bucket must split the failure rate line in two, found ${rateLines} polylines`)
    check((await page.locator('table caption', { hasText: '시간을 가장 많이 쓴 도구' }).count()) === 1, 'the top-by-time table is missing')
    const rows = await page.locator('table:has(caption:text("시간을 가장 많이 쓴 도구")) tbody tr').count()
    check(rows === TOOLS.length, `expected ${TOOLS.length} tool rows, found ${rows}`)
  }

  // The window chips ask the server for their own length and bucket, then draw the answer.
  async function pickWindow(name, sinceHours, bucket) {
    const answered = page.waitForResponse(response => {
      const url = response.url()
      return url.includes('/api/v1/tool-metrics/series') && url.includes(`since_hours=${sinceHours}`) && url.includes(`bucket=${bucket}`)
    })
    await page.getByRole('tab', { name }).click()
    await answered
    await page.locator('[aria-busy="true"]').waitFor({ state: 'detached' })
    await callChart.waitFor()
  }

  await pickWindow('7일 · 시간별', 168, 'hour')
  check(requests.some(request => request.since_hours === '168' && request.bucket === 'hour'), 'the 7-day window never asked for 168 hours')
  await shot('tool-series-7d')

  // Picking a tool in the table filters every chart to it.
  await pickWindow('24시간 · 시간별', 24, 'hour')
  const toolButton = page.getByRole('button', { name: 'tool_execute', exact: true }).first()
  if (await toolButton.count()) {
    await toolButton.click()
    await page.getByText('만 보는 중').waitFor({ timeout: 10_000 })
    check(requests.some(request => request.tool === 'tool_execute'), 'picking tool_execute never asked for that tool')
    await shot('tool-series-tool-filter')
    await page.getByRole('button', { name: '전체 도구 보기' }).click()
  } else {
    check(recorded !== null, 'no tool_execute button in the table')
  }

  // The 30-day window is drawn per day.
  await pickWindow('30일 · 일별', 720, 'day')
  check(requests.some(request => request.since_hours === '720' && request.bucket === 'day'), 'the 30-day window never asked for day buckets')
  await shot('tool-series-30d')

  // The raw values behind a chart are a table a keyboard and a screen reader can read.
  await page.locator('figure[aria-label="구간별 호출 수"] summary').click()
  const rawRow = page.locator('figure[aria-label="구간별 호출 수"] details table tbody tr').first()
  await rawRow.waitFor({ timeout: 5_000 }).catch(() => {})
  check((await rawRow.count()) > 0, 'the raw values table of the call chart is empty')

  // The paper (light) theme and a phone width draw the same panel.
  await page.goto(`${appUrl}?theme=paper#/lab/tools`)
  await callChart.waitFor({ timeout: 20_000 })
  await panel.scrollIntoViewIfNeeded()
  await shot('tool-series-24h-paper')
  await page.setViewportSize({ width: 390, height: 900 })
  await panel.scrollIntoViewIfNeeded()
  await shot('tool-series-24h-phone')
  const overflow = await panel.evaluate(element => element.scrollWidth - element.clientWidth)
  check(overflow <= 1, `the panel is ${overflow}px wider than its box at 390px`)

  check(pageErrors.length === 0, `page errors: ${pageErrors.join(' | ')}`)
} catch (error) {
  // What the panel showed and what it asked for, so a timeout says which step did not happen.
  console.error(`FAIL ${error}`)
  console.error(`requests: ${JSON.stringify(requests)}`)
  if (page) {
    console.error(`panel: ${(await page.locator('.section', { hasText: '도구 실행 통계' }).last().innerText().catch(() => '(none)')).slice(0, 600)}`)
    await page.screenshot({ path: `${artifactDir}/tool-series-failure.png` }).catch(() => {})
  }
  failures.push('the run stopped before the last check')
} finally {
  await browser.close()
}

if (failures.length > 0) {
  for (const message of failures) console.error(`FAIL ${message}`)
  process.exit(1)
}
console.log(`tool series panel checks passed (${requests.length} series requests, screenshots in ${artifactDir})`)
