import { chromium } from 'playwright'
import { createServer } from 'vite'
import assert from 'node:assert/strict'
import { writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'

const out = fileURLToPath(new URL('.', import.meta.url))
const server = await createServer({ server: { host: '127.0.0.1', port: 0 } })
await server.listen()
const address = server.httpServer.address()
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1440, height: 1100 } })
const errors = [], unhandled = [], writes = []
page.on('pageerror', error => errors.push(error.message))
page.on('console', entry => { if (entry.type() === 'error') errors.push(entry.text()) })
const declaration = { id: 'quality-report', source_path: '/fixture/lane-addons/quality.toml',
  enabled: false, desired_revision: 'same-inputs', applied_revision: 'same-inputs', instance_id: 'worker-1' }
const instance = { instance_id: 'worker-1', run_id: 'run-1', addon_id: 'quality-report', title: 'Quality report',
  revision: 'package-1', incarnation: 'worker-1', action_schema: null,
  configuration: { id: declaration.id, source_path: declaration.source_path, revision: 'same-inputs' },
  package: { outputs: {}, binding_schema: null, presentation: { description: null, readings: [] } },
  phase: { kind: 'failed', message: 'Worker cleanup is still unconfirmed' }, observation_seq: 1, rows_count: 1 }
const row = { id: 'reading-1', lane_id: 'worker-1/quality', kind: 'value', title: 'Retained quality reading',
  observed_at: 1791090000, subject_id: 'report', actor: null, clock: null, fields: { count: 7 },
  evidence: [{ uri: 'artifact://synthetic/quality-report', sha256: null }], related_ids: [] }
const snapshot = { configuration: { directory: '/fixture/lane-addons', complete: false,
  declarations: [declaration], issues: [{ id: null, source_path: '/fixture/lane-addons/unreadable.toml',
    message: 'Off requested; worker cleanup waits for a complete declaration and retained-binding reading' }] },
  instances: [instance], rows: [row], coverage: [] }
await page.route('**/api/**', async route => {
  const request = route.request(), pathname = new URL(request.url()).pathname
  if (!pathname.startsWith('/api/')) return route.continue()
  if (request.method() !== 'GET') writes.push({ pathname, method: request.method() })
  if (pathname === '/api/v1/lane-addons') return route.fulfill({ status: 200,
    contentType: 'application/json', body: JSON.stringify(snapshot) })
  unhandled.push(pathname)
  return route.fulfill({ status: 500, contentType: 'application/json', body: '{"error":"unexpected fixture route"}' })
})
try {
  await page.goto(`http://127.0.0.1:${address.port}/dashboard/evidence/2026-10-04-package-lane-enabled/fixture.html`)
  const table = page.getByRole('table', { name: 'TOML declarations' })
  await table.getByText('Off requested · worker cleanup not yet confirmed', { exact: true }).waitFor()
  assert.equal(await table.getByText('Desired revision applied', { exact: true }).count(), 0)
  await page.getByText('Configuration read: incomplete', { exact: true }).waitFor()
  await page.getByText('Worker cleanup is still unconfirmed', { exact: true }).waitFor()
  await page.screenshot({ path: out + 'off-requested.png', fullPage: true })
  declaration.instance_id = null
  declaration.applied_revision = null
  snapshot.configuration.complete = true
  snapshot.configuration.issues = []
  instance.phase = { kind: 'detached' }
  await page.getByRole('button', { name: 'Refresh', exact: true }).click()
  await table.getByText('Configured off · no current worker observed', { exact: true }).waitFor()
  await page.getByText('Fields and original evidence · reading-1', { exact: true }).click()
  await page.getByText(/artifact:\/\/synthetic\/quality-report/).waitFor()
  await page.screenshot({ path: out + 'configured-off.png', fullPage: true })
  await page.setViewportSize({ width: 390, height: 844 })
  await table.scrollIntoViewIfNeeded()
  await page.screenshot({ path: out + 'configured-off-mobile.png', fullPage: true })
  assert.deepEqual(errors, []); assert.deepEqual(unhandled, []); assert.deepEqual(writes, [])
  await writeFile(out + 'browser-result.json', JSON.stringify({ passed: true, browser: await browser.version(),
    scope: 'Actual component and decoder with synthetic HTTP; no native backend, worker cleanup or deployment proof',
    assertions: ['desired off despite equal payload revisions', 'incomplete read and cleanup failure visible',
      'refresh reads configured off with no current worker', 'retained worker and evidence still visible',
      'desktop and mobile screenshots', 'zero writes, page errors or unexpected API routes'], errors, unhandled, writes }, null, 2) + '\n')
  console.log('PASS: actual Chromium package activity display with synthetic HTTP')
} catch (error) {
  await writeFile(out + 'browser-failure.json', JSON.stringify({ message: String(error), errors, unhandled, writes,
    body: await page.locator('body').innerText() }, null, 2) + '\n')
  throw error
} finally { await browser.close(); await server.close() }
