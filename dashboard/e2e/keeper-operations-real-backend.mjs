import { chromium } from 'playwright'
import { readFileSync } from 'node:fs'

const dashboardUrl = process.env.MASC_REAL_DASHBOARD_URL
if (!dashboardUrl) throw new Error('MASC_REAL_DASHBOARD_URL is required')

const adminTokenFile = process.env.MASC_REAL_DASHBOARD_ADMIN_TOKEN_FILE
if (!adminTokenFile) throw new Error('MASC_REAL_DASHBOARD_ADMIN_TOKEN_FILE is required')

const adminAgent = process.env.MASC_REAL_DASHBOARD_ADMIN_AGENT
if (!adminAgent) throw new Error('MASC_REAL_DASHBOARD_ADMIN_AGENT is required')

const adminToken = readFileSync(adminTokenFile, 'utf8').trim()
if (!adminToken) throw new Error('dashboard Admin token file is empty')

const keeperName = process.env.MASC_REAL_KEEPER_NAME
if (!keeperName) throw new Error('MASC_REAL_KEEPER_NAME is required')

const expectedBasePath = process.env.MASC_REAL_EXPECTED_BASE_PATH
if (!expectedBasePath) throw new Error('MASC_REAL_EXPECTED_BASE_PATH is required')

const artifactDir = process.env.MASC_REAL_KEEPER_ARTIFACT_DIR ?? '/tmp'
const queuedScreenshot = `${artifactDir}/keeper-real-backend-queued.png`
const reconnectedScreenshot = `${artifactDir}/keeper-real-backend-reconnected.png`
const prefix = `MASC_REAL_OPERATION_E2E_${Date.now()}`
process.stdout.write(`probe_prefix=${prefix}\n`)

const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))

async function waitFor(predicate, description, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await predicate()
    if (value) return value
    await sleep(100)
  }
  throw new Error(`Timed out waiting for ${description}`)
}

async function submit(page, message) {
  const composer = page.getByLabel('메시지 입력')
  await composer.fill(message)
  await composer.press('Meta+Enter')
  await waitFor(
    async () => (await composer.inputValue()) === '',
    `composer acceptance for ${message}`,
  )
}

async function openControls(page) {
  const open = page.locator('[data-open-keeper-operation-control]')
  await open.waitFor()
  if (await open.isDisabled()) throw new Error('operation controls require an Admin dashboard session')
  await open.click()
  const panel = page.locator('[data-keeper-operation-control-panel]')
  await panel.waitFor()
  return panel
}

function probeRows(panel) {
  return panel.locator('[data-operator-chat-operation]').filter({ hasText: prefix })
}

async function operationIds(rows) {
  return rows.evaluateAll(nodes => nodes.map(node => node.getAttribute('data-operator-chat-operation')))
}

async function cancelRemainingProbeRows(panel) {
  for (;;) {
    const rows = probeRows(panel)
    const beforeCount = await rows.count()
    if (beforeCount === 0) return
    await rows.first().getByRole('button', { name: '취소', exact: true }).click()
    await waitFor(
      async () => (await probeRows(panel).count()) < beforeCount,
      'queued operation cleanup',
    )
  }
}

