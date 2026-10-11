import { afterEach, describe, expect, it, vi } from 'vitest'
const bootstrap = vi.hoisted(() => ({ ensureDevToken: vi.fn() }))
vi.mock('./api/dev-token', () => ({ ensureDevToken: bootstrap.ensureDevToken }))
vi.mock('./sse-store', () => ({ registerKeeperWaitingInventoryRefresh: () => () => {} }))
vi.mock('./dashboard-ws-state', () => ({ dashboardWsReconnectCount: { value: 0, subscribe: () => () => {} } }))
import { clearStoredToken, setStoredToken } from './api/core'
import { keeperWaitingInventoryState, refreshKeeperWaitingInventory, subscribeKeeperWaitingInventory } from './keeper-waiting-inventory-store'

afterEach(() => { clearStoredToken(); vi.unstubAllGlobals(); bootstrap.ensureDevToken.mockReset() })

describe('actual waiting inventory HTTP admission', () => {
  it.each([false, true])('admits initial bootstrap without losing or duplicating its GET (mounted=%s)', async mounted => {
    clearStoredToken()
    bootstrap.ensureDevToken.mockImplementationOnce(async () => { setStoredToken('fixture-bootstrap') })
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) => new Response(JSON.stringify({ keepers: [] }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    }))
    vi.stubGlobal('fetch', fetchMock)
    const name = mounted ? 'mounted-bootstrap' : 'explicit-bootstrap'
    const stop = mounted ? subscribeKeeperWaitingInventory(name) : () => {}
    try {
      await refreshKeeperWaitingInventory(name)
      expect(fetchMock).toHaveBeenCalledTimes(1)
      expect(fetchMock.mock.calls[0]?.[0]).toBe(`/api/v1/keepers/${name}/waiting-inventory`)
      expect(new Headers(fetchMock.mock.calls[0]?.[1]?.headers).get('Authorization')).toBe('Bearer fixture-bootstrap')
      expect(keeperWaitingInventoryState(name)).toMatchObject({ ready: true, loading: false, error: null })
    } finally { stop() }
  })
})
