// CI-built Dashboard rendering actual isolated Keeper decision history.
// All browser mutations, WebSockets and off-origin requests are blocked.
import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { resolve, relative, extname, sep } from 'node:path'
import assert from 'node:assert/strict'

const [previewDir, expectedHead, baseUrl, outputDir, tokenFile, taskId, runId, playwrightPackage, expectedBackendHead = expectedHead] = process.argv.slice(2)
if (!playwrightPackage) throw new Error('Usage: node SCRIPT PREVIEW HEAD BASE_URL OUTPUT TOKEN_FILE TASK_ID RUN_ID PLAYWRIGHT_PACKAGE_JSON [BACKEND_HEAD]')
const require = createRequire(resolve(playwrightPackage))
const { chromium } = require('playwright')
const root = resolve(previewDir)
const output = resolve(outputDir)
const origin = new URL(baseUrl).origin
assert.ok(['127.0.0.1', 'localhost'].includes(new URL(baseUrl).hostname))
const token = (await readFile(tokenFile, 'utf8')).trim()
const manifest = JSON.parse(await readFile(resolve(root, 'preview-provenance.json'), 'utf8'))
assert.equal(manifest.pr_head_commit, expectedHead)
for (const [name, hash] of Object.entries(manifest.files)) {
  const path = resolve(root, name)
  assert.ok(!relative(root, path).startsWith(`..${sep}`) && path.startsWith(root + sep))
  assert.equal(createHash('sha256').update(await readFile(path)).digest('hex'), hash, name)
}
async function readApi(path) {
  const response = await fetch(origin + path, { headers: { Authorization: `Bearer ${token}` }, redirect: 'error' })
  assert.ok(response.ok, `${path}: ${response.status}`)
  return response.json()
}
const health = await readApi('/health?full=1')
assert.equal(health.build.binary_commit, expectedBackendHead)
const history = await readApi(`/api/v1/dashboard/tasks/history?task_id=${encodeURIComponent(taskId)}&limit=100`)
const decisions = history.filter(row => row.type === 'fusion_decision' && row.fusion_run_id === runId)
assert.equal(decisions.length, 1, 'One actual same-run Keeper decision must already exist')
const decision = decisions[0]
assert.equal(decision.task, taskId)
assert.equal(decision.actor_kind, 'keeper')
assert.ok(['adopted', 'rejected', 'modified'].includes(decision.decision))
assert.ok(decision.choice && decision.reason && decision.turn_ref)
const detail = await readApi(`/api/v1/dashboard/tasks/detail?task_id=${encodeURIComponent(taskId)}`)
const fusion = await readApi(`/api/v1/dashboard/fusion-runs/${encodeURIComponent(runId)}`)
assert.ok(JSON.stringify(fusion).includes(decision.decision_id), 'Fusion detail must expose the same durable decision')
await mkdir(output, { recursive: false })
const browser = await chromium.launch({ headless: true })
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.png': 'image/png' }
const blocked = []
const pageErrors = []
const browserHistory = []
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, serviceWorkers: 'block' })
  page.on('pageerror', error => pageErrors.push(error.message))
  page.on('response', async response => {
    if (new URL(response.url()).pathname === '/api/v1/dashboard/tasks/history' && response.ok()) {
      browserHistory.push(await response.json())
    }
  })
  await page.routeWebSocket('**/*', socket => { blocked.push({ kind: 'websocket' }); socket.close() })
  await page.route('**/*', async route => {
    const request = route.request()
    const url = new URL(request.url())
    if (url.origin !== origin || !['GET', 'HEAD'].includes(request.method())) {
      blocked.push({ method: request.method(), path: url.pathname, off_origin: url.origin !== origin })
      return route.abort()
    }
    if (url.pathname.startsWith('/dashboard/')) {
      const name = decodeURIComponent(url.pathname.slice('/dashboard/'.length)) || 'index.html'
      assert.ok(Object.hasOwn(manifest.files, name), `Unmanifested asset ${name}`)
      return route.fulfill({ body: await readFile(resolve(root, name)), contentType: mime[extname(name)] ?? 'application/octet-stream' })
    }
    return route.continue({ headers: { ...request.headers(), Authorization: `Bearer ${token}` } })
  })
  await page.goto(`${origin}/dashboard/#workspace?section=planning&view=default`)
  await page.getByRole('button', { name: detail.task.title, exact: true }).click({ timeout: 60_000 })
  const dialog = page.getByRole('dialog', { name: detail.task.title, exact: true })
  await dialog.waitFor()
  const note = dialog.getByText(decision.notes, { exact: false }).first()
  await note.waitFor({ timeout: 30_000 })
  await note.scrollIntoViewIfNeeded()
  assert.ok((await dialog.textContent()).includes(decision.choice))
  assert.ok(browserHistory.some(rows => rows.some(row => row.decision_id === decision.decision_id)))
  await page.screenshot({ path: resolve(output, 'task-decision-desktop.png') })
  await page.setViewportSize({ width: 390, height: 844 })
  await note.scrollIntoViewIfNeeded()
  await page.screenshot({ path: resolve(output, 'task-decision-mobile.png') })
  const overflow = await dialog.evaluate(node => ({ width: node.clientWidth, scrollWidth: node.scrollWidth }))
  const overflowElements = await dialog.evaluate(node => {
    const right = node.getBoundingClientRect().right
    return [...node.querySelectorAll('*')].filter(child => child.getBoundingClientRect().right > right + 1 || child.scrollWidth > child.clientWidth + 1)
      .map(child => ({ tag: child.tagName, class: child.className, width: child.clientWidth,
        scroll_width: child.scrollWidth, text: child.textContent?.slice(0, 160) }))
  })
  assert.deepEqual(pageErrors, [])
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify({
    observed_at: new Date().toISOString(), scope: 'Actual Keeper decision read from the isolated backend and rendered by exact CI preview; not production deployment or original PDF Task completion',
    preview_manifest: manifest, expected_backend_commit: expectedBackendHead, health, decision, history, fusion, browser_history: browserHistory,
    checks: ['exact_ci_asset_hashes', 'exact_runtime_commit', 'same_task_run_decision_in_two_readbacks', 'actual_task_history_render'],
    page_errors: pageErrors, blocked_requests: blocked, mobile_dialog: overflow, mobile_overflow_elements: overflowElements,
  }, null, 2) + '\n')
  console.log(JSON.stringify({ output, decision_id: decision.decision_id, mobile_dialog: overflow }))
} finally { await browser.close() }
