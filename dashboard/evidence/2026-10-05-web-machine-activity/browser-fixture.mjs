import { chromium } from 'playwright'
import { createServer } from 'vite'
import { createHash } from 'node:crypto'
import assert from 'node:assert/strict'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { getStaticTOMLValue, parseTOML } from 'toml-eslint-parser'
import { committedRuntimeTomlConfigFixture } from '../../src/lib/runtime-config-receipt.test-fixture.ts'

const out = fileURLToPath(new URL('.', import.meta.url))
const root = fileURLToPath(new URL('../..', import.meta.url))
const cacheDir = await mkdtemp(join(tmpdir(), 'masc-web-machine-vite-'))
const server = await createServer({ root, cacheDir, configFile: root + 'vite.config.ts',
  server: { host: '127.0.0.1', port: 0, watch: null } })
await server.listen()
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1440, height: 1100 } })
page.setDefaultTimeout(10000)
const errors = [], unexpected = [], mutations = [], checks = []
const initial = '# operator notes\nmachines={msx={enabled=true},dos={enabled=false}} # retain machines comment\n[providers.fixture]\nlabel="untouched"\n'
let text = initial, reads = 0, applied = 0, refusePreview = false, loseReply = false, failInventory = false
let observedOverride = 'off'
const path = '/fixture/runtime.toml'
const revision = source => createHash('sha256').update('runtime_config_source\0' + source).digest('hex')
const config = () => ({ ok: true, path, file_name: 'runtime.toml', source_text: text, source_revision: revision(text),
  provider_protocols: [{ protocol: 'openai-compatible-http', transport: 'endpoint', semantics: 'http_provider',
    credential_policy: 'optional', requires_non_interactive: false, provider_fields: [], required_provider_fields: [] }],
  reserved_provider_ids: ['providers', 'models', 'runtime', 'machines'] })
