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
const persistenceScreenshotPath = join(artifactDir, 'keeper-persistence-proof.png')
const persistenceMeasurementPath = join(artifactDir, 'keeper-persistence-proof.json')
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

  route.hash = 'workspace?section=verification'
  await page.goto(route.toString())
  const persistencePanel = page.getByTestId('keeper-persistence-proof-panel')
  await persistencePanel.waitFor()
  const persistenceCards = persistencePanel.locator('[data-tier-id][data-evidence-kind]')
  await persistenceCards.first().waitFor()
  const persistenceRefresh = page.getByTestId('keeper-persistence-proof-refresh')
  const [persistenceResponse] = await Promise.all([
    page.waitForResponse(response =>
      response.url().includes('/api/v1/dashboard/keeper-feature-proof') && response.ok(),
    ),
    persistenceRefresh.click(),
  ])
  const refreshedPayload = await persistenceResponse.json()
  const refreshedGeneratedAt = refreshedPayload?.generated_at
  if (typeof refreshedGeneratedAt !== 'string' || !Number.isFinite(Date.parse(refreshedGeneratedAt))) {
    throw new Error('manual refresh response has no generated_at')
  }
  const persistenceFeatures = Array.isArray(refreshedPayload?.features)
    ? refreshedPayload.features.filter(feature => feature?.id === 'persistent_24h_turn_exchange')
    : []
  if (persistenceFeatures.length !== 1) {
    throw new Error(`manual refresh response has ${persistenceFeatures.length} persistence features`)
  }
  const refreshedTiers = persistenceFeatures[0]?.duration_tiers
  if (!Array.isArray(refreshedTiers) || refreshedTiers.length !== 4) {
    throw new Error('manual refresh response has no exact persistence duration tiers')
  }
  await page.waitForFunction(expectedGeneratedAt => {
    const panel = document.querySelector('[data-testid="keeper-persistence-proof-panel"]')
    const button = document.querySelector('[data-testid="keeper-persistence-proof-refresh"]')
    return panel?.getAttribute('data-proof-generated-at') === expectedGeneratedAt
      && button instanceof HTMLButtonElement
      && !button.disabled
  }, refreshedGeneratedAt)
  const renderedTiers = await persistenceCards.evaluateAll(nodes => {
    const countAttribute = (node, name) => {
      const raw = node.getAttribute(name)
      const parsed = Number(raw)
      if (raw == null || !Number.isSafeInteger(parsed) || parsed < 0 || String(parsed) !== raw) {
        throw new Error(`${name} must be a canonical non-negative integer, observed=${raw}`)
      }
      return parsed
    }
    return nodes.map(node => ({
      id: node.getAttribute('data-tier-id'),
      status: node.getAttribute('data-proof-status'),
      evidence_kind: node.getAttribute('data-evidence-kind'),
      observed_count: countAttribute(node, 'data-observed-count'),
      keeper_count: countAttribute(node, 'data-keeper-count'),
      missing_count: countAttribute(node, 'data-missing-count'),
    }))
  })
  const expectedTierIds = ['1h', '2h', '4h', '24h']
  if (JSON.stringify(renderedTiers.map(tier => tier.id)) !== JSON.stringify(expectedTierIds)) {
    throw new Error(`unexpected persistence tier order: ${JSON.stringify(renderedTiers)}`)
  }
  const tiers = renderedTiers.map((rendered, index) => {
    const responseTier = refreshedTiers[index]
    const observedKeepers = responseTier?.observed_keepers
    const missingKeepers = responseTier?.missing_keepers
    if (responseTier?.id !== rendered.id
      || responseTier?.status !== rendered.status
      || responseTier?.evidence_kind !== rendered.evidence_kind
      || responseTier?.observed_count !== rendered.observed_count
      || responseTier?.keeper_count !== rendered.keeper_count
      || responseTier?.missing_count !== rendered.missing_count
      || !Array.isArray(observedKeepers)
      || !Array.isArray(missingKeepers)
      || observedKeepers.some(name => typeof name !== 'string' || !name.trim())
      || missingKeepers.some(name => typeof name !== 'string' || !name.trim())) {
      throw new Error(`rendered persistence tier differs from response: ${JSON.stringify({ rendered, responseTier })}`)
    }
    return {
      ...rendered,
      observed_keepers: observedKeepers,
      missing_keepers: missingKeepers,
    }
  })
  const fleet = new Set([...tiers[0].observed_keepers, ...tiers[0].missing_keepers])
  for (const [index, tier] of tiers.entries()) {
    if (!['pass', 'warn', 'fail'].includes(tier.status)) {
      throw new Error(`unexpected persistence status: ${JSON.stringify(tier)}`)
    }
    if (tier.evidence_kind !== 'durable_turn_span') {
      throw new Error(`unexpected persistence evidence kind: ${JSON.stringify(tier)}`)
    }
    if (![tier.observed_count, tier.keeper_count, tier.missing_count].every(Number.isSafeInteger)) {
      throw new Error(`non-integer persistence count: ${JSON.stringify(tier)}`)
    }
    if (tier.observed_count < 0 || tier.missing_count < 0
      || tier.observed_count + tier.missing_count !== tier.keeper_count) {
      throw new Error(`inconsistent persistence counts: ${JSON.stringify(tier)}`)
    }
    const observed = new Set(tier.observed_keepers)
    const missing = new Set(tier.missing_keepers)
    const tierFleet = new Set([...observed, ...missing])
    if (observed.size !== tier.observed_count || missing.size !== tier.missing_count
      || tierFleet.size !== tier.keeper_count
      || tierFleet.size !== fleet.size
      || [...fleet].some(name => !tierFleet.has(name))
      || [...observed].some(name => missing.has(name))) {
      throw new Error(`inconsistent persistence identities: ${JSON.stringify(tier)}`)
    }
    if (index > 0) {
      const previous = tiers[index - 1]
      const previousObserved = new Set(previous.observed_keepers)
      const previousMissing = new Set(previous.missing_keepers)
      if ([...observed].some(name => !previousObserved.has(name))
        || [...previousMissing].some(name => !missing.has(name))) {
        throw new Error(`non-monotonic persistence identities: ${JSON.stringify(tiers)}`)
      }
    }
  }
  const generatedAt = await persistencePanel.getAttribute('data-proof-generated-at')
  if (!generatedAt) throw new Error('persistence proof generated_at is absent')
  const persistenceScreenshot = await page.screenshot({
    path: persistenceScreenshotPath,
    fullPage: true,
  })
  const persistenceMeasurement = {
    schema: 'masc.keeper_persistence_browser_evidence.v1',
    generated_at: generatedAt,
    interaction: 'manual_refresh',
    tiers,
    viewport,
    screenshot_file: 'keeper-persistence-proof.png',
    screenshot_bytes: persistenceScreenshot.byteLength,
    screenshot_sha256: createHash('sha256').update(persistenceScreenshot).digest('hex'),
  }
  writeFileSync(
    persistenceMeasurementPath,
    `${JSON.stringify(persistenceMeasurement, null, 2)}\n`,
  )
  process.stdout.write(`${JSON.stringify({ composition: measurement, persistence: persistenceMeasurement })}\n`)
} finally {
  await browser.close()
}
