import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  ApiRequestError,
  authHeaders,
  clearStoredToken,
  confirmOperatorAction,
  currentDashboardActor,
  currentStoredTokenRevision,
  dashboardBearerToken,
  defaultBoardVoter,
  extractApiError,
  get,
  getStoredToken,
  getStoredTokenMeta,
  post,
  runOperatorAction,
  setStoredToken,
  subscribeStoredTokenChanges,
} from './core'
import { OperatorActionSchemaDriftError } from './schemas/operator-action'
import {
  currentCanonicalDashboardActor,
  resetDashboardSessionActorForTests,
  setCanonicalDashboardActor,
} from '../lib/dashboard-session-actor'

afterEach(() => {
  resetDashboardSessionActorForTests()
  vi.unstubAllGlobals()
  window.sessionStorage?.clear?.()
  try {
    window.history.replaceState({}, '', 'http://localhost/')
  } catch {
    // Ignore cleanup failures in the test environment.
  }
})

describe('stored token metadata', () => {
  it('persists token metadata and prefers the managed dev actor', () => {
    setStoredToken('loopback-dev-token', {
      source: 'dev',
      actor: 'dashboard-dev!!!',
      scope: 'admin',
    })

    expect(getStoredToken()).toBe('loopback-dev-token')
    expect(getStoredTokenMeta()).toEqual({
      source: 'dev',
      actor: 'dashboard-dev',
      scope: 'admin',
    })
    expect(currentDashboardActor()).toBe('dashboard-dev')
    expect(authHeaders()).toMatchObject({
      Authorization: 'Bearer loopback-dev-token',
      'X-MASC-Agent': 'dashboard-dev',
    })
  })

  it('clears both the token and metadata together', () => {
    setStoredToken('manual-token', { source: 'manual', actor: 'dashboard-user' })
    clearStoredToken()

    expect(getStoredToken()).toBeNull()
    expect(getStoredTokenMeta()).toBeNull()
  })

  it('notifies token listeners only when the semantic token state changes', () => {
    const listener = vi.fn()
    const unsubscribe = subscribeStoredTokenChanges(listener)
    const revisionBeforeChanges = currentStoredTokenRevision()

    setStoredToken('manual-token', { source: 'manual', actor: 'dashboard-user' })
    setStoredToken(' manual-token ', { source: 'manual', actor: 'dashboard-user' })
    setStoredToken('manual-token', { source: 'manual', actor: 'dashboard-user-2' })
    clearStoredToken()
    clearStoredToken()
    unsubscribe()

    expect(listener).toHaveBeenCalledTimes(3)
    expect(currentStoredTokenRevision()).toBe(revisionBeforeChanges + 3)
    expect(listener).toHaveBeenNthCalledWith(1, {
      token: 'manual-token',
      meta: { source: 'manual', actor: 'dashboard-user', scope: null },
    })
    expect(listener).toHaveBeenNthCalledWith(2, {
      token: 'manual-token',
      meta: { source: 'manual', actor: 'dashboard-user-2', scope: null },
    })
    expect(listener).toHaveBeenNthCalledWith(3, {
      token: null,
      meta: null,
    })
  })

  it('normalizes blank raw storage for shared transport auth', () => {
    sessionStorage.setItem('masc_bearer_token', '   ')

    expect(dashboardBearerToken()).toBeNull()
    expect(authHeaders()).not.toHaveProperty('Authorization')
  })
})

