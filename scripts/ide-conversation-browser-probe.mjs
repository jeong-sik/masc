import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { mkdir, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
const [dashboardArg, outputArg] = process.argv.slice(2)
assert.ok(dashboardArg && outputArg, 'DASHBOARD FRESH_OUTPUT required')
const dashboard = resolve(dashboardArg), output = resolve(outputArg)
await mkdir(output)
const require = createRequire(resolve(dashboard, 'package.json'))
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { chromium } = require('playwright')
let vite, browser
let boardMode = 'initial', decisionMode = 'initial'
const pending = [], requests = [], errors = []
let initialReady
const initialResponses = new Promise(resolve => { initialReady = resolve })
const reply = (res, value, status = 200) => { res.statusCode = status; res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(value)) }
const board = body => ({ posts: [{ id: 'post-1', author: 'editor', title: 'Original note', body,
  created_at: '2026-09-13T00:00:00Z', updated_at: '2026-09-13T00:00:00Z', comment_count: 0, votes: 0 }] })
const decisions = { events: [{ keeper_name: 'editor', ts_unix: Date.parse('2026-09-13T00:00:01Z') / 1000, event_type: 'turn_completed', outcome: 'success' }], limit: 200, generated_at: null }
const receipt = { scope: 'Source Reaction Thread in Chromium; synthetic API responses and push invalidations; no installed/runtime acceptance.', passed: false, scenarios: [], requests, errors }
try {
  vite = await createServer({ configFile: false, root: dashboard, cacheDir: resolve(output, 'vite-cache'),
    server: { host: '127.0.0.1', port: 0 }, logLevel: 'error',
    plugins: [{ name: 'conversation-fixture', configureServer(server) {
      server.middlewares.use(async (req, res, next) => {
        const path = new URL(req.url, 'http://localhost').pathname
        if (path === '/__conversation') {
          res.setHeader('Content-Type', 'text/html')
          res.end(await server.transformIndexHtml(path, '<!doctype html><meta charset="UTF-8"><title>Conversation source acceptance</title><style>body{background:#161a22;color:#eee;margin:24px;font:15px sans-serif}main{max-width:920px;margin:auto}.ide-conversation-panel{height:auto}button{margin:4px}h1{font-size:24px}</style><div id="fixture"></div><script type="module" src="/scripts/ide-conversation-browser-fixture.ts"></script>'))
        } else if (path === '/api/v1/board' || path === '/api/v1/dashboard/keeper-decisions') {
          const source = path === '/api/v1/board' ? 'board' : 'decisions'
          const mode = source === 'board' ? boardMode : decisionMode
          requests.push({ source, mode })
          if (mode === 'initial') { pending.push({ source, res }); if (pending.length === 2) initialReady() }
          else if (mode === 'error') reply(res, { error: 'Synthetic source unavailable' }, 503)
          else reply(res, source === 'board' ? board(mode === 'updated' ? 'Note after server invalidation' : 'Retained Board note') : decisions)
        } else next()
      })
    } }],
  })
  await vite.listen()
  const origin = `http://127.0.0.1:${vite.httpServer.address().port}`
  browser = await chromium.launch()
  const page = await browser.newPage({ viewport: { width: 1100, height: 900 } })
  page.on('pageerror', error => errors.push(error.message))
  await page.route('**/*', route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort())
  await page.goto(`${origin}/__conversation`)
  await page.waitForFunction(() => document.querySelectorAll('[data-load-state="loading"]').length === 2)
  assert.equal(await page.getByText('no conversation activity', { exact: true }).count(), 0)
  await page.screenshot({ path: resolve(output, 'loading.png'), fullPage: true })
  receipt.scenarios.push('both sources show loading before an observed response')
  await page.waitForFunction(() => document.querySelector('[data-conversation-source="Board"]'))
  await initialResponses
  boardMode = 'ready'; decisionMode = 'error'
  for (const { source, res } of pending.splice(0)) reply(res, source === 'board' ? board('Retained Board note') : { error: 'Synthetic source unavailable' }, source === 'board' ? 200 : 503)
  await page.getByText('Retained Board note', { exact: true }).waitFor()
  await page.getByRole('button', { name: 'Retry Decisions', exact: true }).waitFor()
  await page.screenshot({ path: resolve(output, 'partial-error.png'), fullPage: true })
  receipt.scenarios.push('Board succeeds independently while Decisions reports an explicit error')
  boardMode = 'error'
  await page.getByRole('button', { name: 'Refresh Board', exact: true }).click()
  await page.getByText('Refresh failed; showing last successful data', { exact: false }).waitFor()
  await page.getByText('Retained Board note', { exact: true }).waitFor()
  await page.screenshot({ path: resolve(output, 'retained-error.png'), fullPage: true })
  decisionMode = 'ready'
  await page.getByRole('button', { name: 'Retry Decisions', exact: true }).click()
  await page.waitForFunction(() => document.querySelector('[data-conversation-source="Decisions"]')?.getAttribute('data-load-state') === 'ready')
  await page.locator('[data-replay-source="decision"]').getByText('turn_completed · success', { exact: true }).waitFor()
  receipt.scenarios.push('manual retry recovers a populated Decisions card without erasing the failed Board source snapshot')
  await page.setViewportSize({ width: 390, height: 844 })
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false)
  await page.screenshot({ path: resolve(output, 'retained-error-mobile.png'), fullPage: true })
  await page.setViewportSize({ width: 1100, height: 900 })
  boardMode = 'updated'
  await page.locator('#board-push').click()
  await page.getByText('Note after server invalidation', { exact: true }).waitFor()
  const countBefore = requests.filter(x => x.source === 'decisions').length
  const decisionResponse = page.waitForResponse(response => response.url().includes('/api/v1/dashboard/keeper-decisions'))
  await page.locator('#decision-push').click()
  await decisionResponse
  await page.waitForFunction(() => document.querySelector('[data-conversation-source="Decisions"]')?.getAttribute('data-load-state') === 'ready')
  assert.equal(requests.filter(x => x.source === 'decisions').length, countBefore + 1)
  await page.screenshot({ path: resolve(output, 'refreshed.png'), fullPage: true })
  receipt.scenarios.push('existing server-push router independently refreshes Board and Decisions')
  assert.deepEqual(errors, [])
  receipt.passed = true
} catch (error) { receipt.error = error.stack; process.exitCode = 1 }
finally {
  for (const { res } of pending) res.destroy()
  await browser?.close(); await vite?.close()
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n')
  console.log(JSON.stringify(receipt))
}
