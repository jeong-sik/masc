import { chromium } from 'playwright'

const fixtureUrl = process.env.KEEPER_LANE_TIMELINE_FIXTURE_URL
if (!fixtureUrl) throw new Error('KEEPER_LANE_TIMELINE_FIXTURE_URL is required')

const artifactDir = process.env.KEEPER_LANE_TIMELINE_ARTIFACT_DIR ?? '/tmp'
const desktopScreenshot = `${artifactDir}/keeper-lane-timeline-desktop.png`
const mobileScreenshot = `${artifactDir}/keeper-lane-timeline-mobile.png`

const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
  await page.goto(fixtureUrl)

  const graph = page.getByTestId('keeper-lane-graph')
  await graph.waitFor()
  const rows = page.getByTestId('keeper-lane-waiting-row')
  if (await rows.count() !== 3) throw new Error('the fixture did not render all queue rows')

  const firstRow = rows.first()
  const card = firstRow.locator(':scope > div').nth(1)
  const timestamp = page.getByTestId('keeper-lane-waiting-time').first()
  if (!(await card.locator('[data-testid="keeper-lane-waiting-time"]').count())) {
    throw new Error('the timestamp is not inside the widened queue card')
  }
  const rowBox = await firstRow.boundingBox()
  const cardBox = await card.boundingBox()
  if (!rowBox || !cardBox || cardBox.width / rowBox.width < 0.9) {
    throw new Error('the queue card did not receive the timeline width')
  }
  await timestamp.locator('time').waitFor()

  const evidence = firstRow.locator('details')
  await evidence.getByText('Typed queue evidence', { exact: true }).click()
  if (!(await evidence.evaluate((node) => node.open))) {
    throw new Error('the typed queue evidence disclosure did not open')
  }
  await evidence.getByText('external_attention_store', { exact: true }).waitFor()
  await page.screenshot({ path: desktopScreenshot, fullPage: true })

  for (const width of [390, 360, 320]) {
    await page.setViewportSize({ width, height: 844 })
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
    if (overflow > 1) throw new Error(`the page overflows the ${width}px viewport by ${overflow}px`)

    const internalOverflow = await graph.evaluate((node) => node.scrollWidth - node.clientWidth)
    if (internalOverflow > 1) {
      throw new Error(`the timeline overflows its graph at ${width}px by ${internalOverflow}px`)
    }

    const overflowingRow = await rows.evaluateAll((nodes) =>
      nodes.findIndex((node) => node.scrollWidth - node.clientWidth > 1),
    )
    if (overflowingRow !== -1) {
      throw new Error(`queue row ${overflowingRow} overflows at ${width}px`)
    }
  }
  await page.screenshot({ path: mobileScreenshot, fullPage: true })

  process.stdout.write(`desktop_screenshot=${desktopScreenshot}\n`)
  process.stdout.write(`mobile_screenshot=${mobileScreenshot}\n`)
} finally {
  await browser.close()
}
