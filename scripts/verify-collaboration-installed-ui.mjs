// Observe the installed server's actual HTTP assets and Goal UI. No asset substitution.
import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { readFile, mkdir, writeFile, realpath } from 'node:fs/promises'
import { resolve, dirname } from 'node:path'
import assert from 'node:assert/strict'
const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const [prefix, expectedCommit, baseUrl, outputDirectory, tokenFile] = process.argv.slice(2)
assert.ok(prefix && expectedCommit && baseUrl && outputDirectory && tokenFile,
  'Usage: INSTALLED_PREFIX EXPECTED_COMMIT BASE_URL OUTPUT_DIR TOKEN_FILE')
const binary = await realpath(resolve(prefix, 'masc'))
const root = dirname(binary)
const release = JSON.parse(await readFile(resolve(root, 'release.json'), 'utf8'))
assert.equal(release.source_commit, expectedCommit)
assert.equal(createHash('sha256').update(await readFile(binary)).digest('hex'), release.binary_sha256)
const token = (await readFile(tokenFile, 'utf8')).trim()
const origin = new URL(baseUrl).origin
const healthResponse = await fetch(new URL('/health?full=1', baseUrl), {
  headers: { Authorization: `Bearer ${token}` },
})
assert.equal(healthResponse.status, 200)
const health = await healthResponse.json()
assert.equal(health.build.binary_commit, expectedCommit)
assert.equal(health.build.executable_sha256, release.binary_sha256)
assert.equal(await realpath(health.build.executable_path), binary)
const output = resolve(outputDirectory)
// A run owns a fresh directory; old screenshots cannot accompany a new failure.
await mkdir(output)
const assets = [], errors = [], failures = [], blocked = [], goalResponses = []
let probePassed = false, assertionFailure = null
const files = new Map(release.files.map(file => [file.path, file]))
const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1100 }, serviceWorkers: 'block' })
  await page.routeWebSocket('**/*', socket => socket.close())
  page.on('pageerror', error => errors.push(error.message))
  await page.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url())
    if (url.origin !== origin || !['GET', 'HEAD'].includes(request.method())) {
      blocked.push({ method: request.method(), path: url.pathname })
      return route.abort()
    }
    try {
      const response = await route.fetch({ headers: { ...request.headers(), Authorization: `Bearer ${token}` } })
      if (url.pathname.startsWith('/dashboard/')) {
        const name = decodeURIComponent(url.pathname.slice('/dashboard/'.length)) || 'index.html'
        const file = files.get(name)
        assert.ok(file, `Unmanifested server asset: ${name}`)
        assert.equal(response.status(), 200, name)
        const body = await response.body()
        const digest = createHash('sha256').update(body).digest('hex')
        assert.equal(digest, file.sha256, name)
        assets.push({ name, status: response.status(), sha256: digest, bytes: body.length })
      } else if (url.pathname.includes('/goals')) {
        goalResponses.push({ path: url.pathname, query: url.search, status: response.status(), body: await response.json() })
      }
      return route.fulfill({ response })
    } catch (error) {
      failures.push({ path: url.pathname, error: String(error) })
      await route.abort()
    }
  })
  await page.goto(new URL('/dashboard/#workspace?section=planning&goal=exhibition-publication-baseline', baseUrl).href)
  const panel = page.getByTestId('goal-confirmation-panel')
  await panel.waitFor({ timeout: 45000 })
  assert.ok((await panel.innerText()).includes('5/5'))
  assert.ok((await panel.innerText()).includes('c36f5a9061458b3efbeb8cbb2cacfc6b'))
  await page.getByRole('button', { name: '이 증명으로 목표 완료 확인', exact: true }).waitFor()
  const text = await page.locator('body').innerText()
  assert.ok(!text.includes('대시보드 아티팩트가 없거나 검증할 수 없습니다.'))
  await panel.scrollIntoViewIfNeeded()
  await page.screenshot({ path: resolve(output, 'goal-desktop.png'), fullPage: true })
  await writeFile(resolve(output, 'page-text.txt'), text)
  await page.setViewportSize({ width: 390, height: 844 })
  await panel.scrollIntoViewIfNeeded()
  await page.screenshot({ path: resolve(output, 'goal-mobile.png'), fullPage: true })
  assert.ok(assets.some(asset => asset.name === 'index.html'))
  assert.equal(failures.length, 0, JSON.stringify(failures))
  assert.equal(errors.length, 0, JSON.stringify(errors))
  probePassed = true
} catch (error) {
  assertionFailure = String(error)
  throw error
} finally {
  await browser.close()
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify({
    observed_at: new Date().toISOString(), source_commit: expectedCommit,
    probe_passed: probePassed, assertion_failure: assertionFailure,
    runtime_build: health.build, runtime_overall_status: health.overall_status,
    assets, goal_responses: goalResponses, errors, failures, blocked,
    scope: 'Actual installed server assets compared with paired release hashes; actual authenticated Goal GETs. Writes and WebSockets blocked. No human completion confirmation or full-dashboard health claim.',
  }, null, 2) + '\n')
}
console.log(JSON.stringify({ output, matched_assets: assets.length, errors, failures }))
