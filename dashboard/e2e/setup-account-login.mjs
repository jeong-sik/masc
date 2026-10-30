import { chromium } from 'playwright'
import { mkdir, writeFile } from 'node:fs/promises'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
// This fixture exercises the real UI and fetch/SSE decoder with an isolated
// browser-owned API. It is not live provider authentication or backend proof.
const url = process.env.SETUP_LOGIN_FIXTURE_URL
const artifacts = process.env.SETUP_LOGIN_ARTIFACT_DIR
if (!url || !artifacts) throw new Error('SETUP_LOGIN_FIXTURE_URL and SETUP_LOGIN_ARTIFACT_DIR are required')
await mkdir(artifacts, { recursive: true })
const browser = await chromium.launch({ headless: true })
const results = []
const productionRoute = !new URL(url).pathname.includes('/dev-fixtures/')
try {
  for (const [client, width] of [['codex', 1280], ['claude', 1280], ['antigravity', 390], ['muse', 390]]) {
    const context = await browser.newContext({ viewport: { width, height: 1000 } })
    await context.addInitScript(() => {
      sessionStorage.setItem('masc_bearer_token', 'f'.repeat(64))
      sessionStorage.setItem('masc_bearer_token_meta', JSON.stringify({ source: 'manual', actor: 'dashboard' }))
      const original = window.fetch.bind(window)
      const sessions = new Map()
      const evidence = { models: [], saves: [], inputs: [], recovered: 0, cancel: 0, sequence: 0, dropComplete: false }
      window.__setupLoginEvidence = evidence
      const json = value => new Response(JSON.stringify(value), { status: 200, headers: { 'content-type': 'application/json' } })
      window.fetch = async (raw, options = {}) => {
        const path = new URL(typeof raw === 'string' ? raw : raw.url, location.href).pathname
        if (path === '/health') return json({ status: 'ok', version: 'fixture', runtime_ready: true })
        if (!path.startsWith('/api/')) return original(raw, options)
        if (options.signal?.aborted) throw new DOMException('aborted', 'AbortError')
        const body = options.body ? JSON.parse(options.body) : {}
        if (path === '/api/v1/dashboard/shell') return json({ counts: { agents: 0, keepers: 0, tasks: 0 } })
        if (path === '/api/v1/setup/status') return json({ schema: 'masc.onboarding_status.v1', base_path: '/fixture/workspace',
          selected_model: evidence.saves.length ? 'fixture-model' : null, selected_runtime: evidence.saves.length ? 'fixture.model' : null, checks: [{ id: 'runtime', condition: 'needs_setup', message: '모의 서버: 로그인할 계정과 모델을 선택하세요.', actions: [] }] })
        if (path === '/api/v1/setup/inventory') return json({ source_revision: 'fixture-source', setup_revision: 'fixture-revision', runtimes: [], integrations: [
          { id: 'codex', display_name: 'Codex', protocol: 'codex-app-server', setup_support: 'new_connection' },
          { id: 'claude', display_name: 'Claude', protocol: 'claude-code', setup_support: 'new_connection' },
          { id: 'antigravity', display_name: 'Antigravity', protocol: 'antigravity-cli', setup_support: 'new_connection' },
          { id: 'muse', display_name: 'Muse', protocol: 'muse-serve', setup_support: 'new_connection' }] })
        if (path === '/api/v1/setup/accounts/login') {
          const login_id = (++evidence.sequence).toString(16).padStart(64, '0')
          const account_ref = (100 + evidence.sequence).toString(16).padStart(64, '0')
          const receipt = { login_id, integration_id: body.integration_id, account_ref, status: 'running', invocation_verified: false }
          let writer
          const stream = new ReadableStream({ start(controller) { writer = controller } })
          const send = (event, data) => writer.enqueue(new TextEncoder().encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`))
          sessions.set(login_id, { receipt, send, writer })
          send('started', receipt)
          send('output', { stream: 'stdout', text: `Open https://example.invalid/device to sign in to ${body.integration_id}.\nPaste the returned code below.\n` })
          options.signal?.addEventListener('abort', () => { if (receipt.status === 'running') writer.error(new DOMException('aborted', 'AbortError')) }, { once: true })
          return new Response(stream, { headers: { 'content-type': 'text/event-stream' } })
        }
        const match = path.match(/^\/api\/v1\/setup\/accounts\/login\/([a-f0-9]{64})(?:\/(input|cancel))?$/)
        if (match) {
          const session = sessions.get(match[1])
          if (!session) throw new Error('Unknown fixture session')
          if (!match[2]) { evidence.recovered++; return json(session.receipt) }
          if (match[2] === 'cancel') {
            evidence.cancel++; session.receipt.status = 'cancelled'
            session.send('error', session.receipt); session.writer.close(); return json({ accepted: true })
          }
          evidence.inputs.push({ kind: body.kind, key: body.key })
          session.send('input_ready', {})
          if (body.kind === 'text') {
            session.receipt.status = 'complete'; session.receipt.authentication = 'authenticated'
            if (!evidence.dropComplete) session.send('complete', session.receipt)
            session.writer.close()
          }
          return json({ accepted: true })
        }
        if (path === '/api/v1/setup/models') {
          evidence.models.push(body)
          return json({ models: [{ id: 'fixture-model', label: 'Fixture model', context: ['codex', 'claude'].includes(body.integration_id) ? null : 32000, tools: true }] })
        }
        if (path === '/api/v1/setup/connections') {
          evidence.saves.push(body)
          return json({ configured: true, commit: { durability: 'durable', warnings: [] }, readiness: 'verified', runtime_id: 'fixture.model', runtime_ids: ['fixture.model'] })
        }
        if (path === '/api/v1/runtime/setup/resume') return json({ runtime_ready: true, exact_output_authority_available: true, model_setup: { status: 'available' } })
        return new Response(JSON.stringify({ error: 'Outside isolated login fixture scope' }), { status: 503, headers: { 'content-type': 'application/json' } })
      }
    })
    const page = await context.newPage()
    const errors = []
    page.on('pageerror', error => errors.push(error.message))
    await page.goto(url)
    if (productionRoute) await page.getByRole('region', { name: '첫 대화 준비', exact: true }).waitFor()
    await page.getByLabel('공급자').selectOption(client)
    await page.getByText('새 계정 로그인', { exact: true }).click()
    await page.getByLabel('로그인 코드', { exact: true }).waitFor()
    assert.equal(await page.getByLabel('로그인 코드', { exact: true }).getAttribute('type'), 'password')
    await page.getByRole('region', { name: '공식 클라이언트 로그인', exact: true }).scrollIntoViewIfNeeded()
    await page.screenshot({ path: `${artifacts}/${client}-${width}-login.png`, fullPage: true })
    if (productionRoute) await page.getByRole('region', { name: '공식 클라이언트 로그인', exact: true }).screenshot({ path: `${artifacts}/${client}-${width}-login-panel.png` })
    if (client === 'antigravity') {
      await page.getByText('로그인 취소', { exact: true }).click()
      await page.getByText('로그인 상태 다시 확인', { exact: true }).click()
      await page.getByText('선택한 계정 다시 로그인', { exact: true }).click()
      await page.getByLabel('로그인 코드', { exact: true }).waitFor()
    }
    if (client === 'claude') await page.evaluate(() => { window.__setupLoginEvidence.dropComplete = true })
    await page.getByLabel('로그인 코드', { exact: true }).fill('synthetic-code')
    await page.getByText('코드 전달', { exact: true }).click()
    if (client === 'codex' || client === 'claude') {
      const contextInput = page.getByLabel('Fixture model context (tokens)', { exact: true })
      await contextInput.waitFor()
      await contextInput.scrollIntoViewIfNeeded()
      await page.screenshot({ path: `${artifacts}/${client}-${width}-context.png`, fullPage: true })
      assert.equal(await page.getByText('이 모델만 준비', { exact: true }).count(), 0)
      await contextInput.fill('123456')
      await page.getByText('context 적용', { exact: true }).click()
    }
    await page.getByLabel('Fixture model', { exact: true }).waitFor()
    await page.getByLabel('Fixture model', { exact: true }).check()
    await page.getByText('선택한 모델 추가', { exact: true }).click()
    await page.getByText('검증 후 선택 저장', { exact: true }).click()
    if (productionRoute) await page.getByText(/선택한 모델의 응답·도구 호출을 확인하고 저장했습니다/).waitFor()
    else await page.getByText('테스트 설정 저장 확인', { exact: true }).waitFor()
    await page.screenshot({ path: `${artifacts}/${client}-${width}-saved.png`, fullPage: true })
    const evidence = await page.evaluate(() => ({ ...window.__setupLoginEvidence,
      stored: Object.fromEntries(Object.entries(sessionStorage)), overflow: document.documentElement.scrollWidth > innerWidth }))
    assert.equal(evidence.models.length, 1)
    assert.ok(evidence.models[0].account_ref)
    assert.equal(evidence.saves[0].connections[0].source.account_ref, evidence.models[0].account_ref)
    if (client === 'codex' || client === 'claude') assert.equal(evidence.saves[0].connections[0].models[0].context, 123456)
    assert.equal(evidence.overflow, false)
    assert.ok(!JSON.stringify(evidence.stored).includes('synthetic-code'))
    if (client === 'claude') assert.equal(evidence.recovered, 1)
    if (client === 'antigravity') assert.equal(evidence.cancel, 1)
    assert.deepEqual(errors, [])
    // Artifact records only request shape and opaque references, never input text.
    delete evidence.stored
    results.push({ client, viewport: width, ...evidence })
    await context.close()
  }
  await writeFile(`${artifacts}/results.json`, JSON.stringify({ source_revision: execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(), route: url, scope: productionRoute ? 'production dashboard settings route with isolated browser API mocks; no live provider authentication' : 'isolated UI fixture; no live provider authentication', results }, null, 2))
  console.log(`PASS: four login/discovery/save flows, documented context entry, lost completion, cancellation, mobile layout; ${artifacts}`)
} finally { await browser.close() }
