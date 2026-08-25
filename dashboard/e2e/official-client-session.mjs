import { chromium } from 'playwright'

// Visual interaction fixture only. The production CanAdmin -> store CAS ->
// refreshed projection contract is exercised against the real HTTP server by
// test_sse_storm_e2e; this route interception intentionally proves layout and
// browser request shape, not backend authorization or persistence.

const fixtureUrl = process.env.OFFICIAL_CLIENT_SESSION_FIXTURE_URL
if (!fixtureUrl) throw new Error('OFFICIAL_CLIENT_SESSION_FIXTURE_URL is required')

const artifactDir = process.env.OFFICIAL_CLIENT_SESSION_ARTIFACT_DIR ?? '/tmp'
const recoveryScreenshot = `${artifactDir}/official-client-session-recovery-required.png`
const resolvedScreenshot = `${artifactDir}/official-client-session-recovery-resolved.png`
const loginScreenshot = `${artifactDir}/official-client-login-self-reported.png`
const recoveryId = '018f3a4a-27f4-7c9a-8fd8-330c2a3845aa'
let getRequests = 0
let postedBody = null
let loginProbeRequests = 0
let loginProbeBody = null

const recoveryPayload = {
  schema: 'masc.dashboard.official-client-session.v1',
  ok: true,
  keeper_name: 'sangsu',
  session: {
    client_kind: 'codex',
    runtime_id: 'codex.codex',
    phase: {
      kind: 'recovery_required',
      recovery_id: recoveryId,
      failure: 'protocol_failed',
      detail: 'malformed app-server event after the durable claim',
      required_at: 1786230000,
      owner_epoch: '018f3a4a-27f4-7c9a-8fd8-330c2a3845ab',
      observed_session_id: 'thread-observed',
      observed_turn_id: null,
      previous_settlement: null,
    },
    turn_count: 1,
    tool_surface_sha256: 'a'.repeat(64),
    last_recovery_resolution: null,
    last_transient_release: null,
    updated_at: 1786230000,
  },
}

const resolvedPayload = {
  ...recoveryPayload,
  resolution_application: 'applied',
  audit: { recorded: true },
  session: {
    ...recoveryPayload.session,
    phase: {
      kind: 'ready',
    },
    last_recovery_resolution: {
      recovery_id: recoveryId,
      failure: 'protocol_failed',
      resolution: { kind: 'restart_fresh' },
      resolved_by: 'dashboard',
      resolved_at: 1786230060,
    },
    updated_at: 1786230060,
  },
}

const loginPayload = {
  schema: 'masc.dashboard.official-client-probe.v1',
  ok: true,
  runtime_id: 'codex.codex',
  client_kind: 'codex',
  configured_model: 'gpt-5.3-codex-spark',
  measured_at: 1786230090,
  login: {
    status: 'ready',
    authenticated: true,
    evidence_source: 'configured_executable_self_report',
    identity_verified: false,
    auth_method: 'chatgpt',
    subscription_type: 'pro',
    api_provider: null,
  },
  client: { user_agent: 'codex_cli_rs/0.147.0' },
  execution: {
    status: 'not_measured',
    reason: 'login_probe_does_not_submit_model_turn',
  },
}

const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
  await page.route('**/api/v1/dashboard/dev-token', route => route.fulfill({
    json: { token: 'fixture-token', actor: 'dashboard', role: 'admin' },
  }))
  await page.route('**/api/v1/runtime/official-client/probe', async route => {
    loginProbeRequests += 1
    loginProbeBody = route.request().postDataJSON()
    await route.fulfill({ json: loginPayload })
  })
  await page.route('**/api/v1/runtime/sessions/official-client?**', route => {
    getRequests += 1
    return route.fulfill({ json: recoveryPayload })
  })
  await page.route('**/api/v1/runtime/sessions/official-client/resolve', async route => {
    postedBody = route.request().postDataJSON()
    await route.fulfill({ json: resolvedPayload })
  })

  await page.goto(fixtureUrl)
  await page.getByTestId('official-client-session-phase').getByText('recovery_required', { exact: true }).waitFor()
  const recovery = page.getByTestId('official-client-session-recovery-required')
  await recovery.getByText('protocol_failed', { exact: true }).waitFor()
  await recovery.getByText('thread-observed', { exact: true }).waitFor()
  await recovery.getByText(recoveryId, { exact: true }).waitFor()
  if (getRequests !== 1) throw new Error(`expected one session GET, got ${getRequests}`)
  if (loginProbeRequests !== 0) throw new Error('login probe ran before explicit operator action')

  const loginProbe = page.getByTestId('official-client-login-probe-codex.codex')
  await loginProbe.getByTestId('official-client-login-probe-run-codex.codex').click()
  await loginProbe.getByTestId('official-client-probe-login').getByText('self_reported', { exact: true }).waitFor()
  await loginProbe.getByTestId('official-client-probe-execution').getByText('not_measured', { exact: true }).waitFor()
  await loginProbe.getByTestId('official-client-probe-details').getByText('unverified', { exact: true }).waitFor()
  await loginProbe.getByText('pro', { exact: true }).waitFor()
  if (loginProbeRequests !== 1) throw new Error(`expected one login probe POST, got ${loginProbeRequests}`)
  if (JSON.stringify(loginProbeBody) !== JSON.stringify({ runtime_id: 'codex.codex' })) {
    throw new Error(`unexpected login probe body: ${JSON.stringify(loginProbeBody)}`)
  }
  await page.screenshot({ path: loginScreenshot, fullPage: true })

  await page.screenshot({ path: recoveryScreenshot, fullPage: true })
  await page.getByTestId('official-client-session-restart-fresh').click()
  await page.getByTestId('official-client-session-phase').getByText('ready', { exact: true }).waitFor()
  await page.getByTestId('official-client-session-last-resolution').getByText(/dashboard/).waitFor()

  const expectedBody = {
    keeper_name: 'sangsu',
    recovery_id: recoveryId,
    resolution: 'restart_fresh',
  }
  if (JSON.stringify(postedBody) !== JSON.stringify(expectedBody)) {
    throw new Error(`unexpected recovery body: ${JSON.stringify(postedBody)}`)
  }
  await page.screenshot({ path: resolvedScreenshot, fullPage: true })
  process.stdout.write(`official_client_recovery_required_screenshot=${recoveryScreenshot}\n`)
  process.stdout.write(`official_client_recovery_resolved_screenshot=${resolvedScreenshot}\n`)
  process.stdout.write(`official_client_login_self_reported_screenshot=${loginScreenshot}\n`)
} finally {
  await browser.close()
}