const parsed = source => getStaticTOMLValue(parseTOML(source, { tomlVersion: '1.0' }))
const seed = JSON.parse(await readFile(new URL('../../src/api/fixtures/lane-inventory.json', import.meta.url), 'utf8'))
function reading() {
  const data = structuredClone(seed), declared = parsed(text).machines
  data.observed_at = Date.now() / 1000
  for (const row of data.rows) {
    if (row.selection.kind !== 'machine') continue
    row.state.activity = observedOverride ?? (declared[row.selection.machine]?.enabled === false ? 'off' : 'on')
    row.state.publication = 'no_screen'
  }
  return data
}
page.on('pageerror', error => errors.push(error.message))
await page.route('**/api/**', async route => {
  const request = route.request(), pathname = new URL(request.url()).pathname
  if (!pathname.startsWith('/api/')) return route.continue()
  const send = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
  if (request.method() !== 'GET') mutations.push({ path: pathname, body: request.postDataJSON() })
  if (pathname === '/api/v1/dashboard/dev-token') return send({ token: 'synthetic-fixture-token', actor: 'dashboard', role: 'admin' })
  if (pathname === '/api/v1/runtime/config/raw/preview') return send({ ok: true, can_save: !refusePreview,
    validation: { valid: !refusePreview, schema_version: 1, current_schema_version: 1, forward_schema: false, issues: [] } })
  if (pathname === '/api/v1/runtime/config/raw') {
    if (request.method() === 'GET') return send(config())
    const body = request.postDataJSON()
    if (body.expected_source_revision !== revision(text)) return send({ code: 'revision_conflict', error: 'file changed',
      current: { source_path: path, source_text: text, source_revision: revision(text) } }, 409)
    text = body.source_text; applied++; observedOverride = null
    if (loseReply) { loseReply = false; return send({ error: 'synthetic reply lost after commit' }, 503) }
    const receipt = committedRuntimeTomlConfigFixture(config())
    receipt.source_revision = revision(text); receipt.commit.source_revision = revision(text)
    receipt.application.skills.input_source_revision = revision(text)
    return send(receipt)
  }
  if (pathname === '/api/v1/lanes') {
    reads++
    return failInventory ? send({ error: 'synthetic inventory unavailable' }, 503) : send(reading())
  }
  if (pathname === '/api/v1/dashboard/standalone-lanes') return send(reading().exact_snapshot)
  if (pathname === '/api/v1/runtime/resolved') return send({ config_path: path, default_runtime: null, runtimes: [], lanes: [], assignments: [] })
  if (pathname === '/api/v1/providers') return send({ providers: [] })
  if (pathname === '/api/v1/runtime/params') return send({ parameters: [] })
  if (pathname === '/api/v1/dashboard/shell') return send({})
  if (pathname === '/api/v1/dashboard/execution') return send(await page.evaluate(() => window.fixtureExecution()))
  if (pathname === '/api/v1/dashboard/keepers/deletions') return send({ operations: [], errors: [], configuration_removals: [], configuration_errors: [] })
  unexpected.push(pathname); return send({ error: 'unexpected fixture route' }, 500)
})
const click = name => page.getByRole('button', { name, exact: true }).click()
async function open(machine = 'msx') {
  await click('Fixture All Lanes')
  const id = `machine/${machine}`, row = seed.rows.find(item => item.id === id)
  await page.getByRole('searchbox', { name: 'Find a Lane' }).fill(id)
  await page.locator('article').filter({ has: page.getByText(id, { exact: true }) })
    .getByRole('button', { name: `Inspect ${row.label}`, exact: true }).click()
  const details = page.getByRole('region', { name: `Details for ${row.label}` })
  const button = details.getByRole('button', { name: /활동 설정 열기/ })
  if (await button.count()) await button.click()
  await details.getByRole('switch').waitFor()
  await page.waitForFunction(() => !document.querySelector('[role=switch]')?.disabled)
  return details
}
try {
  await page.goto(`http://127.0.0.1:${server.httpServer.address().port}/dashboard/evidence/2026-10-05-web-machine-activity/fixture.html`)
  await page.getByTestId('runtime-toml-nav-toml').click()
  await page.waitForFunction(expected => document.querySelector('[data-testid="runtime-toml-source"]')?.value === expected, initial)
  const rawDraft = initial + '# unsaved raw draft\n'
  await page.getByTestId('runtime-toml-source').fill(rawDraft)
  let details = await open()
  await details.getByText('파일 설정: 켜짐', { exact: true }).waitFor()
  await details.getByText('서버 활동 (마지막 조회): 꺼짐', { exact: true }).waitFor()
  await details.getByText(/파일 설정과 마지막 서버 활동이 다릅니다/).waitFor()
  checks.push('file and last observed server activity are separate')
  await details.getByRole('switch').click()
  assert.equal(await details.getByRole('switch').getAttribute('aria-checked'), 'false')
  assert.equal(mutations.length, 0); checks.push('open and toggle make no writes')
  await click('Fixture Runtime'); details = await open()
  assert.equal(await details.getByRole('switch').getAttribute('aria-checked'), 'false')
  checks.push('navigation retains the MSX draft')
  refusePreview = true; await click('활동 설정 저장')
  await details.getByText(/설정 검증에서 저장을 거절했습니다/).waitFor()
  assert.equal(mutations.filter(x => x.path === '/api/v1/runtime/config/raw').length, 0)
  refusePreview = false; checks.push('preview refusal preserves the draft and does not write')
  text = initial + '# concurrent change\n'; const concurrentRevision = revision(text)
  await click('활동 설정 저장'); await click('활동 값만 다시 적용')
  assert.equal(text, initial + '# concurrent change\n'); checks.push('CAS conflict preserves file and draft')
  await click('활동 설정 저장')
  await details.getByText('파일 설정: 꺼짐', { exact: true }).waitFor()
  await details.getByText('서버 활동 (마지막 조회): 꺼짐', { exact: true }).waitFor()
  assert.deepEqual(parsed(text).machines, { msx: { enabled: false }, dos: { enabled: false } })
  assert.deepEqual(parsed(text).providers, parsed(initial).providers)
  assert.ok(text.includes('# retain machines comment')); assert.ok(text.includes('# concurrent change'))
  assert.equal(mutations.filter(x => x.path === '/api/v1/runtime/config/raw').at(-1).body.expected_source_revision, concurrentRevision)
  checks.push('explicit reapply/save preserves inline TOML, comments, DOS and concurrent edits')
  await details.scrollIntoViewIfNeeded(); await page.screenshot({ path: out + 'machine-off-saved.png', animations: 'disabled' })
  await click('Fixture Runtime'); await page.getByTestId('runtime-toml-source').waitFor()
  assert.equal(await page.getByTestId('runtime-toml-source').inputValue(), rawDraft)
  assert.equal(await page.getByTestId('runtime-toml-save').isDisabled(), true)
  checks.push('raw draft is retained with its stale write basis withdrawn')
  details = await open('dos'); await details.getByRole('switch').click()
  loseReply = true; await click('활동 설정 저장')
  await details.getByText('파일 설정: 켜짐', { exact: true }).waitFor()
  await details.getByText('서버 활동 (마지막 조회): 켜짐', { exact: true }).waitFor()
  await details.getByText(/이전 저장 결과는 미확정입니다/).waitFor()
  assert.equal(await details.getByRole('button', { name: '활동 설정 저장', exact: true }).isDisabled(), true)
  const beforeReapply = mutations.length
  await click('활동 값만 다시 적용')
  assert.equal(await details.getByRole('button', { name: '활동 설정 저장', exact: true }).isDisabled(), true)
  assert.equal(mutations.length, beforeReapply)
  assert.deepEqual(parsed(text).machines, { msx: { enabled: false }, dos: { enabled: true } })
  checks.push('lost commit reply triggers readback, retains uncertainty, and never repeats the write')
  details = await open('msx'); await details.getByRole('switch').click(); await click('활동 설정 저장')
  await details.getByText('파일 설정: 켜짐', { exact: true }).waitFor()
  await details.getByText('서버 활동 (마지막 조회): 켜짐', { exact: true }).waitFor()
  assert.deepEqual(parsed(text).machines, { msx: { enabled: true }, dos: { enabled: true } })
  checks.push('independent MSX/DOS changes do not load or restore a machine')
  failInventory = true; await click('현재 설정 읽기')
  await details.getByText(/서버 활동 조회 실패/).waitFor()
  await details.getByText('파일 설정: 켜짐', { exact: true }).waitFor()
  failInventory = false; await click('현재 설정 읽기')
  await details.getByText('서버 활동 (마지막 조회): 켜짐', { exact: true }).waitFor()
  assert.equal(await details.getByText(/서버 활동 조회 실패/).count(), 0)
  checks.push('failed observation is visible and explicitly recoverable')
  await page.setViewportSize({ width: 390, height: 844 }); await details.scrollIntoViewIfNeeded()
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true)
  await page.screenshot({ path: out + 'machine-mobile.png', animations: 'disabled' })
  const mobileControls = await details.getByRole('button').evaluateAll(nodes => nodes.map(node => ({
    text: node.textContent, opacity: getComputedStyle(node).opacity, visibility: getComputedStyle(node).visibility,
    width: node.getBoundingClientRect().width, height: node.getBoundingClientRect().height,
  })))
  assert.ok(mobileControls.every(node => Number(node.opacity) > 0 && node.visibility === 'visible' && node.width > 0 && node.height > 0))
  checks.push('mobile controls remain visible without horizontal overflow')
  assert.equal(applied, 3)
  assert.equal(mutations.filter(x => x.path === '/api/v1/runtime/config/raw').length, 4)
  assert.equal(mutations.filter(x => x.path === '/api/v1/runtime/config/raw/preview').length, 5)
  assert.equal(mutations.length, 9); assert.deepEqual(errors, []); assert.deepEqual(unexpected, [])
  checks.push('only explicit previews/saves: no model resume, machine action, unexpected route or page error')
  await writeFile(out + 'browser-result.json', JSON.stringify({ passed: true, checked_at: new Date().toISOString(), browser: browser.version(),
    scope: 'Actual styled Status, machine panel/session, raw editor, router and API with synthetic HTTP. No real backend validation/publication, machine execution, native TUI, CI or deployment.',
    checks, reads, applied, mutations, mobileControls, errors, unexpected }, null, 2) + '\n')
  console.log(JSON.stringify({ passed: true, checks, reads, applied, mutations: mutations.length, errors, unexpected }))
} catch (error) {
  await writeFile(out + 'browser-failure.json', JSON.stringify({ error: String(error), errors, unexpected, mutations,
    body: await page.locator('body').innerText() }, null, 2) + '\n'); throw error
} finally { await browser.close(); await server.close(); await rm(cacheDir, { recursive: true, force: true }) }
