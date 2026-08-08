import { chromium } from 'playwright'

const fixtureUrl = process.env.KEEPER_QUEUED_STREAM_FIXTURE_URL
if (!fixtureUrl) throw new Error('KEEPER_QUEUED_STREAM_FIXTURE_URL is required')

const artifactDir = process.env.KEEPER_QUEUED_STREAM_ARTIFACT_DIR ?? '/tmp'
const queuedScreenshot = `${artifactDir}/keeper-queued-stream-queued.png`
const runningScreenshot = `${artifactDir}/keeper-queued-stream-running.png`
const succeededScreenshot = `${artifactDir}/keeper-queued-stream-succeeded.png`
const queuedText = 'sangsu가 다른 작업을 처리 중이에요. 메시지는 대기열에 추가했습니다.'

const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
  await page.goto(fixtureUrl)

  const composer = page.getByTestId('queued-stream-composer')
  await composer.fill('첫 번째 요청')
  await page.getByTestId('queued-stream-submit').click()
  await composer.fill('두 번째 요청')
  await page.getByTestId('queued-stream-submit').click()
  if (await page.getByText(queuedText, { exact: true }).count() !== 2) {
    throw new Error('two queued assistant bubbles were not rendered')
  }
  await page.screenshot({ path: queuedScreenshot, fullPage: true })

  await page.getByTestId('queued-stream-start').click()
  const traceToggle = page.locator('.chat-block-trace-hd').first()
  await traceToggle.waitFor()
  await traceToggle.click()
  await page.getByText('요청 내용을 검토하고 있습니다.', { exact: true }).waitFor()
  await page.getByText('keeper_context_status', { exact: true }).waitFor()
  if (await page.getByText(queuedText, { exact: true }).count() !== 1) {
    throw new Error('starting the first receipt mutated the second queued bubble')
  }
  await page.screenshot({ path: runningScreenshot, fullPage: true })

  await page.getByTestId('queued-stream-finish').click()
  await page.getByText(
    '대기 요청도 이제 같은 말풍선에서 실시간으로 답변합니다.',
    { exact: true },
  ).last().waitFor()
  if (await page.getByText(queuedText, { exact: true }).count() !== 1) {
    throw new Error('finishing the first receipt mutated the second queued bubble')
  }
  await page.screenshot({ path: succeededScreenshot, fullPage: true })

  process.stdout.write(`queued_screenshot=${queuedScreenshot}\n`)
  process.stdout.write(`running_screenshot=${runningScreenshot}\n`)
  process.stdout.write(`succeeded_screenshot=${succeededScreenshot}\n`)
} finally {
  await browser.close()
}
