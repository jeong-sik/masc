import { chromium } from 'playwright'
import { createServer } from 'vite'
import assert from 'node:assert/strict'
import { writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { committedRuntimeTomlConfigFixture } from '../../src/lib/runtime-config-receipt.test-fixture.ts'
import { lanes } from './lanes.mjs'
const out = fileURLToPath(new URL('.', import.meta.url))
const server = await createServer({ server: { host: '127.0.0.1', port: 0 } }); await server.listen()
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } })
page.setDefaultTimeout(10000)
const errors = [], unexpected = [], writes = [], reads = []
let active = 'A', releaseSave, saveCount = 0
const path = '/fixture/shared/runtime.toml'
const config = workspace => ({ ok: true, path, file_name: 'runtime.toml', source_text: `[runtime]\n# workspace ${workspace}\n`,
  source_revision: (workspace === 'A' ? 'a' : 'b').repeat(64), provider_protocols: [{ protocol: 'openai-compatible-http', transport: 'endpoint', semantics: 'http_provider', credential_policy: 'optional', requires_non_interactive: false, provider_fields: [], required_provider_fields: [] }],
  reserved_provider_ids: ['runtime', 'models', 'providers', 'board', 'voice', 'turn'] })
const current = { A: config('A'), B: config('B') }
page.on('pageerror', error => errors.push(error.message))
await page.route('**/api/**', async route => {
  const request = route.request(), pathname = new URL(request.url()).pathname
  if (!pathname.startsWith('/api/')) return route.continue()
  const send = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
  if (pathname === '/api/v1/dashboard/dev-token') return send({ token: 'synthetic-fixture-token', actor: 'dashboard', role: 'admin' })
  if (pathname === '/api/v1/runtime/config/raw') {
    if (request.method() === 'GET') { reads.push(active); return send(current[active]) }
    const owner = active, body = request.postDataJSON(); writes.push({ workspace: owner, body }); saveCount++
    if (saveCount === 1) await new Promise(resolve => { releaseSave = resolve })
    assert.equal(body.expected_source_revision, current[owner].source_revision)
    current[owner] = { ...current[owner], source_text: body.source_text, source_revision: (saveCount === 1 ? 'c' : 'd').repeat(64) }
    const committed = committedRuntimeTomlConfigFixture(current[owner])
    return send(JSON.parse(JSON.stringify(committed).replaceAll('runtime-source-revision', current[owner].source_revision)))
  }
  if (pathname === '/api/v1/runtime/setup/resume') return send({ runtime_ready: true, exact_output_authority_available: true, model_setup: { status: 'available' } })
  if (pathname === '/api/v1/runtime/params') return send({ parameters: [] })
  if (pathname === '/api/v1/dashboard/standalone-lanes') return send(lanes)
  if (pathname === '/api/v1/runtime/resolved') return send({ config_path: path, default_runtime: null, runtimes: [], lanes: [], assignments: [] })
  if (pathname === '/api/v1/providers') return send({ providers: [] })
  if (pathname === '/api/v1/dashboard/shell') return send({})
  if (pathname === '/api/v1/dashboard/execution') return send(await page.evaluate(() => window.fixtureExecution()))
  if (pathname === '/api/v1/dashboard/keepers/deletions') return send({ operations: [], errors: [], configuration_removals: [], configuration_errors: [] })
  if (pathname === '/api/v1/skills') return send({ schema: 'masc.skill-snapshot/v1', state: 'uninitialized' })
  if (pathname === '/api/v1/async-requests') return send({ schema: 'masc.async-request-observation/v1', status: 'ready',
    summary: { active: 0, runtime_owned: 0, ownership_unknown: 0, record_errors: 0 }, requests: [], record_errors: [], startup_recovery: null })
  unexpected.push(pathname); return send({ error: 'unexpected route' }, 500)
})
const click = name => page.getByRole('button', { name, exact: true }).click()
const byId = id => page.getByTestId('runtime-toml-' + id)
const textIs = text => page.waitForFunction(expected => document.querySelector('[data-testid="runtime-toml-source"]')?.value === expected, text)
try {
  await page.goto(`http://127.0.0.1:${server.httpServer.address().port}/dashboard/evidence/2026-10-04-runtime-drafts/fixture.html`)
  await byId('nav-toml').click(); await textIs(current.A.source_text)
  const draftA = current.A.source_text + '# unsaved A\n'
  await byId('source').fill(draftA)
  await click('Fixture leave to Skills'); await byId('source').waitFor({ state: 'detached' })
  assert.equal(await page.evaluate(() => { const event = new Event('beforeunload', { cancelable: true }); window.dispatchEvent(event); return event.defaultPrevented }), true)
  await click('Fixture return to Runtime'); await textIs(draftA)
  assert.equal(await byId('nav-toml').getAttribute('aria-pressed'), 'true'); assert.equal(reads.length, 1)
  await byId('save').click(); await page.waitForFunction(() => document.querySelector('[data-testid="runtime-toml-status"]')?.textContent.includes('saving'))
  const newer = draftA + '# typed while save is pending\n'
  await byId('source').fill(newer); await click('Fixture leave to Skills')
  const receipt = page.waitForResponse(response => response.url().endsWith('/runtime/config/raw') && response.request().method() === 'POST')
  releaseSave(); await receipt
  await click('Fixture return to Runtime'); await textIs(newer)
  await page.getByText(/저장 중 추가한 초안은 저장되지 않았습니다/).waitFor()
  await page.waitForFunction(() => !document.querySelector('[data-testid="runtime-toml-save"]')?.disabled)
  await page.screenshot({ path: out + 'late-save-newer-draft.png', fullPage: true })
  active = 'B'; await click('Fixture workspace B'); await byId('nav-toml').click(); await textIs(current.B.source_text)
  const draftB = current.B.source_text + '# isolated B draft\n'; await byId('source').fill(draftB)
  current.A = { ...current.A, source_text: current.A.source_text + '# another writer while away\n', source_revision: 'e'.repeat(64) }
  active = 'A'; await click('Fixture workspace A'); await textIs(newer); await byId('conflict').waitFor()
  assert.equal(await byId('save').isDisabled(), true)
  await page.screenshot({ path: out + 'workspace-a-comparison.png', fullPage: true })
  await byId('adopt-revision').click(); assert.equal(writes.length, 1)
  await byId('save').click()
  await page.waitForFunction(() => document.querySelector('[data-testid="runtime-toml-status"]')?.textContent.includes('saved'))
  assert.equal(writes.length, 2); assert.equal(writes[1].body.expected_source_revision, 'e'.repeat(64))
  assert.equal(writes[1].body.source_text, newer)
  active = 'B'; await click('Fixture workspace B'); await textIs(draftB)
  await click('Fixture withdraw authority'); await byId('source').waitFor({ state: 'detached' })
  await page.getByText(/보관된 초안은 유지됩니다/).waitFor()
  assert.deepEqual(errors, []); assert.deepEqual(unexpected, [])
  await writeFile(out + 'browser-result.json', JSON.stringify({ passed: true, browser: await browser.version(),
    scope: 'Actual Status/RuntimePanel/router/editor and API decoding with synthetic HTTP. No native/backend/deployment.',
    assertions: ['Status navigation unmounts editor', 'dirty unload guard survives navigation', 'draft and section restored without raw refetch',
      'late save settles while unmounted', 'edits made during save remain dirty', 'identical paths keep separate workspace drafts',
      'changed file on return requires comparison; draft retained', 'revision adoption does not write', 'next explicit save uses accepted revision and newer text',
      'withdrawn authority hides the editor without discarding drafts'], writes, reads, errors, unexpected }, null, 2) + '\n')
  console.log('PASS: 10 Runtime draft browser assertions; 2 explicit raw saves; zero page errors')
} catch (error) {
  await writeFile(out + 'browser-failure.json', JSON.stringify({ error: String(error), errors, unexpected, writes, reads,
    body: await page.locator('body').innerText() }, null, 2) + '\n'); throw error
} finally { await browser.close(); await server.close() }
