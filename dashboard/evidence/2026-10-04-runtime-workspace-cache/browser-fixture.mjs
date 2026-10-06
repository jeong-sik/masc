import { chromium } from 'playwright'
import { createServer } from 'vite'
import assert from 'node:assert/strict'
import { writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
const out = fileURLToPath(new URL('.', import.meta.url))
const server = await createServer({ server: { host: '127.0.0.1', port: 0 } }); await server.listen()
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1280, height: 850 } })
page.setDefaultTimeout(10000)
const errors = [], unexpected = [], requests = [], releases = []
let active = 'A', hold = false, failB = true, returned = false
page.on('pageerror', error => errors.push(error.message))
await page.route('**/api/**', async route => {
  const req = route.request(), path = new URL(req.url()).pathname
  if (!path.startsWith('/api/')) return route.continue()
  const reply = (value, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(value) })
  if (path === '/api/v1/dashboard/dev-token') return reply({ token: 'synthetic-fixture-token', actor: 'dashboard', role: 'admin' })
  requests.push({ workspace: active, path, method: req.method() })
  if (!['/api/v1/providers', '/api/v1/runtime/resolved'].includes(path)) {
    unexpected.push(path); return reply({ error: 'unexpected route' }, 500)
  }
  const owner = active, context = active === 'B' ? 222000 : returned ? 333000 : 111000
  const label = active === 'B' ? 'B' : returned ? 'A-returned' : 'A'
  const error = failB && active === 'B'
  if (hold && active === 'A') await new Promise(resolve => releases.push(resolve))
  if (error) return reply({ error: `${owner} reading unavailable` }, 503)
  return path === '/api/v1/providers'
    ? reply({ providers: [{ provider: 'shared.runtime', runtime_id: 'shared.runtime', models: [],
        source: 'runtime.toml', available: true, protocol: 'openai-compatible-http', max_context: context }] })
    : reply({ config_path: '/fixture/shared/runtime.toml', default_runtime: null, runtimes: [],
        lanes: [{ id: 'fixture-lane', declared: true, runtime_ids: [`${label}-primary`, `${label}-secondary`] }],
        assignments: [{ keeper: 'fixture', assignment_source: 'explicit', resolved: { kind: 'lane', id: 'fixture-lane' } }] })
})
const click = name => page.getByRole('button', { name, exact: true }).click()
const waitText = text => page.waitForFunction(value => document.body.innerText.includes(value), text)
const absent = async text => assert.equal((await page.locator('body').innerText()).includes(text), false)
try {
  await page.goto(`http://127.0.0.1:${server.httpServer.address().port}/dashboard/evidence/2026-10-04-runtime-workspace-cache/fixture.html`)
  await waitText('ctx:111000'); await waitText('A-primary')
  assert.equal(requests.length, 2)
  hold = true; await click('Fixture refresh')
  await page.waitForFunction(() => !document.body.innerText.includes('ctx:111000'))
  // Both explicit refreshes must reach the held synthetic server before switch.
  await new Promise((resolve, reject) => {
    const deadline = Date.now() + 10000
    const check = () => releases.length === 2 ? resolve() : Date.now() > deadline ? reject(new Error('held reads missing')) : setTimeout(check, 10)
    check()
  })
  active = 'B'; await click('Fixture workspace B')
  await waitText('catalog unavailable'); await waitText('B reading unavailable')
  await absent('ctx:111000'); await absent('A-primary')
  hold = false; for (const release of releases) release()
  await page.screenshot({ path: out + 'workspace-b-errors.png', fullPage: true })
  failB = false; await click('Fixture refresh')
  await waitText('ctx:222000'); await waitText('B-primary')
  await absent('ctx:111000'); await absent('A-primary')
  await page.screenshot({ path: out + 'workspace-b-recovered.png', fullPage: true })
  const count = requests.length
  await click('Fixture withdraw authority'); await waitText('작업공간을 확인한 뒤')
  await absent('ctx:222000'); await absent('B-primary')
  await click('Fixture refresh'); assert.equal(requests.length, count)
  returned = true; active = 'A'; await click('Fixture workspace A')
  await waitText('ctx:333000'); await waitText('A-returned-primary')
  await absent('ctx:111000'); await absent('B-primary')
  assert.deepEqual(errors, []); assert.deepEqual(unexpected, [])
  assert.equal(requests.every(request => request.method === 'GET'), true)
  await writeFile(out + 'browser-result.json', JSON.stringify({ passed: true, browser: await browser.version(),
    scope: 'Actual shared runtime resources and two direct components with synthetic HTTP; no backend/Keeper/deployment proof.',
    assertions: ['one catalog/resolved read shared by initial consumers', 'pending A data hidden',
      'B failures show errors without A capabilities or candidates', 'late A replies cannot restore A',
      'explicit B retry restores capabilities and candidates', 'unknown authority hides readings and sends no GET',
      'restored A automatically loads new readings in still-mounted consumers', 'all observed requests are GET'], requests, errors, unexpected }, null, 2) + '\n')
  console.log('PASS: 8 runtime workspace browser assertions; zero writes and page errors')
} catch (error) {
  await writeFile(out + 'browser-failure.json', JSON.stringify({ error: String(error), requests, errors, unexpected,
    body: await page.locator('body').innerText() }, null, 2) + '\n'); throw error
} finally { await browser.close(); await server.close() }
