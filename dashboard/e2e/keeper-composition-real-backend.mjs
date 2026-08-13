import { chromium } from 'playwright'
import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { selectCompleteInlineRun } from './keeper-composition-browser-evidence.mjs'

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
const token = readFileSync(tokenFile, 'utf8').trim()
if (!token) throw new Error('dashboard token file is empty')

mkdirSync(artifactDir, { recursive: true })
const screenshotPath = join(artifactDir, 'keeper-composition-inspector.png')
const measurementPath = join(artifactDir, 'keeper-composition-inspector.json')
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
try {
  const page = await browser.newPage({ viewport })
  const route = new URL(dashboardUrl)
  route.searchParams.set('agent', 'dashboard')
  route.searchParams.set('token', token)
  route.hash = `monitoring?section=agents&keeper=${encodeURIComponent(keeperName)}`
  await page.goto(route.toString())
  await page.getByLabel('메시지 입력').waitFor()
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
  process.stdout.write(`${JSON.stringify(measurement)}\n`)
} finally {
  await browser.close()
}
