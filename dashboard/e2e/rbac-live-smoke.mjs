import { mkdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { chromium } from 'playwright'

// Live RBAC E2E smoke test across real single-user and multi-account MASC servers.
// Never mocks auth boundaries: every HTTP check, cookie, CSRF header, PAT, and
// browser navigation talks directly to live main_eio.exe instances serving the
// built dashboard bundle.

const manifestPath = process.env.RBAC_E2E_MANIFEST
const suOffUrl = process.env.RBAC_SU_OFF_URL
const suAuthUrl = process.env.RBAC_SU_AUTH_URL
const suStrictUrl = process.env.RBAC_SU_STRICT_URL
const maUrl = process.env.RBAC_MA_URL
const screenshotDir = process.env.RBAC_SCREENSHOT_DIR || ''
const modeFilter = (process.env.RBAC_E2E_ONLY || 'all').trim().toLowerCase()

if (!manifestPath || !suOffUrl || !suAuthUrl || !suStrictUrl || !maUrl) {
  throw new Error(
    'RBAC_E2E_MANIFEST, RBAC_SU_OFF_URL, RBAC_SU_AUTH_URL, RBAC_SU_STRICT_URL, and RBAC_MA_URL are required',
  )
}

const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
if (screenshotDir) {
  mkdirSync(screenshotDir, { recursive: true })
}

const screenshots = []
const results = []

function assert(cond, message) {
  if (!cond) throw new Error(`Assertion failed: ${message}`)
}

function recordPass(name, detail = '') {
  results.push({ name, detail })
  process.stdout.write(`[rbac-e2e] PASS ${name}${detail ? ` (${detail})` : ''}\n`)
}

async function apiReq(baseUrl, path, opts = {}) {
  const { method = 'GET', headers = {}, body } = opts
  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers: { Accept: 'application/json', ...headers },
    body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body),
    redirect: 'manual',
  })
  const text = await res.text()
  let json = null
  try {
    json = text ? JSON.parse(text) : null
  } catch {
    json = null
  }
  return { status: res.status, text, json, headers: res.headers }
}

function maCookieHeaders(session, originUrl, withCsrf = false) {
  const headers = {
    Cookie: `${session.cookie_name}=${session.cookie_value}`,
    Origin: originUrl,
  }
  if (withCsrf) {
    headers['X-MASC-CSRF-Token'] = session.csrf_token
    headers['Content-Type'] = 'application/json'
  }
  return headers
}

