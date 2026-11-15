// One-off browser proof: the setup login panel shows the screen frames the
// server sends, the last one in place of the one before. The API is a
// browser-owned stub, as in dashboard/e2e/setup-account-login.mjs; the screen
// text is the real agy screen captured through Runtime_setup_login_session.
import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'
const [dashboard, screenFile, out, url] = process.argv.slice(2)
const { chromium } = createRequire(`${dashboard}/package.json`)('playwright')
const finalScreen = readFileSync(screenFile, 'utf8').split('\n').slice(1).join('\n').replace(/\n$/, '')
const spinner = '\x1b[0m\n\x1b[0m Welcome to the \x1b[38;5;69mAntigravity CLI\x1b[39m. You are currently not signed in.\x1b[0m\n\x1b[0m\n\x1b[0m ⣷  Signing in...\x1b[0m'
const browser = await chromium.launch({ headless: true })
try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 1000 } })
  await context.addInitScript(({ spinner, finalScreen }) => {
    sessionStorage.setItem('masc_bearer_token', 'f'.repeat(64))
    sessionStorage.setItem('masc_bearer_token_meta', JSON.stringify({ source: 'manual', actor: 'dashboard' }))
    const original = window.fetch.bind(window)
    const json = value => new Response(JSON.stringify(value), { status: 200, headers: { 'content-type': 'application/json' } })
    window.fetch = async (raw, options = {}) => {
      const path = new URL(typeof raw === 'string' ? raw : raw.url, location.href).pathname
      if (path === '/health') return json({ status: 'ok', version: 'fixture', runtime_ready: true })
      if (!path.startsWith('/api/')) return original(raw, options)
      if (path === '/api/v1/dashboard/shell') return json({ counts: { agents: 0, keepers: 0, tasks: 0 } })
      if (path === '/api/v1/setup/status') return json({ schema: 'masc.onboarding_status.v1', base_path: '/fixture/workspace',
        selected_model: null, selected_runtime: null, checks: [{ id: 'runtime', condition: 'needs_setup', message: '모의 서버: 로그인할 계정과 모델을 선택하세요.', actions: [] }] })
      if (path === '/api/v1/setup/inventory') return json({ source_revision: 'fixture-source', setup_revision: 'fixture-revision', runtimes: [], integrations: [
        { id: 'antigravity', display_name: 'Antigravity', protocol: 'antigravity-cli', setup_support: 'new_connection' }] })
      if (path === '/api/v1/setup/accounts/login') {
        const login_id = '1'.padStart(64, '0')
        const receipt = { login_id, integration_id: 'antigravity', account_ref: '2'.padStart(64, '0'), status: 'running', invocation_verified: false }
        let writer
        const stream = new ReadableStream({ start(controller) { writer = controller } })
        const send = (event, data) => writer.enqueue(new TextEncoder().encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`))
        send('started', receipt)
        send('screen', { text: spinner })
        setTimeout(() => send('screen', { text: finalScreen }), 300)
        return new Response(stream, { headers: { 'content-type': 'text/event-stream' } })
      }
      return json({})
    }
  }, { spinner, finalScreen })
  const page = await context.newPage()
  await page.goto(url)
  await page.screenshot({ path: out.replace('.png', '-landing.png') })
  await page.getByLabel('공급자').selectOption('antigravity')
  await page.getByText('새 계정 로그인', { exact: true }).click()
  const output = page.getByLabel('로그인 안내')
  await output.waitFor()
  await page.waitForFunction(() => document.querySelector('[aria-label="로그인 안내"]')?.textContent?.includes('Select login method'))
  const text = await output.textContent()
  console.log(JSON.stringify({ spinnerGone: !text.includes('Signing in'), hasCR: text.includes('\r') || text.includes('\\x0D'), text }))
  await output.scrollIntoViewIfNeeded()
  await page.screenshot({ path: out, fullPage: true })
} finally {
  await browser.close()
}
