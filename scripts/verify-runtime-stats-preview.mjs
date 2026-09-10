// Run with the dashboard's installed Playwright, a downloaded CI preview,
// and a live backend with write methods/WebSockets blocked. No local compilation.
import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { resolve, relative, extname, sep } from 'node:path'
import assert from 'node:assert/strict'
const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const [previewArgument, expectedHead, baseUrl, outputArgument] = process.argv.slice(2)
if (!previewArgument || !expectedHead || !baseUrl || !outputArgument) {
  throw new Error('Usage: node scripts/verify-runtime-stats-preview.mjs PREVIEW_DIR PR_HEAD BACKEND_URL EVIDENCE_DIR')
}
const pending = { window_minutes: 60, bucket_minutes: 0, total_entries: 0,
  total_error_entries: 0, cost_ledger_read: { state: 'pending' }, latency_buckets: [], models: [] }
const metrics = { window_minutes: 60, cost_ledger_read: { state: 'available',
  malformed_rows: 0, schema_violation_rows: 2, identity_conflict_rows: 1 }, models: [
    { model_id: 'runtime_lane_fixture', success_count: 8, error_count: 2,
      total_input_tokens: 1234, total_output_tokens: 0, p50_latency_ms: 125, p95_latency_ms: 900,
      usage_sample_count: 6, usage_missing_count: 2, telemetry_sample_count: 5, telemetry_missing_count: 3 },
    { model_id: 'runtime_lane_missing', success_count: 0, error_count: 2,
      total_input_tokens: null, total_output_tokens: null, p50_latency_ms: null, p95_latency_ms: null },
  ] }
let mode = 'pending'
const metricRequests = []
const root = resolve(previewArgument)
const output = resolve(outputArgument)
const manifest = JSON.parse(await readFile(resolve(root, 'preview-provenance.json'), 'utf8'))
assert.equal(manifest.pr_head_commit, expectedHead)
for (const [name, hash] of Object.entries(manifest.files)) {
  const file = resolve(root, name)
  assert.ok(!relative(root, file).startsWith(`..${sep}`) && file.startsWith(root + sep))
  assert.equal(createHash('sha256').update(await readFile(file)).digest('hex'), hash, name)
}
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.png': 'image/png' }
await mkdir(output, { recursive: true })
const browser = await chromium.launch({ headless: true })
const mutations = []
const blockedWebSockets = []
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, serviceWorkers: 'block' })
  await page.routeWebSocket('**/*', socket => {
    blockedWebSockets.push(socket.url())
    socket.close()
  })
  const pageErrors = []
  page.on('pageerror', error => pageErrors.push(error.message))
  await page.route('**/*', async route => {
    const request = route.request()
    if (!['GET', 'HEAD'].includes(request.method())) {
      mutations.push({ method: request.method(), path: new URL(request.url()).pathname })
      return route.abort()
    }
    const url = new URL(request.url())
    if (url.origin === new URL(baseUrl).origin && url.pathname === '/api/v1/models/metrics') {
      metricRequests.push({ query: url.search, mode })
      if (mode === 'pending') {
        mode = 'available'
        return route.fulfill({ json: pending })
      }
      if (mode === 'error') return route.fulfill({ status: 503, json: { error: 'fixture: metrics unavailable' } })
      const value = { ...metrics, window_minutes: Number(url.searchParams.get('window')) }
      if (mode === 'ledger-error') value.cost_ledger_read = { state: 'unavailable', detail: 'fixture: cost ledger unavailable' }
      return route.fulfill({ json: value })
    }
    if (url.origin === new URL(baseUrl).origin && url.pathname.startsWith('/dashboard/')) {
      const name = decodeURIComponent(url.pathname.slice('/dashboard/'.length)) || 'index.html'
      assert.ok(Object.hasOwn(manifest.files, name), `Unmanifested asset: ${name}`)
      return route.fulfill({ body: await readFile(resolve(root, name)),
        contentType: mime[extname(name)] ?? 'application/octet-stream' })
    }
    return route.continue()
  })
  await page.goto(new URL('/dashboard/#overview', baseUrl).href)
  const panel = page.locator('[data-overview-runtime-stats]')
  await panel.getByText('서버가 첫 집계를 준비하고 있습니다. 표시 중에는 자동으로 다시 읽습니다.', { exact: true }).waitFor()
  assert.equal(await panel.getByRole('table').count(), 0)
  await panel.scrollIntoViewIfNeeded()
  await page.screenshot({ path: resolve(output, 'pending.png') })
  // Exercise the existing focus refresh channel rather than clicking Retry.
  await page.evaluate(() => window.dispatchEvent(new Event('focus')))
  await panel.getByText('runtime_lane_fixture', { exact: true }).waitFor()
  const text = await panel.getByRole('table').textContent()
  for (const fragment of ['입력 1,234', '출력 0', 'p50 125 ms', 'p95 900 ms', '오류 없음 8', '오류 2', '입력 미보고', 'p95 미보고']) assert.ok(text.includes(fragment), fragment)
  assert.ok(metricRequests.some(row => row.mode === 'pending'))
  assert.ok(metricRequests.some(row => row.mode === 'available'))
  await panel.getByRole('region', { name: '런타임별 토큰·지연·결과' }).focus()
  await page.screenshot({ path: resolve(output, 'desktop.png') })
  await panel.screenshot({ path: resolve(output, 'stats-panel.png') })
  await page.setViewportSize({ width: 390, height: 844 })
  await panel.scrollIntoViewIfNeeded()
  const mobileOverflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)
  assert.equal(mobileOverflow, false)
  await page.screenshot({ path: resolve(output, 'mobile.png') })
  await panel.getByLabel('집계 요청 기간').selectOption('30')
  await panel.getByText(/서버 집계 창: 30분/).waitFor()
  mode = 'ledger-error'
  await panel.getByRole('button', { name: '통계 새로 읽기', exact: true }).click()
  await panel.getByRole('alert').filter({ hasText: 'fixture: cost ledger unavailable' }).waitFor()
  assert.equal(await panel.getByText('runtime_lane_fixture', { exact: true }).count(), 1)
  await page.screenshot({ path: resolve(output, 'ledger-error.png') })
  mode = 'error'
  await panel.getByRole('button', { name: '통계 새로 읽기', exact: true }).click()
  await panel.getByRole('alert').filter({ hasText: '통계를 읽지 못했습니다' }).waitFor()
  assert.equal(await panel.getByRole('table').count(), 0)
  mode = 'available'
  await panel.getByRole('button', { name: '통계 새로 읽기', exact: true }).click()
  await panel.getByText('runtime_lane_fixture', { exact: true }).waitFor()
  await panel.getByRole('link', { name: '토큰·지연 상세', exact: true }).click()
  await page.waitForFunction(() => location.hash.includes('section=runtime') && location.hash.includes('view=cost'))
  const receipt = { observed_at: new Date().toISOString(), manifest,
    metric_requests: metricRequests,
    checks: ['pending_followup_focus_channel', 'per_lane_tokens_percentiles_outcomes', 'missing_vs_zero',
      'period_selection', 'ledger_read_failure', 'http_failure_retry', 'detail_route'],
    mobile_overflow: mobileOverflow, page_errors: pageErrors,
    backend: new URL(baseUrl).origin, blocked_mutations: mutations, blocked_websockets: blockedWebSockets,
    deployment: false, scope: 'CI-built Overview runtime statistics with synthetic API responses over live backend' }
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n')
  console.log(JSON.stringify({ evidence: output, page_errors: pageErrors }))
} finally { await browser.close() }