async function runHttpContractChecks() {
  process.stdout.write('\n=== Phase 1: Live HTTP RBAC Contract Checks ===\n')

  // 1. Single-user auth_off
  {
    const health = await apiReq(suOffUrl, '/health')
    assert(health.status === 200, `su_off /health status=${health.status}`)
    assert(
      health.json?.account_mode === undefined || health.json?.account_mode === 'Single_user',
      `su_off /health account_mode=${JSON.stringify(health.json?.account_mode)}`,
    )
    const shell = await apiReq(suOffUrl, '/api/v1/dashboard/shell')
    assert(shell.status === 200, `su_off /shell status=${shell.status}`)
    assert(shell.json?.auth?.enabled === false, `su_off auth.enabled=${shell.json?.auth?.enabled}`)
    assert(shell.json?.auth?.effective_role === 'admin', `su_off effective_role=${shell.json?.auth?.effective_role}`)
    // Token_permission CanAdmin refuses when workspace auth is disabled.
    const schema = await apiReq(suOffUrl, '/api/v1/config/schema?target=runtime')
    assert(schema.status === 401, `su_off /config/schema expected 401, got ${schema.status}`)
    recordPass('http.su_off', 'health=200 shell.auth.enabled=false config/schema=401')
  }

  // 2a. Single-user auth_on (default loopback: Public_read returns shell.auth metadata, dev_token advertised)
  {
    const tokens = manifest.su_auth.tokens
    const health = await apiReq(suAuthUrl, '/health')
    assert(health.status === 200, `su_auth /health status=${health.status}`)
    assert(health.json?.auth_methods?.dev_token === true, 'su_auth default loopback must advertise dev_token=true')

    // Non-strict loopback Public_read returns 200 with token_valid=false on missing/bad token.
    const missingShell = await apiReq(suAuthUrl, '/api/v1/dashboard/shell')
    assert(missingShell.status === 200 && missingShell.json?.auth?.token_valid === false, `su_auth missing /shell=${missingShell.status}`)
    const badShell = await apiReq(suAuthUrl, '/api/v1/dashboard/shell', {
      headers: { Authorization: 'Bearer invalid-token-smoke-0000' },
    })
    assert(badShell.status === 200 && badShell.json?.auth?.token_valid === false, `su_auth bad /shell=${badShell.status}`)

    // Player token resolves via loopback Public_read /shell (200 effective_role=player) while protected routes return 403.
    const playerHdr = { Authorization: `Bearer ${tokens.player}` }
    const playerShell = await apiReq(suAuthUrl, '/api/v1/dashboard/shell', { headers: playerHdr })
    assert(playerShell.status === 200, `su_auth player /shell status=${playerShell.status}`)
    assert(playerShell.json?.auth?.effective_role === 'player', `su_auth player role=${playerShell.json?.auth?.effective_role}`)
    assert(playerShell.json?.auth?.token_valid === true, 'su_auth player token_valid must be true')
    const playerBoard = await apiReq(suAuthUrl, '/api/v1/dashboard/board', { headers: playerHdr })
    assert(playerBoard.status === 403, `su_auth player /dashboard/board expected 403, got ${playerBoard.status}`)
    const playerSchema = await apiReq(suAuthUrl, '/api/v1/config/schema?target=runtime', { headers: playerHdr })
    assert(playerSchema.status === 403, `su_auth player /config/schema expected 403, got ${playerSchema.status}`)

    recordPass('http.su_auth_loopback', 'missing/bad=200(token_valid=false) Player(shell=200/player,board=403,schema=403)')
  }

  // 2b. Single-user auth_on (strict loopback: dev_token disabled, Public_read enforces CanReadState)
  {
    const tokens = manifest.su_strict.tokens
    const health = await apiReq(suStrictUrl, '/health')
    assert(health.status === 200, `su_strict /health status=${health.status}`)
    assert(health.json?.auth_methods?.dev_token === false, 'su_strict must set dev_token=false')

    const devTok = await apiReq(suStrictUrl, '/api/v1/dashboard/dev-token')
    assert(devTok.status === 404, `su_strict /dev-token expected 404, got ${devTok.status}`)

    const missingShell = await apiReq(suStrictUrl, '/api/v1/dashboard/shell')
    assert(missingShell.status === 401, `su_strict missing token /shell expected 401, got ${missingShell.status}`)

    const badShell = await apiReq(suStrictUrl, '/api/v1/dashboard/shell', {
      headers: { Authorization: 'Bearer invalid-token-smoke-0000' },
    })
    assert(badShell.status === 401, `su_strict bad token /shell expected 401, got ${badShell.status}`)

    // Admin token
    const adminHdr = { Authorization: `Bearer ${tokens.admin}` }
    const adminShell = await apiReq(suStrictUrl, '/api/v1/dashboard/shell', { headers: adminHdr })
    assert(adminShell.status === 200, `su_strict admin /shell status=${adminShell.status}`)
    assert(adminShell.json?.auth?.effective_role === 'admin', `su_strict admin role=${adminShell.json?.auth?.effective_role}`)
    assert(adminShell.json?.auth?.effective_admin === true, 'su_strict admin effective_admin must be true')
    assert(adminShell.json?.auth?.token_valid === true, 'su_strict admin token_valid must be true')
    const adminSchema = await apiReq(suStrictUrl, '/api/v1/config/schema?target=runtime', { headers: adminHdr })
    assert(adminSchema.status === 200, `su_strict admin /config/schema expected 200, got ${adminSchema.status}`)
    const adminExact = await apiReq(suStrictUrl, '/api/v1/dashboard/exact-lane-runs?run_kind=exact_output', { headers: adminHdr })
    assert(adminExact.status === 200, `su_strict admin /exact-lane-runs expected 200, got ${adminExact.status}`)

    // Worker token
    const workerHdr = { Authorization: `Bearer ${tokens.worker}` }
    const workerShell = await apiReq(suStrictUrl, '/api/v1/dashboard/shell', { headers: workerHdr })
    assert(workerShell.status === 200, `su_strict worker /shell status=${workerShell.status}`)
    assert(workerShell.json?.auth?.effective_role === 'worker', `su_strict worker role=${workerShell.json?.auth?.effective_role}`)
    assert(workerShell.json?.auth?.effective_admin === false, 'su_strict worker effective_admin must be false')
    const workerSandboxes = await apiReq(suStrictUrl, '/api/v1/infra/sandboxes', { headers: workerHdr })
    assert(workerSandboxes.status === 200, `su_strict worker /infra/sandboxes expected 200, got ${workerSandboxes.status}`)
    const workerSchema = await apiReq(suStrictUrl, '/api/v1/config/schema?target=runtime', { headers: workerHdr })
    assert(workerSchema.status === 403, `su_strict worker /config/schema expected 403, got ${workerSchema.status}`)
    const workerExact = await apiReq(suStrictUrl, '/api/v1/dashboard/exact-lane-runs?run_kind=exact_output', { headers: workerHdr })
    assert(workerExact.status === 403, `su_strict worker /exact-lane-runs expected 403, got ${workerExact.status}`)

    // Strict mode enforces CanReadState on /shell, so Player receives 403 before shell mounts.
    const playerHdr = { Authorization: `Bearer ${tokens.player}` }
    const playerShell = await apiReq(suStrictUrl, '/api/v1/dashboard/shell', { headers: playerHdr })
    assert(playerShell.status === 403, `su_strict player /shell expected 403, got ${playerShell.status}`)

    recordPass('http.su_strict', 'missing/bad=401 Admin=200 Worker(infra=200,admin=403) Player(shell=403)')
  }

  // 3. Multi-account server
  {
    const { sessions, pats, service_token: serviceToken } = manifest.ma
    const health = await apiReq(maUrl, '/health')
    assert(health.status === 200, `ma /health status=${health.status}`)
    assert(health.json?.account_mode === 'Multi_account', `ma account_mode=${health.json?.account_mode}`)
    assert(health.json?.auth_methods?.dev_token === false, 'ma dev_token must be false')

    // Single-user routes are unmounted (404) in multi-account mode.
    for (const unmounted of ['/api/v1/dashboard/dev-token', '/api/v1/keepers', '/api/v1/setup/inventory']) {
      const r = await apiReq(maUrl, unmounted)
      assert(r.status === 404, `ma ${unmounted} expected 404, got ${r.status}`)
    }

    // Signed-out requests return 401.
    for (const gated of ['/auth/session', '/api/v1/auth/whoami', '/api/v1/dashboard/shell', '/api/v1/auth/keepers']) {
      const r = await apiReq(maUrl, gated)
      assert(r.status === 401, `ma signed_out ${gated} expected 401, got ${r.status}`)
    }

    // Admin1 session: full admin + CSRF check + personal keepers route check.
    const a1Sess = await apiReq(maUrl, '/auth/session', { headers: maCookieHeaders(sessions.admin1, maUrl) })
    assert(a1Sess.status === 200 && a1Sess.json?.user_id === sessions.admin1.user_id, `ma admin1 /auth/session status=${a1Sess.status}`)
    const a1Who = await apiReq(maUrl, '/api/v1/auth/whoami', { headers: maCookieHeaders(sessions.admin1, maUrl) })
    assert(a1Who.status === 200 && a1Who.json?.role === 'admin' && a1Who.json?.binding?.kind === 'session', `ma admin1 whoami=${a1Who.text}`)
    const a1Schema = await apiReq(maUrl, '/api/v1/config/schema?target=runtime', { headers: maCookieHeaders(sessions.admin1, maUrl) })
    assert(a1Schema.status === 200, `ma admin1 /config/schema expected 200, got ${a1Schema.status}`)
    const a1Members = await apiReq(maUrl, '/api/v1/auth/members', { headers: maCookieHeaders(sessions.admin1, maUrl) })
    assert(a1Members.status === 200 && Array.isArray(a1Members.json?.members) && a1Members.json.members.length === 3, `ma admin1 /members=${a1Members.status}`)

    // CSRF boundary check on unsafe POST without CSRF header.
    const noCsrf = await apiReq(maUrl, '/api/v1/auth/keepers', {
      method: 'POST',
      headers: { ...maCookieHeaders(sessions.admin1, maUrl, false), 'Content-Type': 'application/json' },
      body: { keeper_id: 'csrf-should-fail' },
    })
    assert(noCsrf.status === 403, `ma POST /auth/keepers without CSRF expected 403, got ${noCsrf.status}`)

    // With CSRF header, creating + listing personal keeper succeeds.
    const mkKeeper = await apiReq(maUrl, '/api/v1/auth/keepers', {
      method: 'POST',
      headers: maCookieHeaders(sessions.admin1, maUrl, true),
      body: { keeper_id: 'smoke-keeper-1' },
    })
    assert(mkKeeper.status === 200 && mkKeeper.json?.keeper_id === 'smoke-keeper-1', `ma POST /auth/keepers status=${mkKeeper.status} body=${mkKeeper.text}`)
    const listKeepers = await apiReq(maUrl, '/api/v1/auth/keepers', { headers: maCookieHeaders(sessions.admin1, maUrl) })
    assert(
      listKeepers.status === 200
        && Array.isArray(listKeepers.json?.keepers)
        && listKeepers.json.keepers.some((k) => k.keeper_id === 'smoke-keeper-1'),
      `ma GET /auth/keepers missing created keeper: ${listKeepers.text}`,
    )

    // Worker1 session: workspace read OK, admin & infra denied, Manage_own_provider works end-to-end.
    const w1Who = await apiReq(maUrl, '/api/v1/auth/whoami', { headers: maCookieHeaders(sessions.worker1, maUrl) })
    assert(w1Who.status === 200 && w1Who.json?.role === 'worker', `ma worker1 whoami=${w1Who.text}`)
    const w1Board = await apiReq(maUrl, '/api/v1/dashboard/board', { headers: maCookieHeaders(sessions.worker1, maUrl) })
    assert(w1Board.status === 200, `ma worker1 /board expected 200, got ${w1Board.status}`)
    for (const adminOnly of [
      '/api/v1/config/schema?target=runtime',
      '/api/v1/infra/sandboxes',
      '/api/v1/dashboard/exact-lane-runs?run_kind=exact_output',
      '/api/v1/auth/members',
    ]) {
      const r = await apiReq(maUrl, adminOnly, { headers: maCookieHeaders(sessions.worker1, maUrl) })
      assert(r.status === 403, `ma worker1 ${adminOnly} expected 403, got ${r.status}`)
    }

    // Manage_own_provider for MA Worker: list integrations & provider-accounts, add + verify list + delete a key account.
    const w1Integs = await apiReq(maUrl, '/api/v1/auth/integrations', { headers: maCookieHeaders(sessions.worker1, maUrl) })
    assert(w1Integs.status === 200 && Array.isArray(w1Integs.json?.integrations), `ma worker1 /integrations status=${w1Integs.status}`)
    const w1Accts = await apiReq(maUrl, '/api/v1/auth/provider-accounts', { headers: maCookieHeaders(sessions.worker1, maUrl) })
    assert(w1Accts.status === 200 && Array.isArray(w1Accts.json?.provider_accounts), `ma worker1 /provider-accounts status=${w1Accts.status}`)

    const keyCapable = w1Integs.json.integrations.find(
      (i) => Array.isArray(i.connect) && i.connect.includes('key') && typeof i.integration_id === 'string',
    )
    let ownProviderDetail = `integrations=${w1Integs.json.integrations.length}`
    if (keyCapable) {
      const syntheticKey = 'rbac-e2e-dummy-key-fixture-value-0001'
      const addKey = await apiReq(maUrl, '/api/v1/setup/accounts/key', {
        method: 'POST',
        headers: maCookieHeaders(sessions.worker1, maUrl, true),
        body: { integration_id: keyCapable.integration_id, key: syntheticKey },
      })
      assert(addKey.status === 200 && typeof addKey.json?.provider_account_id === 'string', `ma worker1 POST /setup/accounts/key status=${addKey.status} body=${addKey.text}`)
      const createdId = addKey.json.provider_account_id
      const afterAdd = await apiReq(maUrl, '/api/v1/auth/provider-accounts', { headers: maCookieHeaders(sessions.worker1, maUrl) })
      assert(
        afterAdd.status === 200 && afterAdd.json.provider_accounts.some((a) => a.provider_account_id === createdId),
        'ma worker1 created key account missing from /provider-accounts',
      )
      // Admin1 cannot see worker1's personal provider account.
      const adminAccts = await apiReq(maUrl, '/api/v1/auth/provider-accounts', { headers: maCookieHeaders(sessions.admin1, maUrl) })
      assert(
        adminAccts.status === 200 && !adminAccts.json.provider_accounts.some((a) => a.provider_account_id === createdId),
        'ma admin1 leaked worker1 personal provider account',
      )
      const delKey = await apiReq(maUrl, `/api/v1/setup/accounts/key/${encodeURIComponent(createdId)}`, {
        method: 'DELETE',
        headers: maCookieHeaders(sessions.worker1, maUrl, true),
      })
      assert(delKey.status === 200 && delKey.json?.removed === true, `ma worker1 DELETE /setup/accounts/key status=${delKey.status}`)
      ownProviderDetail += ` key_crud=${keyCapable.integration_id}`
    }

    // PAT without CanAdmin: even an Admin's PAT is denied CanAdmin on bridged routes and SSE.
    const adminPatHdr = { Authorization: `Bearer ${pats.admin1}` }
    const adminPatWho = await apiReq(maUrl, '/api/v1/auth/whoami', { headers: adminPatHdr })
    assert(adminPatWho.status === 200 && adminPatWho.json?.role === 'admin' && adminPatWho.json?.binding?.kind === 'pat', `ma admin1_pat whoami=${adminPatWho.text}`)
    const adminPatBoard = await apiReq(maUrl, '/api/v1/dashboard/board', { headers: adminPatHdr })
    assert(adminPatBoard.status === 200, `ma admin1_pat /board expected 200, got ${adminPatBoard.status}`)
    for (const patForbidden of [
      '/api/v1/config/schema?target=runtime',
      '/api/v1/infra/sandboxes',
      '/api/v1/dashboard/exact-lane-runs?run_kind=exact_output',
      '/api/v1/auth/events',
    ]) {
      const r = await apiReq(maUrl, patForbidden, { headers: adminPatHdr })
      assert(r.status === 403, `ma admin1_pat ${patForbidden} expected 403, got ${r.status}`)
    }
    const adminPatMembers = await apiReq(maUrl, '/api/v1/auth/members', { headers: adminPatHdr })
    assert(adminPatMembers.status === 401, `ma admin1_pat /members expected 401 (cookie-only), got ${adminPatMembers.status}`)

    // Worker PAT with manage_own_provider vs read_state-only PAT.
    const wPatProvHdr = { Authorization: `Bearer ${pats.worker_provider}` }
    const wPatProvRes = await apiReq(maUrl, '/api/v1/auth/provider-accounts', { headers: wPatProvHdr })
    assert(wPatProvRes.status === 200, `ma worker_pat_provider /provider-accounts expected 200, got ${wPatProvRes.status}`)
    const wPatProvAdmin = await apiReq(maUrl, '/api/v1/config/schema?target=runtime', { headers: wPatProvHdr })
    assert(wPatProvAdmin.status === 403, `ma worker_pat_provider /config/schema expected 403, got ${wPatProvAdmin.status}`)

    const wPatRoHdr = { Authorization: `Bearer ${pats.worker_readonly}` }
    const wPatRoWho = await apiReq(maUrl, '/api/v1/auth/whoami', { headers: wPatRoHdr })
    assert(wPatRoWho.status === 200, `ma worker_pat_readonly /whoami expected 200, got ${wPatRoWho.status}`)
    const wPatRoProv = await apiReq(maUrl, '/api/v1/auth/provider-accounts', { headers: wPatRoHdr })
    assert(wPatRoProv.status === 403, `ma worker_pat_readonly /provider-accounts expected 403, got ${wPatRoProv.status}`)

    // Service credential: whoami=200 (service), denied own-provider, own-keepers, and admin.
    const svcHdr = { Authorization: `Bearer ${serviceToken}` }
    const svcWho = await apiReq(maUrl, '/api/v1/auth/whoami', { headers: svcHdr })
    assert(svcWho.status === 200 && svcWho.json?.principal?.kind === 'service', `ma service /whoami=${svcWho.text}`)
    for (const svcForbidden of ['/api/v1/auth/provider-accounts', '/api/v1/auth/keepers', '/api/v1/config/schema?target=runtime']) {
      const r = await apiReq(maUrl, svcForbidden, { headers: svcHdr })
      assert(r.status === 403, `ma service ${svcForbidden} expected 403, got ${r.status}`)
    }

    recordPass('http.multi_account', `csrf=403 ${ownProviderDetail} pat_no_admin=403 svc_isolated=403`)
  }
}

