import assert from 'node:assert/strict'
import { mkdir, writeFile } from 'node:fs/promises'
import { chromium } from 'playwright'

const origin = process.argv[2] ?? 'http://127.0.0.1:5197'
const evidence = process.argv[3] ?? '../docs/audits/godfiles-20261008/failure-output'
await mkdir(evidence, { recursive: true })
const browser = await chromium.launch({ headless: true })
try {
  const context = await browser.newContext({ viewport: { width: 1100, height: 900 }, permissions: ['clipboard-read', 'clipboard-write'] })
  const page = await context.newPage()
  const errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.goto(`${origin}/dashboard/e2e/failure-output.html`)
  const entry = page.locator('[data-chat-entry-id="failure-output-fixture"]')
  await entry.locator('[data-chat-retained-output]').waitFor({ state: 'visible' })
  assert.equal(await entry.getAttribute('data-chat-delivery-state'), 'request_failure')
  assert.equal(await entry.getAttribute('data-chat-role'), 'system')
  const bundle = page.locator('[data-chat-turn-bundle]')
  const work = bundle.locator('[data-chat-trace-step="think"]')
  assert.equal(await work.isVisible(), true)
  assert.match(await work.innerText(), /Completed work trace retained after failure/)
  assert.equal(await bundle.locator('[data-chat-trace-step="chat"]').count(), 0)
  assert.equal((await page.locator('body').innerText()).includes('provider disconnected after media'), false)
  await work.scrollIntoViewIfNeeded()
  await page.screenshot({ path: `${evidence}/work.png`, fullPage: true })
  const img = entry.locator('[data-chat-block="image"] img')
  assert.equal(await img.isVisible(), true)
  assert.equal(await img.evaluate(image => image.complete && image.naturalWidth > 0), true)
  const audio = entry.locator('[data-chat-block="voice"] audio')
  assert.equal(await audio.isVisible(), true)
  await audio.evaluate(async element => { element.load(); await element.play(); element.pause() })
  assert.equal(await audio.evaluate(element => element.error === null && element.duration === 1), true)
  assert.equal(await entry.locator('[data-chat-failure-detail]').count(), 0)
  await page.screenshot({ path: `${evidence}/collapsed.png`, fullPage: true })
  await page.locator('.chat-transcript').hover()
  await page.mouse.wheel(0, -1000)
  await page.waitForFunction(() => document.querySelector('.chat-transcript').scrollTop < 0)
  await page.screenshot({ path: `${evidence}/overview.png`, fullPage: true })
  await entry.locator('[data-chat-failure-detail-toggle]').click()
  assert.match(await entry.locator('[data-chat-failure-detail]').innerText(), /provider disconnected after media/)
  await entry.locator('[data-chat-failure-copy]').click()
  assert.equal(await page.evaluate(() => navigator.clipboard.readText()), 'Keeper request failed: provider disconnected after media')
  await page.screenshot({ path: `${evidence}/expanded.png`, fullPage: true })
  await entry.locator('[data-chat-failure-detail-toggle]').click()
  assert.equal(await entry.locator('[data-chat-failure-detail]').count(), 0)
  assert.equal(await img.isVisible(), true)
  assert.equal(await audio.isVisible(), true)
  assert.deepEqual(errors, [])
  const receipt = { scenario: 'persisted failure history after completed media', scope: 'local production ChatTranscript and REST normalization fixture', imageDecoded: true, audioPlayed: true, failureKept: true, retainedWorkVisible: true, failureQuotedAsChat: false, diagnosticsToggleAndCopy: true, pageErrors: errors, browser: browser.version() }
  await writeFile(`${evidence}/browser.json`, `${JSON.stringify(receipt, null, 2)}\n`)
  console.log(JSON.stringify(receipt))
} finally { await browser.close() }
