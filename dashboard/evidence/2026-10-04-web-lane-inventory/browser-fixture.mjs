import { chromium } from 'playwright'
import { createServer } from 'vite'
import assert from 'node:assert/strict'
import { readFile, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
const out = fileURLToPath(new URL('.', import.meta.url))
const server = await createServer({ server: { host: '127.0.0.1', port: 0 } })
await server.listen()
const browser = await chromium.launch({ headless: true })
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } })
const errors = [], unhandled = [], writes = []
let unavailable = false
const data = JSON.parse(await readFile(new URL('../../src/api/fixtures/lane-inventory.json', import.meta.url), 'utf8'))
data.rows.push({ id: 'declaration//fixture/lane-addons/demo.toml', label: 'demo.toml', purpose: 'Configured quality package',
  selection: { kind: 'declaration', source_path: '/fixture/lane-addons/demo.toml' },
  state: { kind: 'package', declaration: { kind: 'valid', enabled: false, installation_id: 'demo', run_id: 'world',
    package_id: 'quality', title: 'Quality report', desired_revision: 'inputs' }, instances: [{ instance_id: 'old-worker',
    incarnation: 'old-worker', run_id: 'world', package_id: 'quality', title: 'Quality report', package_revision: 'package-1',
    presence: 'retained', phase: { kind: 'failed', message: 'Cleanup unconfirmed' }, applied_revision: 'inputs' }] } })
data.package_read.complete = false
data.package_read.issues.push({ source_path: '/fixture/lane-addons/unreadable.toml', message: 'File could not be read' })
page.on('pageerror', error => errors.push(error.message))
await page.route('**/api/**', async route => {
  const request = route.request(), path = new URL(request.url()).pathname
  if (!path.startsWith('/api/')) return route.continue()
  if (request.method() !== 'GET') writes.push(path)
  if (path === '/api/v1/lanes') return route.fulfill({ status: unavailable ? 503 : 200,
    contentType: 'application/json', body: JSON.stringify(unavailable ? { error: 'inventory unavailable' } : data) })
  unhandled.push(path)
  return route.fulfill({ status: 500, contentType: 'application/json', body: '{"error":"unexpected route"}' })
})
try {
  await page.goto(`http://127.0.0.1:${server.httpServer.address().port}/dashboard/evidence/2026-10-04-web-lane-inventory/fixture.html`)
  await page.getByRole('button', { name: 'Inspect demo.toml', exact: true }).waitFor()
  assert.equal(await page.getByRole('button', { name: /^Inspect / }).count(), 13)
  assert.equal(await page.getByRole('link', { name: 'All Lanes', exact: true }).count(), 1)
  await page.getByRole('button', { name: 'Inspect demo.toml', exact: true }).click()
  const details = page.getByRole('region', { name: 'Details for demo.toml' })
  await details.getByText('Off requested · cleanup unconfirmed', { exact: true }).waitFor()
  await details.getByText('retained failed · old-worker · Cleanup unconfirmed', { exact: true }).waitFor()
  assert.equal(await details.evaluate(element => element.parentElement === document.activeElement), true)
  await page.screenshot({ path: out + 'all-lanes-desktop.png', fullPage: true })
  await page.getByRole('searchbox').fill('machine/dos')
  assert.equal(await page.getByRole('button', { name: /^Inspect / }).count(), 1)
  await page.getByRole('button', { name: /^Inspect / }).click()
  await page.getByText('Manage this machine through its TUI detail or operator tools.').waitFor()
  unavailable = true
  await page.getByRole('button', { name: 'Refresh Lanes' }).click()
  await page.getByText(/Showing the previous reading; current state is unverified/).waitFor()
  await page.setViewportSize({ width: 390, height: 844 })
  await page.screenshot({ path: out + 'stale-mobile.png', fullPage: true })
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth), false)
  assert.deepEqual(errors, []); assert.deepEqual(writes, []); assert.deepEqual(unhandled, [])
  await writeFile(out + 'browser-result.json', JSON.stringify({ passed: true, browser: await browser.version(),
    scope: 'Actual Status route, menu, component and decoder; synthetic HTTP. No native, worker or deployment proof.',
    assertions: ['menu route renders 12 builtin kinds and a package', 'off intent retains failed cleanup reading',
      'selected detail receives focus', 'search filters actual row identities', 'unavailable refresh labels previous reading',
      'mobile page has no horizontal overflow', 'zero writes and unexpected routes'], errors, writes, unhandled }, null, 2) + '\n')
  console.log('PASS: common Lane inventory browser fixture')
} catch (error) {
  await writeFile(out + 'browser-failure.json', JSON.stringify({ error: String(error), errors, writes, unhandled,
    body: await page.locator('body').innerText() }, null, 2) + '\n')
  throw error
} finally { await browser.close(); await server.close() }
