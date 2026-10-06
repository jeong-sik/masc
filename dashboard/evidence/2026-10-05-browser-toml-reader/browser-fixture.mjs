import { chromium } from 'playwright'
import { createServer } from 'vite'
import { createHash } from 'node:crypto'
import assert from 'node:assert/strict'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { getStaticTOMLValue, parseTOML } from 'toml-eslint-parser'
import { committedRuntimeTomlConfigFixture } from '../../src/lib/runtime-config-receipt.test-fixture.ts'
const out = fileURLToPath(new URL('.', import.meta.url))
const root = fileURLToPath(new URL('../..', import.meta.url))
const cacheDir = await mkdtemp(join(tmpdir(), 'masc-browser-reader-vite-'))
const server = await createServer({ root, cacheDir, configFile: root + 'vite.config.ts', server: { host: '127.0.0.1', port: 0, watch: null } })
await server.listen()
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } }); page.setDefaultTimeout(10000)
const errors = [], unexpected = [], mutations = [], checks = []
const specialKeys = '[__proto__.browser.automation]\nenabled=false\n[providers.__proto__]\npolluted_from_browser="canary"\n'
const initial = specialKeys + '# operator notes\n[browser]\ngeckodriver="/tools/geckodriver"\nbinary="/tools/firefox"\n[browser.live]\nenabled=true # keep live comment\n[browser.stagehand]\nenabled=false\n[providers.fixture]\nlabel="untouched"\n'
let text = initial, reads = 0, applied = 0
const path = '/fixture/runtime.toml'
const revision = source => createHash('sha256').update('runtime_config_source\0' + source).digest('hex')
const config = () => ({ ok: true, path, file_name: 'runtime.toml', source_text: text, source_revision: revision(text),
  provider_protocols: [{ protocol: 'openai-compatible-http', transport: 'endpoint', semantics: 'http_provider', credential_policy: 'optional', requires_non_interactive: false, provider_fields: [], required_provider_fields: [] }],
  reserved_provider_ids: ['providers','models','runtime'] })
