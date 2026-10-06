import { chromium } from 'playwright'
import { createServer } from 'vite'
import assert from 'node:assert/strict'
import { readFile, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
const out = fileURLToPath(new URL('.', import.meta.url))
const root = fileURLToPath(new URL('../..', import.meta.url))
const server = await createServer({ root, configFile: root + 'vite.config.ts', server: { host: '127.0.0.1', port: 0, watch: null } })
await server.listen()
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
page.setDefaultTimeout(10000)
const errors = [], writes = [], unexpected = [], checks = []
let mode = 'initial', reads = 0
const seed = JSON.parse(await readFile(new URL('../../src/api/fixtures/lane-inventory.json', import.meta.url), 'utf8'))
function reading() {
  const data = structuredClone(seed)
  for (const row of data.rows) {
    if (row.selection.kind !== 'machine') continue
    row.state.activity = row.selection.machine === 'msx' ? 'off' : 'unobserved'
    row.state.publication = row.selection.machine === 'msx' ? 'stable' : 'running'
    if (mode === 'missing') delete row.state.activity
    if (mode === 'enabled') row.state.activity = 'on'
  }
  return data
}
page.on('pageerror', error => errors.push(error.message))
await page.route('**/api/**', async route => {
  const request = route.request(), path = new URL(request.url()).pathname
  if (!path.startsWith('/api/')) return route.continue()
  if (request.method() !== 'GET') writes.push(path)
  if (path === '/api/v1/dashboard/dev-token' && request.method() === 'GET')
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify({ token: 'synthetic-fixture-token', actor: 'dashboard', role: 'admin' }) })
  if (path === '/api/v1/lanes' && request.method() === 'GET') {
    reads++
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify(reading()) })
  }
  unexpected.push(path)
  return route.fulfill({ status: 500, body: '{"error":"unexpected fixture route"}' })
})
async function inspect(id) {
  const row = seed.rows.find(item => item.id === id)
  await page.getByRole('searchbox').fill(id)
  await page.locator('article').filter({ has: page.getByText(id, { exact: true }) })
    .getByRole('button', { name: `Inspect ${row.label}`, exact: true }).click()
  return page.getByRole('region', { name: `Details for ${row.label}` })
}
try {
  await page.goto(`http://127.0.0.1:${server.httpServer.address().port}/dashboard/evidence/2026-10-05-machine-lane-activity/fixture.html`)
  const msx = await inspect('machine/msx')
  await msx.getByText('Off · machine state retained', { exact: true }).waitFor()
  await msx.getByText('Stable screen published', { exact: true }).waitFor()
  checks.push('MSX off retains a stable screen observation')
  await msx.getByText('Off refuses new execution and input; existing machine state and checkpoints are retained.', { exact: true }).waitFor()
  assert.equal(await msx.getByRole('switch').count(), 0)
  checks.push('readout provides policy guidance without an activity toggle')
  await msx.scrollIntoViewIfNeeded()
  await page.screenshot({ path: out + 'machine-off-stable.png', animations: 'disabled' })
  const dos = await inspect('machine/dos')
  await dos.getByText('Activity configuration unavailable', { exact: true }).waitFor()
  await dos.getByText('Machine running', { exact: true }).waitFor()
  checks.push('DOS unobserved activity is separate from its running publication')
  mode = 'missing'
  await page.getByRole('button', { name: 'Refresh Lanes', exact: true }).click()
  await page.getByText('Showing the previous reading; current state is unverified.', { exact: false }).waitFor()
  await dos.getByText('Activity configuration unavailable', { exact: true }).waitFor()
  checks.push('missing activity rejects the complete new inventory and labels the retained reading')
  mode = 'enabled'
  await page.getByRole('button', { name: 'Refresh Lanes', exact: true }).click()
  await dos.getByText('New execution and input enabled', { exact: true }).waitFor()
  await dos.getByText('Machine running', { exact: true }).waitFor()
  checks.push('explicit refresh recovers current activity without changing the publication')
  await page.setViewportSize({ width: 390, height: 844 })
  await dos.scrollIntoViewIfNeeded()
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true)
  await page.screenshot({ path: out + 'machine-mobile-on.png', animations: 'disabled' })
  checks.push('mobile readout has no page-wide horizontal overflow')
  assert.deepEqual(errors, []); assert.deepEqual(writes, []); assert.deepEqual(unexpected, [])
  checks.push('zero writes, page errors and unexpected API routes')
  const result = { passed: true, checked_at: new Date().toISOString(), browser: browser.version(),
    scope: 'Actual Status, inventory decoder and styled rendering with synthetic HTTP. No machine owner, Runtime publication, on/off editor, native TUI or deployment execution.',
    checks, reads, errors, writes, unexpected }
  await writeFile(out + 'browser-result.json', JSON.stringify(result, null, 2) + '\n')
  console.log(JSON.stringify(result))
} catch (error) {
  await writeFile(out + 'browser-failure.json', JSON.stringify({ error: String(error), errors, writes, unexpected, reads,
    body: await page.locator('body').innerText() }, null, 2) + '\n')
  throw error
} finally { await browser.close(); await server.close() }
