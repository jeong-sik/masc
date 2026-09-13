// Run with the dashboard's installed Playwright, a downloaded CI preview,
// and a live backend with write methods/WebSockets blocked. No local compilation.
import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { resolve, relative, extname, sep } from 'node:path'
import assert from 'node:assert/strict'
const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const [previewArgument, expectedHead, baseUrl, outputArgument, tokenFile, expectedToolFile] = process.argv.slice(2)
if (!previewArgument || !expectedHead || !baseUrl || !outputArgument) {
  throw new Error('Usage: node scripts/verify-collaboration-tools-live-preview.mjs PREVIEW_DIR PR_HEAD BACKEND_URL EVIDENCE_DIR TOKEN_FILE EXPECTED_TOOL_JSON')
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
// Declared with the rest. It used to be read from argv[7], one slot past the
// last documented argument, so the advertised usage always failed here and
// the optional TOKEN_FILE could not actually be omitted.
assert.ok(expectedToolFile, 'EXPECTED_TOOL_JSON is required')
const expectedTool = JSON.parse(await readFile(expectedToolFile, 'utf8')).tool
const browser = await chromium.launch({ headless: true })
const blocked = [], errors = []
let toolsResponse = null
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1100 }, serviceWorkers: 'block', permissions: ['clipboard-read', 'clipboard-write'] })
  await page.routeWebSocket('**/*', socket => socket.close())
  page.on('pageerror', error => errors.push(error.message))
  page.on('console', message => { if (message.type() === 'error' && message.text().includes('ErrorBoundary')) errors.push(message.text()) })
  await page.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url())
    if (!['GET', 'HEAD'].includes(request.method()) || url.origin !== new URL(baseUrl).origin) {
      blocked.push({ method: request.method(), path: url.pathname }); return route.abort()
    }
    if (url.pathname.startsWith('/dashboard/')) {
      const name = decodeURIComponent(url.pathname.slice('/dashboard/'.length)) || 'index.html'
      assert.ok(Object.hasOwn(manifest.files, name), `Unmanifested asset: ${name}`)
      return route.fulfill({ body: await readFile(resolve(root, name)), contentType: mime[extname(name)] ?? 'application/octet-stream' })
    }
    const response = await route.fetch({ headers: { ...request.headers(), ...(token ? { Authorization: `Bearer ${token}` } : {}) } })
    if (url.pathname === '/api/v1/dashboard/tools') {
      assert.equal(response.status(), 200)
      toolsResponse = await response.json()
    }
    return route.fulfill({ response })
  })
  await page.goto(new URL('/dashboard/#lab?section=tools', baseUrl).href)
  await page.getByText('경로 없음', { exact: true }).waitFor({ timeout: 45000 })
  assert.equal(toolsResponse.runtime_resolution.server_repo_path.path, null)
  assert.equal(await page.getByRole('button', { name: 'server repo 경로 복사', exact: true }).count(), 0)
  await page.getByRole('button', { name: 'data root 경로 복사', exact: true }).click()
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), toolsResponse.runtime_resolution.data_root.path)
  const actualTool = toolsResponse.tool_inventory.tools.find(item => item.name === expectedTool.name)
  assert.equal(actualTool.description, expectedTool.description)
  await page.getByRole('textbox', { name: '도구 인벤토리 검색' }).fill(actualTool.name)
  const toggle = page.getByRole('button', { name: `${actualTool.name} 설명 펼치기`, exact: true })
  await toggle.focus(); await page.keyboard.press('Enter')
  const expanded = page.getByRole('button', { name: `${actualTool.name} 설명 접기`, exact: true })
  assert.equal(await expanded.getAttribute('aria-expanded'), 'true')
  const id = await expanded.getAttribute('aria-controls')
  const description = page.locator(`[id="${id}"]`)
  assert.equal(await description.textContent(), actualTool.description)
  const card = expanded.locator('xpath=ancestor::article')
  await card.scrollIntoViewIfNeeded()
  await page.screenshot({ path: resolve(output, 'tools-desktop.png') })
  await expanded.focus(); await page.keyboard.press('Space')
  assert.equal(await toggle.getAttribute('aria-expanded'), 'false')
  await page.setViewportSize({ width: 390, height: 844 })
  await toggle.click(); await expanded.waitFor({ state: 'visible' }); await card.scrollIntoViewIfNeeded()
  const geometry = await card.evaluate(element => {
    const bounds = element.getBoundingClientRect()
    return { x: bounds.x, right: bounds.right, width: bounds.width, height: bounds.height, viewportWidth: innerWidth }
  })
  assert.ok(geometry.x >= 0 && geometry.right <= geometry.viewportWidth, 'Card must fit mobile width')
  const overflow = await description.evaluate(element => {
    const style = getComputedStyle(element), rect = element.getBoundingClientRect()
    return { scroll: element.scrollHeight, client: element.clientHeight, height: rect.height, overflowY: style.overflowY, lineClamp: style.webkitLineClamp, whiteSpace: style.whiteSpace, text: element.textContent }
  })
  await page.screenshot({ path: resolve(output, 'tools-mobile.png') })
  await writeFile(resolve(output, 'mobile-measurement.json'), JSON.stringify({ geometry, overflow, expanded: await expanded.getAttribute('aria-expanded') }, null, 2) + '\n')
  assert.equal(overflow.lineClamp, 'none', 'Expanded description must not be line-clamped')
  assert.ok(overflow.overflowY === 'visible' || overflow.scroll <= overflow.client, 'Full text must not be vertically clipped')
  assert.deepEqual(errors, [])
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify({ observed_at: new Date().toISOString(), manifest, backend_build: health.build, actual_tool: actualTool, runtime_paths: toolsResponse.runtime_resolution, checks: ['actual_backend_full_canonical_description', 'null_repo_path_no_copy', 'exact_data_root_clipboard', 'keyboard_expand_collapse', 'mobile_click_and_card_bounds', 'full_text_no_vertical_clip'], geometry, overflow, errors, blocked, scope: 'Real authenticated API responses through a CI preview, no fixture responses and no production UI deployment' }, null, 2) + '\n')
  console.log(JSON.stringify({ output, tool: actualTool.name, errors }))
} finally { await browser.close() }
