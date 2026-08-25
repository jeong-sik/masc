import { chromium } from 'playwright'

const fixtureUrl = process.env.KEEPER_QUEUED_STREAM_FIXTURE_URL
if (!fixtureUrl) throw new Error('KEEPER_QUEUED_STREAM_FIXTURE_URL is required')

const artifactDir = process.env.KEEPER_QUEUED_STREAM_ARTIFACT_DIR ?? '/tmp'
const queuedScreenshot = `${artifactDir}/keeper-queued-stream-queued.png`
const runningScreenshot = `${artifactDir}/keeper-queued-stream-running.png`
const succeededScreenshot = `${artifactDir}/keeper-queued-stream-succeeded.png`
const interruptedScreenshot = `${artifactDir}/keeper-queued-stream-interrupted.png`

async function submit(page, message) {
  const composer = page.getByLabel('메시지 입력')
  await composer.fill(message)
  await composer.press('Meta+Enter')
}

const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
  await page.goto(`${fixtureUrl}?reset=1`)

  await submit(page, '첫 번째 요청')
  await submit(page, '두 번째 요청')
  await page.getByTestId('fixture-operation-status').getByText('Queued 2', { exact: true }).waitFor()
  if (await page.getByText('Queued', { exact: true }).count() !== 2) {
    throw new Error('two durable Queued placeholders were not rendered')
  }
  await page.screenshot({ path: queuedScreenshot, fullPage: true })

  await page.locator('[data-open-keeper-operation-control]').click()
  const controlPanel = page.locator('[data-keeper-operation-control-panel]')
  const rows = controlPanel.locator('[data-operator-chat-operation]')
  await rows.nth(1).waitFor()

  page.once('dialog', dialog => dialog.accept('첫 번째 요청 수정'))
  await rows.nth(0).getByRole('button', { name: '수정', exact: true }).click()
  const editedRow = controlPanel
    .locator('[data-operator-chat-operation]')
    .filter({ hasText: '첫 번째 요청 수정' })
  await editedRow.waitFor()
  await editedRow.getByRole('button', { name: '맨 뒤로', exact: true }).click()
  await controlPanel.locator('[data-operator-chat-operation]').nth(1)
    .getByText('첫 번째 요청 수정', { exact: true }).waitFor()
  await controlPanel.locator('[data-operator-chat-operation]').nth(1)
    .getByRole('button', { name: '취소', exact: true }).click()
  await page.getByTestId('fixture-operation-status').getByText('Cancelled 1', { exact: true }).waitFor()
  await controlPanel.getByRole('button', { name: '닫기', exact: true }).click()

  await page.getByTestId('fixture-start-head').click()
  await page.getByTestId('fixture-operation-status').getByText('Running 1', { exact: true }).waitFor()
  const traceToggle = page.locator('.chat-block-trace-hd').first()
  await traceToggle.waitFor()
  await traceToggle.click()
  await page.getByText('요청 내용을 검토하고 있습니다.', { exact: true }).waitFor()
  await page.getByText('keeper_context_status', { exact: true }).waitFor()
  await page.screenshot({ path: runningScreenshot, fullPage: true })

  await page.getByTestId('fixture-finish-running').click()
  await page.getByText(
    '대기 요청도 이제 같은 말풍선에서 실시간으로 답변합니다.',
    { exact: true },
  ).last().waitFor()
  await page.getByTestId('fixture-operation-status').getByText('Succeeded 1', { exact: true }).waitFor()
  await page.screenshot({ path: succeededScreenshot, fullPage: true })

  await submit(page, '재시작으로 중단될 요청')
  await page.getByTestId('fixture-operation-status').getByText('Queued 1', { exact: true }).waitFor()
  await page.getByTestId('fixture-start-head').click()
  await page.getByTestId('fixture-operation-status').getByText('Running 1', { exact: true }).waitFor()
  await page.getByTestId('fixture-restart-running').click()
  await page.waitForLoadState('domcontentloaded')
  await page.getByTestId('fixture-operation-status').getByText('Interrupted 1', { exact: true }).waitFor()
  await page.getByText('Interrupted', { exact: true }).last().waitFor()
  await page.screenshot({ path: interruptedScreenshot, fullPage: true })

  process.stdout.write(`queued_screenshot=${queuedScreenshot}\n`)
  process.stdout.write(`running_screenshot=${runningScreenshot}\n`)
  process.stdout.write(`succeeded_screenshot=${succeededScreenshot}\n`)
  process.stdout.write(`interrupted_screenshot=${interruptedScreenshot}\n`)
} finally {
  await browser.close()
}
