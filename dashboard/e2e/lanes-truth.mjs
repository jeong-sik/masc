import { chromium } from 'playwright'
import { readFileSync, mkdirSync } from 'node:fs'
import { resolve } from 'node:path'

// Replay the audit's real, secret-free lane snapshot through the HTTP decoder
// and rendered UI. The failure is injected; this does not exercise Stagehand.
const url = process.env.INTERNAL_AGENTS_FIXTURE_URL
if (!url) throw new Error('INTERNAL_AGENTS_FIXTURE_URL is required')
const output = process.env.INTERNAL_AGENTS_ARTIFACT_DIR ?? '/tmp/masc-lanes-truth'
mkdirSync(output, { recursive: true })
const snapshot = JSON.parse(readFileSync(resolve(
  import.meta.dirname, '../../docs/evidence/browser-lanes-audit-20260929/lanes-observed.json',
), 'utf8'))
const json = (route, body, status = 200) => route.fulfill({
  status, contentType: 'application/json', body: JSON.stringify(body),
})
let failLanes = false
let failExact = false
const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1080 } })
  page.on('pageerror', error => console.error('PAGE ERROR:', error.message))
  page.on('console', message => { if (message.type() === 'error') console.error('CONSOLE:', message.text()) })
  await page.route('**/api/v1/**', route => json(route, {}))
  await page.route('**/api/v1/dashboard/dev-token', route => json(route, {
    token: 'fixture-admin', actor: 'dashboard', role: 'admin',
  }))
  const empty = { generated_at: snapshot.generated_at, count: 0, runs: [] }
  await page.route('**/api/v1/dashboard/exact-lane-runs?**', route => failExact
    ? json(route, { error: 'audit injected schema failure' }, 503)
    : json(route, { ...empty, total: 0, has_more: false }))
  await page.route('**/api/v1/dashboard/verification-runs', route => json(route, empty))
  await page.route('**/api/v1/dashboard/fusion-runs', route => json(route, {
    ...empty, replay: { status: 'absent' }, historical_evidence: [],
  }))
  await page.route('**/api/v1/dashboard/standalone-lanes', route => failLanes
    ? json(route, { error: 'audit injected unavailable' }, 503)
    : json(route, snapshot))
  await page.goto(url)
  await page.getByTestId('internal-agents-monitor').waitFor()
  const matrix = page.getByTestId('standalone-lane-matrix')
  const stagehand = matrix.getByRole('row').filter({ hasText: 'browser_stagehand_exact' })
  await stagehand.getByText('Config: unconfigured', { exact: true }).waitFor().catch(async error => { console.error(await page.locator('body').innerText()); throw error })
  await stagehand.getByText(/run records are not retained yet/).waitFor()
  await page.getByRole('heading', { name: 'Lanes', exact: true }).waitFor()
  if (await matrix.getByRole('row').count() !== snapshot.lanes.length + 1) {
    throw new Error('The matrix did not render every observed lane')
  }
  if ((await page.locator('body').innerText()).includes('Invalid')) throw new Error('Fixture decoder error')
  await page.screenshot({ path: `${output}/lanes-observed.png`, fullPage: true })
  failLanes = true
  await page.getByRole('button', { name: 'Refresh', exact: true }).click()
  await page.getByRole('alert').filter({ hasText: 'STALE' }).waitFor()
  await stagehand.getByText('Config: unconfigured', { exact: true }).waitFor()
  await page.screenshot({ path: `${output}/lanes-stale.png`, fullPage: true })
  failLanes = false
  await page.getByRole('button', { name: 'Refresh', exact: true }).click()
  await page.getByRole('alert').filter({ hasText: 'STALE' }).waitFor({ state: 'detached' })
  await stagehand.getByText('Config: unconfigured', { exact: true }).waitFor()
  failExact = true
  await page.reload()
  const inventory = page.locator('section').filter({ has: page.getByRole('heading', { name: 'Observed run inventory', exact: true }) }).last()
  const librarian = inventory.getByRole('button', { name: /Librarian/ })
  await librarian.filter({ hasText: '관측 불가' }).waitFor()
  if (!(await librarian.innerText()).includes('—')) throw new Error('Unread source counted as zero')
  await page.getByText('Run observations unavailable for this filter.', { exact: true }).waitFor()
  await page.screenshot({ path: `${output}/runs-unavailable.png`, fullPage: true })
  failExact = false
  await page.getByRole('button', { name: 'Refresh', exact: true }).click()
  await page.getByText('No internal agent runs for this filter.', { exact: true }).waitFor()
  if (!(await librarian.innerText()).includes('0')) throw new Error('Measured empty source did not show zero')
  console.log('PASS: six lanes, Stagehand limitation, stale recovery, unread source versus measured zero')
} finally {
  await browser.close()
}
