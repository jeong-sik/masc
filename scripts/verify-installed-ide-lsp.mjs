// Full installed IDE acceptance. HTTP bodies and LSP frames come from the real
// installed server; no fixture responses, adapter, or production build.
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { constants } from 'node:fs'
import { readFile, writeFile, mkdir, realpath, open } from 'node:fs/promises'
import { resolve, dirname, basename } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { execFileSync } from 'node:child_process'

const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const [prefix, expectedCommit, baseUrl, outputDirectory, tokenFile, fixtureFile, mode] = process.argv.slice(2)
assert.ok(prefix && expectedCommit && baseUrl && outputDirectory && tokenFile && fixtureFile,
  'Usage: INSTALLED_PREFIX EXPECTED_COMMIT BASE_URL FRESH_OUTPUT_DIR TOKEN_FILE FIXTURE_JSON [--baseline]')
assert.ok(mode === undefined || mode === '--baseline', 'only --baseline is supported')
const baseline = mode === '--baseline', output = resolve(outputDirectory)
await mkdir(output)
const digest = bytes => createHash('sha256').update(bytes).digest('hex')
const events = [], assets = [], protocol = [], blocked = [], errors = [], failures = [], navigation = []
const receipt = { mode: baseline ? 'baseline_only' : 'installed_acceptance', probe_passed: false,
  scope: 'Installed MASC full IDE, real HTTP and WebSocket, probe-owned worktree source. Same-file reselection refreshes the real file API; this is not an autonomous Keeper or automatic file-watch proof. Unrelated dashboard WebSockets and mutation requests are blocked, so overall dashboard connectivity is outside this probe.' }
let browser, page, fixture, source, changed = false
const responseTasks = []

async function changeOwnedSource(expected, replacement) {
  const owner = JSON.parse(await readFile(resolve(fixture.root, '.masc-lsp-probe-owner.json'), 'utf8'))
  assert.deepEqual(owner, fixture, 'probe worktree ownership descriptor')
  const file = await open(source, constants.O_RDWR | constants.O_NOFOLLOW)
  try {
    const stat = await file.stat()
    assert.ok(stat.isFile() && stat.nlink === 1, 'probe source must be one owned regular file')
    assert.equal(await file.readFile('utf8'), expected, 'only replace the expected probe source')
    const bytes = Buffer.from(replacement)
    let offset = 0
    while (offset < bytes.length) {
      const written = await file.write(bytes, offset, bytes.length - offset, offset)
      assert.ok(written.bytesWritten > 0)
      offset += written.bytesWritten
    }
    await file.truncate(bytes.length)
    await file.sync()
  } finally { await file.close() }
}

const allowedLspMethods = new Set(['initialize', 'initialized', 'shutdown', 'exit', 'masc/lspStatus',
  'textDocument/didOpen', 'textDocument/didChange', 'textDocument/didSave', 'textDocument/didClose',
  'textDocument/codeLens', 'textDocument/inlayHint', 'textDocument/diagnostic', 'textDocument/hover',
  'textDocument/definition', 'textDocument/references', 'textDocument/documentSymbol'])

