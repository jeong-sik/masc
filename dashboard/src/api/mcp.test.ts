import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const {
  apiRequestErrorFromResponse,
  fetchWithTimeout,
  reportToolHostFailure,
  authHeaders,
  clearStoredToken,
  currentDashboardActor,
  getStoredToken,
  getStoredTokenMeta,
  isRemoteAccess,
  setStoredToken,
} = vi.hoisted(() => ({
  apiRequestErrorFromResponse: vi.fn(async (method: string, path: string, res: Response) =>
    new Error(`${method} ${path}: ${res.status} ${res.statusText}`.trim())),
  fetchWithTimeout: vi.fn(),
  reportToolHostFailure: vi.fn().mockResolvedValue({ ok: true }),
  authHeaders: vi.fn().mockReturnValue({}),
  clearStoredToken: vi.fn(),
  currentDashboardActor: vi.fn().mockReturnValue('dashboard'),
  // Default to a non-empty stored token so ensureDevToken() short-circuits
  // without consuming a fetchWithTimeout mock. Individual tests that want
  // to exercise the dev-token bootstrap can override this.
  getStoredToken: vi.fn().mockReturnValue('test-stored-token'),
  getStoredTokenMeta: vi.fn().mockReturnValue({
    source: 'manual',
    actor: 'dashboard',
    scope: null,
  }),
  isRemoteAccess: vi.fn().mockReturnValue(false),
  setStoredToken: vi.fn(),
}))

vi.mock('./core', () => ({
  apiRequestErrorFromResponse,
  fetchWithTimeout,
  DEFAULT_MCP_TIMEOUT_MS: 30000,
  authHeaders,
  clearStoredToken,
  currentDashboardActor,
  getStoredToken,
  getStoredTokenMeta,
  isRemoteAccess,
  setStoredToken,
}))

vi.mock('./tool-host-failure', () => ({
  reportToolHostFailure,
}))

vi.mock('../components/common/toast', () => ({
  showActionToast: vi.fn(),
}))

beforeEach(() => {
  // Re-assert default return values because vi.clearAllMocks() in afterEach
  // wipes any per-test `.mockReturnValueOnce` queue and can clash with
  // mocks whose `vi.hoisted` defaults have been overwritten by an earlier
  // test (e.g. authHeaders). The dev-token bootstrap must stay inert unless
  // a test explicitly exercises it.
  currentDashboardActor.mockReturnValue('dashboard')
  getStoredToken.mockReturnValue('test-stored-token')
  getStoredTokenMeta.mockReturnValue({
    source: 'manual',
    actor: 'dashboard',
    scope: null,
  })
  isRemoteAccess.mockReturnValue(false)
  authHeaders.mockReturnValue({})
})

afterEach(async () => {
  const { resetMcpClientState } = await import('./mcp')
  resetMcpClientState()
  vi.clearAllMocks()
  vi.resetModules()
}, 60_000)

function setupMcpSessionMocks(sessionId: string) {
  fetchWithTimeout
    .mockResolvedValueOnce(
      new Response('{}', { status: 200, headers: { 'Mcp-Session-Id': sessionId } }),
    )
    .mockResolvedValueOnce(new Response('', { status: 202 }))
    .mockResolvedValueOnce(
      new Response('data: {"result":{"content":[{"type":"text","text":"ok"}]}}\n', { status: 200 }),
    )
}

/** Find a fetchWithTimeout call by matching the JSON body's "method" field. */
function findCallByMethod(method: string) {
  const calls = fetchWithTimeout.mock.calls as Array<[string, RequestInit, number]>
  return calls.find(([, init]) => {
    const body = init.body
    if (typeof body !== 'string') return false
    try { return JSON.parse(body).method === method }
    catch { return false }
  })
}

describe('mcpHeaders auth integration', () => {
  it('includes Authorization header from authHeaders in MCP initialize request', async () => {
    authHeaders.mockReturnValue({
      'Authorization': 'Bearer test-token-123',
      'X-MASC-Agent': 'dashboard',
    })
    setupMcpSessionMocks('sess-auth')

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_status', {})

    const initCall = findCallByMethod('initialize')
    expect(initCall).toBeDefined()
    const initHeaders = initCall![1].headers as Record<string, string>
    expect(initHeaders['Authorization']).toBe('Bearer test-token-123')
    expect(initHeaders['X-MASC-Agent']).toBe('dashboard')
    expect(initHeaders['Content-Type']).toBe('application/json')

    const toolCall = findCallByMethod('tools/call')
    expect(toolCall).toBeDefined()
    const toolHeaders = toolCall![1].headers as Record<string, string>
    expect(toolHeaders['Authorization']).toBe('Bearer test-token-123')
  }, 60_000)

  it('works without token when authHeaders returns empty', async () => {
    authHeaders.mockReturnValue({})
    setupMcpSessionMocks('sess-noauth')

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_status', {})

    const initCall = findCallByMethod('initialize')
    expect(initCall).toBeDefined()
    const noAuthHeaders = initCall![1].headers as Record<string, string>
    expect(noAuthHeaders['Authorization']).toBeUndefined()
    expect(noAuthHeaders['Content-Type']).toBe('application/json')
  }, 60_000)
})

