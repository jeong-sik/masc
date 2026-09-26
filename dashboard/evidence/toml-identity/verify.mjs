import { chromium } from 'playwright'
import { writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'

const base = process.argv[2]
if (!base) throw new Error('Pass the Vite dashboard base URL')
const artifact = name => fileURLToPath(new URL(name, import.meta.url))
const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 860 } })
  const errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.goto(new URL('evidence/toml-identity/preview.html', base).href)
  const field = page.getByLabel('p exact-body-timeout-s')
  await field.waitFor()
  if (await field.inputValue() !== '10') throw new Error('Initial deadline was not read')
  await page.screenshot({ path: artifact('before.png'), fullPage: true })
  await field.fill('15')
  await field.blur()
  await page.waitForFunction(() => window.fixtureSource.includes('= 15 # operator note'))
  const source = await page.evaluate(() => window.fixtureSource)
  if (source.includes('[providers.p]')) throw new Error('Duplicate table generated')
  if (errors.length) throw new Error(errors.join('\n'))
  await page.screenshot({ path: artifact('after.png'), fullPage: true })
  await writeFile(artifact('browser-result.json'), JSON.stringify({ source, initialDeadline: 10, editedDeadline: 15, errors }, null, 2))
  console.log('PASS: deadline 10 -> 15; quoted header and comment preserved; no duplicate table or page error')
} finally {
  await browser.close()
}