describe('post', () => {
  it('clears the canonical actor immediately when replacing a stored token', () => {
    setCanonicalDashboardActor('codex')

    setStoredToken('next-token')

    expect(currentCanonicalDashboardActor()).toBeNull()
  })

  it('clears the canonical actor immediately when clearing a stored token', () => {
    setCanonicalDashboardActor('codex')

    clearStoredToken()

    expect(currentCanonicalDashboardActor()).toBeNull()
  })

  it('sends a sanitized actor header without URL encoding', async () => {
    window.history.replaceState({}, '', '/?agent=dashboard-eager-manta%E3%85%8A')

    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await post('/api/v1/tools/masc_board_comment', { post_id: 'p-123', content: 'hello' })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const headers = init.headers as Record<string, string>
    const actorHeader = headers['X-MASC-Agent'] ?? headers['x-masc-agent']
    expect(actorHeader).toBe('dashboard-eager-manta')
    expect(actorHeader).not.toContain('%')
  })

  it('bypasses browser HTTP cache for dashboard API reads', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"keepers":[]}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await get('/api/v1/operator')

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(init.cache).toBe('no-store')
  })

  it('keeps board voter resolution scoped to query params', () => {
    window.localStorage?.setItem?.('masc_dashboard_agent_name', 'stored-agent')
    window.history.replaceState({}, '', '/')

    expect(defaultBoardVoter()).toBe('dashboard-user')
  })

  it('surfaces JSON error messages from failed POST responses', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"status":"error","message":"actor mismatch: payload actor must match authenticated actor"}', {
        status: 400,
        statusText: 'Bad Request',
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(post('/api/v1/operator/action', { actor: 'ops-user' })).rejects.toMatchObject({
      name: 'ApiRequestError',
      status: 400,
      detail: 'actor mismatch: payload actor must match authenticated actor',
      errorCode: 'error',
      message: 'POST /api/v1/operator/action: actor mismatch: payload actor must match authenticated actor',
    })
  })

  it('uses the request actor for operator action headers when query agent differs', async () => {
    window.history.replaceState({}, '', '/?agent=dashboard-url-actor')

    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"status":"ok","result":{}}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const controller = new AbortController()
    await runOperatorAction({
      actor: 'dashboard-manual-actor',
      action_type: 'keeper_probe',
      target_type: 'keeper',
      target_id: 'keeper-one',
      payload: {},
    }, { signal: controller.signal })

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const headers = init.headers as Record<string, string>
    expect(headers['X-MASC-Agent'] ?? headers['x-masc-agent']).toBe('dashboard-manual-actor')
    expect(init.signal).toBe(controller.signal)
  })

  it('uses the confirmation actor for operator confirm headers when query agent differs', async () => {
    window.history.replaceState({}, '', '/?agent=dashboard-url-actor')

    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"status":"ok","result":{}}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const controller = new AbortController()
    await confirmOperatorAction(
      'dashboard-manual-actor',
      'opc_test_token',
      'confirm',
      { signal: controller.signal },
    )

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const headers = init.headers as Record<string, string>
    expect(headers['X-MASC-Agent'] ?? headers['x-masc-agent']).toBe('dashboard-manual-actor')
    expect(init.signal).toBe(controller.signal)
  })
  it('surfaces invalid JSON in 200 operator action responses as ApiRequestError', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('not-json', {
        status: 200,
        statusText: 'OK',
        headers: { 'Content-Type': 'text/plain' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(runOperatorAction({
      actor: 'dashboard-manual-actor',
      action_type: 'keeper_probe',
      target_type: 'keeper',
      target_id: 'keeper-one',
      payload: {},
    })).rejects.toMatchObject({
      name: 'ApiRequestError',
      status: 200,
      detail: 'invalid JSON response',
      message: 'POST /api/v1/operator/action: invalid JSON response',
    })
  })

  it('surfaces empty JSON in 200 operator confirm responses as ApiRequestError', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('', {
        status: 200,
        statusText: 'OK',
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(confirmOperatorAction(
      'dashboard-manual-actor',
      'opc_test_token',
      'deny',
    )).rejects.toMatchObject({
      name: 'ApiRequestError',
      status: 200,
      detail: 'empty JSON response',
      message: 'POST /api/v1/operator/confirm: empty JSON response',
    })
  })

  it('rejects 200 operator action payloads whose JSON body is still missing the status contract', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"result":{"ok":true}}', {
        status: 200,
        statusText: 'OK',
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(runOperatorAction({
      actor: 'dashboard-manual-actor',
      action_type: 'keeper_probe',
      target_type: 'keeper',
      target_id: 'keeper-one',
      payload: {},
    })).rejects.toBeInstanceOf(OperatorActionSchemaDriftError)
  })
})

