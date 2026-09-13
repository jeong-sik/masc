// Chromium interaction with the production source component and synthetic API data.
// Vite dev transformation only. No live server mutation or production build.
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { mkdir, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const [dashboardArg, outputArg] = process.argv.slice(2)
assert.ok(dashboardArg && outputArg, 'DASHBOARD FRESH_OUTPUT_DIR required')
const dashboard = resolve(dashboardArg), output = resolve(outputArg)
await mkdir(output)
const require = createRequire(resolve(dashboard, 'package.json'))
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { chromium } = require('playwright')
const requests = [], errors = [], snapshots = []
let vite, browser
const receipt = { scope: 'Production source Activity component in Chromium with synthetic API data. Not installed MASC or real persisted history acceptance.', passed: false }
const events = Array.from({ length: 50 }, (_, index) => ({
  seq: 1923 + index, ts_ms: Date.parse('2026-09-13T00:00:00Z') + index,
  ts_iso: '2026-09-13T00:00:00Z', workspace_id: 'synthetic-workspace', kind: 'task.noted',
  actor: { kind: 'keeper', id: 'fixture-keeper' },
  subject: { kind: 'task', id: `task-${index + 1}` }, payload: { summary: `Workspace record ${index + 1923}` }, tags: [],
}))
try {
  vite = await createServer({ configFile: false, root: dashboard, cacheDir: resolve(output, 'vite-cache'),
    server: { host: '127.0.0.1', port: 0 }, logLevel: 'error',
    plugins: [{ name: 'history-window-fixture', configureServer(server) {
      server.middlewares.use(async (req, res, next) => {
        const url = new URL(req.url, 'http://localhost')
        if (url.pathname === '/__history_probe') {
          res.setHeader('Content-Type', 'text/html')
          res.end(await server.transformIndexHtml('/__history_probe', '<!doctype html><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>History window source acceptance</title><style>body{margin:16px;background:#161a22;color:#eee;font:15px sans-serif}main{max-width:1000px;margin:auto}.ide-activity-panel{height:auto}h1{font-size:24px}label{display:inline-block;margin:0 16px 16px 0}</style><div id="fixture"></div><script type="module" src="/scripts/ide-history-window-browser-fixture.ts"></script>'))
        } else if (url.pathname === '/api/v1/activity/events' || url.pathname === '/api/v1/ide/events') {
          const scenario = new URL(req.headers.referer ?? 'http://localhost').searchParams.get('scenario') ?? 'known'
          requests.push({ path: url.pathname, scenario, codebase: url.searchParams.get('codebase') })
          const data = url.pathname === '/api/v1/activity/events'
            ? { events: scenario === 'empty' ? [] : events, ...(scenario === 'unknown' ? {} : { total_matching_events: scenario === 'empty' ? 0 : 1972 }) }
            : { ok: true, data: { events: scenario === 'empty' ? [] : [{ type: 'turn', keeper_id: 'bridge-keeper', turn_id: 'extra-scoped-event', phase: 'completed', timestamp_ms: Date.parse('2026-09-13T00:01:00Z') }] } }
          res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(data))
        } else next()
      })
    } }],
  })
  await vite.listen()
  const address = vite.httpServer.address()
  assert.ok(address && typeof address === 'object')
  const origin = `http://127.0.0.1:${address.port}`
  browser = await chromium.launch()
  const page = await browser.newPage({ viewport: { width: 1160, height: 1000 } })
  page.on('pageerror', error => errors.push(error.message))
  await page.route('**/*', route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort())
  await page.goto(`${origin}/__history_probe`)
  async function capture(name, text, expectedRows) {
    await page.waitForFunction(({ text, expectedRows }) => document.querySelector('[data-testid="ide-workspace-history-window"]')?.textContent.includes(text)
      && document.querySelectorAll('.ide-activity-row').length === expectedRows, { text, expectedRows })
    const history = await page.getByTestId('ide-workspace-history-window').innerText()
    const geometry = await page.evaluate(() => ({ width: innerWidth, scrollWidth: document.documentElement.scrollWidth }))
    assert.ok(geometry.scrollWidth <= geometry.width, `${name}: horizontal document overflow`)
    snapshots.push({ name, history, displayed_rows: expectedRows, viewport: page.viewportSize(), geometry })
    await page.screenshot({ path: resolve(output, `${name}.png`) })
  }
  await capture('desktop', 'Workspace history: 50 of 1972 loaded', 51)
  await page.getByRole('checkbox', { name: 'Compact layout' }).check()
  await capture('desktop-compact', 'Workspace history: 50 of 1972 loaded', 51)
  await page.setViewportSize({ width: 390, height: 844 })
  await capture('mobile-compact', 'Workspace history: 50 of 1972 loaded', 51)
  await page.getByRole('combobox', { name: 'Fixture scenario' }).selectOption('unknown')
  await page.getByRole('checkbox', { name: 'Compact layout' }).check()
  await capture('mobile-total-unavailable', 'Workspace history: 50 loaded · total unavailable', 51)
  assert.ok(!(await page.getByTestId('ide-workspace-history-window').innerText()).includes('older events'))
  await page.getByRole('combobox', { name: 'Fixture scenario' }).selectOption('empty')
  await page.getByRole('checkbox', { name: 'Compact layout' }).check()
  await capture('mobile-empty', 'Workspace history: 0 of 0 loaded', 0)
  assert.deepEqual(errors, [])
  receipt.passed = true
} catch (error) { receipt.error = String(error); process.exitCode = 1 }
finally {
  await browser?.close(); await vite?.close()
  if (errors.length) { receipt.passed = false; process.exitCode = 1 }
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify({ ...receipt, snapshots, requests, errors }, null, 2) + '\n')
}
console.log(JSON.stringify({ output, passed: receipt.passed, error: receipt.error }))
