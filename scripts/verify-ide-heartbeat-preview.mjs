// Inspect exact CI-built bytes with synthetic HTTP input; no local compilation or backend.
import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { resolve, relative, extname, sep } from 'node:path'
import assert from 'node:assert/strict'
const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const [previewArgument, expectedHead, outputArgument] = process.argv.slice(2)
assert.ok(previewArgument && expectedHead && outputArgument,
  'Usage: node scripts/verify-ide-heartbeat-preview.mjs PREVIEW_DIR PR_HEAD EVIDENCE_DIR')
const root = resolve(previewArgument)
const output = resolve(outputArgument)
const manifest = JSON.parse(await readFile(resolve(root, 'preview-provenance.json'), 'utf8'))
assert.equal(manifest.pr_head_commit, expectedHead)
for (const [name, hash] of Object.entries(manifest.files)) {
  const file = resolve(root, name)
  assert.ok(!relative(root, file).startsWith(`..${sep}`) && file.startsWith(root + sep))
  assert.equal(createHash('sha256').update(await readFile(file)).digest('hex'), hash, name)
}
const heartbeat = '2026-09-10T00:00:00Z'
const rows = ['Running', 'Restarting', 'Failing'].map(phase => ({
  name: phase.toLowerCase(), status: 'online', phase, last_heartbeat: heartbeat,
}))
rows.push({ name: 'no-heartbeat', status: 'online', phase: 'Running',
  created_at: '2026-09-01T00:00:00Z', updated_at: '2026-09-09T00:00:00Z' })
const origin = 'http://heartbeat-preview.test'
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.png': 'image/png' }
const requests = [], blocked = [], pageErrors = [], checks = []
await mkdir(output, { recursive: true })
const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1100 }, serviceWorkers: 'block' })
  await page.clock.setFixedTime(new Date('2026-09-10T00:05:00Z'))
  page.on('pageerror', error => pageErrors.push(error.message))
  await page.routeWebSocket('**/*', socket => { blocked.push({ websocket: socket.url() }); socket.close() })
  await page.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url())
    if (url.origin !== origin || !['GET', 'HEAD'].includes(request.method())) {
      blocked.push({ method: request.method(), url: request.url() }); return route.abort()
    }
    if (url.pathname === '/preview-fixture/heartbeat-keepers') {
      requests.push(url.pathname); return route.fulfill({ json: rows })
    }
    for (const keeper of rows) {
      if (url.pathname === `/api/v1/keepers/${keeper.name}/state-diagram`) {
        requests.push(url.pathname)
        return route.fulfill({ json: { keeper: keeper.name, current_phase: keeper.phase, mermaid: 'graph TD' } })
      }
    }
    if (url.pathname.startsWith('/dashboard/')) {
      const name = decodeURIComponent(url.pathname.slice('/dashboard/'.length))
      if (Object.hasOwn(manifest.files, name)) return route.fulfill({
        body: await readFile(resolve(root, name)), contentType: mime[extname(name)] ?? 'application/octet-stream',
      })
    }
    blocked.push({ method: request.method(), url: request.url() }); return route.abort()
  })
  await page.goto(`${origin}/dashboard/dev-fixtures/ide-heartbeat.html`)
  for (const keeper of rows) {
    const panel = page.locator(`[data-keeper="${keeper.name}"] [data-testid="ide-persistence-panel"]`)
    await panel.waitFor()
    await page.waitForFunction(name => performance.getEntriesByType('resource')
      .some(entry => entry.name.endsWith(`/api/v1/keepers/${name}/state-diagram`)), keeper.name)
    const label = panel.getByLabel('최근 하트비트')
    if (keeper.last_heartbeat) {
      assert.equal(await label.getAttribute('title'), heartbeat)
      assert.equal(await label.textContent(), '하트비트 5분 전')
    } else {
      assert.equal(await label.getAttribute('title'), null)
      assert.equal(await label.textContent(), '하트비트 정보 없음')
    }
    for (const invented of ['저장됨', '동기화 중', '충돌']) assert.equal(await panel.getByText(invented, { exact: true }).count(), 0)
    assert.equal(await panel.getByTestId('ide-persistence-lifecycle').count(), 1)
    assert.ok(await panel.getByRole('button').count() > 0, 'context routes remain available')
    checks.push({ keeper: keeper.name, phase: keeper.phase, heartbeat: keeper.last_heartbeat ?? null })
  }
  await page.screenshot({ path: resolve(output, 'desktop.png'), fullPage: true })
  await page.setViewportSize({ width: 390, height: 844 })
  const mobileOverflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)
  await page.screenshot({ path: resolve(output, 'mobile.png'), fullPage: true })
  assert.equal(mobileOverflow, false, 'mobile document overflow')
  assert.deepEqual(pageErrors, [])
  assert.deepEqual(blocked, [])
  const screenshots = {}
  for (const name of ['desktop.png', 'mobile.png']) screenshots[name] = createHash('sha256').update(await readFile(resolve(output, name))).digest('hex')
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify({ observed_at: new Date().toISOString(),
    manifest, checks, fixture_rows: rows, synthetic_clock: '2026-09-10T00:05:00Z', requests,
    page_errors: pageErrors, blocked_requests: blocked, mobile_overflow: mobileOverflow, screenshots,
    deployment: false, scope: 'CI-built actual IdePersistencePanel with synthetic Keeper and state-diagram HTTP responses; not storage durability or full IDE layout proof',
  }, null, 2) + '\n')
  console.log(JSON.stringify({ evidence: output, checks: checks.length, page_errors: pageErrors }))
} finally { await browser.close() }