describe('dev-token bootstrap', () => {
  it('fetches /api/v1/dashboard/dev-token once when no token is stored and persists the response', async () => {
    getStoredToken.mockReturnValue(null)
    fetchWithTimeout
      .mockResolvedValueOnce(
        new Response(JSON.stringify({
          token: 'loopback-dev-token',
          actor: 'dashboard',
          scope: 'admin',
        }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }),
      )
      // MCP initialize + initialized + tools/call
      .mockResolvedValueOnce(
        new Response('{}', { status: 200, headers: { 'Mcp-Session-Id': 'sess-dev' } }),
      )
      .mockResolvedValueOnce(new Response('', { status: 202 }))
      .mockResolvedValueOnce(
        new Response('data: {"result":{"content":[{"type":"text","text":"ok"}]}}\n', { status: 200 }),
      )

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_status', {})

    expect(setStoredToken).toHaveBeenCalledWith('loopback-dev-token', {
      source: 'dev',
      actor: 'dashboard',
      scope: 'admin',
    })
    const calls = fetchWithTimeout.mock.calls as Array<[string, RequestInit]>
    expect(calls.length).toBeGreaterThanOrEqual(2)
    expect(calls[0]?.[0]).toBe('/api/v1/dashboard/dev-token')
    expect(calls[1]?.[0]).toBe('/mcp')
  }, 60_000)

  it('replaces a borrowed loopback token when the default dashboard actor is active', async () => {
    getStoredToken.mockReturnValue('borrowed-codex-token')
    getStoredTokenMeta.mockReturnValue({
      source: 'manual',
      actor: null,
      scope: null,
    })
    fetchWithTimeout
      .mockResolvedValueOnce(
        new Response(JSON.stringify({
          token: 'loopback-dev-token',
          actor: 'dashboard',
          scope: 'admin',
        }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }),
      )
      .mockResolvedValueOnce(
        new Response('{}', { status: 200, headers: { 'Mcp-Session-Id': 'sess-borrowed' } }),
      )
      .mockResolvedValueOnce(new Response('', { status: 202 }))
      .mockResolvedValueOnce(
        new Response('data: {"result":{"content":[{"type":"text","text":"ok"}]}}\n', { status: 200 }),
      )

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_status', {})

    expect(setStoredToken).toHaveBeenCalledWith('loopback-dev-token', {
      source: 'dev',
      actor: 'dashboard',
      scope: 'admin',
    })
    const calls = fetchWithTimeout.mock.calls as Array<[string, RequestInit]>
    expect(calls[0]?.[0]).toBe('/api/v1/dashboard/dev-token')
  }, 60_000)

  it('keeps manual tokens for non-default dashboard actors', async () => {
    currentDashboardActor.mockReturnValue('dashboard-manual-actor')
    authHeaders.mockReturnValue({
      'Authorization': 'Bearer manual-actor-token',
      'X-MASC-Agent': 'dashboard-manual-actor',
    })
    getStoredToken.mockReturnValue('manual-actor-token')
    getStoredTokenMeta.mockReturnValue({
      source: 'manual',
      actor: null,
      scope: null,
    })
    setupMcpSessionMocks('sess-manual-actor')

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_status', {})

    expect(setStoredToken).not.toHaveBeenCalled()
    const calls = fetchWithTimeout.mock.calls as Array<[string, RequestInit]>
    expect(calls[0]?.[0]).toBe('/mcp')
  }, 60_000)

  it('swallows dev-token fetch failures so strict-auth servers still reach the 401 path', async () => {
    getStoredToken.mockReturnValue(null)
    fetchWithTimeout
      .mockResolvedValueOnce(new Response('not found', { status: 404 }))
      .mockResolvedValueOnce(
        new Response('{}', { status: 200, headers: { 'Mcp-Session-Id': 'sess-nok' } }),
      )
      .mockResolvedValueOnce(new Response('', { status: 202 }))
      .mockResolvedValueOnce(
        new Response('data: {"result":{"content":[{"type":"text","text":"ok"}]}}\n', { status: 200 }),
      )

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_status', {})

    expect(setStoredToken).not.toHaveBeenCalled()
    const initCall = findCallByMethod('initialize')
    expect(initCall).toBeDefined()
  }, 60_000)

  it('clears an old managed dev token when the loopback bootstrap endpoint disappears', async () => {
    getStoredToken.mockReturnValue('stale-dev-token')
    getStoredTokenMeta.mockReturnValue({ source: 'dev', actor: 'dashboard', scope: 'admin' })
    fetchWithTimeout
      .mockResolvedValueOnce(new Response('not found', { status: 404 }))
      .mockResolvedValueOnce(
        new Response('{}', { status: 200, headers: { 'Mcp-Session-Id': 'sess-dev-404' } }),
      )
      .mockResolvedValueOnce(new Response('', { status: 202 }))
      .mockResolvedValueOnce(
        new Response('data: {"result":{"content":[{"type":"text","text":"ok"}]}}\n', { status: 200 }),
      )

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_status', {})

    expect(clearStoredToken).toHaveBeenCalledTimes(1)
    expect(setStoredToken).not.toHaveBeenCalled()
  }, 60_000)
})

