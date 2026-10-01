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
  let account = { status: 'ready', account_revision: 'a'.repeat(64), keeper: 'rondo', balance_milli: '800', owned_items: ['crown'], catalog }
  let failed = false
  let releaseResponse = null
  const requests = []
  const captures = []
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
  await page.route('**/api/v1/keepers/rondo/portrait.png?*', route => route.fulfill({ status: 503 }))
  await page.goto(fixtureUrl)
  await page.getByText('0.800 Candle').waitFor()
  if (await page.getByText('착용 중').count() !== 1) throw new Error('equipped marker missing')
  if (await page.getByText('가격 미설정').count() !== 16) throw new Error('unpriced catalog missing')
  if (errors.length > 0) throw new Error(`browser errors: ${errors.join(' | ')}`)
  await capture('keeper-items-desktop')
  await page.setViewportSize({ width: 360, height: 844 })
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)
  if (overflow > 1) throw new Error(`Item tab overflows 360px viewport by ${overflow}px`)
  await capture('keeper-items-mobile')
  await page.setViewportSize({ width: 1280, height: 900 })

  // A free purchase changes ownership, with the wallet and outfit fixed.
  account = { ...account, account_revision: 'b'.repeat(64), owned_items: ['crown', 'glasses'] }
  let release
  releaseResponse = new Promise(resolve => { release = resolve })
  await page.evaluate(() => window.updateKeeperItemsFixture('b'.repeat(64)))
  await page.getByRole('status').filter({ hasText: 'Item 계정 불러오는 중' }).waitFor()
  if (await page.getByText('0.800 Candle').count()) throw new Error('stale account visible while reloading')
  await capture('keeper-items-loading')
  release()
  releaseResponse = null
  await page.getByText('보유 2 / 18개').waitFor()
  await page.getByText('0.800 Candle').waitFor()
  await capture('keeper-items-free-purchase')

  // A price-only observation also refreshes an already open Item tab.
  account = { ...account, account_revision: 'c'.repeat(64), catalog: catalog.map(item => item.id === 'crown'
    ? { ...item, price_milli: '300' } : item) }
  await page.evaluate(() => window.updateKeeperItemsFixture('c'.repeat(64)))
  await page.getByText('0.300 Candle').waitFor()
  await capture('keeper-items-price-change')

  failed = true
  await page.getByRole('button', { name: '새로고침', exact: true }).click()
  await page.getByRole('alert').waitFor()
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
    requests, captures, errors,
  }, null, 2) + '\n')
  process.stdout.write(`Item tab browser evidence: PASS (${captures.length} screens, ${requests.length} account reads)\n`)
} finally {
  await browser.close()
}