try {
  fixture = JSON.parse(await readFile(fixtureFile, 'utf8'))
  assert.equal(fixture.schema, 'masc.installed-ide-lsp-fixture.v1')
  assert.equal(await realpath(fixture.root), fixture.root)
  assert.equal(basename(fixture.source_relative), fixture.source_relative, 'one root-level probe source')
  assert.match(fixture.source_relative, /^[a-zA-Z0-9_-]+\.ml$/)
  source = resolve(fixture.root, fixture.source_relative)
  assert.equal(await realpath(source), source)
  assert.equal(digest(fixture.initial_text), fixture.initial_sha256)
  assert.equal(digest(fixture.updated_text), fixture.updated_sha256)
  assert.equal(await readFile(source, 'utf8'), fixture.initial_text)
  assert.deepEqual(JSON.parse(await readFile(resolve(fixture.root, '.masc-lsp-probe-owner.json'), 'utf8')), fixture)
  assert.equal(await realpath(execFileSync('git', ['-C', fixture.root, 'rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim()), fixture.root)
  assert.equal(execFileSync('git', ['-C', fixture.root, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(), fixture.worktree_head)
  const binary = await realpath(resolve(prefix, 'masc'))
  const release = JSON.parse(await readFile(resolve(dirname(binary), 'release.json'), 'utf8'))
  assert.equal(release.source_commit, expectedCommit)
  assert.equal(digest(await readFile(binary)), release.binary_sha256)
  const token = (await readFile(tokenFile, 'utf8')).trim()
  const origin = new URL(baseUrl).origin
  const getJson = async path => {
    const response = await fetch(new URL(path, baseUrl), { headers: { Authorization: `Bearer ${token}` }, redirect: 'error' })
    assert.equal(response.status, 200, path)
    return response.json()
  }
  const health = await getJson('/health?full=1')
  assert.equal(health.build.binary_commit, expectedCommit)
  assert.equal(health.build.executable_sha256, release.binary_sha256)
  assert.equal(await realpath(health.build.executable_path), binary)
  receipt.runtime_build = health.build
  receipt.fixture = { repository_id: fixture.repository_id, root: fixture.root, source_relative: fixture.source_relative,
    worktree_head: fixture.worktree_head, initial_sha256: fixture.initial_sha256, updated_sha256: fixture.updated_sha256 }
  const repositories = await getJson('/api/v1/repositories')
  assert.ok(Array.isArray(repositories.repositories))
  const repository = repositories.repositories.find(row => row.id === fixture.repository_id)
  receipt.repository = repository ?? null
  if (repository) {
    assert.equal(await realpath(repository.resolved_local_path ?? repository.local_path), fixture.root)
    assert.equal(repository.auto_sync, false)
    assert.ok(typeof repository.codebase === 'string' && repository.codebase.length > 0)
  } else {
    receipt.missing_setup = ['Register the prepared probe repository through POST /api/v1/repositories; this probe does not register it.']
    assert.ok(baseline, 'probe repository registration required')
  }
  const files = new Map(release.files.map(file => [file.path, file]))
  browser = await chromium.launch({ headless: true })
  page = await browser.newPage({ viewport: { width: 1440, height: 1100 }, serviceWorkers: 'block',
    extraHTTPHeaders: { Authorization: `Bearer ${token}` } })
  page.on('pageerror', error => errors.push(error.message))
  let socketNumber = 0
  let lspObserved = false, notifyLspObservation
  const waitForLspObservation = () => new Promise((resolveWait, reject) => {
    if (lspObserved) return resolveWait()
    const timer = setTimeout(() => reject(new Error('No actual LSP status or close observed within the probe window')), 45000)
    notifyLspObservation = () => { clearTimeout(timer); resolveWait() }
  })
  const observedLsp = () => { lspObserved = true; notifyLspObservation?.() }
  const isFixtureLsp = url => url.origin.replace(/^ws/, 'http') === origin
    && url.pathname === '/api/v1/ide/lsp'
    && url.searchParams.get('repo_id') === fixture.repository_id
  // The installed browser talks directly to the server. Passive frame events:
  // https://playwright.dev/docs/api/class-websocket#web-socket-event-frame-sent
  // Never route this connection: that replaces the browser's native handshake.
  await page.routeWebSocket(url => !isFixtureLsp(url), route => {
    blocked.push({ kind: 'websocket', path: new URL(route.url()).pathname })
    void route.close()
  })
  page.on('websocket', websocket => {
    const url = new URL(websocket.url())
    if (!isFixtureLsp(url)) return
    const socket = ++socketNumber
    protocol.push({ socket, event: 'browser_connection_requested', path: url.pathname,
      repository_id: url.searchParams.get('repo_id'), codebase: url.searchParams.get('codebase') })
    websocket.on('framesent', ({ payload }) => {
      try {
        const message = JSON.parse(String(payload))
        assert.ok(allowedLspMethods.has(message.method), 'only observational LSP methods are allowed')
        const uri = message.params?.textDocument?.uri
        if (uri !== undefined) assert.equal(fileURLToPath(uri), source, 'LSP document stays in probe-owned source')
        protocol.push({ socket, direction: 'client', message })
      } catch (error) { failures.push({ stage: 'lsp_client_boundary', error: String(error) }) }
    })
    websocket.on('framereceived', ({ payload }) => {
      try {
        const message = JSON.parse(String(payload))
        protocol.push({ socket, direction: 'server', message })
        if (message.method === 'masc/lspStatus' || message.method === 'textDocument/publishDiagnostics') observedLsp()
      } catch (error) { failures.push({ stage: 'lsp_server_frame', error: String(error) }) }
    })
    websocket.on('socketerror', error => {
      protocol.push({ socket, event: 'socket_error', error })
      observedLsp()
    })
    websocket.on('close', () => {
      protocol.push({ socket, event: 'actual_server_closed' })
      observedLsp()
    })
  })
  await page.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url())
    let rpc
    if (url.pathname === '/mcp' && request.method() === 'POST') {
      try { rpc = request.postDataJSON() } catch { /* rejected below */ }
    }
    const readRpc = rpc && (['initialize', 'notifications/initialized', 'tools/list'].includes(rpc.method)
      || (rpc.method === 'tools/call' && ['masc_keeper_list', 'masc_keeper_status', 'masc_pause_status'].includes(rpc.params?.name)))
    if (url.origin !== origin || (!['GET', 'HEAD'].includes(request.method()) && !readRpc)) {
      blocked.push({ kind: 'http', method: request.method(), path: url.pathname })
      return route.abort()
    }
    return route.continue()
  })
  page.on('response', response => {
    responseTasks.push((async () => {
      const request = response.request(), url = new URL(response.url())
      try {
        events.push({ method: request.method(), path: url.pathname, status: response.status() })
        if (url.pathname.startsWith('/dashboard/')) {
          const name = decodeURIComponent(url.pathname.slice('/dashboard/'.length)) || 'index.html'
          const manifestFile = files.get(name)
          assert.ok(manifestFile, `unmanifested installed asset ${name}`)
          assert.equal(response.status(), 200, name)
          const bytes = await response.body()
          assert.equal(digest(bytes), manifestFile.sha256, name)
          assets.push({ name, sha256: digest(bytes), bytes: bytes.length })
        } else if (url.pathname === '/api/v1/workspace/file' && url.searchParams.get('path') === fixture.source_relative) {
          assert.equal(url.searchParams.get('repo_id'), fixture.repository_id)
          assert.equal(response.status(), 200, 'fixture source HTTP response')
          const payload = await response.json()
          assert.equal(payload.ok, true, 'complete actual fixture source response')
          assert.ok(payload.content === fixture.initial_text || payload.content === fixture.updated_text)
          events.push({ kind: 'fixture_source_response', sha256: digest(payload.content), bytes: Buffer.byteLength(payload.content) })
        }
      } catch (error) { failures.push({ stage: 'http', path: url.pathname, error: String(error) }) }
    })())
  })
  const shown = () => page.locator('.cm-content').evaluate(element => [...element.querySelectorAll('.cm-line')].map(line => line.textContent).join('\n'))
  const params = new URLSearchParams({ section: 'ide-shell', view: 'source', terminal: 'hidden', rails: 'hidden' })
  await page.goto(new URL(`/dashboard/#code?${params}`, baseUrl).href)
  await page.getByTestId('ide-statusbar').waitFor({ timeout: 45000 })
  const repositorySelect = page.getByRole('combobox', { name: 'IDE repository', exact: true })
  if (repository) {
    await repositorySelect.selectOption(fixture.repository_id)
    await page.getByPlaceholder('파일 이름 필터').fill(fixture.source_relative)
    const row = page.getByRole('treeitem').filter({ has: page.locator('.ide-explorer-row-label').getByText(fixture.source_relative, { exact: true }) })
    await row.waitFor({ state: 'visible', timeout: 45000 })
    assert.equal(await row.count(), 1, 'one exact probe source in filtered explorer')
    await row.click()
    await page.locator('.cm-content').waitFor({ timeout: 45000 })
    await waitForLspObservation()
  }
  await page.getByTestId('ide-readiness-notice').click()
  receipt.baseline_status = await page.getByTestId('ide-statusbar').innerText()
  if (repository) assert.ok(receipt.baseline_status.includes(fixture.source_relative), 'selected file must remain the probe source')
  await page.screenshot({ path: resolve(output, 'initial-desktop.png'), fullPage: true })
  await Promise.all(responseTasks)
  assert.ok(assets.some(asset => asset.name === 'index.html'))
  assert.ok(assets.some(asset => asset.name.startsWith('assets/ide-shell-')))
  if (repository) {
    assert.equal(await shown(), fixture.initial_text)
    assert.ok(events.some(event => event.kind === 'fixture_source_response' && event.sha256 === fixture.initial_sha256))
    receipt.baseline_source = { shown_sha256: digest(await shown()),
      diagnostic_markers: await page.locator('.cm-diagnostic-marker[title]:not([title=""])').count(),
      document_status_present: await page.getByTestId('ide-statusbar-chip-lsp-document').count() === 1 }
  }
  assert.deepEqual(errors, [])
  assert.deepEqual(failures, [])
  receipt.baseline_observed = true
  if (!baseline) {
    const status = page.getByTestId('ide-statusbar-chip-lsp-document')
    await status.waitFor({ timeout: 45000 })
    const markers = page.locator('.cm-diagnostic-marker[title]:not([title=""])')
    await markers.first().waitFor({ timeout: 45000 })
    const opened = protocol.filter(event => event.direction === 'client' && event.message?.method === 'textDocument/didOpen')
    assert.ok(opened.some(event => event.message.params.textDocument.text === fixture.initial_text))
    assert.equal(await shown(), fixture.initial_text)
    receipt.initial = { source_sha256: digest(await shown()), status: await status.innerText(),
      detail: await status.getAttribute('title'), diagnostic_markers: await markers.count() }
    assert.ok(receipt.initial.diagnostic_markers > 0)
    const originalOpen = opened.findLast(event => event.message.params.textDocument.text === fixture.initial_text)
    const originalSocket = originalOpen.socket
    const originalVersion = originalOpen.message.params.textDocument.version
    assert.ok(Number.isInteger(originalVersion) && originalVersion >= 1)
    assert.ok(!protocol.some(event => event.socket === originalSocket && event.event === 'actual_server_closed'))
    const initialization = protocol.find(event => event.socket === originalSocket && event.direction === 'server'
      && event.message?.result?.masc?.workspaceRoot === fixture.root)
    assert.ok(initialization, 'the actual MASC server must resolve the owned fixture workspace')
    assert.ok(protocol.slice(protocol.indexOf(originalOpen) + 1).some(event => event.socket === originalSocket
      && event.direction === 'server' && event.message?.method === 'textDocument/publishDiagnostics'
      && event.message.params.uri === pathToFileURL(source).href && event.message.params.diagnostics.length > 0),
      'actual language server diagnostics must explain the initial gutter markers')
    await page.screenshot({ path: resolve(output, 'diagnostics-before.png'), fullPage: true })
    changed = true
    await changeOwnedSource(fixture.initial_text, fixture.updated_text)
    navigation.push({ action: 'write_probe_owned_source', sha256: fixture.updated_sha256 })
    const row = page.getByRole('treeitem').filter({ has: page.locator('.ide-explorer-row-label').getByText(fixture.source_relative, { exact: true }) })
    await row.click()
    navigation.push({ action: 'reselect_same_file_to_refresh_real_api' })
    await page.waitForFunction(text => document.querySelector('.cm-content')?.textContent.includes(text.trim()), fixture.updated_text)
    await markers.first().waitFor({ state: 'detached', timeout: 45000 })
    await page.waitForFunction(() => /0 (reported|diagnostics)/.test(document.querySelector('[data-testid="ide-statusbar-chip-lsp-document"]')?.textContent ?? ''))
    assert.equal(await shown(), fixture.updated_text)
    const changedFrame = protocol.find(event => event.socket === originalSocket && event.direction === 'client'
      && event.message?.method === 'textDocument/didChange'
      && event.message.params.contentChanges?.[0]?.text === fixture.updated_text)
    assert.ok(changedFrame, 'the same installed editor connection must send actual didChange')
    assert.ok(changedFrame.message.params.textDocument.version > originalVersion)
    const reply = protocol.slice(protocol.indexOf(changedFrame) + 1).findLast(event => event.socket === originalSocket && event.direction === 'server'
      && event.message?.method === 'textDocument/publishDiagnostics'
      && event.message.params.uri === pathToFileURL(source).href && event.message.params.diagnostics.length === 0)
    assert.ok(reply, 'actual language server must publish empty diagnostics for this URI')
    receipt.updated = { source_sha256: digest(await shown()), status: await status.innerText(),
      detail: await status.getAttribute('title'), diagnostic_markers: await markers.count(), version: changedFrame.message.params.textDocument.version }
    if (reply.message.params.version === undefined) assert.match(receipt.updated.status, /version unconfirmed/)
    else assert.equal(reply.message.params.version, receipt.updated.version)
    assert.ok(events.some(event => event.kind === 'fixture_source_response' && event.sha256 === fixture.updated_sha256))
    await page.screenshot({ path: resolve(output, 'diagnostics-after.png'), fullPage: true })
    await page.setViewportSize({ width: 390, height: 844 })
    await page.screenshot({ path: resolve(output, 'ide-mobile.png'), fullPage: true })
    const finalHealth = await getJson('/health?full=1')
    assert.equal(finalHealth.build.runtime_instance_id, health.build.runtime_instance_id)
    assert.equal(finalHealth.build.executable_sha256, release.binary_sha256)
    await Promise.all(responseTasks)
    assert.deepEqual(errors, [])
    assert.deepEqual(failures, [])
    receipt.probe_passed = true
  }
} catch (error) {
  receipt.error = String(error)
  process.exitCode = 1
} finally {
  if (page) {
    await writeFile(resolve(output, 'page-text.txt'), await page.locator('body').innerText()).catch(() => {})
    await page.screenshot({ path: resolve(output, 'final.png'), fullPage: true }).catch(() => {})
  }
  await Promise.all(responseTasks)
  if (browser) {
    try { await browser.close() }
    catch (error) {
      failures.push({ stage: 'browser_close', error: String(error) })
      receipt.probe_passed = false
      process.exitCode = 1
    }
  }
  if (changed) {
    try {
      await changeOwnedSource(fixture.updated_text, fixture.initial_text)
      receipt.fixture_restored = true
    } catch (error) {
      failures.push({ stage: 'restore_fixture', error: String(error) })
      receipt.probe_passed = false
      process.exitCode = 1
    }
  }
  await Promise.all(responseTasks)
  receipt.installed_assets_verified = assets.some(asset => asset.name === 'index.html')
    && assets.some(asset => asset.name.startsWith('assets/ide-shell-'))
    && !failures.some(failure => failure.stage === 'http' && failure.path?.startsWith('/dashboard/'))
  if (errors.length || failures.length || !receipt.installed_assets_verified) {
    receipt.probe_passed = false
    process.exitCode = 1
  }
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify({ ...receipt, assets, events, protocol, navigation, blocked, errors, failures }, null, 2) + '\n')
}
console.log(JSON.stringify({ output, mode: receipt.mode, probe_passed: receipt.probe_passed, error: receipt.error }))
