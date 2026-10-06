import { chromium } from 'playwright'
import { createServer } from 'vite'
import assert from 'node:assert/strict'
import { writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
const out = fileURLToPath(new URL('.', import.meta.url))
const server = await createServer({ server: { host: '127.0.0.1', port: 0 } })
await server.listen()
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } })
page.setDefaultTimeout(10000)
const errors = [], unhandled = [], writes = [], reads = []
let active = 'A', failB = false, releaseObserve, releaseAction, releaseStatus, holdStatus = true
const receipts = new Map()
const snapshot = workspace => ({ configuration: null, rows: [], coverage: [], instances: [{
  instance_id: `${workspace}-worker`, run_id: workspace, addon_id: 'fixture', title: `${workspace} package`,
  revision: 'fixture', incarnation: `${workspace}-worker`, configuration: null,
  action_schema: { type: 'object', properties: { action: { type: 'object' } } },
  phase: { kind: 'attached' }, observation_seq: 0, rows_count: 0,
  package: { outputs: {}, binding_schema: null, presentation: { description: null, readings: [] } },
}] })
page.on('pageerror', error => errors.push(error.message))
await page.route('**/api/**', async route => {
  const request = route.request(), url = new URL(request.url()), path = url.pathname
  if (!path.startsWith('/api/')) return route.continue()
  const reply = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
  if (request.method() === 'GET') reads.push({ workspace: active, path })
  if (path === '/api/v1/lane-addons') return active === 'B' && failB
    ? reply({ error: 'B inventory unavailable' }, 503) : reply(snapshot(active))
  if (path === '/api/v1/lane-addons/slice') return reply({ complete: true, coverage: [], rows: [{
    id: 'A-event', lane_id: 'A-worker/output', kind: 'value', title: 'Frozen A observation', observed_at: 1,
    subject_id: 'A-subject', actor: null, clock: null, fields: { source: 'A' }, evidence: [], related_ids: [],
  }] })
  if (path === '/api/v1/lane-addons/observe' && request.method() === 'POST') {
    const body = request.postDataJSON(); writes.push({ path, body })
    if (body.instance_id === 'A-worker') await new Promise(resolve => { releaseObserve = resolve })
    return reply({ receipt: `${body.instance_id} observation accepted` })
  }
  if (path === '/api/v1/lane-addons/actions') {
    if (request.method() === 'POST') {
      const body = request.postDataJSON(); writes.push({ path, body })
      const receipt = { ...body, incarnation: body.expected_incarnation, requester: 'fixture', executor: null,
        input_sha256: 'fixture', state: 'queued', result: null, detail: null }
      receipts.set(body.request_id, receipt)
      if (body.instance_id === 'A-worker') await new Promise(resolve => { releaseAction = resolve })
      return reply(receipt)
    }
    if (holdStatus) await new Promise(resolve => { releaseStatus = resolve })
    return reply(receipts.get(url.searchParams.get('request_id')))
  }
  unhandled.push(path); return reply({ error: 'unexpected route' }, 500)
})
const click = name => page.getByRole('button', { name, exact: true }).click()
const waitBody = text => page.waitForFunction(value => document.body.innerText.includes(value), text)
const noText = async text => assert.equal((await page.locator('body').innerText()).includes(text), false)
async function choose(workspace) {
  await page.getByRole('combobox', { name: /Action instance/ }).selectOption(`${workspace}-worker:${workspace}-worker`)
}
try {
  await page.goto(`http://127.0.0.1:${server.httpServer.address().port}/dashboard/evidence/2026-10-04-addons-workspace/fixture.html`)
  await page.getByRole('radio').waitFor()
  await click('Slice'); await waitBody('Frozen A observation')
  await click('Observe')
  await choose('A'); await click('Send new request'); await waitBody('Awaiting acceptance receipt')
  const requestA = writes.find(item => item.path.endsWith('/actions')).body.request_id
  failB = true; active = 'B'; await click('Fixture workspace B')
  await waitBody('B inventory unavailable')
  await waitBody('No observations loaded for the current workspace.')
  await noText('No Lane instances or retained observations.')
  assert.equal(await page.getByRole('radio').count(), 0)
  assert.equal(await page.getByRole('button', { name: 'Observe', exact: true }).count(), 0)
  assert.equal(await page.getByRole('button', { name: 'Remove worker', exact: true }).count(), 0)
  await noText('Frozen A observation'); await noText(requestA)
  await page.screenshot({ path: out + 'workspace-b-read-failed.png', fullPage: true })
  failB = false; await click('Refresh'); await page.getByRole('radio').waitFor()
  await noText('Frozen A observation')
  await click('Observe'); await waitBody('B-worker observation accepted')
  const oldObservation = page.waitForResponse(response => response.url().endsWith('/observe')
    && response.request().postDataJSON().instance_id === 'A-worker')
  releaseObserve(); await oldObservation
  await choose('B')
  assert.equal(await page.getByRole('button', { name: 'Send new request' }).isEnabled(), true)
  await click('Send new request'); await waitBody('Queued')
  const acceptedA = page.waitForResponse(response => response.url().endsWith('/actions')
    && response.request().method() === 'POST' && response.request().postDataJSON().instance_id === 'A-worker')
  releaseAction(); await acceptedA
  await noText(requestA); await noText('A-worker observation accepted')
  await waitBody('B-worker observation accepted')
  active = 'A'; await click('Fixture workspace A'); await waitBody(`Request ID: ${requestA}`)
  await click('Check request status'); await page.getByRole('button', { name: 'Checking request status…', exact: true }).waitFor()
  active = 'B'; await click('Fixture workspace B'); await waitBody('B package')
  holdStatus = false; releaseStatus()
  active = 'A'; await click('Fixture workspace A')
  assert.equal(await page.getByRole('button', { name: 'Check request status', exact: true }).isEnabled(), true)
  await click('Check request status')
  await page.waitForFunction(() => [...document.querySelectorAll('button')].some(button => button.textContent === 'Check request status' && !button.disabled))
  await page.screenshot({ path: out + 'workspace-a-request-restored.png', fullPage: true })
  const readCount = reads.length
  await click('Fixture withdraw authority'); await waitBody('Workspace authority is being verified')
  assert.equal(await page.getByRole('radio').count(), 0)
  assert.equal(await page.getByRole('button', { name: 'Slice', exact: true }).isDisabled(), true)
  assert.equal(await page.locator('button[type="submit"]').filter({ hasText: /^Attach$/ }).isDisabled(), true)
  assert.equal(reads.length, readCount)
  assert.deepEqual(errors, []); assert.deepEqual(unhandled, []); assert.equal(writes.length, 4)
  await writeFile(out + 'browser-result.json', JSON.stringify({ passed: true, browser: await browser.version(),
    scope: 'Actual Status/component/API decoder in Chromium against synthetic HTTP; no native backend, worker or deployment.',
    assertions: ['B read failure removes A rows and actions', 'B never displays frozen A slice',
      'late A observation does not replace B receipt', 'A pending action does not block B',
      'late A action receipt stays in A journal', 'A return restores original request ID',
      'aborted status check can be retried on return', 'unknown authority disables reads and hides rows',
      'only four explicitly requested mutations; no automatic replay'], errors, unhandled, writes, reads }, null, 2) + '\n')
  console.log('PASS: 9 workspace browser assertions; 4 explicit synthetic mutations; zero page errors')
} catch (error) {
  await writeFile(out + 'browser-failure.json', JSON.stringify({ error: String(error), errors, unhandled, writes, reads,
    body: await page.locator('body').innerText() }, null, 2) + '\n')
  throw error
} finally { await browser.close(); await server.close() }
