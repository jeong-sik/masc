import { artifactDirectory } from '../artifact-output.mjs'
import { chromium } from 'playwright'
import { createServer } from 'vite'
import { createServer as createHttpServer } from 'node:http'
import assert from 'node:assert/strict'
import { writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { catalog, metrics, usage } from './payloads.mjs'

const out = await artifactDirectory(import.meta.url)
const root = fileURLToPath(new URL('../..', import.meta.url))
const server = await createServer({ root, configFile: root + 'vite.config.ts', server: { host: '127.0.0.1', port: 0, watch: null } })
await server.listen()
const streamServer = createHttpServer((request, response) => {
  const path = new URL(request.url, 'http://fixture.invalid').pathname
  if (path !== '/api/v1/models/metrics/stream') {
    response.writeHead(404).end()
    return
  }
  response.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    'x-masc-sse-instance-id': 'provider-credit-balances-browser-fixture',
    'x-masc-sse-idle-timeout-ms': '60000',
  })
  response.flushHeaders()
  response.write(`data: ${JSON.stringify(metrics)}\n\n`)
  const keepalive = setInterval(() => response.write(': keepalive\n\n'), 1000)
  request.on('close', () => { clearInterval(keepalive); response.end() })
})
await new Promise(resolve => streamServer.listen(0, '127.0.0.1', resolve))
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1280, height: 950 } })
page.setDefaultTimeout(60000)
const errors = [], consoleErrors = [], unexpected = [], requests = [], checks = []
page.on('pageerror', error => errors.push(error.message))
page.on('requestfailed', request => errors.push(`${request.method()} ${request.url()}: ${request.failure()?.errorText}`))
page.on('console', message => { if (message.type() === 'error') consoleErrors.push(message.text()) })
await page.route('**/api/**', async route => {
  const path = new URL(route.request().url()).pathname
  if (!path.startsWith('/api/')) return route.continue()
  const reply = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
  requests.push({ path, method: route.request().method() })
  switch (path) {
    case '/api/v1/dashboard/dev-token': return reply({ token: 'synthetic-fixture-token', actor: 'dashboard', role: 'admin' })
    case '/api/v1/providers': return reply(catalog)
    case '/api/v1/models/metrics': return reply(metrics)
    case '/api/v1/models/metrics/stream':
      return route.continue({ url: `http://127.0.0.1:${streamServer.address().port}${new URL(route.request().url()).pathname}` })
    case '/api/v1/runtime/resolved': return reply(usage)
    default: unexpected.push(path); return reply({ error: 'unexpected route' }, 500)
  }
})
const waitText = value => page.waitForFunction(text => document.body.innerText.includes(text), value)
try {
  await page.goto(`http://127.0.0.1:${server.httpServer.address().port}/dashboard/fixtures/2026-11-19-provider-credit-balances/fixture.html`, { waitUntil: 'domcontentloaded' })
  await waitText('Credit USD 74.75 남음 · USD 25.75/USD 100.50 사용')
  await waitText('Credit USD 72.50 남음 · USD 27.50/USD 100.00 사용')
  await waitText('Credit USD 25.00 남음')
  await waitText('Credit CNY 103.37 남음 · CNY 71.63/CNY 175.00 사용')
  await waitText('Credit credits 2500.75 남음')
  await waitText('Credit unlimited')
  checks.push('OpenRouter, Ollama, Kimi and Codex finite/unlimited Credit render through actual API decoders')
  await page.screenshot({ path: out + 'provider-credit-balances-desktop.png', fullPage: true })
  await page.setViewportSize({ width: 390, height: 844 })
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true)
  await page.screenshot({ path: out + 'provider-credit-balances-mobile.png', fullPage: true })
  checks.push('mobile has no horizontal overflow')
  assert.deepEqual(errors, [])
  assert.deepEqual(consoleErrors, [])
  assert.deepEqual(unexpected, [])
  assert.deepEqual(requests.filter(row => row.method !== 'GET'), [])
  checks.push('no page errors, console errors, unexpected API routes or mutation requests')
  await writeFile(out + 'browser-result.json', JSON.stringify({ passed: true, browser: browser.version(),
    scope: 'Actual styled OverviewRuntimeStats and API parsers with synthetic HTTP. No real backend or provider API calls.', checks, requests, errors, consoleErrors, unexpected }, null, 2) + '\n')
  console.log(JSON.stringify({ result: 'PASS', artifacts: out, checks }, null, 2))
} catch (error) {
  await writeFile(out + 'browser-failure.json', JSON.stringify({ error: String(error), body: await page.locator('body').innerText(), requests, errors, consoleErrors, unexpected }, null, 2) + '\n')
  throw error
} finally {
  await browser.close()
  await new Promise(resolve => streamServer.close(resolve))
  await server.close()
}
