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
let validationFailed = false
let successReceipt = null
const requests = []
const captures = []
const errors = []
let page = null
let stage = 'context'
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
  page = await context.newPage()
  page.on('pageerror', error => errors.push(error.message))
  page.on('response', response => {
    const url = new URL(response.url())
    if (url.origin === target.origin && url.pathname.startsWith('/api/')) {
      requests.push({ path: url.pathname, status: response.status() })
    }
  })
  stage = 'desktop-navigation'
  await page.goto(`${target.origin}/dashboard/#keepers?keeper=${encodeURIComponent(keeper)}`)
  // Keeper routes open the chat workspace; its detail action exposes the tabs.
  stage = 'desktop-detail-entry'
  await page.getByRole('button', { name: '대화 도구', exact: true }).click()
  await page.getByTestId('kw-chat-command-detail').click()
  await page.getByRole('tab', { name: '아이템', exact: true }).click()
  async function verifyPanel(requestStart) {
    const panel = page.getByRole('tabpanel', { name: '아이템', exact: true })
    await panel.getByText('현재 잔액', { exact: true }).locator('..')
      .getByText(balanceLabel, { exact: true }).waitFor()
    await panel.getByText('보유 1 / 18개', { exact: true }).waitFor()
    await panel.getByRole('listitem').filter({ has: page.getByText(ownedItem, { exact: true }) })
      .getByText('착용 중', { exact: true }).waitFor()
    await panel.locator('img').first().waitFor()
    await panel.locator('img').first().evaluate(image => image.decode())
    if (!requests.slice(requestStart).some(row => row.path === `/api/v1/keepers/${keeper}/items` && row.status === 200)) {
      throw new Error('Item account was not read from the real server for this entry')
    }
  }
  stage = 'desktop-item-account'
  await verifyPanel(0)
  async function verifyMobileLayout() {
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)
    if (overflow > 1) throw new Error(`served dashboard overflows 360px by ${overflow}px`)
    const widths = await page.locator('.kw-detail-alert-strip').evaluate(strip => ({
      alert: strip.getBoundingClientRect().width,
      body: strip.parentElement.getBoundingClientRect().width,
    }))
    if (widths.alert + 1 < widths.body) {
      throw new Error('Runtime alert is squeezed into the mobile navigation column')
    }
    await page.getByRole('tabpanel', { name: '아이템', exact: true }).scrollIntoViewIfNeeded()
  }
  async function capture(name) {
    const path = `${output}/${name}.png`
    await page.screenshot({ path, fullPage: true })
    captures.push({ name, sha256: createHash('sha256').update(await readFile(path)).digest('hex') })
  }
  await capture('item-server-desktop')
  stage = 'retained-detail-360px'
  await page.setViewportSize({ width: 360, height: 844 })
  await page.getByRole('tabpanel', { name: '아이템', exact: true })
    .getByText('보유 1 / 18개', { exact: true }).waitFor()
  await verifyMobileLayout()
  await capture('item-server-mobile')
  // Reload at the narrow viewport so entry uses the mobile command menu,
  // with fresh application state rather than a retained desktop detail.
  const mobileRequestStart = requests.length
  stage = 'fresh-document-mobile-entry'
  await page.reload()
  await page.getByRole('button', { name: 'keeper 명령', exact: true }).click()
  const menuUnclipped = await page.getByRole('menu').evaluate(menu => {
    const box = menu.getBoundingClientRect()
    return menu.contains(document.elementFromPoint(box.left + box.width / 2, box.bottom - 2))
  })
  if (!menuUnclipped) throw new Error('Mobile Keeper menu is clipped at its lower edge')
  await page.getByTestId('kw-chat-command-detail').click()
  await page.getByRole('tab', { name: '아이템', exact: true }).click()
  stage = 'fresh-document-mobile-item-account'
  await verifyPanel(mobileRequestStart)
  await verifyMobileLayout()
  await capture('item-server-mobile-entry')
  // Preserve the independently reachable composer command entry as well.
  const composerRequestStart = requests.length
  stage = 'fresh-document-mobile-composer-entry'
  await page.reload()
  await page.getByRole('textbox', { name: '메시지 입력', exact: true }).fill('/detail')
  const commands = page.getByRole('listbox', { name: 'keeper slash commands', exact: true })
  await commands.getByRole('option', { name: /\/detail\b/ }).click()
  await page.getByRole('tab', { name: '아이템', exact: true }).click()
  await verifyPanel(composerRequestStart)
  await verifyMobileLayout()
  await capture('item-server-mobile-composer-entry')
  stage = 'page-errors-and-receipt'
  if (errors.length) throw new Error(`served dashboard page errors: ${errors.join(' | ')}`)
  successReceipt = {
    scope: 'Production dashboard bundle served by isolated native CI server; authenticated real API and synthetic paused Keeper with real free purchase/equipment ledger; no provider/model decision or rollout',
    source_sha: sourceSha, keeper, owned_item: ownedItem, browser_version: browser.version(),
    entry_paths: ['desktop-overflow-detail-items', 'retained-detail-360px', 'fresh-document-mobile-menu-detail-items-360px', 'fresh-document-mobile-composer-detail-items-360px'],
    requests, captures, page_errors: errors, passed: true,
  }
} catch (error) {
  validationFailed = true
  // Keep failure evidence distinct from a PASS receipt. Never persist storage,
  // credentials, request headers/bodies, DOM dumps or raw error text.
  if (page && !page.isClosed()) {
    try {
      const name = 'item-server-failure'
      const path = `${output}/${name}.png`
      await page.screenshot({ path, fullPage: true, timeout: 5000 })
      captures.push({ name, sha256: createHash('sha256').update(await readFile(path)).digest('hex') })
    } catch {
      console.error('Item failure screenshot could not be retained')
    }
  }
  try {
    await writeFile(`${output}/browser-evidence.json`, JSON.stringify({
      scope: 'Failed isolated native-server dashboard acceptance; no PASS or rollout proof',
      source_sha: sourceSha, keeper, owned_item: ownedItem,
      browser_version: browser.version(), stage, requests, captures,
      page_error_count: errors.length, passed: false,
    }, null, 2) + '\n')
  } catch {
    console.error('Item failure receipt could not be retained')
  }
  throw error
} finally {
  try {
    await browser.close()
  } catch (error) {
    if (validationFailed) console.error('Item browser cleanup failed after validation failure')
    else throw error
  }
}
// Publish a success receipt only after browser cleanup also succeeded.
await writeFile(`${output}/browser-evidence.json`, JSON.stringify(successReceipt, null, 2) + '\n')
