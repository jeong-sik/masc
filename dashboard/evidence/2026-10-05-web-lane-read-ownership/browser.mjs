import { chromium } from 'playwright'
import { createServer } from 'vite'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
const out = fileURLToPath(new URL('.', import.meta.url)), root = fileURLToPath(new URL('../..', import.meta.url))
const cacheDir = await mkdtemp(join(tmpdir(), 'masc-lane-reads-'))
process.env.MASC_DASHBOARD_PROXY_TARGET = 'http://127.0.0.1:1'
const server = await createServer({ root, cacheDir, configFile: root + 'vite.config.ts', server: { host: '127.0.0.1', port: 0, watch: null } })
await server.listen()
const browser = await chromium.launch({ headless: true }), context = await browser.newContext({ viewport: { width: 1440, height: 1050 } }), page = await context.newPage()
page.setDefaultTimeout(10000)
const reads = [], writes = [], errors = [], unexpected = [], checks = [], cancelled = []
context.on('page', current => {
  current.on('pageerror', error => errors.push(error.message))
  current.on('requestfailed', request => cancelled.push({ path: new URL(request.url()).pathname, error: request.failure()?.errorText }))
})
page.on('pageerror', error => errors.push(error.message))
page.on('requestfailed', request => cancelled.push({ path: new URL(request.url()).pathname, error: request.failure()?.errorText }))
const directory = '/fixture/A/.masc/config/lane-addons', path = directory + '/pkg.toml'
const original = 'id = "pkg"\nrun_id = "run"\nmanifest_path = "../pkg/lane.toml"\n[binding]\nsources = []\n'
let source = original, revision = 'r1', title = 'Fixture worker', enabled = true
const document = () => ({ file_name: 'pkg.toml', source_path: path, source_text: source, source_revision: revision, desired_revision: 'semantic', validation: { valid: true, messages: [] } })
const snapshot = () => ({ configuration: { directory, complete: true, issues: [], declarations: [{ id: 'pkg', source_path: path, enabled, desired_revision: 'semantic', applied_revision: null, instance_id: null }] },
  instances: [{ instance_id: 'worker', run_id: 'run', addon_id: 'fixture', title, revision: 'v1', incarnation: 'i1', action_schema: null, binding: {}, package: { binding_schema: null, presentation: { description: null, readings: [] }, outputs: {} }, configuration: null, phase: { kind: 'attached' }, observation_seq: 0, rows_count: 0 }], rows: [], coverage: [] })
