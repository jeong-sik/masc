import { chromium } from 'playwright'
import { createServer } from 'vite'
import assert from 'node:assert/strict'
import { readFile, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
const out = fileURLToPath(new URL('.', import.meta.url))
const server = await createServer({ server: { host: '127.0.0.1', port: 0 } }); await server.listen()
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
page.setDefaultTimeout(10000)
const errors = [], writes = [], unexpected = []
let off = true, running = 1
const seed = JSON.parse(await readFile(new URL('../../src/api/fixtures/lane-inventory.json', import.meta.url), 'utf8'))
const label = seed.rows.find(row => row.id === 'exact/librarian_exact').label
function reading() {
  const data = structuredClone(seed)
  const lane = data.exact_snapshot.lanes.find(row => row.lane_id === 'librarian_exact')
  const row = data.rows.find(row => row.id === 'exact/librarian_exact')
  Object.assign(lane, { configured: true, configuration_state: off ? 'off' : 'ready', status: off ? 'off' : 'idle',
    admitted_slots: off ? [] : ['first', 'second'], cli_slots: off ? [] : ['cli'], dropped_slots: [], admission_error: null,
    declared_slots: ['first', 'second'], declared_cli_slots: ['cli'], running_count: running })
  row.state.configuration = off
    ? { kind: 'off', declared_slots: ['first', 'second'], declared_cli_slots: ['cli'] }
    : { kind: 'configured', declared_slots: ['first', 'second'], declared_cli_slots: ['cli'],
        admitted_slots: ['first', 'second'], cli_slots: ['cli'], dropped_slots: [], admission_error: null }
  return data
}
page.on('pageerror', error => errors.push(error.message))
await page.route('**/api/**', async route => {
  const req = route.request(), path = new URL(req.url()).pathname
  if (!path.startsWith('/api/')) return route.continue()
  if (req.method() !== 'GET') writes.push(path)
  if (path === '/api/v1/lanes') return route.fulfill({ contentType: 'application/json', body: JSON.stringify(reading()) })
  unexpected.push(path); return route.fulfill({ status: 500, body: '{"error":"unexpected route"}' })
})
try {
  await page.goto(`http://127.0.0.1:${server.httpServer.address().port}/dashboard/evidence/2026-10-04-exact-lane-activity/fixture.html`)
  await page.getByRole('button', { name: `Inspect ${label}`, exact: true }).click()
  const details = page.getByRole('region', { name: `Details for ${label}` })
  await details.getByText('Off · candidate configuration retained; accepted runs finish', { exact: true }).waitFor()
  await details.getByText(/off · 1 running/).waitFor()
  await details.getByText('Observed configuration and worker details', { exact: true }).click()
  const config = await details.locator('pre').first().textContent()
  assert.deepEqual(JSON.parse(config).configuration.declared_slots, ['first', 'second'])
  assert.deepEqual(JSON.parse(config).configuration.declared_cli_slots, ['cli'])
  await page.screenshot({ path: out + 'off-finishing.png', fullPage: true })
  running = 0; await page.getByRole('button', { name: 'Refresh Lanes', exact: true }).click()
  await details.getByText(/off · 0 running/).waitFor()
  off = false; await page.getByRole('button', { name: 'Refresh Lanes', exact: true }).click()
  await details.getByText('2 HTTP · 1 CLI admitted', { exact: true }).waitFor()
  assert.deepEqual(JSON.parse(await details.locator('pre').first().textContent()).configuration.declared_slots, ['first', 'second'])
  await page.screenshot({ path: out + 'on-retained-candidates.png', fullPage: true })
  assert.deepEqual(errors, []); assert.deepEqual(writes, []); assert.deepEqual(unexpected, [])
  await writeFile(out + 'browser-result.json', JSON.stringify({ passed: true, browser: browser.version(),
    scope: 'Actual Status, inventory, HTTP decoder and rendering with synthetic readings. No activity writer, native backend/TUI or model run.',
    assertions: ['off remains visible with one accepted run', 'HTTP and CLI declarations survive off',
      'finished run does not enable the lane', 'on reading retains candidate order', 'zero mutations, page errors or unexpected routes'],
    errors, writes, unexpected }, null, 2) + '\n')
  console.log('PASS: 5 synthetic Exact activity browser checks')
} catch (error) {
  await writeFile(out + 'browser-failure.json', JSON.stringify({ error: String(error), errors, writes, unexpected,
    body: await page.locator('body').innerText() }, null, 2) + '\n'); throw error
} finally { await browser.close(); await server.close() }
