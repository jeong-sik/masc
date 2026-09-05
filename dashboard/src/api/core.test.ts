import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  ApiRequestError,
  apiRequestErrorFromResponse,
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
  readCacheMode,
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
      actor: 'dashboard',
      role: 'admin',
    })

    expect(getStoredToken()).toBe('loopback-dev-token')
    expect(getStoredTokenMeta()).toEqual({
      source: 'dev',
      actor: 'dashboard',
      role: 'admin',
    })
    expect(currentDashboardActor()).toBe('dashboard')
    expect(authHeaders()).toMatchObject({
      Authorization: 'Bearer loopback-dev-token',
      'X-MASC-Agent': 'dashboard',
    })
  })

  it('clears both the token and metadata together', () => {
    setStoredToken('manual-token', { source: 'manual' })
    clearStoredToken()

    expect(getStoredToken()).toBeNull()
    expect(getStoredTokenMeta()).toBeNull()
  })

  it('notifies token listeners only when the semantic token state changes', () => {
    const listener = vi.fn()
    const unsubscribe = subscribeStoredTokenChanges(listener)
    const revisionBeforeChanges = currentStoredTokenRevision()

    setStoredToken('manual-token', { source: 'manual' })
    setStoredToken(' manual-token ', { source: 'manual' })
    setStoredToken('manual-token', {
      source: 'dev',
      actor: 'dashboard',
      role: 'admin',
    })
    clearStoredToken()
    clearStoredToken()
    unsubscribe()

    expect(listener).toHaveBeenCalledTimes(3)
    expect(currentStoredTokenRevision()).toBe(revisionBeforeChanges + 3)
    expect(listener).toHaveBeenNthCalledWith(1, {
      token: 'manual-token',
      meta: { source: 'manual' },
    })
    expect(listener).toHaveBeenNthCalledWith(2, {
      token: 'manual-token',
      meta: { source: 'dev', actor: 'dashboard', role: 'admin' },
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

  it('omits a guessed actor until a manual token has a server-resolved owner', () => {
    setStoredToken('manual-token', { source: 'manual' })

    expect(authHeaders()).toEqual({ Authorization: 'Bearer manual-token' })

    setCanonicalDashboardActor('codex')
    expect(authHeaders()).toEqual({
      Authorization: 'Bearer manual-token',
      'X-MASC-Agent': 'codex',
    })
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

  it('lets a measured polling route revalidate against the server', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"entries":[]}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await get('/api/v1/dashboard/board')

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(init.cache).toBe('no-cache')
  })

  // Several callers build their path as `${route}?${qs}`. Matching the path as
  // given would leave every one of them on `no-store` while the unparameterised
  // caller revalidated -- a difference no route-level reasoning would predict.
  it('keeps a route revalidating when the caller appends a query string', () => {
    expect(readCacheMode('/api/v1/dashboard/telemetry?window=1h')).toBe('no-cache')
  })

  // The mirror failure: a prefix match would sweep in this sibling, which was
  // never measured for byte-identical repeats.
  it('does not extend a listed route to its sub-routes', () => {
    expect(readCacheMode('/api/v1/dashboard/telemetry/summary')).toBe('no-store')
    expect(readCacheMode('/api/v1/dashboard/provider-logs/tail')).toBe('no-store')
  })

  // This route repeats byte-identically, so it looks eligible on traffic
  // grounds alone. It is excluded because its body names environment variables
  // and host paths, and listing it is what would persist them to disk.
  it('keeps the secret-bearing composite route out of the browser cache', () => {
    expect(readCacheMode('/api/v1/keepers/composite')).toBe('no-store')
  })

  it('leaves an unrecognised route on the conservative default', () => {
    expect(readCacheMode('/api/v1/some/route/added/later')).toBe('no-store')
  })

  it('revalidates high-frequency polling dashboard routes with ETags', () => {
    expect(readCacheMode('/api/v1/dashboard/execution')).toBe('no-cache')
    expect(readCacheMode('/api/v1/dashboard/execution?view=light')).toBe('no-cache')
    expect(readCacheMode('/api/v1/dashboard/config')).toBe('no-cache')
    expect(readCacheMode('/api/v1/dashboard/keeper-memory-health')).toBe('no-cache')
    expect(readCacheMode('/api/v1/dashboard/tasks/history')).toBe('no-cache')
    expect(readCacheMode('/api/v1/dashboard/tasks/history?limit=50')).toBe('no-cache')
    expect(readCacheMode('/api/v1/dashboard/workspace')).toBe('no-cache')
    expect(readCacheMode('/api/v1/dashboard/provider-logs')).toBe('no-cache')
    expect(readCacheMode('/api/v1/dashboard/briefing')).toBe('no-cache')
    expect(readCacheMode('/api/v1/dashboard/planning')).toBe('no-cache')
    expect(readCacheMode('/api/v1/tool-metrics')).toBe('no-cache')
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

describe('typed API errors', () => {
  it('reads a typed code from a structured REST error object', async () => {
    const error = await apiRequestErrorFromResponse(
      'POST',
      '/api/v1/keepers/alpha/config',
      new Response(JSON.stringify({
        error: {
          code: 'keeper_config_revision_conflict',
          expected: { state: 'missing' },
          observed: { state: 'sha256', value: 'a'.repeat(64) },
        },
      }), { status: 409 }),
    )

    expect(error.errorCode).toBe('keeper_config_revision_conflict')
    expect(error.status).toBe(409)
  })

  it('preserves reconciliation state and authoritative reload instruction', async () => {
    const payload = {
      config_application: { state: 'indeterminate' },
      runtime_sync: false,
      authoritative_reload_required: true,
      error: {
        code: 'keeper_manifest_reconciliation_required',
        path: '/workspace/.masc/config/keepers/alpha.toml',
        observed: { state: 'unreadable', detail: 'injected' },
      },
    }
    const error = await apiRequestErrorFromResponse(
      'POST',
      '/api/v1/keepers/alpha/config',
      new Response(JSON.stringify(payload), { status: 503 }),
    )

    expect(error.errorCode).toBe('keeper_manifest_reconciliation_required')
    expect(error.configApplied).toBeUndefined()
    expect(error.configApplicationState).toBe('indeterminate')
    expect(error.runtimeSync).toBe(false)
    expect(error.authoritativeReloadRequired).toBe(true)
    expect(error.responseData).toEqual(payload)
  })

  it('keeps the indeterminate verdict when config_application grows a field', async () => {
    // The verdict rides the state discriminator. A field-count check flipped
    // it to undefined the moment the server added anything beside `state` —
    // the exact moment the operator cannot tell whether the write landed.
    const error = await apiRequestErrorFromResponse(
      'POST',
      '/api/v1/keepers/alpha/config',
      new Response(JSON.stringify({
        config_application: { state: 'indeterminate', detail: 'store fsync unconfirmed' },
        error: { code: 'keeper_manifest_reconciliation_required' },
      }), { status: 503 }),
    )

    expect(error.configApplicationState).toBe('indeterminate')
  })

  it('uses auth_error_code as authority and keeps error prose as detail', async () => {
    const error = await apiRequestErrorFromResponse(
      'POST',
      '/mcp',
      new Response(JSON.stringify({
        error: 'stored token belongs to a different actor',
        auth_error_code: 'actor_mismatch',
      }), { status: 401 }),
    )

    expect(error.errorCode).toBe('actor_mismatch')
    expect(error.authErrorCode).toBe('actor_mismatch')
    expect(error.detail).toBe('stored token belongs to a different actor')
  })

  it('reads auth_error_code from the JSON-RPC error data contract', async () => {
    const error = await apiRequestErrorFromResponse(
      'POST',
      '/mcp',
      new Response(JSON.stringify({
        jsonrpc: '2.0',
        id: null,
        error: {
          code: -32001,
          message: 'stored token is no longer valid',
          data: { auth_error_code: 'invalid_token' },
        },
      }), { status: 401 }),
    )

    expect(error.errorCode).toBe('invalid_token')
    expect(error.authErrorCode).toBe('invalid_token')
    expect(error.detail).toBe('stored token is no longer valid')
  })

  it('does not reinterpret error prose as a typed error code', async () => {
    const error = await apiRequestErrorFromResponse(
      'POST',
      '/mcp',
      new Response(JSON.stringify({ error: 'invalid_token' }), { status: 401 }),
    )

    expect(error.errorCode).toBe('invalid_token')
    expect(error.authErrorCode).toBeUndefined()
    expect(error.detail).toBe('invalid_token')
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

  // The server answers /api/v1/dashboard/* warm-up reads with
  // {"status":"initializing"} (server_auth.ml not_initialized_response), not
  // {"error":"not initialized"}. Until 2026-08-22 that envelope flowed into
  // the execution store as an empty fleet.
  it('maps the dashboard status:initializing envelope to the execution initializing payload', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{"status":"initializing","message":"Server is warming up"}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const data = await get<{ status?: { project?: string }; keepers?: unknown[] }>('/api/v1/dashboard/execution')

    expect(data.status?.project).toBe('initializing')
    expect(data.keepers).toEqual([])
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

  // The namespace-truth route used to answer here too, with a handler
  // byte-identical to project-snapshot's and no caller fetching it (masc#27664).
  it('does not remap the retired namespace-truth route', async () => {
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

    const retired = await get<{ status?: string; error?: string }>('/api/v1/dashboard/namespace-truth')
    expect(retired.status).toBeUndefined()
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
      goals?: unknown[]
      task_backlog?: { todo?: number }
    }>('/api/v1/dashboard/planning')

    expect(data.generated_at).toBeDefined()
    expect(data.goals).toEqual([])
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
