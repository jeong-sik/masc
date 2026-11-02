import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ApiRequestError, clearStoredToken, currentStoredTokenRevision, getStoredToken, setStoredToken } from './core'
import { fetchDashboardGoalDetail, fetchDashboardGoalsTree } from './dashboard-goals'
import { devTokenBootstrapStatus, ensureDevToken, installRejectedCredentialRecovery, resetDevTokenBootstrap } from './dev-token'
import { callMcpTool, callMcpToolAtIdentity, mcpCallFailureDisposition, resetMcpClientState } from './mcp'
import { DEFAULT_GET_TIMEOUT_MS, DEFAULT_MCP_TIMEOUT_MS } from '../config/constants'

vi.mock('./tool-host-failure', () => ({
  // A stuck diagnostics endpoint must not hold the original operation receipt.
  reportToolHostFailure: () => new Promise(() => {}),
}))

const workspace = { basePath: '/workspace', mascRoot: '/workspace/.masc' }

beforeEach(() => {
  vi.useFakeTimers()
  clearStoredToken()
  resetDevTokenBootstrap()
  resetMcpClientState()
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.useRealTimers()
  clearStoredToken()
  resetDevTokenBootstrap()
  resetMcpClientState()
})

function stalledResponse(status: number, started: () => void, signal: AbortSignal): Response {
  const body = () => {
    started()
    return new Promise<never>((_resolve, reject) => {
      signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true })
    })
  }
  const response = { ok: status === 200, status, statusText: '',
    headers: new Headers({ 'x-masc-workspace-read': 'matched-v1' }),
    text: body, json: body, clone: () => response } as unknown as Response
  return response
}

it('does not let an old Goal MCP 401 clear the current credential', async () => {
  setStoredToken('manual-test-token', { source: 'manual' })
  const uninstall = installRejectedCredentialRecovery()
  try {
    let current = true
    let resolveResponse!: (response: Response) => void
    let markStarted!: () => void
    const started = new Promise<void>(resolve => { markStarted = resolve })
    const fetchMock = vi.fn(() => {
      markStarted()
      return new Promise<Response>(resolve => { resolveResponse = resolve })
    })
    vi.stubGlobal('fetch', fetchMock)
    const request = callMcpToolAtIdentity('masc_goal_transition', { goal_id: 'goal-1' },
      { revision: currentStoredTokenRevision(), actor: 'dashboard' }, () => current).catch(error => error)
    await started
    current = false
    resolveResponse(new Response(JSON.stringify({ error: 'refused', auth_error_code: 'token_expired' }), {
      status: 401, headers: { 'Content-Type': 'application/json' },
    }))
    await request
    await Promise.resolve()
    expect(getStoredToken()).toBe('manual-test-token')
    expect(fetchMock).toHaveBeenCalledTimes(1)
  } finally {
    uninstall()
  }
})

it('does not send a bound Goal detail refusal to global credential recovery', async () => {
  setStoredToken('same-token', { source: 'manual' })
  const uninstall = installRejectedCredentialRecovery()
  try {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
      error: 'refused', auth_error_code: 'token_expired',
    }), { status: 401, headers: { 'Content-Type': 'application/json' } })))
    await expect(fetchDashboardGoalDetail('goal-1', workspace)).rejects.toBeInstanceOf(ApiRequestError)
    await Promise.resolve()
    expect(getStoredToken()).toBe('same-token')
  } finally {
    uninstall()
  }
})

it('recovers a current Goal MCP 401 without replaying the write', async () => {
  setStoredToken('expired-test-token', { source: 'manual' })
  const fetchMock = vi.fn(async () => new Response(JSON.stringify({ error: 'refused', auth_error_code: 'token_expired' }), {
    status: 401, headers: { 'Content-Type': 'application/json' },
  }))
  vi.stubGlobal('fetch', fetchMock)
  const result = callMcpToolAtIdentity('masc_goal_transition', { goal_id: 'goal-1' },
    { revision: currentStoredTokenRevision(), actor: 'dashboard' }, () => true).catch(error => error)
  expect(await result).toBeInstanceOf(ApiRequestError)
  expect(getStoredToken()).toBeNull()
  expect(fetchMock).toHaveBeenCalledTimes(1)
})

