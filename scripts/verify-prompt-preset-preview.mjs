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
  throw new Error('Usage: node scripts/verify-prompt-preset-preview.mjs PREVIEW_DIR PR_HEAD BACKEND_URL EVIDENCE_DIR')
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
    if (url.origin === new URL(baseUrl).origin && url.pathname.startsWith('/dashboard/')) {
      const name = decodeURIComponent(url.pathname.slice('/dashboard/'.length)) || 'index.html'
      assert.ok(Object.hasOwn(manifest.files, name), `Unmanifested asset: ${name}`)
      return route.fulfill({ body: await readFile(resolve(root, name)),
        contentType: mime[extname(name)] ?? 'application/octet-stream' })
    }
    return route.continue()
  })
  await page.goto(new URL('/dashboard/#settings?section=prompts', baseUrl).href)
  const panel = page.locator('[data-prompt-preset-content]')
  await panel.getByRole('button', { name: '프리셋 전체 원문 보기' }).click()
  const prompts = await page.evaluate(async () => (await (await fetch('/api/v1/prompts')).json()).prompts)
  await page.waitForFunction(count =>
    document.querySelectorAll('[data-prompt-preset-content] [data-preset-prompt]').length === count, prompts.length)
  for (const prompt of prompts) {
    const article = panel.locator('[data-preset-prompt]').filter({ has: page.getByRole('heading', { name: prompt.key, exact: true }) })
    if (prompt.source !== 'missing') {
      assert.equal(await article.locator('pre').textContent(), prompt.effective === '' ? '(빈 원문)' : prompt.effective)
    }
  }
  const selector = panel.getByRole('combobox', { name: '원문을 볼 프리셋' })
  const systemValue = await selector.locator('option').evaluateAll(options =>
    options.find(option => option.textContent.includes('System rules'))?.value)
  assert.ok(systemValue, 'System rules preset is missing')
  await selector.selectOption(systemValue)
  await page.waitForFunction(value =>
    document.querySelector('[data-prompt-preset-content]')?.getAttribute('data-active-preset') === value, systemValue)
  const selectedKeys = await panel.locator('[data-preset-prompt]').evaluateAll(elements =>
    elements.map(element => element.getAttribute('data-preset-prompt')))
  assert.deepEqual(selectedKeys, ['keeper'], 'System rules membership')
  const source = panel.locator('pre').first()
  await source.focus()
  assert.equal(await source.evaluate(element => element === document.activeElement), true)
  await panel.scrollIntoViewIfNeeded()
  await page.screenshot({ path: resolve(output, 'desktop.png') })
  await page.setViewportSize({ width: 390, height: 844 })
  await panel.scrollIntoViewIfNeeded()
  await page.screenshot({ path: resolve(output, 'mobile.png') })
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth), false, 'Mobile horizontal overflow')
  const receipt = { observed_at: new Date().toISOString(), manifest,
    prompts_compared: prompts.length, selected_preset: systemValue,
    backend: new URL(baseUrl).origin, blocked_mutations: mutations, blocked_websockets: blockedWebSockets,
    deployment: false, scope: 'CI-built frontend over read-only live backend' }
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n')
  console.log(JSON.stringify({ prompts_compared: prompts.length, selected_preset: systemValue, evidence: output }))
} finally { await browser.close() }
