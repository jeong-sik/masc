import assert from 'node:assert/strict'
import { mkdir, writeFile, readFile } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { createRequire } from 'node:module'
const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const [origin, output] = process.argv.slice(2)
if (!origin || !output) throw new Error('Usage: node scripts/verify-workspace-curator-prompt-surface.mjs VITE_ORIGIN FRESH_OUTPUT')
await mkdir(output, { recursive: false })
const item = (key, effective, source = 'file') => ({
  key, category: key === 'keeper' ? 'keeper' : 'librarian', description: key,
  current: effective, effective, file_value: effective, override_value: source === 'override' ? effective : null,
  source, file_path: `fixture/config/prompts/${key}.md`, char_count: effective.length,
  required_file: true, template_variables: [],
})
const curator = item('workspace_memory_curator', 'Curate {{workspace_memory_inventory}} with attributed evidence.', 'override')
const librarian = item('librarian', 'Remember {{current_memory}} for this Keeper.')
let prompts = [curator, librarian, item('keeper', 'Shared Keeper instructions.')]
const errors = [], mutations = [], requests = []
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1360, height: 1000 }, serviceWorkers: 'block' })
page.on('pageerror', error => errors.push(error.stack ?? error.message))
try {
  await page.routeWebSocket('**/*', socket => socket.close())
  await page.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url())
    if (!['GET', 'HEAD'].includes(request.method())) {
      mutations.push({ method: request.method(), path: url.pathname })
      return route.abort()
    }
    if (url.origin !== new URL(origin).origin) return route.abort()
    if (url.pathname.startsWith('/api/v1/')) {
      requests.push(url.pathname)
      if (url.pathname === '/api/v1/prompts') return route.fulfill({ json: { prompts } })
      if (url.pathname === '/api/v1/auth/dev-token') return route.fulfill({ json: { token: 'fixture-only', role: 'admin' } })
      errors.push('Unexpected API: ' + url.pathname)
      return route.fulfill({ status: 404, json: { error: 'unexpected fixture request' } })
    }
    return route.continue()
  })
  await page.goto(new URL('/dashboard/dev-fixtures/workspace-curator-prompts.html', origin).href)
  const card = page.locator('[data-workspace-curator-runtime-contract]')
  const libraryCard = page.locator('[data-librarian-runtime-contract]')
  await card.getByText('workspace_memory_inventory', { exact: true }).waitFor()
  assert.ok((await libraryCard.innerText()).includes('fixture/config/prompts/librarian.md'))
  assert.ok(!(await libraryCard.innerText()).includes('workspace_memory_curator'))
  await libraryCard.getByRole('button').click()
  await page.waitForFunction(text => document.querySelector('textarea')?.value === text, librarian.effective)
  await card.getByRole('button', { name: '공유 메모리 프롬프트 열기' }).click()
  await page.waitForFunction(text => document.querySelector('textarea')?.value === text, curator.effective)
  await card.screenshot({ path: `${output}/desktop.png` })
  await page.setViewportSize({ width: 390, height: 844 })
  await card.screenshot({ path: `${output}/mobile.png` })
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false)
  prompts = [curator, item('keeper', 'Shared Keeper instructions.')]
  await page.reload()
  await libraryCard.getByText('librarian prompt 누락', { exact: true }).waitFor()
  assert.equal(await libraryCard.getByRole('button').count(), 0)
  assert.equal(await card.getByRole('button').count(), 1)
  assert.deepEqual(errors, [])
  assert.deepEqual(mutations, [])
  const source = await readFile(new URL('../dashboard/src/components/tools/prompt-registry-panel.ts', import.meta.url))
  await writeFile(`${output}/receipt.json`, JSON.stringify({
    status: 'passed', scope: 'source component in Chromium; synthetic HTTP data',
    source_sha256: createHash('sha256').update(source).digest('hex'),
    curator_first: true, exact_key_binding: true, original_opened: true,
    missing_librarian_not_substituted: true, mobile_overflow: false, mutations, errors, requests,
    installed_runtime: 'not_exercised', model_execution: 'not_exercised',
  }, null, 2) + '\n')
} catch (error) {
  await writeFile(`${output}/failure.json`, JSON.stringify({ error: String(error), errors, mutations,
    body: await page.locator('body').innerText() }, null, 2))
  throw error
} finally { await browser.close() }
