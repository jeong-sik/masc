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

    await store.refreshShell({ force: true })

    expect(sessionActor.currentCanonicalDashboardActor()).toBeNull()
    expect(store.shellAuthSummary.value).toBeNull()
    expect(toastMocks.showToast).toHaveBeenCalledWith(
      '서버 연결 실패 — 데이터를 불러올 수 없습니다',
      'error',
      6000,
    )
  })
})
