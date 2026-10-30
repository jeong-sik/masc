import assert from 'node:assert/strict'
import { mkdir, writeFile, readFile } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { createRequire } from 'node:module'
const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const [origin, output] = process.argv.slice(2)
if (!origin || !output) throw new Error('Usage: node scripts/verify-workspace-curator-prompt-refresh.mjs VITE_ORIGIN FRESH_OUTPUT')
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
const outcomes = ['queued', 'no_owner', 'unavailable']
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1360, height: 1000 }, serviceWorkers: 'block' })
page.on('pageerror', error => errors.push(error.stack ?? error.message))
try {
  await page.routeWebSocket('**/*', socket => socket.close())
  await page.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url())
    if (request.method() === 'POST' && url.origin === new URL(origin).origin && url.pathname === '/api/v1/prompts') {
      const body = request.postDataJSON()
      assert.equal(body.key, curator.key)
      const status = outcomes[mutations.length]
      assert.ok(status)
      mutations.push({ action: body.action, key: body.key, status })
      prompts = prompts.map(prompt => prompt.key === curator.key ? { ...prompt, source: body.action === 'clear' ? 'file' : 'override' } : prompt)
      return route.fulfill({ json: { ok: true, message: body.action === 'clear' ? 'override cleared' : 'override set', curator_refresh: { status, ...(status === 'unavailable' ? { detail: 'fixture workspace unavailable' } : {}) } } })
    }
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
  await page.getByRole('button', { name: '오버라이드 적용', exact: true }).click()
  await page.getByText('override set · workspace curator 재확인 요청됨. 실행 완료는 아직 확인되지 않았습니다.', { exact: true }).waitFor()
  await page.screenshot({ path: `${output}/queued-desktop.png`, fullPage: true })
  await page.getByRole('button', { name: '오버라이드 제거', exact: true }).click()
  await page.getByText('override cleared · 활성 workspace curator가 없어 재확인을 요청하지 못했습니다.', { exact: true }).waitFor()
  await page.setViewportSize({ width: 390, height: 844 })
  await page.screenshot({ path: `${output}/no-owner-mobile.png`, fullPage: true })
  await page.getByRole('button', { name: '오버라이드 적용', exact: true }).click()
  await page.getByText('override set · workspace curator 재확인 요청 실패: fixture workspace unavailable', { exact: true }).waitFor()
  await page.screenshot({ path: `${output}/unavailable-mobile.png`, fullPage: true })
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false)
  assert.deepEqual(errors, [])
  assert.deepEqual(mutations.map(row => row.status), outcomes)
  const source = await readFile(new URL('../dashboard/src/components/tools/prompt-registry-panel.ts', import.meta.url))
  await writeFile(`${output}/receipt.json`, JSON.stringify({
    status: 'passed', scope: 'source component in Chromium; synthetic HTTP data',
    source_sha256: createHash('sha256').update(source).digest('hex'),
    exact_key_binding: true, persisted_success_separated_from_refresh: true, mobile_overflow: false, mutations, errors, requests,
    installed_runtime: 'not_exercised', model_execution: 'not_exercised',
  }, null, 2) + '\n')
} catch (error) {
  await writeFile(`${output}/failure.json`, JSON.stringify({ error: String(error), errors, mutations,
    body: await page.locator('body').innerText() }, null, 2))
  throw error
} finally { await browser.close() }