describe('get bootstrap warm-up mapping', () => {
  it('preserves upstream abort signals instead of reporting them as timeouts', async () => {
    const fetchMock = vi.fn().mockImplementation((_path: string, init?: RequestInit) => (
      new Promise((_resolve, reject) => {
        const signal = init?.signal as AbortSignal | undefined
        signal?.addEventListener('abort', () => {
          reject(new DOMException('superseded request', 'AbortError'))
        })
      })
    ))
    vi.stubGlobal('fetch', fetchMock)

    const controller = new AbortController()
    const request = get('/api/v1/dashboard/project-snapshot', { signal: controller.signal })
    controller.abort()

    await expect(request).rejects.toMatchObject({
      name: 'AbortError',
    })
  })

  it('maps dashboard project-snapshot not-initialized errors to initializing payloads', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{ status?: string; message?: string }>('/api/v1/dashboard/project-snapshot')

    expect(data.status).toBe('initializing')
    expect(data.message).toContain('warming up')
  })

  it('maps dashboard shell not-initialized errors to an empty bootstrap shell payload', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{
      status?: { project?: string }
      counts?: { agents?: number; tasks?: number; keepers?: number }
    }>('/api/v1/dashboard/shell')

    expect(data.status?.project).toBe('initializing')
    expect(data.counts).toEqual({ agents: 0, tasks: 0, keepers: 0 })
  })

  it('preserves errors for non-bootstrap routes', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(get('/api/v1/board')).rejects.toMatchObject({
      name: 'ApiRequestError',
      status: 500,
      path: '/api/v1/board',
    })
  })

  it('surfaces JSON error messages from failed GET responses', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"computation_timeout","message":"Dashboard Gate timed out after 30s"}', {
        status: 504,
        statusText: 'Gateway Timeout',
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(get('/api/v1/dashboard/gate')).rejects.toMatchObject({
      name: 'ApiRequestError',
      status: 504,
      detail: 'Dashboard Gate timed out after 30s',
      errorCode: 'computation_timeout',
      message: 'GET /api/v1/dashboard/gate: Dashboard Gate timed out after 30s',
    })
  })

  it('does not remap 4xx bootstrap responses', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(get('/api/v1/dashboard/project-snapshot')).rejects.toMatchObject({
      name: 'ApiRequestError',
      status: 401,
      path: '/api/v1/dashboard/project-snapshot',
    })
  })

  it('remaps 2xx not-initialized responses on bootstrap paths', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{ status?: string; message?: string }>('/api/v1/dashboard/project-snapshot')

    expect(data.status).toBe('initializing')
    expect(data.message).toContain('warming up')
  })

  it('remaps namespace/workspace-truth aliases the same as project-snapshot', async () => {
    const fetchMock = vi.fn().mockImplementation(() =>
      Promise.resolve(
        new Response('{"error":"not initialized"}', {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }),
      ))
    vi.stubGlobal('fetch', fetchMock)

    const canonical = await get<{ status?: string; message?: string }>('/api/v1/dashboard/project-snapshot')
    expect(canonical.status).toBe('initializing')
    expect(canonical.message).toContain('warming up')

    const legacyNamespace = await get<{ status?: string; message?: string }>('/api/v1/dashboard/namespace-truth')
    expect(legacyNamespace.status).toBe('initializing')
    expect(legacyNamespace.message).toContain('warming up')

    const data = await get<{ status?: string; message?: string }>('/api/v1/dashboard/workspace-truth')
    expect(data.status).toBe('initializing')
    expect(data.message).toContain('warming up')
  })

  it('maps execution not-initialized 5xx to empty execution payload', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{
      generated_at?: string
      execution_queue?: unknown[]
      operation_briefs?: unknown[]
      agents?: unknown[]
    }>('/api/v1/dashboard/execution')

    expect(data.generated_at).toBeDefined()
    expect(data.execution_queue).toEqual([])
    expect(data.operation_briefs).toEqual([])
    expect(data.agents).toEqual([])
  })

  it('maps planning not-initialized 2xx to empty planning payload', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{
      generated_at?: string
      task_backlog?: { todo?: number }
    }>('/api/v1/dashboard/planning')

    expect(data.generated_at).toBeDefined()
    expect(data.task_backlog?.todo).toBe(0)
  })

  it('maps briefing not-initialized 5xx to empty briefing payload', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"error":"not initialized"}', {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{
      generated_at?: string
      summary?: { workspace_health?: string }
      incidents?: unknown[]
      command_focus?: Record<string, unknown>
      operator_targets?: { keepers?: unknown[] }
    }>('/api/v1/dashboard/briefing')

    expect(data.generated_at).toBeDefined()
    expect(data.summary?.workspace_health).toBe('initializing')
    expect(data.incidents).toEqual([])
    expect(data.command_focus).toEqual({})
    expect(data.operator_targets?.keepers).toEqual([])
  })

  it('passes through valid 2xx responses on bootstrap paths', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"status":"ok","agents":5}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{ status?: string; agents?: number }>('/api/v1/dashboard/namespace-truth')

    expect(data.status).toBe('ok')
    expect(data.agents).toBe(5)
  })

  it('surfaces invalid JSON in 200 GET responses as ApiRequestError', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('service unavailable', {
        status: 200,
        statusText: 'OK',
        headers: { 'Content-Type': 'text/plain' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(get('/api/v1/dashboard/gate')).rejects.toMatchObject({
      name: 'ApiRequestError',
      status: 200,
      detail: 'invalid JSON response',
      message: 'GET /api/v1/dashboard/gate: invalid JSON response',
    })
  })
})

