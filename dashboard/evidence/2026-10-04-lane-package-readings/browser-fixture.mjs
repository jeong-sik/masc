import { chromium } from 'playwright'
import assert from 'node:assert/strict'
import { writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'

const out = fileURLToPath(new URL('.', import.meta.url))
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1440, height: 1100 } })
const errors = [], unhandled = [], writes = []
page.on('pageerror', error => errors.push(error.message))
page.on('console', entry => { if (entry.type() === 'error') errors.push(entry.text()) })
const readings = [
  { lane_id: 'quality', path: ['missing'], label: 'Missing records', unit: 'records', format: 'number' },
  { lane_id: 'quality', path: ['ready'], label: 'Ready', unit: null, format: 'boolean' },
  { lane_id: 'quality', path: ['note'], label: 'Operator note', unit: null, format: 'text' },
  { lane_id: 'quality', path: ['details'], label: 'Details', unit: null, format: 'json' },
  { lane_id: 'quality', path: ['absent'], label: 'No reading supplied', unit: 'records', format: 'number' },
  { lane_id: 'quality', path: ['wrong'], label: 'Wrong typed value', unit: null, format: 'boolean' },
]
const instance = { instance_id: 'instance-1', run_id: 'run-1', addon_id: 'quality-report', title: 'Quality report',
  revision: 'package-1', incarnation: 'run-1', action_schema: null, configuration: null,
  package: { outputs: { quality: { lanes: ['quality'] } }, binding_schema: { type: 'object', properties: { sources: { type: 'array' } } },
    presentation: { description: 'Declared quality observations', readings } },
  phase: { kind: 'attached' }, observation_seq: 1, rows_count: 1 }
const row = { id: 'reading-1', lane_id: 'instance-1/quality', kind: 'value', title: 'Latest quality readings',
  observed_at: 1791090000, subject_id: 'report', actor: null, clock: null,
  fields: { missing: 0, ready: false, note: '<img src=x onerror=alert(1)>\nOperator text remains text', details: { count: 7 }, wrong: 'true' },
  evidence: [{ uri: 'artifact://synthetic/quality-report', sha256: null }], related_ids: [] }
const snapshot = { configuration: null, instances: [instance,
  { ...instance, instance_id: 'instance-2', title: 'Other instance', rows_count: 0,
    package: { ...instance.package, presentation: { description: null, readings: [{ ...readings[0], label: 'Other instance label' }] } } }],
  rows: [row], coverage: [] }
await page.route('**/api/**', async route => {
  const request = route.request(), pathname = new URL(request.url()).pathname
  if (!pathname.startsWith('/api/')) return route.continue()
  if (request.method() !== 'GET') writes.push({ pathname, method: request.method() })
  if (pathname === '/api/v1/lane-addons') return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(snapshot) })
  unhandled.push(pathname)
  return route.fulfill({ status: 500, contentType: 'application/json', body: JSON.stringify({ error: 'unexpected fixture route' }) })
})
try {
  await page.goto(process.env.LANE_READINGS_FIXTURE_URL ?? 'http://127.0.0.1:5197/dashboard/evidence/2026-10-04-lane-package-readings/fixture.html')
  const group = page.getByLabel('Package readings for reading-1', { exact: true })
  await group.waitFor()
  assert.deepEqual(await group.locator('dt').allTextContents(), readings.map(x => x.label))
  assert.deepEqual(await group.locator('dd').allTextContents(), [
    '0 records', 'false', row.fields.note, '{"count":7}',
    'Unavailable · field unavailable', 'Unavailable · field does not match declared display format',
  ])
  assert.equal(await group.locator('img').count(), 0)
  assert.equal((await group.textContent()).includes('Other instance label'), false)
  await page.getByText('Fields and original evidence · reading-1', { exact: true }).click()
  await page.getByText(/artifact:\/\/synthetic\/quality-report/).waitFor()
  await page.screenshot({ path: out + 'readings.png', fullPage: true })
  await page.getByRole('button', { name: 'Inspect Latest quality readings · reading-1' }).click()
  const selected = page.getByRole('region', { name: 'Selected Lane event' })
  assert.equal(await selected.getByLabel('Package readings for reading-1', { exact: true }).count(), 1)
  await page.setViewportSize({ width: 390, height: 844 })
  await selected.getByLabel('Package readings for reading-1', { exact: true }).scrollIntoViewIfNeeded()
  await page.screenshot({ path: out + 'readings-mobile.png', fullPage: true })
  assert.deepEqual(writes, [])
  assert.deepEqual(unhandled, [])
  assert.deepEqual(errors, [])
  const result = { passed: true, browser: await browser.version(), scope: 'Actual component and decoder, synthetic HTTP; no native/backend/worker execution',
    assertions: ['declared order and label', 'number unit including zero', 'boolean false remains false', 'multiline HTML escaped', 'JSON preserved',
      'absent and wrong type unavailable', 'other instance cannot supply labels', 'original fields/evidence accessible', 'selected detail renders same contract', 'display starts no writes'],
    errors, unhandled, writes }
  await writeFile(out + 'browser-result.json', JSON.stringify(result, null, 2) + '\n')
  console.log('PASS: actual Chromium Lane readings fixture, 10 assertions, zero writes')
} catch (error) {
  await writeFile(out + 'browser-failure.json', JSON.stringify({ message: String(error), errors, unhandled, writes }, null, 2) + '\n')
  throw error
} finally { await browser.close() }
