// Real native server acceptance. Credentials arrive on stdin, never in argv/URL/artifacts.
import { chromium } from 'playwright'
import { createHash } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'

let input = ''
for await (const chunk of process.stdin) input += chunk
const { origin, token, output, sourceSha, keeper, ownedItem, balanceLabel } = JSON.parse(input)
input = ''
if (typeof balanceLabel !== 'string' || !balanceLabel) throw new Error('Missing expected wallet label')
const target = new URL(origin)
if (target.hostname !== '127.0.0.1' || target.protocol !== 'http:') {
  throw new Error('Item browser acceptance requires isolated loopback HTTP')
}
const browser = await chromium.launch({ headless: true })
const requests = []
const captures = []
const errors = []
try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } })
  await context.addInitScript(({ token, origin }) => {
    if (location.origin === origin) {
      sessionStorage.setItem('masc_bearer_token', token)
      sessionStorage.setItem('masc_bearer_token_meta', JSON.stringify({ source: 'manual' }))
    }
  }, { token, origin: target.origin })
  // Keep all requests inside the isolated server; every API response is real.
  await context.route('**/*', route => {
    const url = new URL(route.request().url())
    if (url.origin === target.origin && url.pathname === '/api/v1/dashboard/dev-token') {
      errors.push('bootstrap attempted to replace the supplied manual bearer')
      return route.abort('blockedbyclient')
    }
    if (url.origin === target.origin) return route.continue()
    return route.abort('blockedbyclient')
  })
  const page = await context.newPage()
  page.on('pageerror', error => errors.push(error.message))
  page.on('response', response => {
    const url = new URL(response.url())
    if (url.origin === target.origin && url.pathname.startsWith('/api/')) {
      requests.push({ path: url.pathname, status: response.status() })
    }
  })
  await page.goto(`${target.origin}/dashboard/#keepers?keeper=${encodeURIComponent(keeper)}`)
  // Keeper routes open the chat workspace; open details before selecting its tabs.
  await page.getByRole('button', { name: '대화 도구', exact: true }).click()
  await page.getByTestId('kw-chat-command-detail').click()
  await page.getByRole('tab', { name: '아이템', exact: true }).click()
  const panel = page.getByRole('tabpanel', { name: '아이템', exact: true })
  await panel.getByText('현재 잔액', { exact: true }).locator('..')
    .getByText(balanceLabel, { exact: true }).waitFor()
  await panel.getByText('보유 1 / 18개', { exact: true }).waitFor()
  await panel.getByRole('listitem').filter({ has: page.getByText(ownedItem, { exact: true }) })
    .getByText('착용 중', { exact: true }).waitFor()
  await panel.locator('img').first().waitFor()
  await panel.locator('img').first().evaluate(image => image.decode())
  if (!requests.some(row => row.path === `/api/v1/keepers/${keeper}/items` && row.status === 200)) {
    throw new Error('Item account was not read from the real server')
  }
  async function capture(name) {
    const path = `${output}/${name}.png`
    await page.screenshot({ path, fullPage: true })
    captures.push({ name, sha256: createHash('sha256').update(await readFile(path)).digest('hex') })
  }
  await capture('item-server-desktop')
  await page.setViewportSize({ width: 360, height: 844 })
  await panel.getByText('보유 1 / 18개', { exact: true }).waitFor()
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)
  if (overflow > 1) throw new Error(`served dashboard overflows 360px by ${overflow}px`)
  await capture('item-server-mobile')
  if (errors.length) throw new Error(`served dashboard page errors: ${errors.join(' | ')}`)
  await writeFile(`${output}/browser-evidence.json`, JSON.stringify({
    scope: 'Production dashboard bundle served by isolated native CI server; authenticated real API and synthetic paused Keeper with real free purchase/equipment ledger; no provider/model decision or rollout',
    source_sha: sourceSha, keeper, owned_item: ownedItem, browser_version: browser.version(),
    requests, captures, page_errors: errors, passed: true,
  }, null, 2) + '\n')
} finally {
  await browser.close()
}
