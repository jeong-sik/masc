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
  throw new Error('Usage: node scripts/verify-skill-source-preview.mjs PREVIEW_DIR PR_HEAD BACKEND_URL EVIDENCE_DIR')
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
const sourceReads = []
let failNextRead = false
const tokenPath = process.argv[6]
const token = tokenPath ? (await readFile(tokenPath, 'utf8')).trim() : null
const blockedWebSockets = []
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, serviceWorkers: 'block' })
  await page.routeWebSocket('**/*', socket => {
    blockedWebSockets.push(socket.url())
    socket.close()
  })
  await page.route('**/*', async route => {
    const request = route.request()
    const url = new URL(request.url())
    if (url.origin === new URL(baseUrl).origin && url.pathname === '/api/v1/skills/editor/read' && request.method() === 'POST') {
      if (failNextRead) {
        failNextRead = false
        return route.fulfill({ status: 503, json: { error: 'browser fixture: source unavailable' } })
      }
      const response = await route.fetch(token ? { headers: { ...request.headers(), authorization: `Bearer ${token}` } } : {})
      const payload = await response.json()
      assert.equal(response.status(), 200)
      sourceReads.push({ request: request.postDataJSON(), payload })
      return route.fulfill({ response })
    }
    if (!['GET', 'HEAD'].includes(request.method())) {
      mutations.push({ method: request.method(), path: url.pathname })
      return route.abort()
    }
    if (url.origin === new URL(baseUrl).origin && url.pathname.startsWith('/dashboard/')) {
      const name = decodeURIComponent(url.pathname.slice('/dashboard/'.length)) || 'index.html'
      assert.ok(Object.hasOwn(manifest.files, name), `Unmanifested asset: ${name}`)
      return route.fulfill({ body: await readFile(resolve(root, name)),
        contentType: mime[extname(name)] ?? 'application/octet-stream' })
    }
    return route.continue()
  })
  await page.goto(new URL('/dashboard/#monitoring?section=skills', baseUrl).href)
  const first = page.getByRole('button', { name: /^Read instructions for / }).first()
  await first.waitFor()
  assert.equal(sourceReads.length, 0)
  await first.click()
  const source = page.getByLabel('Exact Skill source', { exact: true })
  await source.waitFor()
  assert.equal(sourceReads.length, 1)
  assert.deepEqual(sourceReads[0].payload.reference, sourceReads[0].request.reference)
  assert.equal(await source.textContent(), sourceReads[0].payload.source_text)
  assert.equal(await page.locator('[data-testid="skill-source-editor"]').count(), 0)
  await source.focus()
  assert.equal(await source.evaluate(element => element === document.activeElement), true)
  await source.scrollIntoViewIfNeeded()
  await page.screenshot({ path: resolve(output, 'desktop.png') })
  await page.setViewportSize({ width: 390, height: 844 })
  await source.scrollIntoViewIfNeeded()
  const mobileSourceBounds = await source.boundingBox()
  assert.ok(mobileSourceBounds && mobileSourceBounds.x >= 0 && mobileSourceBounds.x + mobileSourceBounds.width <= 390, 'Source must fit mobile viewport')
  await page.screenshot({ path: resolve(output, 'mobile.png') })
  const mobileOverflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)
  await page.setViewportSize({ width: 1440, height: 1000 })
  await first.click()
  failNextRead = true
  await first.click()
  const unavailable = page.getByRole('alert').filter({ hasText: 'browser fixture: source unavailable' })
  await unavailable.waitFor()
  assert.equal(await page.getByLabel('Exact Skill source', { exact: true }).count(), 0)
  await unavailable.scrollIntoViewIfNeeded()
  await page.screenshot({ path: resolve(output, 'unavailable.png') })
  await page.getByRole('button', { name: 'Retry source read', exact: true }).click()
  await source.waitFor()
  assert.equal(sourceReads.length, 2)
  assert.equal(await source.textContent(), sourceReads[1].payload.source_text)
  const receipt = { observed_at: new Date().toISOString(), manifest,
    backend: new URL(baseUrl).origin, blocked_mutations: mutations, blocked_websockets: blockedWebSockets,
    deployment: false, mobile_overflow: mobileOverflow, mobile_source_bounds: mobileSourceBounds,
    reads: sourceReads.map(({ request, payload }) => ({ reference: request.reference,
      access: payload.access, source_sha256: createHash('sha256').update(payload.source_text).digest('hex'),
      source_bytes: Buffer.byteLength(payload.source_text), exact_text_match: true })),
    scope: 'CI-built Skills catalog, real live revision-bound source read, synthetic503 retry scenario' }
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n')
  console.log(JSON.stringify({ source_reads: sourceReads.length, evidence: output, mobile_overflow: mobileOverflow }))
} finally { await browser.close() }
