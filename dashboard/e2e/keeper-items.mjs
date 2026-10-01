import { chromium } from 'playwright'
import { createHash } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'

const fixtureUrl = process.env.KEEPER_ITEMS_FIXTURE_URL
if (!fixtureUrl) throw new Error('KEEPER_ITEMS_FIXTURE_URL is required')
const artifactDir = process.env.KEEPER_ITEMS_ARTIFACT_DIR ?? '/tmp'
await mkdir(artifactDir, { recursive: true })
const catalog = Object.entries({
  face: ['glasses', 'shades', 'eye_patch', 'plaster', 'freckles', 'beard'],
  neck: ['scarf', 'bow_tie', 'medal'],
  head: ['bow', 'crown', 'beanie'],
  hand: ['book', 'mug', 'quill'],
  base: ['dish_gilt', 'dish_silver', 'dish_oak'],
}).flatMap(([slot, ids]) => ids.map(id => ({
  id, slot, price_status: ['crown', 'glasses'].includes(id) ? 'priced' : 'unpriced',
  ...(id === 'crown' ? { price_milli: '200' } : id === 'glasses' ? { price_milli: '0' } : {}),
})))

const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
  const errors = []
  page.on('pageerror', error => errors.push(error.message))
  let account = { status: 'ready', keeper: 'rondo', balance_milli: '800', owned_items: ['crown'], catalog }
  let failed = false
  let releaseResponse = null
  const requests = []
  const captures = []
  const portraitRequests = []
  let holdObservedPortrait = false
  let releaseObservedPortrait = null
  await page.route('**/api/v1/keepers/rondo/items', async route => {
    const status = failed ? 503 : 200
    const body = JSON.stringify(failed ? { error: 'fixture ledger unreadable' } : account)
    requests.push({ failed, owned_items: [...account.owned_items] })
    if (releaseResponse) await releaseResponse
    await route.fulfill({
      status, contentType: 'application/json', body,
    })
  })
  async function capture(name) {
    const path = `${artifactDir}/${name}.png`
    await page.screenshot({ path, fullPage: true })
    captures.push({ name, sha256: createHash('sha256').update(await readFile(path)).digest('hex') })
  }
  await page.route('**/api/v1/keepers/*/portrait.png?*', async route => {
    const url = new URL(route.request().url())
    const request = { keeper: decodeURIComponent(url.pathname.split('/')[4]), size: url.searchParams.get('size'), preview: url.searchParams.get('preview') }
    portraitRequests.push(request)
    if (request.keeper !== 'rondo' || request.size !== '224'
      || (request.preview !== null && request.preview !== 'beanie')) {
      throw new Error(`unexpected portrait request: ${JSON.stringify(request)}`)
    }
    if (holdObservedPortrait && request.preview === null) {
      await new Promise(resolve => { releaseObservedPortrait = resolve })
    }
    await route.fulfill({ status: 503 })
  })
  await page.goto(fixtureUrl)
  await page.getByText('0.800 Candle').waitFor()
  if (await page.getByText('착용 중').count() !== 1) throw new Error('equipped marker missing')
  if (await page.getByText('가격 미설정').count() !== 16) throw new Error('unpriced catalog missing')
  if (errors.length > 0) throw new Error(`browser errors: ${errors.join(' | ')}`)
  await capture('keeper-items-desktop')
  // Preview is a separate picture request. Its failure must remain explicit,
  // and restoring the observed outfit must preserve the account observation.
  const previewRequestStart = portraitRequests.length
  await page.getByRole('button', { name: 'beanie 미리보기', exact: true }).click()
  await page.getByRole('alert').filter({ hasText: '미리보기 그림을 불러오지 못했습니다' }).waitFor()
  await page.getByText('미리보기 · beanie', { exact: true }).waitFor()
  await page.getByText('0.800 Candle', { exact: true }).waitFor()
  await page.getByText('보유 1 / 18개', { exact: true }).waitFor()
  if (!portraitRequests.slice(previewRequestStart).some(request => request.preview === 'beanie')) {
    throw new Error('selected beanie preview was not sent to the portrait endpoint')
  }
  await capture('keeper-items-preview-unavailable')
  const restoreRequestStart = portraitRequests.length
  holdObservedPortrait = true
  await page.getByRole('button', { name: '현재 착용 보기', exact: true }).click()
  await page.getByText('현재 착용 모습', { exact: true }).waitFor()
  if (await page.getByRole('alert').count()) throw new Error('restoring the observed outfit retained preview failure')
  if (await page.getByText('미리보기 · beanie', { exact: true }).count()) throw new Error('restoring the observed outfit retained selection')
  await page.getByText('보유 1 / 18개', { exact: true }).waitFor()
  await page.getByTestId('keeper-portrait-loading').waitFor()
  // The status label changes synchronously; the held network response must
  // still leave the portrait loading and cannot already show its fallback.
  const restoreDeadline = Date.now() + 10_000
  while (releaseObservedPortrait === null) {
    if (Date.now() >= restoreDeadline) throw new Error('observed portrait request did not arrive')
    await new Promise(resolve => setTimeout(resolve, 10))
  }
  if (await page.locator('[aria-label="rondo"]').count()) throw new Error('restore settled before its held response')
  if (!portraitRequests.slice(restoreRequestStart).some(request => request.preview === null)) {
    throw new Error('restoring equipment did not remove the preview query')
  }
  releaseObservedPortrait()
  holdObservedPortrait = false
  await page.getByTestId('keeper-portrait-loading').waitFor({ state: 'detached' })
  await page.locator('[aria-label="rondo"]').waitFor()
  await capture('keeper-items-preview-restored')
  await page.setViewportSize({ width: 360, height: 844 })
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)
  if (overflow > 1) throw new Error(`Item tab overflows 360px viewport by ${overflow}px`)
  await capture('keeper-items-mobile')
  await page.setViewportSize({ width: 1280, height: 900 })

  // A free purchase changes ownership, with the wallet and outfit fixed.
  account = { ...account, owned_items: ['crown', 'glasses'] }
  let release
  releaseResponse = new Promise(resolve => { release = resolve })
  await page.evaluate(() => window.updateKeeperItemsFixture('a'.repeat(64)))
  await page.getByRole('status').filter({ hasText: 'Item 계정 불러오는 중' }).waitFor()
  if (await page.getByText('0.800 Candle').count()) throw new Error('stale account visible while reloading')
  await capture('keeper-items-loading')
  release()
  releaseResponse = null
  await page.getByText('보유 2 / 18개').waitFor()
  await page.getByText('0.800 Candle').waitFor()
  await capture('keeper-items-free-purchase')

  // A price-only observation also refreshes an already open Item tab.
  account = { ...account, catalog: catalog.map(item => item.id === 'crown'
    ? { ...item, price_milli: '300' } : item) }
  await page.evaluate(() => window.updateKeeperItemsFixture('b'.repeat(64)))
  await page.getByText('0.300 Candle').waitFor()
  await capture('keeper-items-price-change')

  failed = true
  await page.getByRole('button', { name: '새로고침', exact: true }).click()
  await page.getByRole('alert').waitFor()
  const failureText = await page.getByRole('alert').textContent()
  if (!failureText?.includes('fixture ledger unreadable') || failureText.includes('/api/')) {
    throw new Error('Item error must show the server reason without an internal endpoint')
  }
  if (await page.getByText('0.800 Candle').count()) throw new Error('failed refresh retained balance')
  await capture('keeper-items-unavailable')
  failed = false
  await page.getByRole('button', { name: '새로고침', exact: true }).click()
  await page.getByText('보유 2 / 18개').waitFor()
  if (await page.getByRole('alert').count()) throw new Error('recovery retained error')
  await capture('keeper-items-recovered')
  if (requests.length !== 5) throw new Error(`expected five account reads, got ${requests.length}`)
  if (errors.length) throw new Error(`browser errors: ${errors.join(' | ')}`)
  await writeFile(`${artifactDir}/manifest.json`, JSON.stringify({
    scope: 'production Item component in a controlled browser fixture; synthetic account and roster revisions',
    source_sha: process.env.GITHUB_SHA ?? null, browser_version: browser.version(),
    requests, portrait_requests: portraitRequests, restoration: 'held observed request released and settled to intended badge fallback', captures, errors,
  }, null, 2) + '\n')
  process.stdout.write(`Item tab browser evidence: PASS (${captures.length} screens, ${requests.length} account reads)\n`)
} finally {
  await browser.close()
}