describe('callMcpTool', () => {
  it('injects the dashboard actor into MCP tool arguments', async () => {
    setupMcpSessionMocks('sess-actor')

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_keeper_create_from_persona', { persona_name: 'sonsukku' })

    const toolCall = findCallByMethod('tools/call')
    expect(toolCall).toBeDefined()
    const body = JSON.parse(toolCall![1].body as string)
    expect(body.params.arguments).toEqual({
      persona_name: 'sonsukku',
      _agent_name: 'dashboard',
    })
  }, 60_000)

  it('omits implicit dashboard actor for token-bound sessions without actor metadata', async () => {
    getStoredToken.mockReturnValue('codex-token')
    getStoredTokenMeta.mockReturnValue(null)
    isRemoteAccess.mockReturnValue(true)
    authHeaders.mockImplementation((opts?: { actorName?: string | null }) => ({
      Authorization: 'Bearer codex-token',
      ...(opts?.actorName ? { 'X-MASC-Agent': opts.actorName } : {}),
    }))
    setupMcpSessionMocks('sess-token-owner')

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_persona_list', {})

    const toolCall = findCallByMethod('tools/call')
    expect(toolCall).toBeDefined()
    const body = JSON.parse(toolCall![1].body as string)
    expect(body.params.arguments).toEqual({})
    const headers = toolCall![1].headers as Record<string, string>
    expect(headers.Authorization).toBe('Bearer codex-token')
    expect(headers['X-MASC-Agent']).toBeUndefined()
  }, 60_000)

  it('treats legacy agent_name as payload when the session is token-authenticated', async () => {
    authHeaders.mockImplementation((opts?: { actorName?: string | null }) => (
      opts?.actorName ? { 'X-MASC-Agent': opts.actorName } : {}
    ))
    setupMcpSessionMocks('sess-explicit')

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_agent_fitness', { agent_name: 'codex-tool-matrix', days: 7 })

    const toolCall = findCallByMethod('tools/call')
    expect(toolCall).toBeDefined()
    const body = JSON.parse(toolCall![1].body as string)
    expect(body.params.arguments).toEqual({
      agent_name: 'codex-tool-matrix',
      days: 7,
      _agent_name: 'dashboard',
    })
    const headers = toolCall![1].headers as Record<string, string>
    expect(headers['X-MASC-Agent']).toBe('dashboard')
  }, 60_000)

  it('still honors an explicit _agent_name override', async () => {
    authHeaders.mockImplementation((opts?: { actorName?: string | null }) => (
      opts?.actorName ? { 'X-MASC-Agent': opts.actorName } : {}
    ))
    setupMcpSessionMocks('sess-explicit-internal')

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_join', { _agent_name: 'codex-tool-matrix' })

    const toolCall = findCallByMethod('tools/call')
    expect(toolCall).toBeDefined()
    const body = JSON.parse(toolCall![1].body as string)
    expect(body.params.arguments).toEqual({
      _agent_name: 'codex-tool-matrix',
    })
    const headers = toolCall![1].headers as Record<string, string>
    expect(headers['X-MASC-Agent']).toBe('codex-tool-matrix')
  }, 60_000)

  it('reports tool-host failures after the MCP session is established', async () => {
    fetchWithTimeout
      .mockResolvedValueOnce(
        new Response('{}', {
          status: 200,
          headers: { 'Mcp-Session-Id': 'sess-1' },
        }),
      )
      .mockResolvedValueOnce(new Response('', { status: 202 }))
      .mockRejectedValueOnce(new Error('POST /mcp: timeout after 30000ms'))

    const { callMcpTool } = await import('./mcp')

    await expect(
      callMcpTool('masc_keeper_msg', { name: 'sangsu', message: 'ping' }),
    ).rejects.toThrow('POST /mcp: timeout after 30000ms')

    expect(reportToolHostFailure).toHaveBeenCalledTimes(1)
    expect(reportToolHostFailure).toHaveBeenCalledWith(
      expect.objectContaining({
        client_name: 'masc-dashboard',
        tool_name: 'masc_keeper_msg',
        transport: 'mcp_http',
        phase: 'tools/call',
        session_id: 'sess-1',
        timeout_ms: 30000,
      }),
    )
  })

  it('does not retry implicit actor mismatches', async () => {
    fetchWithTimeout
      .mockResolvedValueOnce(
        new Response('{}', {
          status: 200,
          headers: { 'Mcp-Session-Id': 'sess-mismatch-1' },
        }),
      )
      .mockResolvedValueOnce(new Response('', { status: 202 }))
      .mockResolvedValueOnce(
        new Response('data: {"result":{"isError":true,"content":[{"type":"text","text":"🔐 Unauthorized: No credential found for dashboard (bearer token belongs to codex)"}]}}\n', { status: 200 }),
      )

    const { callMcpTool } = await import('./mcp')

    await expect(callMcpTool('masc_persona_list', {})).rejects.toThrow(
      'No credential found for dashboard',
    )
    const toolCalls = (fetchWithTimeout.mock.calls as Array<[string, RequestInit]>)
      .filter(([, init]) => typeof init.body === 'string' && JSON.parse(init.body as string).method === 'tools/call')
    expect(toolCalls).toHaveLength(1)
  })

  it('does not retry explicit _agent_name mismatches', async () => {
    authHeaders.mockImplementation((opts?: { actorName?: string | null }) => (
      opts?.actorName ? { 'X-MASC-Agent': opts.actorName } : {}
    ))
    fetchWithTimeout
      .mockResolvedValueOnce(
        new Response('{}', {
          status: 200,
          headers: { 'Mcp-Session-Id': 'sess-explicit-mismatch' },
        }),
      )
      .mockResolvedValueOnce(new Response('', { status: 202 }))
      .mockResolvedValueOnce(
        new Response('data: {"result":{"isError":true,"content":[{"type":"text","text":"🔐 Unauthorized: No credential found for dashboard (bearer token belongs to codex)"}]}}\n', { status: 200 }),
      )

    const { callMcpTool } = await import('./mcp')

    await expect(callMcpTool('masc_join', { _agent_name: 'dashboard' })).rejects.toThrow(
      'No credential found for dashboard',
    )
  })

  it('blocks subsequent calls after tools/call returns 403', async () => {
    fetchWithTimeout
      .mockResolvedValueOnce(
        new Response('{}', {
          status: 200,
          headers: { 'Mcp-Session-Id': 'sess-403' },
        }),
      )
      .mockResolvedValueOnce(new Response('', { status: 202 }))
      .mockResolvedValueOnce(
        new Response('Forbidden', { status: 403, statusText: 'Forbidden' }),
      )

    const { callMcpTool } = await import('./mcp')

    await expect(callMcpTool('masc_status', {})).rejects.toThrow(
      'MCP 연결이 차단되었습니다',
    )

    fetchWithTimeout.mockClear()
    await expect(callMcpTool('masc_status', {})).rejects.toThrow(
      'MCP 연결이 차단되었습니다',
    )
    expect(fetchWithTimeout).not.toHaveBeenCalled()
  })

  it('throws on non-2xx initialize response without proceeding', async () => {
    fetchWithTimeout.mockResolvedValueOnce(
      new Response('Internal Server Error', { status: 500, statusText: 'Internal Server Error' }),
    )

    const { callMcpTool } = await import('./mcp')

    await expect(callMcpTool('masc_status', {})).rejects.toThrow(
      'POST /mcp initialize: 500',
    )
    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)
  })

  it('blocks subsequent calls after initialize returns 403', async () => {
    fetchWithTimeout.mockResolvedValueOnce(
      new Response('Forbidden', { status: 403, statusText: 'Forbidden' }),
    )

    const { callMcpTool } = await import('./mcp')

    await expect(callMcpTool('masc_status', {})).rejects.toThrow(
      'MCP 연결이 차단되었습니다',
    )

    fetchWithTimeout.mockClear()
    await expect(callMcpTool('masc_status', {})).rejects.toThrow(
      'MCP 연결이 차단되었습니다',
    )
    expect(fetchWithTimeout).not.toHaveBeenCalled()
  })
})