const slice = { complete: true, coverage: [], rows: [{ id: 'event', lane_id: 'worker/output', kind: 'value', title: 'Frozen observation', observed_at: 1, subject_id: 'subject', actor: null, clock: null, fields: {}, evidence: [], related_ids: [] }] }
const send = (route, body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
const inventoryReady = route => send(route, snapshot()), sliceReady = route => send(route, slice)
let inventoryHandler = inventoryReady, sliceHandler = sliceReady
function hold() {
  let accept
  const promise = new Promise(resolve => { accept = resolve })
  return { promise, handler: route => { accept(route) } }
}
await context.route('**/api/**', async route => {
  const request = route.request(), url = new URL(request.url()), p = url.pathname
  if (!p.startsWith('/api/')) return route.continue()
  if (request.method() !== 'GET') {
    writes.push({ path: p, body: request.postDataJSON() })
    if (p === '/api/v1/lane-addons/declaration') {
      const body = request.postDataJSON()
      assert.equal(body.mode, 'save'); assert.equal(body.file_name, 'pkg.toml'); assert.equal(body.expected_source_revision, revision)
      assert.equal(body.source_text, 'enabled = false\n' + original)
      source = body.source_text; revision = 'r2'; enabled = false
      return send(route, { document: document(), write: { state: 'saved', durability: 'durable', detail: null }, application: 'pending_reconciliation' })
    }
    unexpected.push(p); return send(route, { error: 'Unexpected write' }, 500)
  }
  reads.push({ path: p, query: url.search })
  if (p === '/api/v1/auth/dev-token' || p === '/api/v1/dashboard/dev-token') return send(route, { token: 'fixture', actor: 'fixture', role: 'admin' })
  if (p === '/api/v1/lane-addons') return inventoryHandler(route)
  if (p === '/api/v1/lane-addons/slice') return sliceHandler(route)
  if (p === '/api/v1/lane-addons/declaration') { assert.equal(url.searchParams.get('source_path'), path); return send(route, document()) }
  unexpected.push(p); return send(route, { error: 'Unexpected fixture route' }, 500)
})
const click = name => page.getByRole('button', { name, exact: true }).click()
const loaded = () => page.getByRole('radio', { name: title, exact: true }).waitFor()
const frozen = () => page.getByText('Frozen observation', { exact: true }).waitFor()
const invisible = text => page.getByText(text, { exact: true }).waitFor({ state: 'hidden' })
const url = server.resolvedUrls.local[0] + 'evidence/2026-10-05-web-lane-read-ownership/fixture.html'
try {
  await page.goto(url); await loaded()
  let gate = hold(); sliceHandler = gate.handler; await click('Slice'); let pending = await gate.promise
  title = 'Worker after refresh'; await click('Refresh'); await loaded()
  await page.getByText('Reading requested slice…', { exact: true }).waitFor()
  await send(pending, slice); await frozen(); await invisible('Reading requested slice…')
  checks.push('pending Slice survives manual inventory refresh and both results display')

  gate = hold(); inventoryHandler = gate.handler; await click('Refresh'); pending = await gate.promise
  sliceHandler = sliceReady; await click('Slice'); await invisible('Reading requested slice…')
  await page.getByText('Reading retained observations…', { exact: true }).waitFor()
  title = 'Worker after Slice'; await send(pending, snapshot()); await loaded()
  checks.push('Slice completion leaves pending inventory request and loading state intact')

  const inv = hold(), sl = hold(); inventoryHandler = inv.handler; sliceHandler = sl.handler
  await click('Refresh'); const invRoute = await inv.promise; await click('Slice'); const sliceRoute = await sl.promise
  await click('Clear slice'); await invisible('Reading requested slice…')
  await page.getByText('Reading retained observations…', { exact: true }).waitFor()
  title = 'Worker after Clear slice'; await send(invRoute, snapshot()); await loaded()
  await send(sliceRoute, slice); await invisible('Frozen observation')
  checks.push('Clear slice cancels only Slice; inventory completes and cancelled late Slice stays hidden')

  inventoryHandler = route => send(route, { error: 'Inventory unavailable' }, 503)
  await click('Refresh'); await page.getByRole('alert').filter({ hasText: 'Inventory unavailable' }).waitFor()
  sliceHandler = sliceReady; await click('Slice'); await frozen()
  await page.getByRole('alert').filter({ hasText: 'Inventory unavailable' }).waitFor()
  checks.push('successful Slice preserves failed inventory evidence and stale-inventory notice')

  sliceHandler = route => send(route, { error: 'Slice unavailable' }, 503)
  await click('Slice'); await page.getByRole('alert').filter({ hasText: 'Slice unavailable' }).waitFor()
  inventoryHandler = inventoryReady; await click('Refresh'); await invisible('Reading retained observations…')
  await page.getByRole('alert').filter({ hasText: 'Slice unavailable' }).waitFor(); await page.getByRole('alert').filter({ hasText: 'Inventory unavailable' }).waitFor({ state: 'hidden' })
  await page.screenshot({ path: out + 'independent-errors-desktop.png', fullPage: true })
  checks.push('successful inventory refresh preserves Slice failure and its frozen data')

  await click('Clear slice'); await click('Configure activity for pkg')
  const toggle = page.getByRole('switch', { name: 'Activity draft for pkg', exact: true })
  await toggle.waitFor(); await toggle.click()
  gate = hold(); sliceHandler = gate.handler; await click('Slice'); pending = await gate.promise
  const before = reads.filter(r => r.path === '/api/v1/lane-addons').length
  await click('Save activity'); await page.getByText(/Activity configuration saved/).waitFor()
  await page.getByText('Observed configuration: Off · no current worker observed', { exact: true }).waitFor()
  assert.ok(reads.filter(r => r.path === '/api/v1/lane-addons').length > before)
  await page.getByText('Reading requested slice…', { exact: true }).waitFor()
  await send(pending, slice); await frozen()
  checks.push('explicit activity save triggers inventory refresh without cancelling pending Slice; receipt stays pending reconciliation')

  const oldInv = hold(), oldSlice = hold(); inventoryHandler = oldInv.handler; sliceHandler = oldSlice.handler
  await click('Refresh'); const oldInventoryRoute = await oldInv.promise
  await click('Slice'); const oldSliceRoute = await oldSlice.promise
  title = 'Workspace B worker'; inventoryHandler = inventoryReady; await click('Fixture workspace B'); await loaded()
  await send(oldInventoryRoute, { ...snapshot(), instances: [] }); await send(oldSliceRoute, slice)
  await invisible('Frozen observation'); await loaded()
  checks.push('workspace transition aborts both readers and ignores old-workspace completions')

  inventoryHandler = route => send(route, { error: 'Initial inventory unavailable' }, 503)
  sliceHandler = route => send(route, { error: 'Initial slice unavailable' }, 503)
  const emptyPage = await context.newPage(); await emptyPage.setViewportSize({ width: 390, height: 844 })
  await emptyPage.goto(url); await emptyPage.getByRole('alert').filter({ hasText: 'Initial inventory unavailable' }).waitFor()
  await emptyPage.getByRole('button', { name: 'Slice', exact: true }).click()
  await emptyPage.getByRole('alert').filter({ hasText: 'Initial slice unavailable' }).waitFor()
  await emptyPage.getByText(/No observations have been loaded/).waitFor()
  assert.equal(await emptyPage.getByText(/The latest loaded inventory remains visible/).count(), 0)
  await emptyPage.screenshot({ path: out + 'no-data-mobile.png', fullPage: true })
  checks.push('initial inventory and Slice failure show both errors and honestly report no retained observations')
  assert.equal(writes.length, 1); assert.deepEqual(errors, []); assert.deepEqual(unexpected, [])
  await writeFile(out + 'browser-result.json', JSON.stringify({ scope: 'Synthetic HTTP, actual styled Status/router/panel/decoders; not live backend or native TUI', checks, reads, writes, errors, unexpected, cancelled }, null, 2) + '\n')
  console.log(JSON.stringify({ checks: checks.length, reads: reads.length, writes: writes.length, errors, unexpected }))
} catch (error) {
  await writeFile(out + 'browser-failure.json', JSON.stringify({ error: String(error), checks, reads, writes, errors, unexpected, cancelled, text: await page.locator('body').innerText() }, null, 2))
  throw error
} finally { await browser.close(); await server.close(); await rm(cacheDir, { recursive: true, force: true }) }
