import { afterEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchDashboardExecution: vi.fn(),
  fetchDashboardMemory: vi.fn(),
  fetchDashboardPlanning: vi.fn(),
  fetchDashboardShell: vi.fn(),
}))

const toastMocks = vi.hoisted(() => ({
  showToast: vi.fn(),
}))

const devTokenMocks = vi.hoisted(() => ({
  refreshDevTokenAfterAuthError: vi.fn(async () => true),
}))

vi.mock('./api', () => apiMocks)
vi.mock('./api/dashboard-hot', () => ({
  fetchDashboardShell: apiMocks.fetchDashboardShell,
}))
vi.mock('./sse', () => ({
  journal: {
    log: vi.fn(),
  },
}))
vi.mock('./components/common/toast', () => ({
  showToast: toastMocks.showToast,
}))
vi.mock('./api/dev-token', async importOriginal => ({
  ...(await importOriginal<typeof import('./api/dev-token')>()),
  refreshDevTokenAfterAuthError: devTokenMocks.refreshDevTokenAfterAuthError,
}))

afterEach(async () => {
  vi.clearAllMocks()
  vi.resetModules()
})

describe('refreshShell auth failure handling', () => {
  it('starts a fresh forced request after an older shell refresh finishes', async () => {
    let resolveFirst: ((value: Record<string, unknown>) => void) | undefined
    apiMocks.fetchDashboardShell
      .mockImplementationOnce(() => new Promise(resolve => { resolveFirst = resolve }))
      .mockResolvedValueOnce({
        generated_at: '2026-07-11T11:00:01Z',
        status: { project: 'me' },
        counts: { agents: 0, tasks: 0, keepers: 0, total_runtimes: 0 },
        auth: { enabled: true, require_token: true, token_present: false, token_valid: false },
      })

    const store = await import('./store')
    const older = store.refreshShell({ force: true })
    await vi.waitFor(() => expect(apiMocks.fetchDashboardShell).toHaveBeenCalledTimes(1))

    const afterStateChange = store.refreshShell({ force: true })
    const concurrentAfterStateChange = store.refreshShell({ force: true })
    expect(apiMocks.fetchDashboardShell).toHaveBeenCalledTimes(1)
    resolveFirst?.({
      generated_at: '2026-07-11T11:00:00Z',
      status: { project: 'me' },
      counts: { agents: 0, tasks: 0, keepers: 0, total_runtimes: 0 },
      auth: { enabled: true, require_token: true, token_present: true, token_valid: true },
    })

    await expect(older).resolves.toBe(true)
    await expect(afterStateChange).resolves.toBe(true)
    await expect(concurrentAfterStateChange).resolves.toBe(true)
    expect(apiMocks.fetchDashboardShell).toHaveBeenCalledTimes(2)
    expect(store.shellAuthSummary.value?.token_present).toBe(false)
    expect(store.shellAuthSummary.value?.token_valid).toBe(false)
  })

  it('does not let a full waiter join a light follow-up', async () => {
    const shell = (light: boolean) => ({
      generated_at: light ? '2026-07-11T11:00:01Z' : '2026-07-11T11:00:02Z',
      status: { project: 'me' },
      counts: { agents: 0, tasks: 0, keepers: 0, total_runtimes: 0 },
      auth: { enabled: false, require_token: false, token_present: false, token_valid: false },
    })
    let resolveFirst: ((value: Record<string, unknown>) => void) | undefined
    apiMocks.fetchDashboardShell
      .mockImplementationOnce(() => new Promise(resolve => { resolveFirst = resolve }))
      .mockImplementation((opts?: { light?: boolean }) =>
        Promise.resolve(shell(opts?.light === true)))

    const store = await import('./store')
    const first = store.refreshShell({ force: true })
    await vi.waitFor(() => expect(apiMocks.fetchDashboardShell).toHaveBeenCalledTimes(1))

    // The light waiter registers first, so it reaches follow-up scheduling
    // first once the in-flight request resolves.
    const lightWaiter = store.refreshShell({ force: true, light: true })
    const fullWaiter = store.refreshShell({ force: true })

    resolveFirst?.(shell(false))
    await expect(first).resolves.toBe(true)
    await expect(lightWaiter).resolves.toBe(true)
    await expect(fullWaiter).resolves.toBe(true)

    const fullFetches = apiMocks.fetchDashboardShell.mock.calls.filter(
      ([opts]) => (opts as { light?: boolean } | undefined)?.light !== true)
    // One for the original request, one the full waiter must have fetched for
    // itself instead of joining the light follow-up.
    expect(fullFetches.length).toBe(2)
  })

  it('clears canonical actor and auth summary when shell refresh fails', async () => {
    apiMocks.fetchDashboardShell.mockRejectedValue(new Error('network down'))

    const sessionActor = await import('./lib/dashboard-session-actor')
    const store = await import('./store')

    sessionActor.setCanonicalDashboardActor('codex')
    store.shellAuthSummary.value = {
      enabled: true,
      require_token: true,
      token_present: true,
      requested_agent: 'dashboard',
      effective_agent: 'codex',
      effective_role: 'worker',
      token_valid: true,
      token_agent: 'codex',
      auth_error_code: null,
      auth_error_detail: null,
      can_keeper_msg: true,
      keeper_msg_error: null,
    }

    const refreshed = await store.refreshShell({ force: true })

    expect(refreshed).toBe(false)
    expect(sessionActor.currentCanonicalDashboardActor()).toBeNull()
    expect(store.shellAuthSummary.value).toBeNull()
    expect(toastMocks.showToast).toHaveBeenCalledWith(
      '서버 연결 실패 — 데이터를 불러올 수 없습니다',
      'error',
      6000,
    )
  })

  it('preserves request-bound auth when hydrating a pushed shell slice', async () => {
    const sessionActor = await import('./lib/dashboard-session-actor')
    const store = await import('./store')

    const verifiedAuth = {
      enabled: true,
      require_token: true,
      token_present: true,
      requested_agent: 'dashboard',
      effective_agent: 'dashboard',
      effective_role: 'admin',
      token_valid: true,
      token_agent: 'dashboard',
      auth_error_code: null,
      auth_error_detail: null,
      can_keeper_msg: true,
      keeper_msg_error: null,
    } as const

    sessionActor.setCanonicalDashboardActor('dashboard')
    store.shellAuthSummary.value = verifiedAuth

    store.hydrateShellSnapshot(
      {
        generated_at: '2026-06-04T13:26:17Z',
        status: { project: 'me' },
        counts: { agents: 0, tasks: 1, keepers: 1, total_runtimes: 1 },
        auth: {
          enabled: true,
          require_token: true,
          token_present: false,
          token_valid: false,
          effective_agent: 'dashboard',
          effective_role: null,
          auth_error_code: 'missing_token',
          auth_error_detail: 'Authentication required',
          can_keeper_msg: false,
          keeper_msg_error: 'Authentication required',
        },
      } as never,
      { light: true, preserveAuth: true },
    )

    expect(store.shellAuthSummary.value).toBe(verifiedAuth)
    expect(sessionActor.currentCanonicalDashboardActor()).toBe('dashboard')
  })
})

