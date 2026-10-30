// Real browser and product source component with explicit synthetic API data.
// Vite development transformation only; no production build or live mutations.
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
const receipt = { scope: 'Product source Activity panel in Chromium with synthetic API fixtures. Not installed MASC acceptance.', passed: false }
const fixtureTime = Date.parse('2026-09-13T00:00:00Z')
const globalEvents = [
  { seq: 1, ts_ms: fixtureTime + 1, ts_iso: '2026-09-13T00:00:00Z', kind: 'task.noted',
    actor: { kind: 'keeper', id: 'global-keeper' }, subject: { kind: 'task', id: 'global-task' },
    payload: { file_path: 'src/shared.ml', line: 99, codebase: 'github.com_owner_a',
      summary: 'Global history has no codebase authority', goal_id: 'global-goal', task_id: 'global-task' }, tags: [] },
  { seq: 2, ts_ms: fixtureTime + 2, ts_iso: '2026-09-13T00:00:00Z', kind: 'keeper.turn_completed',
    actor: { kind: 'keeper', id: 'global-keeper' }, subject: { kind: 'keeper', id: 'global-keeper' }, payload: {}, tags: [] },
]
const bridgeEvent = (codebase, file, index) => ({ type: 'tool', keeper_id: 'scoped-keeper',
  turn_id: `turn-${codebase}-${index}`, timestamp_ms: fixtureTime + 3 + index, tool_name: 'read_file',
  outcome: 'success', typed_outcome: 'progress', latency_ms: 1,
  summary: `observed ${codebase} ${file}`, file_path: file })
try {
  vite = await createServer({ configFile: false, root: dashboard, cacheDir: resolve(output, 'vite-cache'),
    server: { host: '127.0.0.1', port: 0 }, logLevel: 'error',
    plugins: [{ name: 'ide-file-context-fixture', configureServer(server) {
      server.middlewares.use(async (req, res, next) => {
        const url = new URL(req.url, 'http://localhost')
        if (url.pathname === '/__context_probe') {
          res.setHeader('Content-Type', 'text/html')
          res.end(await server.transformIndexHtml('/__context_probe', '<!doctype html><meta charset="UTF-8"><title>File context source acceptance</title><style>body{margin:24px;background:#161a22;color:#eee;font:15px sans-serif}main{max-width:1000px;margin:auto}.ide-activity-panel{height:auto}h1{font-size:24px}</style><div id="fixture"></div><script type="module" src="/scripts/ide-file-context-browser-fixture.ts"></script>'))
        } else if (url.pathname === '/api/v1/activity/events' || url.pathname === '/api/v1/ide/events') {
          const codebase = url.searchParams.get('codebase')
          requests.push({ path: url.pathname, codebase })
          const data = url.pathname === '/api/v1/activity/events' ? { events: globalEvents }
            : { ok: true, data: { events: codebase === 'github.com_owner_empty' ? []
              : [bridgeEvent(codebase, 'src/shared.ml', 1), bridgeEvent(codebase, 'src/other.ml', 2)] } }
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
  const page = await browser.newPage({ viewport: { width: 1160, height: 1100 } })
  page.on('pageerror', error => errors.push(error.message))
  await page.route('**/*', route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort())
  await page.goto(`${origin}/__context_probe`)
  for (const repo of ['a', 'b', 'empty']) {
    const codebase = `github.com_owner_${repo}`
    if (repo !== 'a') await page.getByRole('combobox', { name: 'Fixture repository' }).selectOption(codebase)
    await page.waitForFunction(({ repo, codebase }) => {
      const pane = document.querySelector('[data-testid="ide-context-lens"]')
      const count = pane?.getAttribute('data-total-anchors')
      const rows = document.querySelectorAll('.ide-activity-row')
      return repo === 'empty' ? count === '0' && rows.length === 2
        : count === '1' && rows.length === 4 && pane.textContent.includes(codebase)
    }, { repo, codebase })
    const lens = page.getByTestId('ide-context-lens')
    const globalRow = page.locator('.ide-activity-row').filter({ hasText: 'Global history has no codebase authority' })
    assert.equal(await globalRow.getByRole('button', { name: /^Open Code / }).count(), 0)
    assert.equal(await globalRow.locator('.ide-activity-context-jump').count(), 0)
    assert.equal(await globalRow.getByRole('button', { name: 'Open Task global-task', exact: true }).count(), 1)
    if (repo === 'empty') assert.equal(await lens.getByRole('button', { name: /^Open Code / }).count(), 0)
    else assert.equal(await lens.locator('.ide-context-anchor-action').count(), 1)
    snapshots.push({ codebase, file: 'src/shared.ml', anchor_count: Number(await lens.getAttribute('data-total-anchors')),
      timeline_count: await page.locator('.ide-activity-row').count(), lens: await lens.innerText() })
    await page.screenshot({ path: resolve(output, `repo-${repo}.png`), fullPage: true })
  }
  assert.deepEqual(errors, [])
  receipt.passed = true
} catch (error) { receipt.error = String(error); process.exitCode = 1 }
finally {
  await browser?.close(); await vite?.close()
  if (errors.length) { receipt.passed = false; process.exitCode = 1 }
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify({ ...receipt, snapshots, requests, errors }, null, 2) + '\n')
}
console.log(JSON.stringify({ output, passed: receipt.passed, error: receipt.error }))
