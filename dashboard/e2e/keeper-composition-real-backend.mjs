import { chromium } from 'playwright'
import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  selectCompleteInlineRun,
  waitForKeeperComposerReady,
} from './keeper-composition-browser-evidence.mjs'

function required(name) {
  const value = process.env[name]?.trim()
  if (!value) throw new Error(`${name} is required`)
  return value
}

const dashboardUrl = required('MASC_COMPOSITION_DASHBOARD_URL')
const tokenFile = required('MASC_COMPOSITION_DASHBOARD_TOKEN_FILE')
const keeperName = required('MASC_COMPOSITION_KEEPER_NAME')
const expectedBasePath = required('MASC_COMPOSITION_EXPECTED_BASE_PATH')
const artifactDir = required('MASC_COMPOSITION_BROWSER_ARTIFACT_DIR')
const goalVerificationGoalId = required('MASC_GOAL_VERIFICATION_GOAL_ID')
// Optional on purpose: when the RW23 phase left no proven run (#32597), the
// composition proof still runs and the goal-verification measurement records
// that it was skipped, so one mission's failure does not erase another's proof.
const goalVerificationRunId = process.env.MASC_GOAL_VERIFICATION_RUN_ID?.trim() || null
const token = readFileSync(tokenFile, 'utf8').trim()
if (!token) throw new Error('dashboard token file is empty')

mkdirSync(artifactDir, { recursive: true })
const screenshotPath = join(artifactDir, 'keeper-composition-inspector.png')
const measurementPath = join(artifactDir, 'keeper-composition-inspector.json')
const goalVerificationScreenshotPath = join(artifactDir, 'goal-verification-run-proof.png')
const goalVerificationMeasurementPath = join(artifactDir, 'goal-verification-run-proof.json')
const failureScreenshotPath = join(artifactDir, 'keeper-composition-failure.png')
const failureStatePath = join(artifactDir, 'keeper-composition-failure.json')
const viewport = { width: 1440, height: 1000 }

const healthResponse = await fetch(new URL('/health?full=1', dashboardUrl))
if (!healthResponse.ok) throw new Error(`health preflight failed: ${healthResponse.status}`)
const health = await healthResponse.json()
if (health?.paths?.effective_base_path !== expectedBasePath) {
  throw new Error(
    `refusing non-isolated backend: expected=${expectedBasePath} observed=${health?.paths?.effective_base_path}`,
  )
}
if (health?.dashboard_surface?.status !== 'ok') {
  throw new Error(
    `dashboard surface is not built and fresh: ${JSON.stringify(health?.dashboard_surface)}`,
  )
}