it('does not replay a generic MCP write when another owner replaces the dev credential during refresh', async () => {
  setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
  let devFetches = 0
  let resolveRefresh!: (response: Response) => void
  let markRefreshStarted!: () => void
  const refreshStarted = new Promise<void>(resolve => { markRefreshStarted = resolve })
  const fetchMock = vi.fn((path: string) => {
    if (path === '/mcp') return Promise.resolve(new Response(JSON.stringify({
      error: 'refused', auth_error_code: 'token_expired',
    }), { status: 401, headers: { 'Content-Type': 'application/json' } }))
    devFetches += 1
    if (devFetches === 1) return Promise.resolve(new Response(JSON.stringify({
      token: 'old-dev-token', actor: 'dashboard', role: 'admin',
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
    markRefreshStarted()
    return new Promise<Response>(resolve => { resolveRefresh = resolve })
  })
  vi.stubGlobal('fetch', fetchMock)
  const result = callMcpTool('masc_goal_upsert', { title: 'one request' }).catch(error => error)
  await refreshStarted
  setStoredToken('other-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
  resolveRefresh(new Response(JSON.stringify({ token: 'stale-response-token', actor: 'dashboard', role: 'admin' }), {
    status: 200, headers: { 'Content-Type': 'application/json' },
  }))
  expect(await result).toBeInstanceOf(ApiRequestError)
  expect(getStoredToken()).toBe('other-dev-token')
  expect(fetchMock.mock.calls.filter(([path]) => path === '/mcp')).toHaveLength(1)
})

it('does not start recovery for a generic MCP 401 whose body belongs to an older credential', async () => {
  setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
  let finishBody!: (body: string) => void
  let markBodyStarted!: () => void
  const bodyStarted = new Promise<void>(resolve => { markBodyStarted = resolve })
  const body = new Promise<string>(resolve => { finishBody = resolve })
  const fetchMock = vi.fn((path: string) => path === '/mcp'
    ? Promise.resolve({ ok: false, status: 401, statusText: 'Unauthorized', text: () => {
      markBodyStarted()
      return body
    } } as Response)
    : Promise.resolve(new Response(JSON.stringify({ token: 'old-dev-token', actor: 'dashboard', role: 'admin' }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    })))
  vi.stubGlobal('fetch', fetchMock)
  const result = callMcpTool('masc_goal_upsert', { title: 'one request' }).catch(error => error)
  await bodyStarted
  setStoredToken('other-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
  finishBody(JSON.stringify({ error: 'refused', auth_error_code: 'token_expired' }))
  expect(await result).toBeInstanceOf(Error)
  expect(getStoredToken()).toBe('other-dev-token')
  expect(fetchMock.mock.calls.filter(([path]) => path === '/mcp')).toHaveLength(1)
  expect(fetchMock.mock.calls.filter(([path]) => path === '/api/v1/dashboard/dev-token')).toHaveLength(1)
})

it('does not let an old scoped MCP 403 block the next owner', async () => {
  setStoredToken('same-token', { source: 'manual' })
  let current = true
  let resolveOld!: (response: Response) => void
  let markStarted!: () => void
  const started = new Promise<void>(resolve => { markStarted = resolve })
  let calls = 0
  const fetchMock = vi.fn((_path: string, init: RequestInit) => {
    calls += 1
    if (calls === 1) {
      markStarted()
      return new Promise<Response>(resolve => { resolveOld = resolve })
    }
    const { id } = JSON.parse(String(init.body))
    return Promise.resolve(new Response(JSON.stringify({ id, result: { content: [{ type: 'text', text: 'ok' }] } }),
      { status: 200, headers: { 'Content-Type': 'application/json' } }))
  })
  vi.stubGlobal('fetch', fetchMock)
  const old = callMcpToolAtIdentity('masc_goal_transition', { goal_id: 'goal-1' },
    { revision: currentStoredTokenRevision(), actor: 'dashboard' }, () => current).catch(error => error)
  await started
  current = false
  resolveOld(new Response(JSON.stringify({ error: 'forbidden', auth_error_code: 'insufficient_role' }), {
    status: 403, headers: { 'Content-Type': 'application/json' },
  }))
  expect(await old).toBeInstanceOf(ApiRequestError)
  await expect(callMcpToolAtIdentity('masc_goal_transition', { goal_id: 'goal-2' },
    { revision: currentStoredTokenRevision(), actor: 'dashboard' }, () => true)).resolves.toBe('ok')
  expect(fetchMock).toHaveBeenCalledTimes(2)
})

it('does not apply a generic MCP 403 block to an independently scoped request', async () => {
  setStoredToken('same-token', { source: 'manual' })
  const fetchMock = vi.fn((_path: string, init: RequestInit) => {
    if (fetchMock.mock.calls.length === 1) return Promise.resolve(new Response('forbidden', { status: 403 }))
    const { id } = JSON.parse(String(init.body))
    return Promise.resolve(new Response(JSON.stringify({ id, result: { content: [{ type: 'text', text: 'ok' }] } }),
      { status: 200, headers: { 'Content-Type': 'application/json' } }))
  })
  vi.stubGlobal('fetch', fetchMock)
  await expect(callMcpTool('masc_status', {})).rejects.toThrow()
  await expect(callMcpToolAtIdentity('masc_goal_transition', { goal_id: 'goal-1' },
    { revision: currentStoredTokenRevision(), actor: 'dashboard' }, () => true)).resolves.toBe('ok')
  expect(fetchMock).toHaveBeenCalledTimes(2)
})

it.each([false, true])('keeps an explicitly selected operator without a token (old dev metadata: %s)', async staleMeta => {
  window.localStorage.setItem('masc_dashboard_agent_name', 'alice')
  try {
    if (staleMeta) {
      setStoredToken('old-dev-token', { source: 'dev', actor: 'dashboard', role: 'admin' })
      window.sessionStorage.removeItem('masc_bearer_token')
    }
    const fetchMock = vi.fn(async (_path: string, init: RequestInit) => {
      const { id } = JSON.parse(String(init.body))
      return new Response(JSON.stringify({ id, result: { content: [{ type: 'text', text: 'ok' }] } }),
        { status: 200, headers: { 'Content-Type': 'application/json' } })
    })
    vi.stubGlobal('fetch', fetchMock)
    await expect(callMcpToolAtIdentity('masc_goal_transition', { goal_id: 'goal-1' },
      { revision: currentStoredTokenRevision(), actor: 'alice' }, () => true)).resolves.toBe('ok')
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/mcp')
    const headers = new Headers(fetchMock.mock.calls[0]?.[1].headers)
    expect(headers.get('x-masc-agent')).toBe('alice')
    expect(headers.get('authorization')).toBeNull()
    expect(getStoredToken()).toBeNull()
  } finally {
    window.localStorage.removeItem('masc_dashboard_agent_name')
  }
})

it.each([200, 409])('reports an unknown MCP outcome when the %i body stalls', async status => {
  setStoredToken('manual-test-token', { source: 'manual' })
  let bodyStarted!: () => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  const fetchMock = vi.fn(async (_path: string, init: RequestInit) => stalledResponse(status, bodyStarted, init.signal!))
  vi.stubGlobal('fetch', fetchMock)
  const result = callMcpToolAtIdentity('masc_goal_transition', { goal_id: 'goal-1', action: 'request_complete' },
    { revision: currentStoredTokenRevision(), actor: 'dashboard' }).catch(error => error)
  await started
  await vi.advanceTimersByTimeAsync(DEFAULT_MCP_TIMEOUT_MS)
  const error: unknown = await result
  expect(error).toBeInstanceOf(ApiRequestError)
  expect(error).toMatchObject({ timeout: true })
  expect(mcpCallFailureDisposition(error)).toBe('outcome_unknown')
  expect(fetchMock).toHaveBeenCalledTimes(1)
})

it('does not impose the Goal body deadline on other MCP mutations', async () => {
  setStoredToken('manual-test-token', { source: 'manual' })
  let bodyStarted!: () => void
  let finishBody!: (body: string) => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  const body = new Promise<string>(resolve => { finishBody = resolve })
  const response = { ok: true, status: 200, headers: new Headers(), text: () => {
    bodyStarted()
    return body
  } } as unknown as Response
  vi.stubGlobal('fetch', vi.fn(async () => response))
  let settled = false
  const result = callMcpTool('masc_goal_upsert', { title: 'new goal' }).finally(() => { settled = true })
  await started
  await vi.advanceTimersByTimeAsync(DEFAULT_MCP_TIMEOUT_MS * 2)
  expect(settled).toBe(false)
  finishBody(JSON.stringify({ result: { content: [{ type: 'text', text: 'created' }] } }))
  await expect(result).resolves.toBe('created')
})

it.each(['tree', 'detail'] as const)('times out a stalled bound Goal %s read', async kind => {
  let bodyStarted!: () => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  const fetchMock = vi.fn(async (_path: string, init: RequestInit) => stalledResponse(200, bodyStarted, init.signal!))
  vi.stubGlobal('fetch', fetchMock)
  const result = (kind === 'tree' ? fetchDashboardGoalsTree(workspace)
    : fetchDashboardGoalDetail('goal-1', workspace)).catch(error => error)
  await started
  await vi.advanceTimersByTimeAsync(DEFAULT_GET_TIMEOUT_MS)
  expect(await result).toMatchObject({ timeout: true })
  expect(fetchMock).toHaveBeenCalledTimes(1)
})

it('releases dev-token bootstrap when the response body stalls', async () => {
  let bodyStarted!: () => void
  const started = new Promise<void>(resolve => { bodyStarted = resolve })
  const fetchMock = vi.fn(async (_path: string, init: RequestInit) => stalledResponse(200, bodyStarted, init.signal!))
  vi.stubGlobal('fetch', fetchMock)
  const result = ensureDevToken()
  await started
  await vi.advanceTimersByTimeAsync(3000)
  await result
  expect(devTokenBootstrapStatus.value).toBe('network')
  expect(fetchMock).toHaveBeenCalledTimes(1)
})