const pageAuditors = new WeakMap()

function attachNetworkAuditor(page, allowExpected = () => false) {
  const unexpected = []
  const seen = []
  const pageErrors = []
  const inFlight = new Set()

  const isEventStream = (url) =>
    url.pathname === '/api/v1/auth/events'
    || url.pathname === '/sse'
    || url.pathname.endsWith('/events')
    || url.pathname.includes('/stream')

  page.on('pageerror', (err) => {
    pageErrors.push(err.message || String(err))
  })
  page.on('request', (req) => {
    try {
      const url = new URL(req.url())
      const isApi = url.pathname.startsWith('/api/') || url.pathname.startsWith('/auth/') || url.pathname === '/health'
      if (isApi && !isEventStream(url)) {
        inFlight.add(req)
      }
    } catch {
      // Ignore non-HTTP URLs.
    }
  })
  page.on('requestfinished', (req) => {
    inFlight.delete(req)
  })
  page.on('requestfailed', (req) => {
    inFlight.delete(req)
  })
  page.on('response', (response) => {
    const req = response.request()
    const url = new URL(response.url())
    const path = `${url.pathname}${url.search}`
    const status = response.status()
    const isApi = url.pathname.startsWith('/api/') || url.pathname.startsWith('/auth/') || url.pathname === '/health'
    if (isApi) {
      seen.push({ method: req.method(), path, pathname: url.pathname, status })
    }
    if (status >= 400 && !allowExpected({ method: req.method(), path, pathname: url.pathname, status })) {
      unexpected.push(`${req.method()} ${path} -> ${status}`)
    }
  })

  async function waitForApiIdle(timeoutMs = 8_000) {
    const deadline = Date.now() + timeoutMs
    let quietSince = null
    while (Date.now() < deadline) {
      if (inFlight.size === 0) {
        if (quietSince === null) quietSince = Date.now()
        if (Date.now() - quietSince >= 150) return
      } else {
        quietSince = null
      }
      await new Promise((r) => setTimeout(r, 30))
    }
  }

  const auditor = {
    seen,
    unexpected,
    pageErrors,
    waitForApiIdle,
    assertClean(label) {
      assert(pageErrors.length === 0, `${label}: uncaught page errors: ${JSON.stringify(pageErrors)}`)
      assert(
        unexpected.length === 0,
        `${label}: unexpected >=400 HTTP responses (${unexpected.length}): ${unexpected.join('; ')}`,
      )
    },
  }
  pageAuditors.set(page, auditor)
  return auditor
}

