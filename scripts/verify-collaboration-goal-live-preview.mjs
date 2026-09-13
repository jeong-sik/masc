// Run with the dashboard's installed Playwright, a downloaded CI preview,
// and a live backend with write methods/WebSockets blocked. No local compilation.
import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { resolve, relative, extname, sep } from 'node:path'
import assert from 'node:assert/strict'
const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const [previewArgument, expectedHead, baseUrl, outputArgument, tokenFile, goalState] = process.argv.slice(2)
if (!previewArgument || !expectedHead || !baseUrl || !outputArgument) {
  throw new Error('Usage: node scripts/verify-collaboration-goal-live-preview.mjs PREVIEW_DIR PR_HEAD BACKEND_URL EVIDENCE_DIR TOKEN_FILE GOAL_STATE\nGOAL_STATE is refuted or awaiting_confirmation')
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
// A run owns a fresh directory; old screenshots cannot accompany a new
// failure. verify-collaboration-installed-ui.mjs already requires this.
await mkdir(output)
const health = await (await fetch(new URL('/health?full=1', baseUrl))).json()
assert.equal(health.build.commit, expectedHead)
const browser = await chromium.launch({ headless: true })
const blocked = [], errors = [], responses = []
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1100 }, serviceWorkers: 'block' })
  await page.routeWebSocket('**/*', socket => socket.close())
  page.on('pageerror', error => errors.push(error.message))
  await page.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url())
    if (!['GET', 'HEAD'].includes(request.method())) {
      blocked.push({ method: request.method(), path: url.pathname }); return route.abort()
    }
    if (url.origin !== new URL(baseUrl).origin) return route.abort()
    if (url.pathname.startsWith('/dashboard/')) {
      const name = decodeURIComponent(url.pathname.slice('/dashboard/'.length)) || 'index.html'
      assert.ok(Object.hasOwn(manifest.files, name), `Unmanifested asset: ${name}`)
      return route.fulfill({ body: await readFile(resolve(root, name)), contentType: mime[extname(name)] ?? 'application/octet-stream' })
    }
    const response = await route.fetch({ headers: { ...request.headers(), ...(token ? { Authorization: `Bearer ${token}` } : {}) } })
    if (url.pathname.includes('/goals')) {
      const body = await response.text()
      responses.push({ path: url.pathname, query: url.search, status: response.status(), body })
    }
    return route.fulfill({ response })
  })
  await page.goto(new URL('/dashboard/#workspace?section=planning&goal=exhibition-publication-baseline', baseUrl).href)
  await page.getByText('가상 전시 출판물 완성', { exact: true }).first().waitFor({ timeout: 45000 })
  // Declared, not read off an undocumented argv slot: every invocation that
  // followed the usage line selected the refuted branch, then waited 45s for a
  // verdict the page was never going to draw.
  assert.ok(['refuted', 'awaiting_confirmation'].includes(goalState),
    `GOAL_STATE must be refuted or awaiting_confirmation, got ${goalState}`)
  const awaitingConfirmation = goalState === 'awaiting_confirmation'
  const verdict = awaitingConfirmation
    ? page.getByRole('button', { name: '이 증명으로 목표 완료 확인', exact: true })
    : page.getByText('검증 · 반증됨', { exact: true })
  await verdict.waitFor({ timeout: 45000 })
  await verdict.scrollIntoViewIfNeeded()
  if (awaitingConfirmation) {
    const panel = page.getByTestId('goal-confirmation-panel')
    assert.ok((await panel.innerText()).includes('5/5'))
    assert.ok((await panel.innerText()).includes('c36f5a9061458b3efbeb8cbb2cacfc6b'))
  } else {
    assert.ok((await page.locator('body').innerText()).includes('lookup_output_invalid_utf8'))
    assert.equal(await page.getByRole('button', { name: '이 증명으로 목표 완료 확인', exact: true }).count(), 0)
  }
  await page.screenshot({ path: resolve(output, 'goal-desktop.png'), fullPage: true })
  await writeFile(resolve(output, 'page-text.txt'), await page.locator('body').innerText())
  await page.setViewportSize({ width: 390, height: 844 })
  await verdict.scrollIntoViewIfNeeded()
  await page.screenshot({ path: resolve(output, 'goal-mobile.png'), fullPage: true })
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify({ observed_at: new Date().toISOString(), manifest, health: { build: health.build, startup_phase: health.startup.phase }, responses, blocked_mutations: blocked, page_errors: errors, scope: `CI preview identified by PR head; checkout commit may be GitHub merge commit. ${token ? 'Actual authenticated backend GETs' : 'Actual backend GETs with no Authorization header'}; no synthetic domain responses or production UI deployment.` }, null, 2) + '\n')
  // After the receipt, not before it: a run that raised a pageerror is exactly
  // the run whose evidence is worth keeping. verify-collaboration-tools-live-preview.mjs
  // and verify-collaboration-installed-ui.mjs both refuse a frame the page threw under;
  // this one collected the errors and then passed anyway.
  assert.deepEqual(errors, [])
  console.log(JSON.stringify({ output, response_count: responses.length, errors }))
} finally { await browser.close() }