const browser = await chromium.launch({ headless: true })
// Run 32444698841 timed out on the composer with the page showing
// "Client WS · disconnected" and a registry stuck on "loading": auth had
// passed and the route had selected the keeper, so the failure was the socket,
// not the locator. The screenshot said which subsystem; it could not say why.
// Console lines and failed requests name the cause, and both have to be
// subscribed before the first navigation to catch anything.
const consoleLines = []
const failedRequests = []
const CAPTURE_LIMIT = 400
try {
  const page = await browser.newPage({ viewport })
  page.on('console', message => {
    if (consoleLines.length < CAPTURE_LIMIT) {
      consoleLines.push(`[${message.type()}] ${message.text()}`)
    }
  })
  page.on('pageerror', error => {
    if (consoleLines.length < CAPTURE_LIMIT) {
      consoleLines.push(`[pageerror] ${error.message}`)
    }
  })
  page.on('requestfailed', request => {
    if (failedRequests.length < CAPTURE_LIMIT) {
      failedRequests.push(
        `${request.method()} ${request.url()} — ${request.failure()?.errorText ?? 'unknown'}`,
      )
    }
  })
  const route = new URL(dashboardUrl)
  route.searchParams.set('agent', 'dashboard')
  route.searchParams.set('token', token)
  route.hash = `monitoring?section=agents&keeper=${encodeURIComponent(keeperName)}`
  await page.goto(route.toString())
  await waitForKeeperComposerReady(page)
  await page.getByTestId('kw-chat-command-menu-toggle').click()
  await page.getByTestId('kw-chat-command-detail').click()
  await page.getByRole('tab', { name: '진단', exact: true }).click()

  const runtimeDiagnostics = page.locator('details').filter({
    has: page.getByText('런타임 진단', { exact: true }),
  })
  await runtimeDiagnostics.locator('summary').click()
  const compositionRows = page.locator('[data-composition-node][data-composition-run]')
  await compositionRows.first().waitFor()

  const rows = await compositionRows.evaluateAll(nodes => nodes.map(node => ({
    run: node.getAttribute('data-composition-run'),
    node: node.getAttribute('data-composition-node'),
    execution: node.getAttribute('data-composition-execution'),
    disposition: node.getAttribute('data-tool-call-disposition'),
  })))
  const complete = selectCompleteInlineRun(rows)
  if (!complete) {
    throw new Error(`no complete inline composition run in inspector rows: ${JSON.stringify(rows)}`)
  }

  const [compositionRunId, runRows] = complete
  const exactMemoryRow = page.locator(
    `[data-composition-run="${compositionRunId}"][data-composition-node="memory"]`,
  )
  await exactMemoryRow.locator('button[aria-expanded="false"]').click()
  await exactMemoryRow.getByLabel('도구 호출 입력 복사').waitFor()
  await exactMemoryRow.getByLabel('도구 호출 출력 복사').waitFor()

  const pageMeasurements = await page.evaluate(() => ({
    document_width: document.documentElement.scrollWidth,
    document_height: document.documentElement.scrollHeight,
    device_pixel_ratio: window.devicePixelRatio,
  }))
  const screenshot = await page.screenshot({ path: screenshotPath, fullPage: true })
  const measurement = {
    schema: 'masc.keeper_composition_browser_evidence.v1',
    keeper: keeperName,
    composition_run_id: compositionRunId,
    nodes: runRows.map(row => row.node).sort(),
    execution: 'inline',
    dispositions: runRows.map(row => row.disposition),
    visible_composition_rows: rows.length,
    expanded_node: 'memory',
    input_visible: await exactMemoryRow.getByLabel('도구 호출 입력 복사').isVisible(),
    output_visible: await exactMemoryRow.getByLabel('도구 호출 출력 복사').isVisible(),
    viewport,
    ...pageMeasurements,
    screenshot_file: 'keeper-composition-inspector.png',
    screenshot_bytes: screenshot.byteLength,
    screenshot_sha256: createHash('sha256').update(screenshot).digest('hex'),
  }
  writeFileSync(measurementPath, `${JSON.stringify(measurement, null, 2)}\n`)

  route.hash = 'workspace?section=verification'
  await page.goto(route.toString())
  let goalVerificationMeasurement
  if (goalVerificationRunId) {
  const goalRunsResponse = await fetch(
    new URL('/api/v1/dashboard/goal-verification-runs', dashboardUrl),
    { headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' } },
  )
  if (!goalRunsResponse.ok) {
    throw new Error(`Goal verification runs fetch failed: ${goalRunsResponse.status}`)
  }
  const goalRunsPayload = await goalRunsResponse.json()
  const expectedRun = Array.isArray(goalRunsPayload?.runs)
    ? goalRunsPayload.runs.find(run => run?.run_id === goalVerificationRunId)
    : undefined
  if (expectedRun?.goal_id !== goalVerificationGoalId
    || expectedRun?.review_kind !== 'proof'
    || expectedRun?.status !== 'committed'
    || !Array.isArray(expectedRun?.tools)
    || !expectedRun.tools.some(tool => tool?.tool_name === 'verification_read_file')) {
    throw new Error(`exact Goal verification run is absent or incomplete: ${JSON.stringify(expectedRun)}`)
  }

  const goalPanel = page.getByTestId('goal-verification-runs-panel')
  await goalPanel.waitFor()
  const goalRunRow = goalPanel.locator(
    `[data-goal-verification-run="${goalVerificationRunId}"]`,
  )
  await goalRunRow.waitFor()
  if (await goalRunRow.getAttribute('data-goal-id') !== goalVerificationGoalId
    || await goalRunRow.getAttribute('data-run-status') !== 'committed'
    || await goalRunRow.getAttribute('data-review-kind') !== 'proof') {
    throw new Error('rendered Goal verification row identity differs from backend payload')
  }
  const goalToolDetails = goalRunRow.locator(
    `[data-goal-verification-tools="${goalVerificationRunId}"]`,
  )
  await goalToolDetails.locator('summary').click()
  const artifactTool = goalToolDetails.getByText('verification_read_file', { exact: true })
  await artifactTool.waitFor()
  const goalVerificationScreenshot = await page.screenshot({
    path: goalVerificationScreenshotPath,
    fullPage: true,
  })
  goalVerificationMeasurement = {
    schema: 'masc.goal_verification_browser_evidence.v1',
    goal_id: goalVerificationGoalId,
    run_id: goalVerificationRunId,
    status: await goalRunRow.getAttribute('data-run-status'),
    review_kind: await goalRunRow.getAttribute('data-review-kind'),
    artifact_tool_visible: await artifactTool.isVisible(),
    backend_tool_names: expectedRun.tools.map(tool => tool.tool_name),
    viewport,
    screenshot_file: 'goal-verification-run-proof.png',
    screenshot_bytes: goalVerificationScreenshot.byteLength,
    screenshot_sha256: createHash('sha256').update(goalVerificationScreenshot).digest('hex'),
  }
  writeFileSync(
    goalVerificationMeasurementPath,
    `${JSON.stringify(goalVerificationMeasurement, null, 2)}\n`,
  )
  } else {
    goalVerificationMeasurement = {
      schema: 'masc.goal_verification_browser_evidence.v1',
      goal_id: goalVerificationGoalId,
      run_id: null,
      status: 'skipped',
      reason: 'no_proven_run',
      viewport,
    }
    writeFileSync(
      goalVerificationMeasurementPath,
      `${JSON.stringify(goalVerificationMeasurement, null, 2)}\n`,
    )
  }
  process.stdout.write(`${JSON.stringify({
    composition: measurement,
    persistence: persistenceMeasurement,
    goal_verification: goalVerificationMeasurement,
  })}\n`)
} catch (error) {
  // The success path screenshots after every assertion has passed, so a locator
  // timeout produced only its own message: run 32434575143 aborted on
  // getByLabel('메시지 입력') with no record of what the page actually showed.
  // The aria-label exists in the component, so the element was absent from the
  // rendered state rather than mislocated, and separating "keeper missing from
  // the list" from "route selected nothing" from "panel refused to draw" needs
  // the page itself. Capture is best-effort: a browser that died takes its
  // page with it, and the original error must still surface.
  try {
    const page = browser.contexts()[0]?.pages()[0]
    if (page) {
      await page.screenshot({ path: failureScreenshotPath, fullPage: true })
      writeFileSync(
        failureStatePath,
        `${JSON.stringify(
          {
            error: String(error?.message ?? error),
            url: page.url(),
            title: await page.title(),
            body_text: (await page.locator('body').innerText()).slice(0, 20000),
            console_lines: consoleLines,
            failed_requests: failedRequests,
          },
          null,
          2,
        )}\n`,
      )
    }
  } catch (captureError) {
    process.stderr.write(`failure capture unavailable: ${captureError}\n`)
  }
  throw error
} finally {
  await browser.close()
}
