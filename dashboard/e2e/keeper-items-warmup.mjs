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
}).flatMap(([slot, ids]) => ids.map(id => ({ id, slot, price_status: 'unpriced' })))
const errors = [], captures = [], executionReads = [], accountReads = []
let recovered = false
const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
  page.on('pageerror', error => errors.push(error.message))
  await page.route('**/api/v1/keepers/rondo/items', route => {
    accountReads.push({ recovered })
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify({
      status: 'ready', keeper: 'rondo', balance_milli: recovered ? '600' : '800',
      owned_items: recovered ? ['crown', 'beanie'] : ['crown'], catalog,
    }) })
  })
  await page.route('**/api/v1/keepers/rondo/portrait.png?*', route => route.fulfill({ status: 503 }))
  await page.route('**/api/v1/dashboard/execution', route => {
    executionReads.push({ recovered })
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify(recovered ? {
      execution_publication_epoch: 'keeper-items-browser-fixture', execution_publication_generation: 2,
      status: { workspace_root: '/fixture/keeper-items', project: 'keeper-items-fixture' },
    } : { status: { project: 'initializing' } }) })
  })
  async function capture(name) {
    const path = `${artifactDir}/${name}.png`
    await page.screenshot({ path, fullPage: true })
    captures.push({ name, sha256: createHash('sha256').update(await readFile(path)).digest('hex') })
  }
  await page.goto(fixtureUrl)
  await page.getByText('0.800 Candle', { exact: true }).waitFor()
  await page.getByRole('button', { name: 'beanie 미리보기', exact: true }).click()
  await page.getByText('미리보기 · beanie', { exact: true }).waitFor()
  await page.getByRole('alert').waitFor()
  await capture('item-preview-before-warmup')
  let warmUpRejected = false
  try {
    await page.evaluate(() => window.refreshKeeperItemsExecutionFixture())
  } catch (error) {
    if (!error?.message?.includes('Execution projection is initializing')) {
      throw error
    }
    warmUpRejected = true
  }
  if (!warmUpRejected) {
    throw new Error('expected warmup execution refresh to reject with initializing')
  }
  await page.getByText('현재 작업 공간을 확인하는 중…', { exact: true }).waitFor()
  for (const text of ['0.800 Candle', '미리보기 · beanie', '보유 1 / 18개']) {
    if (await page.getByText(text, { exact: true }).count()) throw new Error(`warm-up retained ${text}`)
  }
  if (await page.getByRole('alert').count()) throw new Error('warm-up retained old preview failure')
  await capture('item-workspace-warmup')
  recovered = true
  await page.evaluate(() => window.refreshKeeperItemsExecutionFixture())
  await page.getByText('0.600 Candle', { exact: true }).waitFor()
  await page.getByText('보유 2 / 18개', { exact: true }).waitFor()
  await page.getByText('현재 착용 모습', { exact: true }).waitFor()
  if (await page.getByText('미리보기 · beanie', { exact: true }).count()) throw new Error('workspace recovery revived old preview')
  if (await page.getByRole('alert').count()) throw new Error('workspace recovery retained old preview failure')
  await capture('item-workspace-recovered')
  if (errors.length) throw new Error(`browser errors: ${errors.join(' | ')}`)
  await writeFile(`${artifactDir}/warmup-manifest.json`, JSON.stringify({
    scope: 'real Chromium production Item component/store with synthetic HTTP accounts and execution warm-up; mocked PNG503',
    source_sha: process.env.GITHUB_SHA ?? null, browser_version: browser.version(),
    executionReads, accountReads, captures, errors,
  }, null, 2) + '\n')
  process.stdout.write('Item execution warm-up browser: PASS\n')
} finally {
  await browser.close()
}
