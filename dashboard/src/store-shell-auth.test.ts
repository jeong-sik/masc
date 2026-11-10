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
  recoverFromRejectedCredential: vi.fn(async (_rejection: { token: string; authErrorCode: string | undefined }): Promise<void> => {}),
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
  recoverFromRejectedCredential: devTokenMocks.recoverFromRejectedCredential,
}))

afterEach(async () => {
  vi.clearAllMocks()
  vi.resetModules()
  sessionStorage.clear()
  localStorage.removeItem('masc_dashboard_agent_name')
})

describe('refreshShell auth failure handling', () => {
  it('starts a fresh forced request after an older shell refresh finishes', async () => {
    let resolveFirst: ((value: Record<string, unknown>) => void) | undefined
    apiMocks.fetchDashboardShell
      .mockImplementationOnce(() => new Promise(resolve => { resolveFirst = resolve }))
      .mockResolvedValueOnce({
        generated_at: '2026-07-11T11:00:01Z',
        status: { project: 'ws' },
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
      status: { project: 'ws' },
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
      status: { project: 'ws' },
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

  it('keeps the request actor and withdraws auth summary when the shell read fails', async () => {
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
    expect(sessionActor.currentCanonicalDashboardActor()).toBe('codex')
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
        status: { project: 'ws' },
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
      { light: true, preserveAuth: true, sentToken: null },
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
      status: { project: 'ws' },
      counts: { agents: 0, tasks: 0, keepers: 0, total_runtimes: 0 },
      auth,
    } as never
  }

  it('hands the sent token and the typed code to the credential recovery', async () => {
    const store = await import('./store')
    store.hydrateShellSnapshot(shellBody(rejected), { light: true, sentToken: 'sent-token' })
    expect(devTokenMocks.recoverFromRejectedCredential).toHaveBeenCalledWith({
      token: 'sent-token',
      authErrorCode: 'invalid_token',
    })
  })

  it('retires a managed owner once per newly observed shell rejection', async () => {
    const core = await import('./api/core')
    const actor = await import('./lib/dashboard-session-actor')
    const store = await import('./store')
    core.setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const revision = actor.managedDashboardActorRevision.peek()
    const authRevision = actor.managedDashboardAuthRevision.peek()
    const hydrate = (auth: Record<string, unknown>) => store.hydrateShellSnapshot(shellBody(auth), {
      light: true, sentToken: 'dev-token', authOwner: core.captureDashboardCredentialOwner(),
    })
    hydrate(rejected)
    expect(actor.managedDashboardActorRevision.peek()).toBe(revision + 1)
    hydrate(rejected)
    expect(actor.managedDashboardActorRevision.peek()).toBe(revision + 1)
    hydrate({ ...rejected, token_valid: true, token_agent: 'dashboard', effective_agent: 'dashboard', auth_error_code: null })
    expect(actor.managedDashboardActorRevision.peek()).toBe(revision + 2)
    expect(actor.managedDashboardRefusal.peek()).toBeNull()
    hydrate(rejected)
    expect(actor.managedDashboardActorRevision.peek()).toBe(revision + 3)
    expect(actor.managedDashboardAuthRevision.peek()).toBe(authRevision + 3)
    expect(actor.managedDashboardRefusal.peek()).toBe(core.currentStoredTokenRevision())
  })

  it('hydrates a managed shell after an unused actor hint changes during its request', async () => {
    window.history.replaceState({}, '', '/')
    const core = await import('./api/core')
    const actor = await import('./lib/dashboard-session-actor')
    const hints = await import('./lib/dashboard-actor')
    const store = await import('./store')
    core.setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const revision = actor.managedDashboardActorRevision.peek()
    let resolveShell!: (value: unknown) => void
    apiMocks.fetchDashboardShell.mockImplementationOnce(() => new Promise(resolve => { resolveShell = resolve }))
    const pending = store.refreshShell({ force: true })
    await vi.waitFor(() => expect(apiMocks.fetchDashboardShell).toHaveBeenCalledOnce())

    hints.persistDashboardActorName('alice')
    resolveShell(shellBody({ ...rejected, token_valid: true, token_agent: 'dashboard', effective_agent: 'dashboard', auth_error_code: null }))

    expect(await pending).toBe(true)
    expect(store.shellAuthSummary.peek()?.token_valid).toBe(true)
    expect(actor.currentCanonicalDashboardActor()).toBe('dashboard')
    expect(actor.managedDashboardActorRevision.peek()).toBe(revision)
  })

  it('still recovers a managed refusal if a subscriber changes an unused hint', async () => {
    window.history.replaceState({}, '', '/')
    const { effect } = await import('@preact/signals')
    const core = await import('./api/core')
    const actor = await import('./lib/dashboard-session-actor')
    const hints = await import('./lib/dashboard-actor')
    const store = await import('./store')
    core.setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const revision = core.currentStoredTokenRevision()
    const stop = effect(() => {
      if (actor.managedDashboardRefusal.value === revision) hints.persistDashboardActorName('alice')
    })
    apiMocks.fetchDashboardShell.mockResolvedValueOnce(shellBody(rejected))
    try {
      expect(await store.refreshShell({ force: true })).toBe(true)
      expect(devTokenMocks.recoverFromRejectedCredential).toHaveBeenCalledWith({
        token: 'dev-token', authErrorCode: 'invalid_token',
      })
      expect(store.shellAuthSummary.peek()?.token_valid).toBe(false)
    } finally {
      stop()
    }
  })

  it('does not recover a managed refusal after a subscriber changes the canonical actor and returns', async () => {
    const { effect } = await import('@preact/signals')
    const core = await import('./api/core')
    const actor = await import('./lib/dashboard-session-actor')
    const store = await import('./store')
    core.setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const revision = core.currentStoredTokenRevision()
    let changed = false
    const stop = effect(() => {
      if (!changed && actor.managedDashboardRefusal.value === revision) {
        changed = true
        actor.setCanonicalDashboardActor('other-actor')
        actor.setCanonicalDashboardActor(null)
      }
    })
    apiMocks.fetchDashboardShell.mockResolvedValueOnce(shellBody(rejected))
    try {
      expect(await store.refreshShell({ force: true })).toBe(false)
      expect(devTokenMocks.recoverFromRejectedCredential).not.toHaveBeenCalled()
    } finally {
      stop()
    }
  })

  it('does not hydrate an older valid shell response after the credential is refused', async () => {
    const core = await import('./api/core')
    const actor = await import('./lib/dashboard-session-actor')
    const store = await import('./store')
    core.setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    let resolveShell!: (value: unknown) => void
    apiMocks.fetchDashboardShell.mockImplementationOnce(() => new Promise(resolve => { resolveShell = resolve }))
    const pending = store.refreshShell({ force: true })
    await vi.waitFor(() => expect(apiMocks.fetchDashboardShell).toHaveBeenCalledOnce())
    actor.recordManagedCredentialRefusal(core.currentStoredTokenRevision())
    resolveShell(shellBody({ ...rejected, token_valid: true, token_agent: 'dashboard', effective_agent: 'dashboard', auth_error_code: null }))
    expect(await pending).toBe(false)
    expect(actor.currentCanonicalDashboardActor()).toBeNull()
    expect(actor.managedDashboardRefusal.peek()).toBe(core.currentStoredTokenRevision())
    expect(store.shellAuthSummary.peek()).toBeNull()
  })

  it('does not let a valid shell response erase a later refusal of the same token', async () => {
    const core = await import('./api/core')
    const actor = await import('./lib/dashboard-session-actor')
    const store = await import('./store')
    core.setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const revision = core.currentStoredTokenRevision()
    actor.recordManagedCredentialRefusal(revision)
    let resolveShell!: (value: unknown) => void
    apiMocks.fetchDashboardShell.mockImplementationOnce(() => new Promise(resolve => { resolveShell = resolve }))
    const pending = store.refreshShell({ force: true })
    await vi.waitFor(() => expect(apiMocks.fetchDashboardShell).toHaveBeenCalledOnce())
    actor.recordManagedCredentialRefusal(revision)
    resolveShell(shellBody({ ...rejected, token_valid: true, token_agent: 'dashboard', effective_agent: 'dashboard', auth_error_code: null }))
    expect(await pending).toBe(false)
    expect(actor.managedDashboardRefusal.peek()).toBe(revision)
    expect(actor.currentCanonicalDashboardActor()).toBeNull()
  })

  it('retires a delayed 401 body when a later shell verifies its token', async () => {
    const core = await import('./api/core')
    const actor = await import('./lib/dashboard-session-actor')
    const store = await import('./store')
    core.setStoredToken('dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const ownerBeforeHeader = core.captureDashboardCredentialOwner()
    const managedActor = actor.managedDashboardActorRevision.peek()
    actor.noteManagedCredentialRefusalObservation(core.currentStoredTokenRevision())
    apiMocks.fetchDashboardShell.mockResolvedValueOnce(shellBody({ ...rejected, token_valid: true,
      token_agent: 'dashboard', effective_agent: 'dashboard', auth_error_code: null }))
    expect(await store.refreshShell({ force: true })).toBe(true)
    expect(actor.currentCanonicalDashboardActor()).toBe('dashboard')
    expect(actor.managedDashboardActorRevision.peek()).toBe(managedActor + 1)
    expect(core.dashboardCredentialOwnerIsCurrent(ownerBeforeHeader)).toBe(false)
    expect(actor.managedCredentialNeedsRevalidation(core.currentStoredTokenRevision())).toBe(false)
  })

  it('does not recover or hydrate auth from a shell response for a changed credential', async () => {
    const core = await import('./api/core')
    core.setStoredToken('sent-token', { source: 'manual' })
    apiMocks.fetchDashboardShell.mockImplementationOnce(async () => {
      core.setStoredToken('token-set-during-request', { source: 'manual' })
      return shellBody(rejected)
    })
    const store = await import('./store')
    expect(await store.refreshShell({ force: true })).toBe(false)
    expect(devTokenMocks.recoverFromRejectedCredential).not.toHaveBeenCalled()
    expect(store.shellAuthSummary.value).toBeNull()
  })

  it.each(['token', 'actor'] as const)('does not hydrate an old shell response after %s changes and returns', async changed => {
    const core = await import('./api/core')
    const actor = await import('./lib/dashboard-session-actor')
    const store = await import('./store')
    core.setStoredToken('token-a', { source: 'manual' })
    actor.setCanonicalDashboardActor('actor-a')
    let resolveFirst!: (value: unknown) => void
    apiMocks.fetchDashboardShell.mockImplementationOnce(() => new Promise(resolve => { resolveFirst = resolve }))
    const pending = store.refreshShell({ force: true })
    if (changed === 'token') {
      core.setStoredToken('token-b', { source: 'manual' })
      core.setStoredToken('token-a', { source: 'manual' })
      actor.setCanonicalDashboardActor('actor-a')
    } else {
      actor.setCanonicalDashboardActor('actor-b')
      actor.setCanonicalDashboardActor('actor-a')
    }
    resolveFirst(shellBody(rejected))
    expect(await pending).toBe(false)
    expect(devTokenMocks.recoverFromRejectedCredential).not.toHaveBeenCalled()
    expect(actor.currentCanonicalDashboardActor()).toBe('actor-a')
    expect(store.shellAuthSummary.value).toBeNull()

    apiMocks.fetchDashboardShell.mockResolvedValueOnce(shellBody({
      ...rejected, token_valid: true, effective_agent: 'actor-a', auth_error_code: null,
    }))
    expect(await store.refreshShell()).toBe(true)
    expect(store.shellAuthSummary.value?.token_valid).toBe(true)
  })

  it('does not clear the new actor when an older shell request fails', async () => {
    const core = await import('./api/core')
    const actor = await import('./lib/dashboard-session-actor')
    const store = await import('./store')
    core.setStoredToken('token-a', { source: 'manual' })
    let rejectFirst!: (error: Error) => void
    apiMocks.fetchDashboardShell.mockImplementationOnce(() => new Promise((_resolve, reject) => { rejectFirst = reject }))
    const pending = store.refreshShell({ force: true })
    core.setStoredToken('token-b', { source: 'manual' })
    actor.setCanonicalDashboardActor('actor-b')
    rejectFirst(new Error('old request failed'))
    expect(await pending).toBe(false)
    expect(actor.currentCanonicalDashboardActor()).toBe('actor-b')
  })

  it('recovers a current rejected token after the shell resets its actor', async () => {
    const core = await import('./api/core')
    const actor = await import('./lib/dashboard-session-actor')
    const actualRecovery = await vi.importActual<typeof import('./api/dev-token')>('./api/dev-token')
    devTokenMocks.recoverFromRejectedCredential.mockImplementationOnce(actualRecovery.recoverFromRejectedCredential)
    const store = await import('./store')
    core.setStoredToken('token-a', { source: 'manual' })
    actor.setCanonicalDashboardActor('actor-a')
    apiMocks.fetchDashboardShell.mockResolvedValueOnce(shellBody(rejected))
    expect(await store.refreshShell({ force: true })).toBe(true)
    await vi.waitFor(() => expect(core.getStoredToken()).toBeNull())
  })

  it('leaves an accepted credential alone', async () => {
    const store = await import('./store')
    store.hydrateShellSnapshot(
      shellBody({ ...rejected, token_valid: true, auth_error_code: null, auth_error_detail: null }),
      { light: true, sentToken: 'sent-token' },
    )
    expect(devTokenMocks.recoverFromRejectedCredential).not.toHaveBeenCalled()
  })

  /* No stored credential is the pre-bootstrap state, not a rejection —
     `ensureDevToken` mints the first token there. Refreshing on it would
     race the bootstrap that is already in flight. */
  it('does not treat a missing credential as a rejection', async () => {
    const store = await import('./store')
    store.hydrateShellSnapshot(
      shellBody({ ...rejected, token_present: false, auth_error_code: 'missing_token' }),
      { light: true, sentToken: null },
    )
    expect(devTokenMocks.recoverFromRejectedCredential).not.toHaveBeenCalled()
  })

  /* `preserveAuth` callers are explicitly not reporting on the credential —
     they carry a stale auth slice forward, so acting on it would refresh from
     data the caller already disclaimed. */
  it('stays out of preserveAuth hydration', async () => {
    const store = await import('./store')
    store.hydrateShellSnapshot(shellBody(rejected), { light: true, preserveAuth: true, sentToken: 'sent-token' })
    expect(devTokenMocks.recoverFromRejectedCredential).not.toHaveBeenCalled()
  })
})
