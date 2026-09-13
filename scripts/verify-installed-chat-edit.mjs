// Read the actual installed Dashboard and a real Keeper Edit. No fixture responses.
import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { readFile, mkdir, writeFile, realpath } from 'node:fs/promises'
import { resolve, dirname } from 'node:path'
import assert from 'node:assert/strict'
const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const { applyPatch } = require('diff')
const [prefix, expectedCommit, baseUrl, outputDirectory, tokenFile, keeper, editReceiptFile, runtimeRoot] = process.argv.slice(2)
assert.ok(prefix && expectedCommit && baseUrl && outputDirectory && tokenFile && keeper && editReceiptFile && runtimeRoot,
  'Usage: INSTALLED_PREFIX EXPECTED_COMMIT BASE_URL FRESH_OUTPUT_DIR TOKEN_FILE KEEPER EDIT_RECEIPT_JSON RUNTIME_ROOT')
const output = resolve(outputDirectory)
await mkdir(output)
const digest = bytes => createHash('sha256').update(bytes).digest('hex')
async function readVerifiedBlob(ref) {
  assert.ok(ref && typeof ref === 'object', 'Expected an explicit blob reference')
  assert.match(ref.sha256, /^[0-9a-f]{64}$/)
  assert.ok(Number.isSafeInteger(ref.bytes) && ref.bytes >= 0, 'Expected an exact blob byte length')
  const bytes = await readFile(resolve(runtimeRoot, 'tool_blobs', ref.sha256.slice(0, 2), ref.sha256))
  assert.equal(bytes.length, ref.bytes, 'Stored blob byte length')
  assert.equal(digest(bytes), ref.sha256, 'Stored blob SHA-256')
  const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes)
  assert.equal(digest(Buffer.from(text)), ref.sha256, 'UTF-8 round-trip SHA-256')
  return { sha256: ref.sha256, bytes: ref.bytes, text }
}
async function readEditOriginals(receipt) {
  let result = typeof receipt.output === 'string' ? JSON.parse(receipt.output) : receipt.output
  let source = { kind: 'inline_json' }
  if (result?._blob) {
    assert.equal(result._blob.mime, 'application/vnd.masc.tool-result-manifest+json')
    const { text, ...ref } = await readVerifiedBlob(result._blob)
    const manifest = JSON.parse(text)
    assert.equal(manifest.schema, 'masc.tool-result-artifact-manifest.v1')
    assert.equal(typeof manifest.content, 'string')
    result = JSON.parse(manifest.content)
    assert.deepEqual(manifest.structured_content, result, 'Manifest content and structured_content must agree')
    source = { kind: 'verified_manifest', ...ref }
  }
  assert.equal(result?.ok, true)
  assert.equal(result.edit_snapshots?.status, 'stored')
  assert.ok(Array.isArray(receipt.artifact_refs), 'Expected receipt artifact references')
  const originals = await Promise.all(['before', 'after'].map(async side => {
    const artifact = result.edit_snapshots[side]
    assert.ok(artifact?._blob, `Missing explicit ${side} snapshot reference`)
    assert.ok(receipt.artifact_refs.some(ref => ref?._blob?.sha256 === artifact._blob.sha256),
      `${side} snapshot must be present in receipt artifact_refs`)
    for (const ref of receipt.artifact_refs.filter(ref => ref?._blob?.sha256 === artifact._blob.sha256)) {
      assert.deepEqual(ref, artifact, `${side} snapshot artifact reference must agree`)
    }
    return { side, ...await readVerifiedBlob(artifact._blob) }
  }))
  return { source, originals }
}
const events = [], assets = [], errors = [], failures = [], blocked = [], workers = [], matchedReceipts = [], navigation = []
let browser, page, health, release, expected, originals, editOutputSource, rendered, probePassed = false, assertionFailure = null
try {
  const binary = await realpath(resolve(prefix, 'masc'))
  release = JSON.parse(await readFile(resolve(dirname(binary), 'release.json'), 'utf8'))
  assert.equal(release.source_commit, expectedCommit)
  assert.equal(digest(await readFile(binary)), release.binary_sha256)
  const token = (await readFile(tokenFile, 'utf8')).trim()
  const origin = new URL(baseUrl).origin
  const healthResponse = await fetch(new URL('/health?full=1', baseUrl), { headers: { Authorization: `Bearer ${token}` } })
  assert.equal(healthResponse.status, 200)
  health = await healthResponse.json()
  assert.equal(health.build.binary_commit, expectedCommit)
  assert.equal(health.build.executable_sha256, release.binary_sha256)
  assert.equal(await realpath(health.build.executable_path), binary)
  expected = JSON.parse(await readFile(editReceiptFile, 'utf8'))
  assert.equal(expected.success, true)
  assert.equal(expected.turn_kind, 'autonomous')
  assert.match(expected.execution_id, /^[A-Za-z0-9:_-]+$/)
  const editOriginals = await readEditOriginals(expected)
  originals = editOriginals.originals
  editOutputSource = editOriginals.source
  const files = new Map(release.files.map(file => [file.path, file]))
  function collectExactReceipt(value) {
    if (!value || typeof value !== 'object') return
    if (value.record_kind === 'tool_call' && value.execution_id === expected.execution_id) matchedReceipts.push(value)
    for (const child of Object.values(value)) collectExactReceipt(child)
  }
  browser = await chromium.launch({ headless: true })
  page = await browser.newPage({ viewport: { width: 1440, height: 1100 }, serviceWorkers: 'block' })
  await page.routeWebSocket('**/*', socket => socket.close())
  page.on('pageerror', error => errors.push(error.message))
  page.on('worker', worker => workers.push(worker.url()))
  await page.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url())
    let rpc
    if (url.pathname === '/mcp' && request.method() === 'POST') {
      try { rpc = request.postDataJSON() } catch { /* malformed input is not admitted */ }
    }
    const readRpc = rpc && (['initialize', 'notifications/initialized', 'tools/list'].includes(rpc.method)
      || (rpc.method === 'tools/call' && ['masc_keeper_list', 'masc_keeper_status', 'masc_pause_status'].includes(rpc.params?.name)))
    const event = { method: request.method(), path: url.pathname, query: url.search, rpc_method: rpc?.method, tool: rpc?.params?.name }
    if (url.origin !== origin || (!['GET', 'HEAD'].includes(request.method()) && !readRpc)) {
      blocked.push(event)
      return route.abort()
    }
    try {
      const response = await route.fetch({ headers: { ...request.headers(), Authorization: `Bearer ${token}` }, maxRedirects: 0 })
      events.push({ ...event, status: response.status() })
      if (url.pathname.startsWith('/dashboard/')) {
        const name = decodeURIComponent(url.pathname.slice('/dashboard/'.length)) || 'index.html'
        const file = files.get(name)
        assert.ok(file, `Unmanifested server asset: ${name}`)
        assert.equal(response.status(), 200, name)
        const body = await response.body()
        assert.equal(digest(body), file.sha256, name)
        assets.push({ name, status: response.status(), bytes: body.length, sha256: digest(body) })
      } else if (url.pathname.startsWith(`/api/v1/keepers/${encodeURIComponent(keeper)}/`)
          && response.headers()['content-type']?.includes('application/json')) {
        collectExactReceipt(await response.json())
      }
      return route.fulfill({ response })
    } catch (error) {
      failures.push({ path: url.pathname, error: String(error) })
      return route.abort()
    }
  })
  await page.goto(new URL(`/dashboard/#keepers?keeper=${encodeURIComponent(keeper)}`, baseUrl).href)
  await page.locator('[data-keeper-chat-layout="workspace"]').waitFor({ timeout: 45000 })
  await page.getByRole('button', { name: '대화 도구', exact: true }).click()
  await page.getByTestId('kw-chat-command-search').click()
  const load = page.getByRole('button', { name: /^(전체 이력|이력 불러오기)/ })
  await load.first().waitFor({ timeout: 45000 })
  await load.first().click()
  await load.first().waitFor({ state: 'hidden', timeout: 45000 })
  await page.getByTestId('tweaks-panel-toggle').click()
  // TweakToggle currently labels its enclosing row, not its switch element.
  for (const label of ['내부 메시지', '자율턴', '자율턴 펼침']) {
    const row = page.locator('.twk-row').filter({ has: page.locator('.twk-lbl').getByText(label, { exact: true }) })
    const toggle = row.getByRole('switch')
    await toggle.waitFor()
    if (await toggle.getAttribute('aria-checked') !== 'true') await toggle.click()
  }
  await page.getByTestId('tweaks-panel-toggle').click()
  const id = expected.execution_id
  const row = page.locator(`[data-chat-tool-execution-id="${id}"], [data-chat-trace-execution-id="${id}"]`)
  // Each autonomous group keeps its own closed state independently of Tweaks.
  // Walk the actual loaded history controls until the target is rendered.
  while (await row.count() === 0) {
    const closed = page.locator('.chat-block-trace-hd[aria-expanded="false"]')
      .filter({ has: page.locator('.chat-block-trace-label').getByText('자율턴', { exact: true }) })
    const more = page.locator('.chat-auto-run-more')
    const control = await closed.count() > 0 ? closed.first() : more.first()
    if (await control.count() === 0) break
    navigation.push({ action: 'expand_autonomous_history', label: await control.innerText() })
    await control.click()
  }
  await row.first().waitFor({ timeout: 45000 })
  assert.equal(await row.count(), 1, 'The real execution must join to one rendered Edit record')
  // Historical output loads only when its execution row enters the viewport.
  // Find that identity first; waiting for a snapshot child before scrolling
  // would wait on the very lookup that bringing the row into view triggers.
  await row.scrollIntoViewIfNeeded()
  navigation.push({ action: 'reveal_execution', execution_id: id })
  await row.locator('[data-edit-snapshot-view]').waitFor({ timeout: 45000 })
  await row.getByRole('button', { name: '편집 전후 원본 보기', exact: true }).click()
  const diff = row.getByLabel('편집 원본의 Unified diff', { exact: true })
  await diff.waitFor({ timeout: 45000 })
  const before = await row.getByLabel('편집 전 전체 원본', { exact: true }).textContent()
  const after = await row.getByLabel('편집 후 전체 원본', { exact: true }).textContent()
  const patch = await diff.textContent()
  assert.equal(before, originals[0].text)
  assert.equal(after, originals[1].text)
  assert.equal(applyPatch(before, patch), after, 'Rendered patch must reconstruct the actual saved after-file')
  await diff.focus()
  assert.equal(await diff.evaluate(element => document.activeElement === element), true)
  await row.scrollIntoViewIfNeeded()
  await page.screenshot({ path: resolve(output, 'chat-edit-desktop.png'), fullPage: true })
  await row.screenshot({ path: resolve(output, 'edit-record-desktop.png') })
  await writeFile(resolve(output, 'displayed.diff'), patch)
  await page.setViewportSize({ width: 390, height: 844 })
  await diff.scrollIntoViewIfNeeded()
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false)
  await page.screenshot({ path: resolve(output, 'chat-edit-mobile.png'), fullPage: true })
  await diff.screenshot({ path: resolve(output, 'edit-diff-mobile.png') })
  assert.ok(workers.length > 0, 'Actual browser diff worker must execute')
  assert.ok(assets.some(asset => asset.name === 'index.html'))
  for (const original of originals) {
    assert.ok(events.some(event => event.path === `/api/v1/artifacts/${original.sha256}` && event.status === 200))
  }
  assert.ok(matchedReceipts.length > 0, 'Actual API must return the execution receipt')
  for (const receipt of matchedReceipts) {
    assert.equal(receipt.keeper, keeper)
    assert.equal(receipt.success, true)
    assert.equal(receipt.route_evidence?.descriptor_id, 'agent.edit_file')
    for (const field of ['execution_id', 'tool_use_id', 'trace_id', 'session_id', 'turn', 'keeper_turn_id', 'turn_kind', 'task_id']) {
      assert.notEqual(expected[field], undefined, `Expected receipt lacks ${field}`)
      assert.equal(receipt[field], expected[field], `Actual execution receipt ${field}`)
    }
    for (const field of ['input', 'output', 'artifact_refs', 'file_change_evidence']) {
      assert.deepEqual(receipt[field], expected[field], `Actual execution receipt ${field}`)
    }
  }
  assert.deepEqual(events.filter(event => event.status >= 400), [])
  assert.deepEqual(failures, [])
  assert.deepEqual(errors, [])
  rendered = { before_sha256: digest(before), after_sha256: digest(after), diff_sha256: digest(patch), patch_reconstructs_after: true }
  probePassed = true
} catch (error) {
  assertionFailure = String(error)
  throw error
} finally {
  if (page) {
    try {
      await writeFile(resolve(output, 'page-text.txt'), await page.locator('body').innerText())
      if (!probePassed) await page.screenshot({ path: resolve(output, 'failure.png'), fullPage: true })
    } catch (error) {
      failures.push({ stage: 'final_capture', error: String(error) })
      probePassed = false
      assertionFailure ??= String(error)
    }
  }
  if (browser) {
    try { await browser.close() } catch (error) {
      failures.push({ stage: 'browser_close', error: String(error) })
      probePassed = false
      assertionFailure ??= String(error)
    }
  }
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify({
    observed_at: new Date().toISOString(), source_commit: expectedCommit,
    probe_passed: probePassed, assertion_failure: assertionFailure,
    runtime_build: health?.build, runtime_status: health?.status, keeper,
    execution_id: expected?.execution_id, tool_use_id: expected?.tool_use_id,
    edit_output_source: editOutputSource,
    originals: originals?.map(({ text, ...ref }) => ref), rendered,
    assets, events, matched_receipts: matchedReceipts, navigation, workers, errors, failures, blocked,
    scope: 'Read-only installed Dashboard acceptance probe. Original-byte equality and diff reconstruction are established only when probe_passed and rendered are present. Domain writes and WebSockets blocked. No fresh model turn, Gate replay, or general Dashboard health claim.',
  }, null, 2) + '\n')
}
console.log(JSON.stringify({ output, probe_passed: probePassed, matched_assets: assets.length }))
if (!probePassed) process.exitCode = 1
