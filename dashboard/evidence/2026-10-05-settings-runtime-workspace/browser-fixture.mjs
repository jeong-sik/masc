import { chromium } from 'playwright'
import { createServer } from 'vite'
import { createHash } from 'node:crypto'
import assert from 'node:assert/strict'
import { writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { committedRuntimeTomlConfigFixture } from '../../src/lib/runtime-config-receipt.test-fixture.ts'
const out = fileURLToPath(new URL('.', import.meta.url)), root = fileURLToPath(new URL('../..', import.meta.url))
const server = await createServer({ root, configFile: root + 'vite.config.ts', server: { host: '127.0.0.1', port: 0, watch: null } })
await server.listen()
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } }); page.setDefaultTimeout(10000)
const checks = [], reads = [], writes = [], errors = [], unexpected = []
const state = { A: { file: 'A.first', applied: 'A.first' }, B: { file: 'B.first', applied: 'B.first' } }
let active = 'A', readGate = null, saveGate = null, resumeGate = null
const revision = text => createHash('sha256').update('runtime_config_source\0' + text).digest('hex')
function raw(owner) {
  const text = `[runtime]\ndefault="${state[owner].file}"\n`
  return { ok: true, path: `/fixture/${owner}/runtime.toml`, file_name: 'runtime.toml', source_text: text, source_revision: revision(text),
    provider_protocols: [{ protocol: 'openai-compatible-http', transport: 'endpoint', semantics: 'http_provider', credential_policy: 'optional', requires_non_interactive: false, provider_fields: [], required_provider_fields: [] }], reserved_provider_ids: ['runtime','models','providers'] }
}
const runtimes = owner => ['first', 'second'].map(part => ({ id: `${owner}.${part}`, provider: owner, model: part,
  effective_max_context: 128000, max_context_source: 'override', max_output_tokens: null, is_local: false, is_default: state[owner].applied === `${owner}.${part}` }))
