import { chromium } from 'playwright'
import { createHash } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'

const fixtureUrl = process.env.KEEPER_ITEMS_FIXTURE_URL
if (!fixtureUrl) throw new Error('KEEPER_ITEMS_FIXTURE_URL is required')
const artifactDir = process.env.KEEPER_ITEMS_ARTIFACT_DIR ?? '/tmp'
await mkdir(artifactDir, { recursive: true })
const catalog = Object.entries({
  face: ['glasses', 'shades', 'eye_patch', 'plaster', 'freckles', 'beard'],
  neck: ['scarf', 'bow_tie', 'medal'], head: ['bow', 'crown', 'beanie'],
  hand: ['book', 'mug', 'quill'], base: ['dish_gilt', 'dish_silver', 'dish_oak'],
}).flatMap(([slot, ids]) => ids.map(id => ({
  id, slot, price_status: id === 'crown' ? 'priced' : 'unpriced',
  ...(id === 'crown' ? { price_milli: '200' } : {}),
})))
function account(owned, price) {
  return { status: 'ready', account_revision: 'a'.repeat(64), keeper: 'rondo', balance_milli: '800', owned_items: owned,
    catalog: catalog.map(item => item.id === 'crown' ? { ...item, price_milli: price } : item) }
}
function gate() {
  let release, started, finished
  return {
    release: () => release(),
    started: new Promise(resolve => { started = resolve }),
    finished: new Promise(resolve => { finished = resolve }),
    wait: new Promise(resolve => { release = resolve }),
    markStarted: () => started(), markFinished: () => finished(),
  }
}
const oldA = gate(), currentA = gate()
const replies = [
  { root: 'A', account: account(['crown'], '200') },
  { root: 'A-held', account: account(['crown', 'beanie', 'book'], '900'), gate: oldA },
  { root: 'B', account: account(['crown', 'beanie'], '300') },
  { root: 'A-current', account: account(['crown', 'beanie', 'book', 'mug'], '400'), gate: currentA },
]
const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
  const errors = [], requests = [], failures = [], captures = [], transitions = []
  page.on('pageerror', error => errors.push(error.message))
  page.on('requestfailed', request => {
    if (request.url().includes('/api/v1/keepers/rondo/items')) failures.push({
      url: request.url(), error: request.failure()?.errorText ?? null,
    })
  })
  await page.route('**/api/v1/keepers/rondo/items', async route => {
    const reply = replies[requests.length]
    if (!reply) { errors.push('Unexpected additional Item read'); await route.abort(); return }
    const receipt = { index: requests.length + 1, root: reply.root,
      owned_items: reply.account.owned_items, crown_price_milli: reply.account.catalog.find(item => item.id === 'crown').price_milli,
      outcome: 'held', transport_error: null }
    requests.push(receipt)
    reply.gate?.markStarted()
    if (reply.gate) await reply.gate.wait
    try {
      await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(reply.account) })
      receipt.outcome = 'fulfill-returned'
    } catch (error) {
      receipt.transport_error = error.message
      const failure = route.request().failure()?.errorText
      if (failure === 'net::ERR_ABORTED') receipt.outcome = 'aborted-before-release'
      else { receipt.outcome = 'unexpected-transport-error'; errors.push(error.message) }
    } finally { reply.gate?.markFinished() }
  })
  await page.route('**/api/v1/keepers/rondo/portrait.png?*', route => route.fulfill({ status: 503 }))
  async function absent(text) {
    if (await page.getByText(text, { exact: true }).count()) throw new Error(`Stale Item value visible: ${text}`)
  }
  async function capture(name, width = 1280, height = 900) {
    await page.setViewportSize({ width, height })
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)
    if (overflow > 1) throw new Error(`Item tab overflows ${width}px viewport by ${overflow}px`)
    const path = `${artifactDir}/keeper-items-workspace-${name}.png`
    await page.screenshot({ path, fullPage: true })
    captures.push({ name, width, height, sha256: createHash('sha256').update(await readFile(path)).digest('hex') })
  }
  async function workspace(root) {
    transitions.push({ root, request_count_before: requests.length })
    await page.evaluate(value => window.updateKeeperItemsWorkspaceFixture(value), root)
  }
  await page.goto(fixtureUrl)
  await page.getByText('보유 1 / 18개', { exact: true }).waitFor()
  await page.getByText('0.800 Candle', { exact: true }).waitFor()
  if (await page.getByText('착용 중', { exact: true }).count() !== 1) throw new Error('Fixed outfit marker missing')
  await capture('a-desktop')
  await capture('a-mobile', 360, 844)
  const heldRead = page.waitForRequest('**/api/v1/keepers/rondo/items')
  await page.getByRole('button', { name: '새로고침', exact: true }).click()
  await heldRead
  await oldA.started
  await page.getByText('Item 계정 불러오는 중…', { exact: true }).waitFor()
  await absent('보유 1 / 18개')
  await workspace('/fixture/keeper-items-b')
  await page.getByText('보유 2 / 18개', { exact: true }).waitFor()
  await page.getByText('0.300 Candle', { exact: true }).waitFor()
  await absent('0.200 Candle')
  await capture('b-desktop')
  await capture('b-mobile', 360, 844)
  const returningRead = page.waitForRequest('**/api/v1/keepers/rondo/items')
  await workspace('/fixture/keeper-items')
  await returningRead
  await currentA.started
  await page.getByText('Item 계정 불러오는 중…', { exact: true }).waitFor()
  await absent('보유 2 / 18개')
  await absent('0.300 Candle')
  // The browser can abort the transport before server release. Record that
  // outcome rather than claiming this forces an aborted JS promise to resolve.
  oldA.release()
  await oldA.finished
  await absent('보유 3 / 18개')
  await absent('0.900 Candle')
  await capture('a-return-loading')
  currentA.release()
  await currentA.finished
  await page.getByText('보유 4 / 18개', { exact: true }).waitFor()
  await page.getByText('0.400 Candle', { exact: true }).waitFor()
  await page.getByText('0.800 Candle', { exact: true }).waitFor()
  await absent('0.900 Candle')
  await capture('a-current-desktop')
  await capture('a-current-mobile', 360, 844)
  await workspace(null)
  await page.getByText('현재 작업 공간을 확인하는 중…', { exact: true }).waitFor()
  await absent('보유 4 / 18개')
  await absent('0.800 Candle')
  await capture('unknown-mobile', 360, 844)
  if (requests.length !== 4) throw new Error(`Expected four scoped account reads, got ${requests.length}`)
  if (errors.length) throw new Error(`Browser fixture errors: ${errors.join(' | ')}`)
  await writeFile(`${artifactDir}/workspace-manifest.json`, JSON.stringify({
    scope: 'Item component in a controlled workspace fixture; synthetic account responses, not production',
    source_sha: process.env.GITHUB_SHA ?? null, fixture_url: fixtureUrl, browser_version: browser.version(),
    fixed: { keeper: 'rondo', balance_milli: '800', head: 'crown', project: 'keeper-items-fixture' },
    transitions, requests, failures, captures, errors,
  }, null, 2) + '\n')
  process.stdout.write(`Item workspace browser fixture completed: ${captures.length} screenshots, ${requests.length} scoped reads\n`)
} finally { await browser.close() }
