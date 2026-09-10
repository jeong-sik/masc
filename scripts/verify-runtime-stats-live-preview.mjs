// Run with the dashboard's installed Playwright, a downloaded CI preview,
// and a live backend with write methods/WebSockets blocked. No local compilation.
import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { resolve, relative, extname, sep } from 'node:path'
import assert from 'node:assert/strict'
const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const [previewArgument, expectedHead, baseUrl, outputArgument, tokenFile] = process.argv.slice(2)
if (!previewArgument || !expectedHead || !baseUrl || !outputArgument) {
  throw new Error('Usage: node scripts/verify-runtime-stats-preview.mjs PREVIEW_DIR PR_HEAD BACKEND_URL EVIDENCE_DIR [TOKEN_FILE]')
}
const token = tokenFile ? (await readFile(tokenFile, 'utf8')).trim() : null
const observations = []
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
  const pageErrors = []
  page.on('pageerror', error => pageErrors.push(error.message))
  await page.route('**/*', async route => {
    const request = route.request()
    if (!['GET', 'HEAD'].includes(request.method())) {
      mutations.push({ method: request.method(), path: new URL(request.url()).pathname })
      return route.abort()
    }
    const url = new URL(request.url())
    if (url.origin === new URL(baseUrl).origin && url.pathname === '/api/v1/models/metrics') {
      const response = await fetch(url, { headers: token ? { Authorization: `Bearer ${token}` } : {} })
      const body = await response.text()
      if (response.ok) observations.push({ observed_at: new Date().toISOString(), query: url.search, data: JSON.parse(body) })
      return route.fulfill({ status: response.status, body, contentType: 'application/json' })
    }
    if (url.origin === new URL(baseUrl).origin && url.pathname.startsWith('/dashboard/')) {
      const name = decodeURIComponent(url.pathname.slice('/dashboard/'.length)) || 'index.html'
      assert.ok(Object.hasOwn(manifest.files, name), `Unmanifested asset: ${name}`)
      return route.fulfill({ body: await readFile(resolve(root, name)),
        contentType: mime[extname(name)] ?? 'application/octet-stream' })
    }
    return route.continue()
  })
  await page.goto(new URL('/dashboard/#overview', baseUrl).href)
  const panel = page.locator('[data-overview-runtime-stats]')
  await panel.getByRole('table').waitFor({ timeout: 180_000 })
  const observation = observations.at(-1)
  assert.ok(observation)
  assert.notEqual(observation.data.cost_ledger_read?.state, 'pending')
  const rows = await panel.locator('tbody tr').all()
  assert.equal(rows.length, observation.data.models.length)
  for (let i = 0; i < rows.length; i++) {
    const model = observation.data.models[i]
    const row = await rows[i].textContent()
    assert.ok(row.includes(model.model_id))
    for (const [field, label] of [['total_input_tokens', '입력'], ['total_output_tokens', '출력']]) {
      const value = model[field]
      const expected = value == null ? '미보고' : Number(value).toLocaleString(undefined, { maximumFractionDigits: 1 })
      assert.ok(row.includes(`${label} ${expected}`), `${model.model_id} ${field}`)
    }
  }
  await panel.scrollIntoViewIfNeeded()
  await panel.screenshot({ path: resolve(output, 'live-panel.png') })
  await page.setViewportSize({ width: 390, height: 844 })
  await panel.scrollIntoViewIfNeeded()
  await page.screenshot({ path: resolve(output, 'live-mobile.png') })
  const receipt = { observed_at: new Date().toISOString(), manifest,
    observations, checks: ['actual_backend_response', 'runtime_row_identity', 'input_output_tokens_match_response'],
    page_errors: pageErrors, backend: new URL(baseUrl).origin,
    blocked_mutations: mutations, blocked_websockets: blockedWebSockets,
    deployment: false, scope: 'CI-built Overview rendering actual authenticated backend metrics; underlying ledger accuracy is not independently verified' }
  assert.deepEqual(pageErrors, [])
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n')
  console.log(JSON.stringify({ evidence: output, runtime_rows: rows.length, page_errors: pageErrors }))
} finally { await browser.close() }