const resolved = owner => ({ config_path: `/fixture/${owner}/runtime.toml`, default_runtime: runtimes(owner).find(row => row.is_default), runtimes: runtimes(owner), lanes: [], assignments: [] })
function deferred() { let resolve; const promise = new Promise(yes => { resolve = yes }); return { promise, resolve } }
page.on('pageerror', error => errors.push(error.message))
await page.route('**/api/**', async route => {
  const request = route.request(), path = new URL(request.url()).pathname, owner = active
  if (!path.startsWith('/api/')) return route.continue()
  const send = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
  if (request.method() === 'GET') reads.push({ path, owner })
  else writes.push({ path, owner, body: request.postDataJSON() })
  if (path === '/api/v1/dashboard/dev-token') return send({ token: 'synthetic-fixture-token', actor: 'dashboard', role: 'admin' })
  if (path === '/api/v1/dashboard/config') return send({ generated_at: new Date().toISOString(), server: { version: 'fixture', git_commit: null, ocaml_version: '5.5', uptime_seconds: 1, pid: 1 }, categories: {} })
  if (path === '/api/v1/dashboard/tools') return send({ tool_inventory: { count: 0, tools: [] } })
  if (path === '/api/v1/dashboard/runtime-defaults') return send({ config_path: `/fixture/${owner}/runtime.toml`, default_runtime_id: state[owner].applied, default_model: 'fixture', default_max_context: 128000,
    runtimes: runtimes(owner).map(row => ({ ...row, max_context: row.effective_max_context })), model_routing: { media_failover: [] } })
  if (path === '/api/v1/runtime/resolved') {
    const value = resolved(owner)
    if (readGate) { const gate = readGate; readGate = null; gate.started.resolve(); await gate.promise }
    return send(value)
  }
  if (path === '/api/v1/providers') return send({ providers: [] })
  if (path === '/api/v1/runtime/config/raw') return send(raw(owner))
  if (path === '/api/v1/runtime/config/routing') {
    const body = request.postDataJSON()
    assert.equal(body.lane, 'default')
    state[owner].file = body.runtime_id
    if (saveGate) {
      const gate = saveGate; saveGate = null; gate.started.resolve(); await gate.promise
      if (gate.fail) return route.abort('failed')
    }
    const receipt = committedRuntimeTomlConfigFixture(raw(owner))
    receipt.source_revision = raw(owner).source_revision; receipt.commit.source_revision = receipt.source_revision
    receipt.application.skills.input_source_revision = receipt.source_revision
    return send(receipt)
  }
  if (path === '/api/v1/runtime/setup/resume') {
    if (resumeGate) { const gate = resumeGate; resumeGate = null; gate.started.resolve(); await gate.promise }
    state[owner].applied = state[owner].file
    return send({ runtime_ready: true, exact_output_authority_available: true, model_setup: { status: 'available' } })
  }
  if (path === '/api/v1/runtime/params') return send({ parameters: [] })
  if (path === '/api/v1/dashboard/shell') return send({})
  if (path === '/api/v1/dashboard/execution') return send(await page.evaluate(() => window.fixtureExecution()))
  if (path === '/api/v1/dashboard/keepers/deletions') return send({ operations: [], errors: [], configuration_removals: [], configuration_errors: [] })
  unexpected.push(path); return send({ error: 'unexpected fixture route' }, 500)
})
const click = name => page.getByRole('button', { name, exact: true }).click()
const select = () => page.getByTestId('runtime-routing-default')
const selected = value => page.waitForFunction(expected => document.querySelector('[data-testid="runtime-routing-default"]')?.value === expected && !document.querySelector('[data-testid="runtime-routing-default"]')?.disabled, value)
const gate = () => ({ ...deferred(), started: deferred() })
try {
  await page.goto(`http://127.0.0.1:${server.httpServer.address().port}/dashboard/evidence/2026-10-05-settings-runtime-workspace/fixture.html`)
  await selected('A.first'); checks.push('initial Settings reads current A via actual API decoders')
  const oldRead = gate(); readGate = oldRead
  await page.getByTestId('settings-runtime-refresh').click(); await oldRead.started.promise
  active = 'B'; await click('Fixture workspace B'); await selected('B.first')
  assert.equal(await select().locator('option[value="A.first"]').count(), 0)
  oldRead.resolve(); checks.push('workspace B replaces A options; late A request cannot restore them')
  await page.screenshot({ path: out + 'settings-workspace-b.png', animations: 'disabled', fullPage: true })
  const pendingSave = gate(); saveGate = pendingSave
  await select().selectOption('B.second'); await pendingSave.started.promise
  active = 'A'; await click('Fixture workspace A'); await selected('A.first')
  const response = page.waitForResponse(response => response.url().endsWith('/runtime/config/routing'))
  pendingSave.resolve(); await response
  assert.equal(writes.filter(row => row.path.endsWith('/setup/resume')).length, 0)
  assert.equal(await select().inputValue(), 'A.first'); checks.push('late B receipt neither resumes A nor replaces its Settings')
  active = 'B'; await click('Fixture workspace B'); await selected('B.first')
  const pendingResume = gate(); resumeGate = pendingResume
  await select().selectOption('B.second'); await pendingResume.started.promise
  await click('Fixture leave'); await page.getByText('Settings unmounted', { exact: true }).waitFor()
  await click('Fixture return'); await select().waitFor()
  assert.equal(await select().isDisabled(), true)
  pendingResume.resolve(); await selected('B.second')
  checks.push('sent same-workspace save survives navigation; remounted Settings refreshes after resume')
  await page.screenshot({ path: out + 'settings-resumed.png', animations: 'disabled', fullPage: true })
  const uncertainSave = { ...gate(), fail: true }; saveGate = uncertainSave
  await select().selectOption('B.first'); await uncertainSave.started.promise
  await click('Fixture leave'); await page.getByText('Settings unmounted', { exact: true }).waitFor()
  await click('Fixture return'); await select().waitFor()
  assert.equal(await select().isDisabled(), true)
  checks.push('remounted Settings shares the pending write and keeps new typed writes disabled')
  uncertainSave.resolve()
  await page.getByText(/저장 결과가 불확실합니다/).waitFor()
  assert.equal(await select().isDisabled(), true)
  await page.screenshot({ path: out + 'settings-remount-uncertain.png', animations: 'disabled', fullPage: true })
  const readsBeforeRecovery = reads.filter(row => row.path.endsWith('/config/raw')).length
  await page.getByTestId('settings-runtime-refresh').click(); await selected('B.second')
  assert.ok(reads.filter(row => row.path.endsWith('/config/raw')).length > readsBeforeRecovery)
  checks.push('lost dispatched response stays uncertain after remount until a subsequent file-inclusive refresh')
  await click('Fixture withdraw authority')
  await page.getByText('현재 작업공간을 확인한 뒤 Runtime 설정을 읽고 수정할 수 있습니다.', { exact: true }).waitFor()
  assert.equal(await select().isDisabled(), true)
  assert.equal(await select().locator('option[value="B.second"]').count(), 0)
  checks.push('unknown workspace withdraws Runtime options and disables writes')
  await page.setViewportSize({ width: 390, height: 844 })
  await page.getByTestId('settings-runtime-workspace').scrollIntoViewIfNeeded()
  await page.screenshot({ path: out + 'settings-mobile-withdrawn.png', animations: 'disabled' })
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true)
  checks.push('mobile has no horizontal overflow')
  assert.equal(writes.filter(row => row.path.endsWith('/config/routing')).length, 3)
  assert.equal(writes.filter(row => row.path.endsWith('/setup/resume')).length, 1)
  assert.deepEqual(errors, []); assert.deepEqual(unexpected, [])
  checks.push('only three explicit routing writes and one matching resume, zero page errors/unexpected routes')
  await writeFile(out + 'browser-result.json', JSON.stringify({ passed: true, checked_at: new Date().toISOString(), browser: browser.version(),
    scope: 'Actual Settings/workspace store/router/API and synthetic HTTP. No production/backend/native execution; held A read may be transport-aborted. Unit tests also deliver late responses ignoring cancellation.', checks, reads, writes, errors, unexpected }, null, 2) + '\n')
  console.log(JSON.stringify({ passed: true, checks, reads: reads.length, writes, errors, unexpected }))
} catch (error) {
  await writeFile(out + 'browser-failure.json', JSON.stringify({ error: String(error), reads, writes, errors, unexpected, body: await page.locator('body').innerText() }, null, 2) + '\n'); throw error
} finally { await browser.close(); await server.close() }
