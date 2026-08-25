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

  // Oldest first: the fixture's 2026-08-06 row leads, and its bar spans the
  // whole age axis because it is the oldest wait on the strip.
  const firstRow = rows.first()
  if (await firstRow.getAttribute('data-waiting-on') !== 'discord:incident-room') {
    throw new Error('the oldest wait is not the first row')
  }
  const bars = page.getByTestId('keeper-lane-waiting-bar')
  const widths = await bars.evaluateAll((nodes) => nodes.map((node) => Number.parseFloat(node.style.width)))
  if (widths[0] !== 100 || !(widths[1] < widths[0]) || !(widths[2] < widths[1])) {
    throw new Error(`bar widths do not fall with age: ${widths.join(', ')}`)
  }
  const axisTicks = await page.getByTestId('keeper-lane-age-axis').locator('[data-axis-tick]').allTextContents()
  if (axisTicks[0] !== '지금' || !axisTicks.includes('1시간') || !axisTicks.includes('1일')) {
    throw new Error(`the age axis is missing its ticks: ${axisTicks.join(', ')}`)
  }

  // The operator sentence is the default reading; the wire enum is not.
  const firstBar = bars.first()
  await firstBar.getByText('discord:incident-room 멘션', { exact: true }).waitFor()
  if (await firstRow.getByText('external_attention_store', { exact: true }).count()) {
    throw new Error('the wake producer leaked into the default reading')
  }

  // Opening a row discloses the timestamp; the 기술 상세 toggle discloses the
  // wire vocabulary and the typed detail.
  await firstBar.click()
  if (!(await firstRow.evaluate((node) => node.open))) {
    throw new Error('the queue row did not open')
  }
  await firstRow.locator('[data-testid="keeper-lane-waiting-time"] time').waitFor()
  await page.getByTestId('keeper-lane-dev-toggle').click()
  await firstRow.getByText('external_attention_store', { exact: true }).waitFor()
  await firstRow.getByText('keeper_process_external_attention', { exact: true }).waitFor()
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