async function waitForDashboardSettled(page) {
  await page.locator('[data-testid="route-gate-probing"]').waitFor({ state: 'detached', timeout: 15_000 }).catch(() => {})
  const auditor = pageAuditors.get(page)
  if (auditor) {
    await auditor.waitForApiIdle(8_000)
  }
}

async function navHash(page, hashPath) {
  await page.evaluate((target) => {
    window.location.hash = target
  }, `#${hashPath}`)
  await waitForDashboardSettled(page)
}

async function saveShot(page, filename, summary) {
  if (!screenshotDir) return
  const absPath = join(screenshotDir, filename)
  await page.screenshot({ path: absPath, fullPage: false })
  screenshots.push({ path: absPath, summary })
  process.stdout.write(`Screenshot: ${absPath} | ${summary}\n`)
}

async function verifyLanesAndExact(page, { expectLaneConfigLocked, expectExactLocked }) {
  await navHash(page, '/runtime/lanes')
  await page.locator('[data-testid="lane-config-toggle"]').click()
  await page.locator('[data-testid="lane-config-body"]').waitFor({ timeout: 10_000 })
  if (expectLaneConfigLocked) {
    await page.locator('[data-testid="lane-config-admin-locked"]').waitFor({ timeout: 10_000 })
  } else {
    assert(
      await page.locator('[data-testid="lane-config-admin-locked"]').count() === 0,
      'lane-config should be unlocked for admin',
    )
  }
  await page.getByRole('tab', { name: 'Exact Output' }).click()
  await waitForDashboardSettled(page)
  if (expectExactLocked) {
    await page.locator('[data-testid="exact-runs-admin-locked"]').waitFor({ timeout: 10_000 })
  } else {
    assert(
      await page.locator('[data-testid="exact-runs-admin-locked"]').count() === 0,
      'exact output should be unlocked for admin',
    )
  }
}

