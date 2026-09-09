import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { resolve, extname } from 'node:path'
import assert from 'node:assert/strict'
const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const [directory, expectedHead, evidenceDirectory] = process.argv.slice(2)
assert.ok(directory && expectedHead && evidenceDirectory, 'Usage: PREVIEW_DIR PR_HEAD EVIDENCE_DIR')
const root = resolve(directory)
const output = resolve(evidenceDirectory)
const manifest = JSON.parse(await readFile(resolve(root, 'preview-provenance.json'), 'utf8'))
assert.equal(manifest.pr_head_commit, expectedHead)
const assets = new Map()
for (const [name, hash] of Object.entries(manifest.files)) {
  assert.ok(resolve(root, name).startsWith(root + '/'))
  const body = await readFile(resolve(root, name))
  assert.equal(createHash('sha256').update(body).digest('hex'), hash)
  assets.set('/dashboard/' + name, body)
}
function artifact(content) {
  return { content, sha256: createHash('sha256').update(content).digest('hex'),
    bytes: Buffer.byteLength(content), mime: 'application/octet-stream' }
}
const before = artifact('\tlet answer = 20\r\nunchanged\r\n')
const after = artifact('\tlet answer = 21\r\nunchanged')
const bad = artifact('corrupt target')
const artifacts = new Map([before, after, bad].map(value => [value.sha256, value]))
function ref({ sha256, bytes, mime }) { return { _blob: { sha256, bytes, mime, preview: '' } } }
function receipt(path, edit_snapshots) {
  return { ts: 1, keeper: 'preview-writer', tool: 'Edit', success: true, duration_ms: 3,
    execution_id: `execution:${path}`, tool_call_id: 'provider-reused-id',
    input: {}, route_evidence: { descriptor_id: 'agent.edit_file' },
    output: JSON.stringify({ ok: true, mode: 'patch', path, occurrences: 1, edit_snapshots }) }
}
const fixtures = [
  receipt('essay.ml', { status: 'stored', before: ref(before), after: ref(after) }),
  receipt('unavailable.ml', { status: 'unavailable', detail: 'scenario: storage unavailable' }),
  receipt('corrupt.ml', { status: 'stored', before: ref(before), after: ref(bad) }),
]
const requests = []
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.woff2': 'font/woff2' }
const server = createServer((request, response) => {
  const path = new URL(request.url, 'http://localhost').pathname
  requests.push({ method: request.method, path })
  const json = value => { response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify(value)) }
  if (request.method !== 'GET') { response.writeHead(405).end(); return }
  if (path === '/preview-fixture/edit-receipts') { json(fixtures); return }
  if (path.startsWith('/api/v1/artifacts/')) {
    const value = artifacts.get(path.slice('/api/v1/artifacts/'.length))
    if (!value) { response.writeHead(404).end(); return }
    json(value === bad ? { ...bad, content: 'altered payload' } : value); return
  }
  const body = assets.get(path)
  if (!body) { response.writeHead(404).end(); return }
  response.setHeader('Content-Type', mime[extname(path)] ?? 'application/octet-stream')
  response.end(body)
})
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
await mkdir(output, { recursive: true })
const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, serviceWorkers: 'block' })
  const errors = []
  const workers = []
  page.on('pageerror', error => errors.push(error.message))
  page.on('worker', worker => workers.push(worker.url()))
  await page.goto(`http://127.0.0.1:${server.address().port}/dashboard/dev-fixtures/chat-edit-snapshots.html`)
  const normal = page.locator('[data-scenario="0"]')
  await normal.getByRole('button', { name: '편집 전후 원본 보기', exact: true }).click()
  const diff = normal.getByLabel('편집 원본의 Unified diff')
  await diff.waitFor()
  assert.equal(await diff.textContent(),
    '===================================================================\n'
    + '--- before\n+++ after\n@@ -1,2 +1,2 @@\n'
    + '-\tlet answer = 20\r\n-unchanged\r\n'
    + '+\tlet answer = 21\r\n+unchanged\n'
    + '\\ No newline at end of file\n')
  assert.equal(await normal.getByLabel('편집 전 전체 원본').textContent(), before.content)
  assert.equal(await normal.getByLabel('편집 후 전체 원본').textContent(), after.content)
  await diff.focus()
  assert.equal(await diff.evaluate(element => document.activeElement === element), true)
  assert.ok(await page.locator('[data-scenario="1"]').textContent().then(text => text.includes('scenario: storage unavailable')))
  await page.locator('[data-scenario="2"]').getByRole('button', { name: '편집 전후 원본 보기', exact: true }).click()
  await page.locator('[data-scenario="2"]').getByRole('alert').waitFor()
  assert.equal(await page.locator('[data-scenario="2"] pre').count(), 0)
  await page.screenshot({ path: resolve(output, 'desktop.png'), fullPage: true })
  await page.setViewportSize({ width: 390, height: 844 })
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false)
  await page.screenshot({ path: resolve(output, 'mobile.png'), fullPage: true })
  assert.ok(workers.length > 0, 'Actual browser worker must run')
  assert.deepEqual(errors, [])
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify({ observed_at: new Date().toISOString(),
    manifest, requests, workers, errors, deployment: false,
    scope: 'CI-built full ChatTranscript, canonical execution join and actual worker; synthetic receipts and artifact HTTP responses' }, null, 2) + '\n')
  console.log(JSON.stringify({ evidence: output, workers: workers.length, scenarios: 3 }))
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)) }
