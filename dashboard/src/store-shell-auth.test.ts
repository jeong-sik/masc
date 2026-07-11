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
    expect(apiMocks.fetchDashboardShell).toHaveBeenCalledTimes(1)
    resolveFirst?.({
      generated_at: '2026-07-11T11:00:00Z',
      status: { project: 'me' },
      counts: { agents: 0, tasks: 0, keepers: 0, total_runtimes: 0 },
      auth: { enabled: true, require_token: true, token_present: true, token_valid: true },
    })

    await expect(older).resolves.toBe(true)
    await expect(afterStateChange).resolves.toBe(true)
    expect(apiMocks.fetchDashboardShell).toHaveBeenCalledTimes(2)
    expect(store.shellAuthSummary.value?.token_present).toBe(false)
    expect(store.shellAuthSummary.value?.token_valid).toBe(false)
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
      default_role: 'worker',
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
      default_role: 'worker',
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