// The harness only converts the known benign suffix. The actual editor reads
// the complete file, including special keys. Do not pollute the Node harness.
const parsed = source => {
  assert.ok(source.startsWith(specialKeys))
  return getStaticTOMLValue(parseTOML(source.slice(specialKeys.length), { tomlVersion: '1.0' }))
}
const seed = JSON.parse(await readFile(new URL('../../src/api/fixtures/lane-inventory.json', import.meta.url), 'utf8'))
function reading() {
  const data = structuredClone(seed), declared = parsed(text).browser
  for (const row of data.rows) {
    if (row.selection.kind !== 'browser') continue
    row.state.activity = declared[row.selection.lane]?.enabled === false ? 'off' : 'on'
    if (row.state.kind === 'browser_clients') row.state.connected_clients = 2
    else row.state.registered = false
  }
  return data
}
await page.addInitScript(() => { window.prototypeBefore = Object.getOwnPropertyDescriptors(Object.prototype) })
page.on('pageerror', error => errors.push(error.message))
await page.route('**/api/**', async route => {
  const request = route.request(), pathname = new URL(request.url()).pathname
  if (!pathname.startsWith('/api/')) return route.continue()
  const send = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
  if (request.method() !== 'GET') mutations.push({ path: pathname, body: request.postDataJSON() })
  if (pathname === '/api/v1/dashboard/dev-token') return send({ token: 'synthetic-fixture-token', actor: 'dashboard', role: 'admin' })
  if (pathname === '/api/v1/runtime/config/raw/preview') return send({ ok: true, can_save: true, validation: { valid: true, schema_version: 1, current_schema_version: 1, forward_schema: false, issues: [] } })
  if (pathname === '/api/v1/runtime/config/raw') {
    if (request.method() === 'GET') return send(config())
    const body = request.postDataJSON()
    if (body.expected_source_revision !== revision(text)) return send({ code: 'revision_conflict', error: 'file changed', current: { source_path: path, source_text: text, source_revision: revision(text) } }, 409)
    text = body.source_text; applied++
    const receipt = committedRuntimeTomlConfigFixture(config())
    receipt.source_revision = revision(text); receipt.commit.source_revision = revision(text); receipt.application.skills.input_source_revision = revision(text)
    return send(receipt)
  }
  if (pathname === '/api/v1/lanes') { reads++; return send(reading()) }
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
async function inspect(id) {
  const row = seed.rows.find(item => item.id === id)
  await page.getByRole('searchbox', { name: 'Find a Lane' }).fill(id)
  await page.locator('article').filter({ has: page.getByText(id, { exact: true }) }).getByRole('button', { name: `Inspect ${row.label}`, exact: true }).click()
  return page.getByRole('region', { name: `Details for ${row.label}` })
}
async function open(id = 'browser/automation') {
  await click('Fixture All Lanes')
  const details = await inspect(id)
  const button = details.getByRole('button', { name: /활동 설정 열기/ })
  if (await button.count()) await button.click()
  await details.getByRole('switch').waitFor()
  await page.waitForFunction(() => !document.querySelector('[role=switch]')?.disabled)
  return details
}
try {
  await page.goto(`http://127.0.0.1:${server.httpServer.address().port}/dashboard/evidence/2026-10-05-browser-toml-reader/fixture.html`)
  await page.getByTestId('runtime-toml-nav-toml').click()
  await page.waitForFunction(expected => document.querySelector('[data-testid="runtime-toml-source"]')?.value === expected, initial)
  const rawDraft = initial + '# unsaved raw draft\n'
  await page.getByTestId('runtime-toml-source').fill(rawDraft)
  let details = await open()
  await details.getByRole('switch').click()
  assert.equal(await details.getByRole('switch').getAttribute('aria-checked'), 'false')
  assert.equal(mutations.length, 0); checks.push('opening and toggling make no writes')
  await click('Fixture Runtime'); details = await open()
  // A retained session may paint before the entry effect rereads it. Settle
  // an explicit read before introducing the later CAS-conflict fixture.
  await click('현재 설정 읽기')
  await page.waitForFunction(() => !document.querySelector('[role=switch]')?.disabled)
  assert.equal(await details.getByRole('switch').getAttribute('aria-checked'), 'false'); checks.push('navigation retains Browser draft')
  text = initial + '# concurrent change\n'; const concurrentRevision = revision(text)
  await click('활동 설정 저장'); await click('활동 값만 다시 적용')
  assert.equal(text, initial + '# concurrent change\n'); checks.push('CAS conflict keeps file and draft')
  await click('활동 설정 저장')
  await details.getByText('파일 설정: 꺼짐', { exact: true }).waitFor()
  await details.getByText('Off · configuration and sessions retained', { exact: true }).waitFor()
  await details.getByText('Executor not registered', { exact: true }).waitFor()
  const saved = parsed(text), original = parsed(initial)
  assert.deepEqual(saved.browser.automation, { geckodriver: '/tools/geckodriver', binary: '/tools/firefox', enabled: false })
  assert.equal(Object.hasOwn(saved.browser, 'geckodriver'), false); assert.equal(Object.hasOwn(saved.browser, 'binary'), false)
  assert.deepEqual(saved.browser.live, original.browser.live); assert.deepEqual(saved.browser.stagehand, original.browser.stagehand)
  assert.deepEqual(saved.providers, original.providers)
  assert.ok(text.includes('# keep live comment')); assert.ok(text.includes('# concurrent change'))
  assert.equal(mutations.filter(x => x.path === '/api/v1/runtime/config/raw').at(-1).body.expected_source_revision, concurrentRevision)
  checks.push('explicit reapply/save migrates flat paths, preserves other backends and concurrent edit, refreshes activity separately from executor')
  await details.scrollIntoViewIfNeeded(); await page.screenshot({ path: out + 'browser-off-saved.png', animations: 'disabled' })
  await click('Fixture Runtime'); await page.getByTestId('runtime-toml-source').waitFor()
  assert.equal(await page.getByTestId('runtime-toml-source').inputValue(), rawDraft)
  assert.equal(await page.getByTestId('runtime-toml-save').isDisabled(), true); checks.push('independent raw draft retained, old write basis withdrawn')
  details = await open('browser/stagehand')
  await details.getByRole('switch').click(); await click('활동 설정 저장')
  await details.getByText('파일 설정: 켜짐', { exact: true }).waitFor()
  await details.getByText('New requests enabled', { exact: true }).waitFor()
  await details.getByText('Executor not registered', { exact: true }).waitFor()
  assert.equal(parsed(text).browser.automation.enabled, false)
  checks.push('unconfigured Stagehand can be enabled without changing Automation or claiming an installed executor')
  await page.setViewportSize({ width: 390, height: 844 }); await details.scrollIntoViewIfNeeded()
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true)
  await page.screenshot({ path: out + 'browser-mobile.png', animations: 'disabled' }); checks.push('mobile controls without horizontal overflow')
  const mobileControls = await details.getByRole('button').evaluateAll(nodes => nodes.map(node => ({
    text: node.textContent, opacity: getComputedStyle(node).opacity, visibility: getComputedStyle(node).visibility,
    width: node.getBoundingClientRect().width, height: node.getBoundingClientRect().height,
  })))
  assert.ok(mobileControls.every(node => Number(node.opacity) > 0 && node.visibility === 'visible' && node.width > 0 && node.height > 0))
  assert.equal(applied, 2)
  assert.equal(mutations.filter(x => x.path === '/api/v1/runtime/config/raw').length, 3)
  assert.equal(mutations.filter(x => x.path === '/api/v1/runtime/config/raw/preview').length, 3)
  assert.equal(mutations.length, 6); assert.deepEqual(errors, []); assert.deepEqual(unexpected, [])
  checks.push('only three explicit previews and saves, one conflict; no model resume, page errors or unexpected routes')
  assert.equal(await page.evaluate(() => {
    const before = window.prototypeBefore, after = Object.getOwnPropertyDescriptors(Object.prototype)
    return Reflect.ownKeys(before).length === Reflect.ownKeys(after).length && Reflect.ownKeys(before).every(key => {
      const a = before[key], b = after[key]
      return b && a.value === b.value && a.get === b.get && a.set === b.set && a.writable === b.writable
        && a.enumerable === b.enumerable && a.configurable === b.configurable
    })
  }), true)
  assert.ok(text.startsWith(specialKeys))
  checks.push('special TOML namespaces preserve Object.prototype throughout actual Browser read/edit/save and remain in the source')
  await writeFile(out + 'browser-result.json', JSON.stringify({ passed: true, checked_at: new Date().toISOString(), browser: browser.version(),
    scope: 'Actual Status, Browser panel/session, raw editor, router and API with synthetic HTTP. No backend validation/publication, real Browser sessions, native TUI, CI or deployment.', checks, reads, applied, mutations, mobileControls, errors, unexpected }, null, 2) + '\n')
  console.log(JSON.stringify({ passed: true, checks, reads, applied, mutations: mutations.length, errors, unexpected }))
} catch (error) {
  await writeFile(out + 'browser-failure.json', JSON.stringify({ error: String(error), errors, unexpected, mutations, body: await page.locator('body').innerText() }, null, 2) + '\n'); throw error
} finally { await browser.close(); await server.close(); await rm(cacheDir, { recursive: true, force: true }) }
