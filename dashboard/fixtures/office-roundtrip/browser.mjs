// Run from dashboard: node --import tsx fixtures/office-roundtrip/browser.mjs
import assert from 'node:assert/strict'
import { readFile, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright'
import { createServer } from 'vite'
import { artifactDirectory } from '../artifact-output.mjs'
import { importArtifactDocx } from '../../src/lib/artifact-docx-import.ts'
import { importArtifactHwpx } from '../../src/lib/artifact-hwpx-import.ts'

const out = await artifactDirectory(import.meta.url)
process.env.MASC_DASHBOARD_PROXY_TARGET = 'http://127.0.0.1:1'
const server = await createServer({ root: fileURLToPath(new URL('../..', import.meta.url)),
  server: { host: '127.0.0.1', port: 0, watch: null } })
let browser
const observations = []
try {
  await server.listen()
  browser = await chromium.launch({ headless: true })
  const page = await browser.newPage({ viewport: { width: 1280, height: 960 }, acceptDownloads: true })
  const errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.context().tracing.start({ screenshots: true, snapshots: true })
  await page.goto(new URL('fixtures/office-roundtrip/', server.resolvedUrls.local[0]).href)
  const frame = page.frameLocator('iframe[title="문서 미리보기"]')
  await frame.locator('figure[data-masc-chart] svg').nth(3).waitFor()
  await page.screenshot({ path: out + 'initial.png', fullPage: true })
  const download = async (format, name) => {
    const button = page.getByRole('button', { name: format === 'docx' ? 'Word 파일 다운로드' : 'HWPX 파일 다운로드', exact: true })
    if (!await button.isVisible()) await page.getByText('Word·HWPX로 내보내기', { exact: true }).click()
    const pending = page.waitForEvent('download')
    await button.click()
    const file = await pending
    await file.saveAs(out + name)
    assert.equal(await file.failure(), null)
    assert.match(file.suggestedFilename(), new RegExp(`-v\\d+\\.${format}$`))
    return out + name
  }
  const originals = {}
  for (const format of ['docx', 'hwpx']) originals[format] = await download(format, `initial.${format}`)
  for (const format of ['docx', 'hwpx']) {
    await page.getByRole('button', { name: '파일 가져오기', exact: true }).click()
    await page.getByLabel('가져올 문서 파일').setInputFiles(originals[format])
    const source = page.getByLabel('문서 본문')
    await source.waitFor()
    const imported = await source.inputValue()
    assert.match(imported, /colspan="2"/)
    assert.equal((imported.match(/data-masc-chart=/g) ?? []).length, 4)
    assert.match(imported, /<td>12\.5<\/td>/)
    await source.fill(imported.replace('<td>12.5</td>', '<td>42</td>'))
    await page.getByRole('button', { name: '아티팩트 등록', exact: true }).click()
    await frame.locator('figure[data-masc-chart="column"] td').filter({ hasText: /^42$/ }).waitFor()
    const editedPath = await download(format, `edited.${format}`)
    const bytes = new Uint8Array(await readFile(editedPath))
    const edited = await (format === 'docx' ? importArtifactDocx : importArtifactHwpx)(bytes)
    assert.match(edited.content, /<td>42<\/td>/)
    assert.match(edited.content, /colspan="2"/)
    assert.equal((edited.content.match(/data-masc-chart=/g) ?? []).length, 4)
    observations.push({ format, bytes: bytes.length, mergedTable: true, charts: 4, editedValue: 42 })
    await page.screenshot({ path: out + `edited-${format}.png`, fullPage: true })
  }
  assert.deepEqual(errors, [])
  await page.context().tracing.stop({ path: out + 'trace.zip' })
  await writeFile(out + 'result.json', JSON.stringify({ status: 'passed', mode: 'isolated fixture with in-memory publication', observations }, null, 2))
} catch (error) {
  await writeFile(out + 'result.json', JSON.stringify({ status: 'failed', observations, error: String(error) }, null, 2))
  throw error
} finally {
  if (browser) await browser.close()
  await server.close()
}