describe('extractApiError', () => {
  it('extracts status and path from an ApiRequestError with status', () => {
    const err = new ApiRequestError({ method: 'GET', path: '/api/v1/operator', status: 404, statusText: 'Not Found' })
    const summary = extractApiError(err, 'fallback')
    expect(summary.status).toBe(404)
    expect(summary.path).toBe('/api/v1/operator')
    expect(summary.message).toContain('404')
    expect(summary.timeout).toBe(false)
  })

  it('extracts timeout flag from an ApiRequestError with timeout', () => {
    const err = new ApiRequestError({ method: 'POST', path: '/api/v1/operator/action', timeout: true, timeoutMs: 5000 })
    const summary = extractApiError(err, 'fallback')
    expect(summary.timeout).toBe(true)
    expect(summary.status).toBeNull()
    expect(summary.path).toBe('/api/v1/operator/action')
  })

  it('stores structured error codes on ApiRequestError', () => {
    const err = new ApiRequestError({
      method: 'GET',
      path: '/api/v1/dashboard/gate',
      status: 504,
      statusText: 'Gateway Timeout',
      detail: 'Dashboard Gate timed out after 30s',
      errorCode: 'computation_timeout',
    })
    expect(err.errorCode).toBe('computation_timeout')
  })

  it('returns null status + path for plain Error', () => {
    const summary = extractApiError(new Error('network down'), 'fallback')
    expect(summary.message).toBe('network down')
    expect(summary.status).toBeNull()
    expect(summary.path).toBeNull()
    expect(summary.timeout).toBe(false)
  })

  it('uses fallbackMessage for non-Error thrown values', () => {
    const summary = extractApiError('string rejection', 'Failed to load')
    expect(summary.message).toBe('Failed to load')
    expect(summary.status).toBeNull()
  })

  it('uses fallbackMessage for undefined', () => {
    const summary = extractApiError(undefined, 'Failed to load')
    expect(summary.message).toBe('Failed to load')
  })
})
