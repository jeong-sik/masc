import { chromium } from 'playwright'

const fixtureUrl = process.env.OFFICIAL_CLIENT_RUNTIME_FIXTURE_URL
if (!fixtureUrl) throw new Error('OFFICIAL_CLIENT_RUNTIME_FIXTURE_URL is required')

const artifactDir = process.env.OFFICIAL_CLIENT_RUNTIME_ARTIFACT_DIR ?? '/tmp'
const screenshot = `${artifactDir}/official-client-runtime-evidence.png`
let providersRequests = 0
let metricsRequests = 0
let forcedProbeRequests = 0

const providersPayload = {
  updated_at: '2026-08-09T07:30:00Z',
  summary: {
    providers: 2,
    runtimes: 2,
    local_models: 0,
    cloud_models: 0,
    cli_models: 2,
    default_runtime_id: 'antigravity_subscription.flash',
  },
  config_path: '/home/operator/.masc/runtime.toml',
  providers: [
    {
      provider: 'antigravity_subscription.flash',
      runtime_id: 'antigravity_subscription.flash',
      provider_id: 'antigravity_subscription',
      model_id: 'flash',
      model_api_name: 'gemini-3.6-flash-low',
      protocol: 'antigravity-cli',
      transport: 'cli',
      runtime_kind: 'cli',
      auth_kind: 'none',
      kind: 'cli',
      status: 'verified',
      available: true,
      is_default_runtime: true,
      max_context: 128000,
      models: ['gemini-3.6-flash-low'],
      verification: {
        status: 'verified',
        measured: true,
        observed_at: 1786239000,
        reason: null,
        evidence: {
          runtime_id: 'antigravity_subscription.flash',
          observed_at: 1786239000,
          outcome: 'success',
          measurement: {
            client: 'antigravity',
            execution_mode: 'plan_sandbox',
            tool_owner: 'official_client',
            permission_mode: 'always-proceed',
            session_bound: true,
            resumed: true,
            turn_count: 2,
            tool_calls: 1,
            usage: {
              input_tokens: 21,
              output_tokens: 4,
              thinking_tokens: 2,
              cache_read_tokens: 7,
              total_tokens: 25,
            },
          },
        },
      },
    },
    {
      provider: 'codex_subscription.spark',
      runtime_id: 'codex_subscription.spark',
      provider_id: 'codex_subscription',
      model_id: 'spark',
      model_api_name: 'gpt-5.3-codex-spark',
      protocol: 'codex-app-server',
      transport: 'cli',
      runtime_kind: 'cli',
      auth_kind: 'none',
      kind: 'cli',
      status: 'configured_unverified',
      available: null,
      is_default_runtime: false,
      max_context: 128000,
      models: ['gpt-5.3-codex-spark'],
      verification: {
        status: 'unverified',
        measured: false,
        observed_at: null,
        reason: 'no_successful_runtime_observation',
        evidence: null,
      },
    },
  ],
}

const metricsPayload = {
  window_minutes: 30,
  bucket_minutes: 5,
  total_entries: 0,
  total_error_entries: 0,
  latency_buckets: [],
  models: [],
}

const probePayload = {
  generated_at: '2026-08-09T07:30:00Z',
  refresh_state: 'fresh',
  probe: {
    summary: { runtimes: 2, reachable: 0, failed: 0, skipped: 2 },
    providers: [],
  },
}

const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } })
  await page.route('**/api/v1/providers', async route => {
    providersRequests += 1
    await route.fulfill({ json: providersPayload })
  })
  await page.route('**/api/v1/models/metrics**', async route => {
    metricsRequests += 1
    const url = new URL(route.request().url())
    const windowMinutes = Number(url.searchParams.get('window') ?? 30)
    await route.fulfill({ json: { ...metricsPayload, window_minutes: windowMinutes } })
  })
  await page.route('**/api/v1/dashboard/runtime-probe**', async route => {
    const url = new URL(route.request().url())
    if (url.searchParams.get('force') === '1') forcedProbeRequests += 1
    await route.fulfill({ json: probePayload })
  })

  await page.goto(fixtureUrl)
  await page.getByText('공식 구독 CLI · 실측 turn 성공', { exact: true }).waitFor()
  await page.getByText('공식 구독 CLI · 아직 실측 없음', { exact: true }).waitFor()

  const measured = page.getByTestId('official-client-evidence-antigravity_subscription.flash')
  await measured.getByText('client · antigravity', { exact: true }).waitFor()
  await measured.getByText('turn · 2 · resumed', { exact: true }).waitFor()
  await measured.getByText(
    'provider usage · in 21 · out 4 · thinking 2 · cache 7 · total 25',
    { exact: true },
  ).waitFor()

  const unmeasured = page.getByTestId('official-client-evidence-codex_subscription.spark')
  await unmeasured.getByText('auth / usage / session unknown', { exact: true }).waitFor()

  await page.getByLabel('시간 윈도우 선택').selectOption('60')
  await page.getByText('60m', { exact: true }).waitFor()
  await page.getByRole('button', { name: 'runtime snapshot 새로고침' }).click()
  await page.getByText('공식 구독 CLI · 실측 turn 성공', { exact: true }).waitFor()

  if (providersRequests < 3) {
    throw new Error(`expected provider reloads after interactions, got ${providersRequests}`)
  }
  if (metricsRequests < 3) {
    throw new Error(`expected metrics reloads after interactions, got ${metricsRequests}`)
  }
  if (forcedProbeRequests !== 1) {
    throw new Error(`expected one forced live probe, got ${forcedProbeRequests}`)
  }

  await page.screenshot({ path: screenshot, fullPage: true })
  process.stdout.write(`official_client_runtime_screenshot=${screenshot}\n`)
} finally {
  await browser.close()
}