/* The server keeps the loopback read contract available to an unauthenticated
   caller, so a rejected credential comes back as HTTP 200 with
   `token_valid: false` and a typed `auth_error_code` in the body. The MCP
   client only recovers from the auth envelope of a *failed* call, so before
   this wiring a tab whose traffic was the shell poll re-sent the same
   rejected token indefinitely — measured every 6 minutes across two server
   restarts on 2026-08-12. */
describe('rejected shell credential recovery', () => {
  const rejected = {
    enabled: true,
    require_token: true,
    token_present: true,
    token_valid: false,
    token_agent: null,
    requested_agent: null,
    effective_agent: null,
    effective_role: null,
    auth_error_code: 'invalid_token',
    auth_error_detail: '[AuthError] Invalid token: Token mismatch',
    can_keeper_msg: false,
    keeper_msg_error: '[AuthError] Invalid token: Token mismatch',
  } as const

  function shellBody(auth: Record<string, unknown>) {
    return {
      generated_at: '2026-08-12T14:02:00Z',
      status: { project: 'me' },
      counts: { agents: 0, tasks: 0, keepers: 0, total_runtimes: 0 },
      auth,
    } as never
  }

  it('asks for a fresh dev token and forwards the typed rejection code', async () => {
    const store = await import('./store')
    store.hydrateShellSnapshot(shellBody(rejected), { light: true })
    expect(devTokenMocks.refreshDevTokenAfterAuthError).toHaveBeenCalledWith('invalid_token')
  })

  it('reaches the same recovery through a shell refresh response', async () => {
    apiMocks.fetchDashboardShell.mockResolvedValueOnce(shellBody(rejected))
    const store = await import('./store')
    await store.refreshShell({ force: true })
    expect(devTokenMocks.refreshDevTokenAfterAuthError).toHaveBeenCalledWith('invalid_token')
  })

  it('leaves an accepted credential alone', async () => {
    const store = await import('./store')
    store.hydrateShellSnapshot(
      shellBody({ ...rejected, token_valid: true, auth_error_code: null, auth_error_detail: null }),
      { light: true },
    )
    expect(devTokenMocks.refreshDevTokenAfterAuthError).not.toHaveBeenCalled()
  })

  /* No stored credential is the pre-bootstrap state, not a rejection —
     `ensureDevToken` mints the first token there. Refreshing on it would
     race the bootstrap that is already in flight. */
  it('does not treat a missing credential as a rejection', async () => {
    const store = await import('./store')
    store.hydrateShellSnapshot(
      shellBody({ ...rejected, token_present: false, auth_error_code: 'missing_token' }),
      { light: true },
    )
    expect(devTokenMocks.refreshDevTokenAfterAuthError).not.toHaveBeenCalled()
  })

  /* `preserveAuth` callers are explicitly not reporting on the credential —
     they carry a stale auth slice forward, so acting on it would refresh from
     data the caller already disclaimed. */
  it('stays out of preserveAuth hydration', async () => {
    const store = await import('./store')
    store.hydrateShellSnapshot(shellBody(rejected), { light: true, preserveAuth: true })
    expect(devTokenMocks.refreshDevTokenAfterAuthError).not.toHaveBeenCalled()
  })
})
