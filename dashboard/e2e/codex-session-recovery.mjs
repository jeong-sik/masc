import { chromium } from 'playwright'

const fixtureUrl = process.env.CODEX_SESSION_RECOVERY_FIXTURE_URL
if (!fixtureUrl) throw new Error('CODEX_SESSION_RECOVERY_FIXTURE_URL is required')

const artifactDir = process.env.CODEX_SESSION_RECOVERY_ARTIFACT_DIR ?? '/tmp'
const recoveryScreenshot = `${artifactDir}/codex-session-recovery-required.png`
const resolvedScreenshot = `${artifactDir}/codex-session-recovery-resolved.png`
const recoveryId = '018f3a4a-27f4-7c9a-8fd8-330c2a3845aa'
let getRequests = 0
let postedBody = null

const recoveryPayload = {
  schema: 'masc.dashboard.codex-session.v1',
  ok: true,
  keeper_name: 'sangsu',
  session: {
    runtime_id: 'codex.codex',
    phase: {
      kind: 'recovery_required',
      recovery_id: recoveryId,
      failure: 'protocol_failed',
      detail: 'malformed app-server event after the durable claim',
      required_at: 1786230000,
      observed_thread_id: 'thread-observed',
      observed_turn_id: null,
      previous_settlement: null,
    },
    turn_count: 1,
    tool_surface_sha256: 'a'.repeat(64),
    last_recovery_resolution: null,
    updated_at: 1786230000,
  },
}

const resolvedPayload = {
  ...recoveryPayload,
  session: {
    ...recoveryPayload.session,
    phase: {
      kind: 'settled',
      thread_id: 'thread-verified',
      turn_id: 'turn-verified',
    },
    last_recovery_resolution: {
      recovery_id: recoveryId,
      failure: 'protocol_failed',
      resolution: {
        kind: 'adopt_verified',
        settlement: { thread_id: 'thread-verified', turn_id: 'turn-verified' },
      },
      resolved_by: 'dashboard',
      resolved_at: 1786230060,
    },
    updated_at: 1786230060,
  },
}

const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
  await page.route('**/api/v1/dashboard/dev-token', route => route.fulfill({
    json: { token: 'fixture-token', actor: 'dashboard', role: 'worker' },
  }))
  await page.route('**/api/v1/runtime/sessions/codex?**', route => {
    getRequests += 1
    return route.fulfill({ json: recoveryPayload })
  })
  await page.route('**/api/v1/runtime/sessions/codex/resolve', async route => {
    postedBody = route.request().postDataJSON()
    await route.fulfill({ json: resolvedPayload })
  })

  await page.goto(fixtureUrl)
  await page.getByTestId('codex-session-phase').getByText('recovery_required', { exact: true }).waitFor()
  const recovery = page.getByTestId('codex-session-recovery-required')
  await recovery.getByText('protocol_failed', { exact: true }).waitFor()
  await recovery.getByText('thread-observed', { exact: true }).waitFor()
  await recovery.getByText(recoveryId, { exact: true }).waitFor()
  if (getRequests !== 1) throw new Error(`expected one session GET, got ${getRequests}`)

  await page.screenshot({ path: recoveryScreenshot, fullPage: true })
  await page.getByTestId('codex-session-adopt-thread').fill('thread-verified')
  await page.getByTestId('codex-session-adopt-turn').fill('turn-verified')
  await page.getByTestId('codex-session-adopt-verified').click()
  await page.getByTestId('codex-session-phase').getByText('settled', { exact: true }).waitFor()
  await page.getByTestId('codex-session-last-resolution').getByText(/dashboard/).waitFor()

  const expectedBody = {
    keeper_name: 'sangsu',
    recovery_id: recoveryId,
    resolution: 'adopt_verified',
    thread_id: 'thread-verified',
    turn_id: 'turn-verified',
  }
  if (JSON.stringify(postedBody) !== JSON.stringify(expectedBody)) {
    throw new Error(`unexpected recovery body: ${JSON.stringify(postedBody)}`)
  }
  await page.screenshot({ path: resolvedScreenshot, fullPage: true })
  process.stdout.write(`codex_recovery_required_screenshot=${recoveryScreenshot}\n`)
  process.stdout.write(`codex_recovery_resolved_screenshot=${resolvedScreenshot}\n`)
} finally {
  await browser.close()
}