async function addMaSessionCookie(context, session) {
  // CDP Storage.setCookies validates __Host- Secure cookies against an https://
  // URL while Chromium sends host-only Secure cookies to loopback http://127.0.0.1
  // per RFC 6265bis trustworthy-origin rules.
  await context.addCookies([
    {
      name: session.cookie_name,
      value: session.cookie_value,
      url: 'https://127.0.0.1/',
      httpOnly: true,
      secure: true,
      sameSite: 'Strict',
    },
  ])
}

async function runPlaywrightChecks() {
  process.stdout.write('\n=== Phase 2: Live Playwright Dashboard RBAC E2E ===\n')
  const browser = await chromium.launch({ headless: true })
  const viewport = { width: 1400, height: 920 }

  try {
    // Scenario 1: Single-user auth_off
    {
      const context = await browser.newContext({ viewport })
      const page = await context.newPage()
      const audit = attachNetworkAuditor(page)
      try {
        await page.goto(`${suOffUrl}/dashboard/#/pulse`, { waitUntil: 'domcontentloaded' })
        await waitForDashboardSettled(page)
        assert(await page.locator('[data-testid="route-gate-auth-required"]').count() === 0, 'su_off must not show auth gate')

        // Infra is accessible in SU auth_off (su_read_ma_admin).
        await navHash(page, '/infra/sandboxes')
        assert(await page.locator('[data-testid="route-gate-admin-only"]').count() === 0, 'su_off infra should mount')

        // Settings requires Token_permission CanAdmin (enabled && require_token), so auth_off gates it cleanly with zero 401.
        await navHash(page, '/settings')
        await page.locator('[data-testid="route-gate-admin-only"]').waitFor({ timeout: 10_000 })
        assert(
          !audit.seen.some((r) => r.pathname === '/api/v1/config/schema'),
          'su_off must not speculatively fetch /api/v1/config/schema',
        )

        // Wiki write & Lanes admin/exact-output are locked cleanly when token-admin is off.
        await navHash(page, '/knowledge/wiki')
        assert(await page.getByRole('button', { name: '+ 새 페이지' }).count() === 0, 'su_off wiki write should be gated')

        await verifyLanesAndExact(page, { expectLaneConfigLocked: true, expectExactLocked: true })

        audit.assertClean('playwright.su_off')
        recordPass('playwright.su_off', `requests=${audit.seen.length} unexpected_errors=0`)
      } finally {
        await context.close()
      }
    }

    // Scenario 2: Single-user Admin token (via ?token= URL scrub + full admin unlock)
    {
      const context = await browser.newContext({ viewport })
      const page = await context.newPage()
      const audit = attachNetworkAuditor(page)
      try {
        const adminTok = manifest.su_auth.tokens.admin
        await page.goto(`${suAuthUrl}/dashboard/?token=${encodeURIComponent(adminTok)}#/settings`, {
          waitUntil: 'domcontentloaded',
        })
        await page.locator('[data-testid="settings-workspace"]').waitFor({ timeout: 15_000 })
        await waitForDashboardSettled(page)
        // Verify ?token= was scrubbed from URL history.
        const currentSearch = await page.evaluate(() => window.location.search)
        assert(!currentSearch.includes('token='), `URL ?token= was not scrubbed: ${currentSearch}`)
        assert(
          audit.seen.some((r) => r.pathname === '/api/v1/config/schema' && r.status === 200),
          'su_admin did not load /api/v1/config/schema 200',
        )
        await saveShot(page, '01-su-admin-settings.png', 'Single-user Admin token: Settings config tree unlocked (0 errors)')

        await navHash(page, '/knowledge/wiki')
        await page.getByRole('button', { name: '+ 새 페이지' }).waitFor({ timeout: 10_000 })

        await verifyLanesAndExact(page, { expectLaneConfigLocked: false, expectExactLocked: false })

        await navHash(page, '/infra/sandboxes')
        assert(await page.locator('[data-testid="route-gate-admin-only"]').count() === 0, 'su_admin infra should unlock')

        audit.assertClean('playwright.su_admin')
        recordPass('playwright.su_admin', `requests=${audit.seen.length} settings+wiki+lanes+infra unlocked`)
      } finally {
        await context.close()
      }
    }

    // Scenario 3: Single-user Worker token
    {
      const context = await browser.newContext({ viewport })
      const page = await context.newPage()
      const audit = attachNetworkAuditor(page)
      try {
        const workerTok = manifest.su_auth.tokens.worker
        await page.goto(`${suAuthUrl}/dashboard/?token=${encodeURIComponent(workerTok)}#/settings`, {
          waitUntil: 'domcontentloaded',
        })
        await page.locator('[data-testid="route-gate-admin-only"]').waitFor({ timeout: 15_000 })
        await waitForDashboardSettled(page)
        assert(
          !audit.seen.some((r) => r.pathname === '/api/v1/config/schema'),
          'su_worker speculatively called /api/v1/config/schema',
        )
        await saveShot(page, '02-su-worker-settings-locked.png', 'Single-user Worker token: Settings route gated (zero 403 storm)')

        // SU Worker CAN read Infra (su_read_ma_admin), while Wiki write / Lanes admin / Exact Output / Provider Inventory are locked.
        await navHash(page, '/infra/sandboxes')
        assert(await page.locator('[data-testid="route-gate-admin-only"]').count() === 0, 'su_worker infra should be readable')

        await navHash(page, '/knowledge/wiki')
        assert(await page.getByRole('button', { name: '+ 새 페이지' }).count() === 0, 'su_worker wiki write must be locked')

        await verifyLanesAndExact(page, { expectLaneConfigLocked: true, expectExactLocked: true })
        assert(
          !audit.seen.some((r) => r.pathname === '/api/v1/dashboard/exact-lane-runs'),
          'su_worker speculatively called /api/v1/dashboard/exact-lane-runs',
        )
        await saveShot(page, '03-su-worker-lanes-locked.png', 'Single-user Worker token: Lanes config and Exact Output locked cleanly')

        await navHash(page, '/runtime/quotas')
        await page.locator('[data-testid="provider-inventory-toggle"]').click()
        await page.locator('[data-testid="provider-inventory-admin-locked"]').waitFor({ timeout: 10_000 })

        audit.assertClean('playwright.su_worker')
        recordPass('playwright.su_worker', `requests=${audit.seen.length} locked=settings+wiki_write+lanes+exact+provider_inv`)
      } finally {
        await context.close()
      }
    }

    // Scenario 4: Single-user Player token
    {
      const context = await browser.newContext({ viewport })
      const page = await context.newPage()
      const audit = attachNetworkAuditor(page)
      try {
        const playerTok = manifest.su_auth.tokens.player
        await page.goto(`${suAuthUrl}/dashboard/?token=${encodeURIComponent(playerTok)}#/pulse`, {
          waitUntil: 'domcontentloaded',
        })
        await page.locator('[data-testid="route-gate-role-restricted"]').waitFor({ timeout: 15_000 })
        await waitForDashboardSettled(page)
        await saveShot(page, '04-su-player-restricted.png', 'Single-user Player token: member workspace restricted (zero 403 storm)')

        await navHash(page, '/work/goals')
        await page.locator('[data-testid="route-gate-role-restricted"]').waitFor({ timeout: 10_000 })

        await navHash(page, '/infra/sandboxes')
        await page.locator('[data-testid="route-gate-admin-only"]').waitFor({ timeout: 10_000 })

        await navHash(page, '/settings')
        await page.locator('[data-testid="route-gate-admin-only"]').waitFor({ timeout: 10_000 })

        await navHash(page, '/account')
        await page.locator('[data-testid="account-local-operator"]').waitFor({ timeout: 10_000 })

        audit.assertClean('playwright.su_player')
        recordPass('playwright.su_player', `requests=${audit.seen.length} role_restricted+admin_only verified`)
      } finally {
        await context.close()
      }
    }

    // Scenario 5: Single-user missing/bad token on strict loopback + non-strict bad token + live SU Admin -> Worker swap purge
    {
      // 5a. Non-strict loopback with bad token: /shell returns 200 token_valid=false -> Dashboard rejects fail-closed as auth_required.
      const nsContext = await browser.newContext({ viewport })
      const nsPage = await nsContext.newPage()
      const nsAudit = attachNetworkAuditor(nsPage)
      try {
        await nsPage.goto(`${suAuthUrl}/dashboard/?token=invalid-loopback-token-0000#/pulse`, {
          waitUntil: 'domcontentloaded',
        })
        await nsPage.locator('[data-testid="route-gate-auth-required"]').waitFor({ timeout: 15_000 })
        await waitForDashboardSettled(nsPage)
        nsAudit.assertClean('playwright.su_loopback_bad_token')
      } finally {
        await nsContext.close()
      }

      // 5b. Strict loopback missing/bad token + live SU Admin -> Worker swap purge
      const context = await browser.newContext({ viewport })
      const page = await context.newPage()
      // Only GET /api/v1/dashboard/shell 401 is expected during missing/bad token probes.
      const audit = attachNetworkAuditor(
        page,
        (r) => r.pathname === '/api/v1/dashboard/shell' && r.status === 401,
      )
      try {
        await page.goto(`${suStrictUrl}/dashboard/#/pulse`, { waitUntil: 'domcontentloaded' })
        await page.locator('[data-testid="route-gate-auth-required"]').waitFor({ timeout: 15_000 })
        await waitForDashboardSettled(page)
        assert(
          !audit.seen.some((r) => r.pathname === '/api/v1/dashboard/dev-token'),
          'strict loopback must not probe /api/v1/dashboard/dev-token',
        )
        await saveShot(page, '05-su-missing-token-gate.png', 'Single-user strict loopback missing token: Auth Required gate')

        // Enter bad token in Account panel -> explicit error alert.
        await navHash(page, '/account')
        const tokenInput = page.locator('[data-testid="account-local-operator"] input[type="password"]')
        await tokenInput.fill('invalid-token-smoke-1234')
        await page.getByRole('button', { name: 'Apply & Verify' }).click()
        await page.locator('[data-testid="local-token-error"]').waitFor({ timeout: 10_000 })

        // Apply valid Admin token -> unlock Settings -> then swap in-place to Worker token -> Settings immediately purged.
        await tokenInput.fill(manifest.su_strict.tokens.admin)
        await page.getByRole('button', { name: 'Apply & Verify' }).click()
        await page.getByText('Bearer Active').waitFor({ timeout: 10_000 })
        await navHash(page, '/settings')
        await page.locator('[data-testid="settings-workspace"]').waitFor({ timeout: 10_000 })

        await navHash(page, '/account')
        await tokenInput.fill(manifest.su_strict.tokens.worker)
        await page.getByRole('button', { name: 'Apply & Verify' }).click()
        await page.getByText('Bearer Active').waitFor({ timeout: 10_000 })
        await navHash(page, '/settings')
        await page.locator('[data-testid="route-gate-admin-only"]').waitFor({ timeout: 10_000 })
        assert(await page.locator('[data-testid="settings-workspace"]').count() === 0, 'su admin->worker swap did not purge settings')

        audit.assertClean('playwright.su_missing_bad_and_swap')
        recordPass('playwright.su_missing_bad_and_swap', 'loopback_bad_tok + strict_missing_gate + bad_token_err + su_admin_to_worker_purge')
      } finally {
        await context.close()
      }
    }

    // Scenario 6: Multi-account signed_out
    {
      const context = await browser.newContext({ viewport })
      const page = await context.newPage()
      const audit = attachNetworkAuditor(
        page,
        (r) => r.pathname === '/auth/session' && r.status === 401,
      )
      try {
        await page.goto(`${maUrl}/dashboard/#/pulse`, { waitUntil: 'domcontentloaded' })
        await page.locator('[data-testid="route-gate-auth-required"]').waitFor({ timeout: 15_000 })
        await waitForDashboardSettled(page)

        await navHash(page, '/account')
        await page.locator('[data-testid="multi-account-signin-gate"]').waitFor({ timeout: 10_000 })
        await saveShot(page, '06-ma-signed-out-gate.png', 'Multi-account signed out: Sign-In gate (zero speculative API storms)')

        audit.assertClean('playwright.ma_signed_out')
        recordPass('playwright.ma_signed_out', `requests=${audit.seen.length} only /auth/session=401`)
      } finally {
        await context.close()
      }
    }

    // Scenario 7: Multi-account Worker session (locked Settings/Infra/Members/Lanes/Exact/Wiki write + working Manage_own_provider)
    {
      const w1 = manifest.ma.sessions.worker1
      const context = await browser.newContext({ viewport })
      await addMaSessionCookie(context, w1)
      const page = await context.newPage()
      const audit = attachNetworkAuditor(page)
      try {
        await page.goto(`${maUrl}/dashboard/#/pulse`, { waitUntil: 'domcontentloaded' })
        await waitForDashboardSettled(page)
        assert(await page.locator('[data-testid="route-gate-auth-required"]').count() === 0, 'ma_worker should be signed in')

        await navHash(page, '/settings')
        await page.locator('[data-testid="route-gate-admin-only"]').waitFor({ timeout: 10_000 })

        // Unlike SU Worker, MA Worker is blocked from Infra.
        await navHash(page, '/infra/sandboxes')
        await page.locator('[data-testid="route-gate-admin-only"]').waitFor({ timeout: 10_000 })
        await saveShot(page, '07-ma-worker-infra-locked.png', 'Multi-account Worker: Infra locked (Admin-only in MA bridge)')

        await navHash(page, '/account/members')
        await page
          .locator('[data-testid="route-gate-admin-only"], [data-testid="account-admin-locked"]')
          .first()
          .waitFor({ timeout: 10_000 })
        assert(await page.locator('[data-testid="account-members-tab"]').count() === 0, 'ma_worker must not mount account-members-tab')

        await navHash(page, '/knowledge/wiki')
        assert(await page.getByRole('button', { name: '+ 새 페이지' }).count() === 0, 'ma_worker wiki write must be locked')

        await verifyLanesAndExact(page, { expectLaneConfigLocked: true, expectExactLocked: true })

        // Manage_own_provider works for MA Worker on /runtime/quotas without touching /api/v1/setup/inventory.
        await navHash(page, '/runtime/quotas')
        await page.locator('[data-testid="provider-inventory-toggle"]').click()
        await page.locator('[data-testid="provider-inventory-body"]').waitFor({ timeout: 10_000 })
        assert(await page.locator('[data-testid="provider-inventory-admin-locked"]').count() === 0, 'ma_worker own-provider must NOT be admin-locked')
        assert(
          audit.seen.some((r) => r.pathname === '/api/v1/auth/provider-accounts' && r.status === 200),
          'ma_worker did not fetch /api/v1/auth/provider-accounts 200',
        )
        assert(
          audit.seen.some((r) => r.pathname === '/api/v1/auth/integrations' && r.status === 200),
          'ma_worker did not fetch /api/v1/auth/integrations 200',
        )
        assert(
          !audit.seen.some((r) => r.pathname === '/api/v1/setup/inventory'),
          'ma_worker must never call single-user /api/v1/setup/inventory',
        )
        await saveShot(page, '08-ma-worker-own-provider.png', 'Multi-account Worker: Manage_own_provider panel loaded (200 OK)')

        // Multi-account Personal Keepers UI: create keeper, assign personal runtime,
        // start + read + delete conversation, and verify SU-only tabs emit zero 404s.
        const workerRuntimeId = manifest.ma.worker_runtime_id
        await navHash(page, '/keepers')
        await page.locator('[data-testid="ma-personal-keepers-workspace"]').waitFor({ timeout: 10_000 })
        await page.locator('[data-testid="ma-create-keeper-btn"]').click()
        await page.locator('[data-testid="ma-create-keeper-modal"]').waitFor({ timeout: 10_000 })
        await page.locator('[data-testid="ma-create-keeper-modal"] input[type="text"]').fill('ma-worker-keeper-1')
        await page.locator('[data-testid="ma-create-keeper-submit"]').click()
        await page.locator('[data-keeper="ma-worker-keeper-1"]').waitFor({ timeout: 10_000 })
        await page.locator('[data-keeper="ma-worker-keeper-1"]').click()
        await page.locator('[data-testid="ma-keeper-header"]').waitFor({ timeout: 10_000 })
        await page.locator('[data-testid="ma-keeper-chat"]').waitFor({ timeout: 10_000 })

        // Assign seeded personal runtime via strict-key-order POST /api/v1/auth/keepers/assign.
        await page.locator('[data-testid="ma-header-runtime-select"]').selectOption(workerRuntimeId)
        await page.locator('[data-testid="ma-header-assign-btn"]').click()
        await page.locator('[data-testid="ma-keeper-runtime-pill"]').filter({ hasText: workerRuntimeId }).waitFor({ timeout: 10_000 })
        await waitForDashboardSettled(page)

        // Start a conversation (POST /api/v1/auth/keepers/conversation), verify rendered, then delete it.
        await page.locator('[data-testid="ma-new-conversation-btn"]').click()
        const delBtn = page.locator('[data-testid^="ma-delete-conv-"]').first()
        await delBtn.waitFor({ timeout: 10_000 })
        await saveShot(page, '11-ma-worker-personal-keepers.png', 'Multi-account Worker: Personal Keepers create, assign runtime, and conversation flow')
        await delBtn.click()
        await page.locator('[data-testid^="ma-confirm-delete-"]').first().click()
        await delBtn.waitFor({ state: 'detached', timeout: 10_000 })
        await waitForDashboardSettled(page)

        // Verify SU-only tabs show honest MA notices with zero SU /api/v1/keepers/* 404s.
        for (const tab of ['memory', 'portrait-candle', 'work-sandbox', 'config']) {
          await navHash(page, `/keepers/ma-worker-keeper-1/${tab}`)
          await page.locator('[data-testid="ma-keeper-su-only-tab"]').waitFor({ timeout: 10_000 })
        }
        assert(
          !audit.seen.some(
            (r) =>
              r.pathname === '/api/v1/keepers'
              || r.pathname.startsWith('/api/v1/keepers/')
              || r.pathname.startsWith('/api/v1/dashboard/keepers'),
          ),
          'ma_worker personal keepers must never hit single-user /api/v1/keepers* routes',
        )

        audit.assertClean('playwright.ma_worker')
        recordPass('playwright.ma_worker', `requests=${audit.seen.length} infra/settings/members locked + own_provider=200 + personal_keepers CRUD`)
      } finally {
        await context.close()
      }
    }

    // Scenario 8: Multi-account Admin session + LIVE in-place Admin -> Worker demotion cache purge
    {
      const a1 = manifest.ma.sessions.admin1
      const a2 = manifest.ma.sessions.admin2
      const context = await browser.newContext({ viewport })
      await addMaSessionCookie(context, a2)
      const page = await context.newPage()
      let demotionStarted = false
      // After demotion starts, a single 403 on an admin endpoint is expected to trigger scheduleForbiddenRoleRecheck.
      const audit = attachNetworkAuditor(
        page,
        (r) => demotionStarted && r.status === 403 && r.pathname.startsWith('/api/v1/'),
      )
      try {
        // 1. Admin2 loads Admin-only surfaces cleanly.
        await page.goto(`${maUrl}/dashboard/#/account/members`, { waitUntil: 'domcontentloaded' })
        await page.locator('[data-testid="account-members-tab"]').waitFor({ timeout: 15_000 })
        await waitForDashboardSettled(page)
        const membersText = await page.locator('[data-testid="account-members-tab"]').innerText()
        assert(membersText.includes(a2.user_id), 'ma_admin2 members tab missing admin2 row')
        await saveShot(page, '09-ma-admin-members.png', 'Multi-account Admin: Members & Admin lifecycle unlocked')

        await navHash(page, '/infra/sandboxes')
        assert(await page.locator('[data-testid="route-gate-admin-only"]').count() === 0, 'ma_admin2 infra should unlock')

        await navHash(page, '/settings')
        await page.locator('[data-testid="settings-workspace"]').waitFor({ timeout: 15_000 })
        await waitForDashboardSettled(page)

        // Return to Members tab (with Settings schema already cached) and verify zero errors before demotion.
        await navHash(page, '/account/members')
        await page.locator('[data-testid="account-members-tab"]').waitFor({ timeout: 10_000 })
        audit.assertClean('playwright.ma_admin_before_demotion')

        // 2. Admin1 demotes Admin2 -> Member in-place via live server revoke-admin endpoint.
        demotionStarted = true
        const revokeRes = await apiReq(maUrl, `/api/v1/auth/members/${encodeURIComponent(a2.user_id)}/revoke-admin`, {
          method: 'POST',
          headers: maCookieHeaders(a1, maUrl, true),
          body: { cause: 'operational' },
        })
        assert(
          revokeRes.status === 200 && revokeRes.json?.role === 'member',
          `live revoke-admin failed: status=${revokeRes.status} body=${revokeRes.text}`,
        )

        // 3. Click the real Refresh button on Members tab -> server returns 403 -> transport.ts triggers
        // scheduleForbiddenRoleRecheck -> GET /api/v1/auth/whoami returns role=worker -> sessionEpoch bumps
        // and cached admin UI purges in-place without page reload.
        await page.locator('[data-testid="account-members-tab"]').getByRole('button', { name: 'Refresh' }).click()
        await page
          .locator('[data-testid="route-gate-admin-only"], [data-testid="account-admin-locked"]')
          .first()
          .waitFor({ timeout: 15_000 })
        assert(
          await page.locator('[data-testid="account-members-tab"]').count() === 0,
          'ma_admin2 demotion did not purge mounted account-members-tab',
        )

        // Navigating to Settings & Infra must immediately show purged admin gates (zero cached settings-workspace).
        await navHash(page, '/settings')
        await page.locator('[data-testid="route-gate-admin-only"]').waitFor({ timeout: 10_000 })
        assert(
          await page.locator('[data-testid="settings-workspace"]').count() === 0,
          'ma_admin2 demotion leaked cached settings-workspace',
        )
        await saveShot(page, '10-ma-admin-demoted-purged.png', 'Multi-account live Admin -> Worker demotion: cached Settings purged in-place')

        await navHash(page, '/infra/sandboxes')
        await page.locator('[data-testid="route-gate-admin-only"]').waitFor({ timeout: 10_000 })

        audit.assertClean('playwright.ma_admin_demotion')
        recordPass('playwright.ma_admin_demotion', 'admin_unlocked -> live_revoke_admin -> 403_recheck -> in_place_purge_verified')
      } finally {
        await context.close()
      }
    }
  } finally {
    await browser.close()
  }
}

async function main() {
  if (modeFilter === 'all' || modeFilter === 'http') {
    await runHttpContractChecks()
  }
  if (modeFilter === 'all' || modeFilter === 'dashboard') {
    await runPlaywrightChecks()
  }
  process.stdout.write(
    `\n[rbac-e2e] ALL CHECKS PASSED (${results.length} suites, ${screenshots.length} screenshots)\n`,
  )
}

main().catch((err) => {
  process.stderr.write(`[rbac-e2e] FAILED: ${err instanceof Error ? err.stack || err.message : String(err)}\n`)
  process.exit(1)
})