const browser = await chromium.launch({ headless: true })
let page
try {
  const healthUrl = new URL('/health?full=1', dashboardUrl)
  const healthResponse = await fetch(healthUrl)
  if (!healthResponse.ok) throw new Error(`health preflight failed: ${healthResponse.status}`)
  const health = await healthResponse.json()
  const observedBasePath = health?.paths?.effective_base_path
  if (observedBasePath !== expectedBasePath) {
    throw new Error(`refusing non-isolated backend: expected=${expectedBasePath} observed=${observedBasePath}`)
  }

  page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
  const route = new URL(dashboardUrl)
  route.searchParams.set('agent', adminAgent)
  route.searchParams.set('token', adminToken)
  route.hash = `monitoring?section=agents&keeper=${encodeURIComponent(keeperName)}`
  await page.goto(route.toString())
  await page.getByLabel('메시지 입력').waitFor()

  // Fail before creating durable operations when this dashboard session
  // cannot edit/cancel them during cleanup.
  const preflightPanel = await openControls(page)
  await preflightPanel.getByRole('button', { name: '닫기', exact: true }).click()
  await preflightPanel.waitFor({ state: 'detached' })

  for (let index = 1; index <= 4; index += 1) {
    await submit(page, `${prefix}_${index}`)
  }

  let panel = await openControls(page)
  const initialRows = probeRows(panel)
  await waitFor(async () => {
    const rowCount = await initialRows.count()
    const noActiveTurn = await panel
      .getByText('현재 실행 중인 턴이 없습니다.', { exact: true })
      .count()
    return rowCount === 4 && noActiveTurn === 1
  }, 'all four durable Queued operations remain queued with no active turn')
  const acceptedIds = await operationIds(initialRows)
  if (acceptedIds.length !== 4 || acceptedIds.some(id => !id)) {
    throw new Error(`expected four queued operation ids, observed=${acceptedIds}`)
  }
  await page.screenshot({ path: queuedScreenshot, fullPage: true })

  await page.reload()
  await page.getByLabel('메시지 입력').waitFor()
  panel = await openControls(page)
  const hydratedRows = probeRows(panel)
  await waitFor(async () => (await hydratedRows.count()) === 4, 'operation-id reconnect hydration')
  const hydratedIds = await operationIds(hydratedRows)
  const preservedIds = acceptedIds.filter(id => hydratedIds.includes(id))
  if (preservedIds.length !== 4) {
    throw new Error(`reconnect lost operation identities: accepted=${acceptedIds} hydrated=${hydratedIds}`)
  }

  const target = hydratedRows.first()
  const targetId = await target.getAttribute('data-operator-chat-operation')
  if (!targetId) throw new Error('edit target omitted operation_id')
  const editedMessage = `${prefix}_EDITED`
  page.once('dialog', dialog => dialog.accept(editedMessage))
  await target.getByRole('button', { name: '수정', exact: true }).click()
  const edited = panel.locator(`[data-operator-chat-operation="${targetId}"]`)
  await edited.getByText(editedMessage, { exact: true }).waitFor()

  const beforeMove = await operationIds(panel.locator('[data-operator-chat-operation]'))
  const moveButton = edited.getByRole('button', { name: '맨 뒤로', exact: true })
  if (await moveButton.isDisabled()) throw new Error('selected queued operation was already the FIFO tail')
  await moveButton.click()
  await waitFor(async () => {
    const afterMove = await operationIds(panel.locator('[data-operator-chat-operation]'))
    return afterMove.at(-1) === targetId && JSON.stringify(afterMove) !== JSON.stringify(beforeMove)
  }, 'move-to-end sequence change')

  await panel.locator(`[data-operator-chat-operation="${targetId}"]`)
    .getByRole('button', { name: '취소', exact: true })
    .click()
  await waitFor(
    async () => await panel.locator(`[data-operator-chat-operation="${targetId}"]`).count() === 0,
    'cancelled operation removal',
  )
  await page.screenshot({ path: reconnectedScreenshot, fullPage: true })

  await cancelRemainingProbeRows(panel)
  process.stdout.write(`keeper=${keeperName}\n`)
  process.stdout.write(`accepted_operation_ids=${acceptedIds.join(',')}\n`)
  process.stdout.write(`edited_moved_cancelled_operation_id=${targetId}\n`)
  process.stdout.write(`queued_screenshot=${queuedScreenshot}\n`)
  process.stdout.write(`reconnected_screenshot=${reconnectedScreenshot}\n`)
} finally {
  if (page) {
    const panel = page.locator('[data-keeper-operation-control-panel]')
    if (await panel.count()) await cancelRemainingProbeRows(panel).catch(() => {})
  }
  await browser.close()
}
