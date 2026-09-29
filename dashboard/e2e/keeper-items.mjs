import { chromium } from 'playwright'

const fixtureUrl = process.env.KEEPER_ITEMS_FIXTURE_URL
if (!fixtureUrl) throw new Error('KEEPER_ITEMS_FIXTURE_URL is required')
const artifactDir = process.env.KEEPER_ITEMS_ARTIFACT_DIR ?? '/tmp'
const catalog = Object.entries({
  face: ['glasses', 'shades', 'eye_patch', 'plaster', 'freckles', 'beard'],
  neck: ['scarf', 'bow_tie', 'medal'],
  head: ['bow', 'crown', 'beanie'],
  hand: ['book', 'mug', 'quill'],
  base: ['dish_gilt', 'dish_silver', 'dish_oak'],
}).flatMap(([slot, ids]) => ids.map(id => ({
  id, slot, price_status: id === 'crown' ? 'priced' : 'unpriced',
  ...(id === 'crown' ? { price_milli: '200' } : {}),
})))

const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
  const errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.route('**/api/v1/keepers/rondo/items', route => route.fulfill({
    status: 200, contentType: 'application/json',
    body: JSON.stringify({ status: 'ready', keeper: 'rondo', balance_milli: '800', owned_items: ['crown'], catalog }),
  }))
  await page.route('**/api/v1/keepers/rondo/portrait.png?*', route => route.fulfill({ status: 503 }))
  await page.goto(fixtureUrl)
  await page.getByText('0.800 Candle').waitFor()
  if (await page.getByText('착용 중').count() !== 1) throw new Error('equipped marker missing')
  if (await page.getByText('가격 미설정').count() !== 17) throw new Error('unpriced catalog missing')
  if (errors.length > 0) throw new Error(`browser errors: ${errors.join(' | ')}`)
  await page.screenshot({ path: `${artifactDir}/keeper-items-desktop.png`, fullPage: true })
  await page.setViewportSize({ width: 360, height: 844 })
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)
  if (overflow > 1) throw new Error(`Item tab overflows 360px viewport by ${overflow}px`)
  await page.screenshot({ path: `${artifactDir}/keeper-items-mobile.png`, fullPage: true })
  process.stdout.write(`Item tab browser evidence: ${artifactDir}/keeper-items-desktop.png, ${artifactDir}/keeper-items-mobile.png\n`)
} finally {
  await browser.close()
}
