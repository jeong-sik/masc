// Run with the dashboard's installed Playwright, a downloaded CI preview,
// and a read-only live backend. No local compilation or runtime mutation.
import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { resolve, relative, extname, sep } from 'node:path'
import assert from 'node:assert/strict'
const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const [previewArgument, expectedHead, baseUrl, outputArgument] = process.argv.slice(2)
if (!previewArgument || !expectedHead || !baseUrl || !outputArgument) {
  throw new Error('Usage: node scripts/verify-workspace-memory-preview.mjs PREVIEW_DIR PR_HEAD BACKEND_URL EVIDENCE_DIR')
}
const snapshot = claim => ({ status: 'available', snapshot: {
  revision: 2, updated_at: 1, facts: [{ claim, category: 'fact', origin: { trace_id: 'fixture-turn' } }],
} })
const memoryFixture = {
  schema: 'workspace.memory.context.v1', generated_at: 1,
  source_validation: 'stored_bindings_not_revalidated', consistency: 'individual_store_snapshots',
  discovery: { status: 'available' }, keepers: [
    { keeper_id: 'writer', ordinary: snapshot('Chapter finished'), source_bound: { status: 'missing' } },
    { keeper_id: 'reviewer', ordinary: snapshot('Chapter incomplete'), source_bound: { status: 'unavailable', detail: 'fixture: source read failed' } },
  ],
}
const root = resolve(previewArgument)
const output = resolve(outputArgument)
const manifest = JSON.parse(await readFile(resolve(root, 'preview-provenance.json'), 'utf8'))
assert.equal(manifest.pr_head_commit, expectedHead)
for (const [name, hash] of Object.entries(manifest.files)) {
  const file = resolve(root, name)
  assert.ok(!relative(root, file).startsWith(`..${sep}`) && file.startsWith(root + sep))
  assert.equal(createHash('sha256').update(await readFile(file)).digest('hex'), hash, name)
}
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.png': 'image/png' }
await mkdir(output, { recursive: true })
const browser = await chromium.launch({ headless: true })
const mutations = []
const blockedWebSockets = []
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, serviceWorkers: 'block' })
  await page.routeWebSocket('**/*', socket => {
    blockedWebSockets.push(socket.url())
    socket.close()
  })
  await page.route('**/*', async route => {
    const request = route.request()
    if (!['GET', 'HEAD'].includes(request.method())) {
      mutations.push({ method: request.method(), path: new URL(request.url()).pathname })
      return route.abort()
    }
    const url = new URL(request.url())
    if (url.origin === new URL(baseUrl).origin && url.pathname === '/api/v1/dashboard/workspace-memory-context') {
      return route.fulfill({ json: memoryFixture })
    }
    if (url.origin === new URL(baseUrl).origin && url.pathname.startsWith('/dashboard/')) {
      const name = decodeURIComponent(url.pathname.slice('/dashboard/'.length)) || 'index.html'
      assert.ok(Object.hasOwn(manifest.files, name), `Unmanifested asset: ${name}`)
      return route.fulfill({ body: await readFile(resolve(root, name)),
        contentType: mime[extname(name)] ?? 'application/octet-stream' })
    }
    return route.continue()
  })
  await page.goto(new URL('/dashboard/#lab?section=keeper-memory-health', baseUrl).href)
  const panel = page.locator('[data-workspace-memory-context]')
  await panel.getByText('Chapter finished', { exact: true }).waitFor()
  assert.equal(await panel.getByText('Chapter incomplete', { exact: true }).count(), 1)
  assert.ok((await panel.getByRole('alert').textContent()).includes('fixture: source read failed'))
  const writer = panel.locator('[data-memory-owner="writer"]')
  await writer.getByText('현재 저장 원문·최근 변경', { exact: true }).click()
  const source = writer.getByLabel('일반 기억 저장 원문')
  assert.ok((await source.textContent()).includes('fixture-turn'))
  await source.focus()
  assert.equal(await source.evaluate(element => element === document.activeElement), true)
  await panel.scrollIntoViewIfNeeded()
  await page.screenshot({ path: resolve(output, 'desktop.png') })
  await page.setViewportSize({ width: 390, height: 844 })
  await panel.scrollIntoViewIfNeeded()
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false)
  await page.screenshot({ path: resolve(output, 'mobile.png') })
  await panel.getByLabel('Keeper 선택').selectOption('reviewer')
  assert.equal(await panel.getByText('Chapter finished', { exact: true }).count(), 0)
  assert.equal(await panel.getByText('Chapter incomplete', { exact: true }).count(), 1)
  const receipt = { observed_at: new Date().toISOString(), manifest,
    fixture_keepers: memoryFixture.keepers.length,
    backend: new URL(baseUrl).origin, blocked_mutations: mutations, blocked_websockets: blockedWebSockets,
    deployment: false, scope: 'CI-built Lab memory panel with synthetic memory context over read-only live backend' }
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n')
  console.log(JSON.stringify({ fixture_keepers: memoryFixture.keepers.length, evidence: output }))
} finally { await browser.close() }
