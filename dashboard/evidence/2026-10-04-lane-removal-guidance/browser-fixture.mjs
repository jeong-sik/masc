import { chromium } from 'playwright'
import assert from 'node:assert/strict'
import { writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
const out = fileURLToPath(new URL('.', import.meta.url))
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } })
const errors = [], unexpected = [], writes = []
page.on('pageerror', error => errors.push(error.message))
const directory = '/synthetic/.masc/config/lane-addons'
const owned = { id: 'installed', source_path: directory + '/installed.toml', revision: 'installed-revision' }
const instance = { instance_id: 'configured', run_id: 'run', addon_id: 'package', title: 'TOML managed installation',
  revision: 'package-revision', incarnation: 'one', action_schema: null, configuration: owned,
  package: { outputs: {}, binding_schema: null, presentation: { description: null, readings: [] } },
  phase: { kind: 'attached' }, observation_seq: 0, rows_count: 0 }
await page.route('**/api/**', async route => {
  const request = route.request(), path = new URL(request.url()).pathname
  if (!path.startsWith('/api/')) return route.continue()
  if (request.method() !== 'GET') writes.push(path)
  if (path !== '/api/v1/lane-addons') { unexpected.push(path); return route.fulfill({ status: 500, body: '{}' }) }
  return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({
    configuration: { directory, complete: true, issues: [], declarations: [{ ...owned, desired_revision: owned.revision,
      applied_revision: owned.revision, instance_id: 'configured' }] },
    instances: [instance, { ...instance, instance_id: 'manual', configuration: null, title: 'Manual attachment' }], rows: [], coverage: [],
  }) })
})
try {
  await page.goto('http://127.0.0.1:5197/dashboard/evidence/2026-10-04-lane-removal-guidance/fixture.html')
  await page.getByRole('button', { name: 'Remove TOML + worker', exact: true }).waitFor()
  await page.getByRole('button', { name: 'Remove worker', exact: true }).waitFor()
  assert.equal(await page.getByRole('button', { name: 'Detach', exact: true }).count(), 0)
  await page.getByText(/Deletes the matching installation TOML from disk/).waitFor()
  await page.getByText('Cleans up this worker and its owned resources. Retained observations and evidence remain.', { exact: true }).waitFor()
  await page.screenshot({ path: out + 'removal-guidance.png', fullPage: true })
  assert.deepEqual(writes, []); assert.deepEqual(unexpected, []); assert.deepEqual(errors, [])
  await writeFile(out + 'browser-result.json', JSON.stringify({ passed: true, browser: await browser.version(),
    scope: 'Actual LaneAddonsPanel with synthetic HTTP; label/effect explanation only, no real detach or native TUI',
    assertions: ['TOML-managed removal label', 'manual worker removal label', 'disk deletion explanation', 'retained evidence explanation', 'zero mutation requests'],
    writes, unexpected, errors }, null, 2) + '\n')
  console.log('PASS: removal guidance browser fixture, 5 assertions, no mutations')
} finally { await browser.close() }
