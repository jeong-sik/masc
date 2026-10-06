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
let activity = 'off', reads = 0
const seed = JSON.parse(await readFile(new URL('../../src/api/fixtures/lane-inventory.json', import.meta.url), 'utf8'))
function reading() {
  const data = structuredClone(seed)
  for (const row of data.rows) {
    if (row.selection.kind !== 'browser') continue
    row.state.activity = activity
    if (row.state.kind === 'browser_clients') row.state.connected_clients = 2
    else row.state.registered = true
  }
  return data
}
page.on('pageerror', error => errors.push(error.message))
await page.route('**/api/**', async route => {
  const request = route.request(), path = new URL(request.url()).pathname
  if (!path.startsWith('/api/')) return route.continue()
  if (request.method() !== 'GET') writes.push(path)
  if (path === '/api/v1/dashboard/dev-token' && request.method() === 'GET') {
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify({ token: 'synthetic-fixture-token', actor: 'dashboard', role: 'admin' }) })
  }
  if (path === '/api/v1/lanes' && request.method() === 'GET') {
    reads++
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify(reading()) })
  }
  unexpected.push(path)
  return route.fulfill({ status: 500, body: '{"error":"unexpected route"}' })
})
async function inspect(id) {
  const row = seed.rows.find(item => item.id === id)
  await page.getByRole('searchbox').fill(id)
  await page.getByRole('button', { name: `Inspect ${row.label}`, exact: true }).click()
  return page.getByRole('region', { name: `Details for ${row.label}` })
}
try {
  await page.goto(`http://127.0.0.1:${server.httpServer.address().port}/dashboard/evidence/2026-10-04-browser-lane-activity/fixture.html`)
  const automation = await inspect('browser/automation')
  await automation.getByText('Off · configuration and sessions retained', { exact: true }).waitFor()
  await automation.getByText('Executor registered · session activity unverified', { exact: true }).waitFor()
  await automation.getByText(/Status and close remain available while off/).waitFor()
  checks.push('off and registered executor remain separate, with status/close and startup-path guidance')
  await page.screenshot({ path: out + 'automation-off.png', fullPage: true })
  const live = await inspect('browser/live')
  await live.getByText('Off · configuration and sessions retained', { exact: true }).waitFor()
  await live.getByText('2 connected clients', { exact: true }).waitFor()
  checks.push('live off preserves the observed connected-client count')
  activity = 'unobserved'
  await page.getByRole('button', { name: 'Refresh Lanes', exact: true }).click()
  const stagehand = await inspect('browser/stagehand')
  await stagehand.getByText('Activity configuration unavailable', { exact: true }).waitFor()
  await stagehand.getByText('Executor registered · session activity unverified', { exact: true }).waitFor()
  checks.push('missing configuration authority is distinct from executor registration')
  await page.screenshot({ path: out + 'stagehand-unobserved.png', fullPage: true })
  activity = 'on'
  await page.getByRole('button', { name: 'Refresh Lanes', exact: true }).click()
  await stagehand.getByText('New requests enabled', { exact: true }).waitFor()
  checks.push('a refreshed on observation replaces the previous activity')
  await page.setViewportSize({ width: 390, height: 844 })
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true)
  await page.screenshot({ path: out + 'mobile-on.png', fullPage: true })
  checks.push('mobile has no horizontal overflow')
  assert.deepEqual(errors, []); assert.deepEqual(writes, []); assert.deepEqual(unexpected, [])
  checks.push('zero writes, page errors and unexpected API routes')
  await writeFile(out + 'browser-result.json', JSON.stringify({ passed: true, checked_at: new Date().toISOString(), browser: browser.version(),
    scope: 'Actual Status, inventory, HTTP decoder and rendering with synthetic Browser observations. No activity save UI, Runtime publication, real Browser sessions, native TUI or deployment.',
    checks, reads, errors, writes, unexpected }, null, 2) + '\n')
  console.log(JSON.stringify({ passed: true, checks, reads, writes, errors, unexpected }))
} catch (error) {
  await writeFile(out + 'browser-failure.json', JSON.stringify({ error: String(error), errors, writes, unexpected,
    body: await page.locator('body').innerText() }, null, 2) + '\n')
  throw error
} finally { await browser.close(); await server.close() }
