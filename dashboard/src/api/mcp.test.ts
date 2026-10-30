import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const {
  ApiRequestError,
  apiRequestErrorFromResponse,
  fetchWithTimeout,
  reportToolHostFailure,
  authHeaders,
  clearStoredToken,
  currentDashboardActor,
  currentStoredTokenRevision,
  getStoredToken,
  getStoredTokenMeta,
  isRemoteAccess,
  setStoredToken,
} = vi.hoisted(() => ({
  // Carries timeout/timeoutMs like the real one in ./core. The double used to
  // drop them, so every case that "tested a timeout" actually threw an error
  // with no timeout field and a hand-written message -- which is why a
  // message-substring classifier looked correct here.
  ApiRequestError: class ApiRequestError extends Error {
    status?: number
    authErrorCode?: string
    timeout?: boolean
    timeoutMs?: number

    constructor(opts: {
      status?: number
      detail?: string
      authErrorCode?: string
      timeout?: boolean
      timeoutMs?: number
      method?: string
      path?: string
    }) {
      super(
        opts.timeout === true
          ? `${opts.method ?? 'POST'} ${opts.path ?? '/mcp'}: timeout after ${opts.timeoutMs ?? 0}ms`
          : opts.detail ?? 'API request failed')
      this.name = 'ApiRequestError'
      this.status = opts.status
      this.authErrorCode = opts.authErrorCode
      this.timeout = opts.timeout
      this.timeoutMs = opts.timeoutMs
    }
  },
  apiRequestErrorFromResponse: vi.fn(async (method: string, path: string, res: Response) =>
    new Error(`${method} ${path}: ${res.status}`)),
  fetchWithTimeout: vi.fn(),
  reportToolHostFailure: vi.fn().mockResolvedValue({ ok: true }),
  authHeaders: vi.fn().mockReturnValue({}),
  clearStoredToken: vi.fn(),
  currentDashboardActor: vi.fn().mockReturnValue('dashboard'),
  currentStoredTokenRevision: vi.fn().mockReturnValue(0),
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
  ApiRequestError,
  apiRequestErrorFromResponse,
  fetchWithTimeout,
  DEFAULT_MCP_TIMEOUT_MS: 30000,
  authHeaders,
  clearStoredToken,
  currentDashboardActor,
  currentStoredTokenRevision,
  getStoredToken,
  getStoredTokenMeta,
  isRemoteAccess,
  setStoredToken,
}))

vi.mock('./tool-host-failure', () => ({ reportToolHostFailure }))
vi.mock('../components/common/toast', () => ({ showActionToast: vi.fn() }))

const okToolResponse = (text = 'ok') =>
  new Response(`data: ${JSON.stringify({ result: { content: [{ type: 'text', text }] } })}\n`, {
    status: 200,
  })

function callsByMethod(method: string) {
  const calls = fetchWithTimeout.mock.calls as Array<[string, RequestInit, number]>
  return calls.filter(([, init]) => {
    if (typeof init.body !== 'string') return false
    return JSON.parse(init.body).method === method
  })
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((resolvePromise) => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}

beforeEach(() => {
  fetchWithTimeout.mockReset()
  reportToolHostFailure.mockReset().mockResolvedValue({ ok: true })
  apiRequestErrorFromResponse.mockReset().mockImplementation(
    async (method: string, path: string, res: Response) =>
      new Error(`${method} ${path}: ${res.status}`),
  )
  currentDashboardActor.mockReturnValue('dashboard')
  currentStoredTokenRevision.mockReturnValue(0)
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
  vi.unstubAllGlobals()
  vi.clearAllMocks()
  vi.resetModules()
})

describe('MCP 2026-07-28 dashboard client', () => {
  it('sends one stateless tools/call with current mirrored metadata', async () => {
    authHeaders.mockReturnValue({ Authorization: 'Bearer current-token' })
    fetchWithTimeout.mockResolvedValueOnce(okToolResponse())

    const { callMcpTool } = await import('./mcp')
    await expect(callMcpTool('masc_status', {})).resolves.toBe('ok')

    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)
    const [path, init] = fetchWithTimeout.mock.calls[0] as [string, RequestInit]
    expect(path).toBe('/mcp')
    const headers = init.headers as Record<string, string>
    expect(headers).toMatchObject({
      Authorization: 'Bearer current-token',
      'Mcp-Protocol-Version': '2026-07-28',
      'Mcp-Method': 'tools/call',
      'Mcp-Name': 'masc_status',
    })
    expect(headers['Mcp-Session-Id']).toBeUndefined()
    const body = JSON.parse(init.body as string)
    expect(body.params._meta).toEqual({
      'io.modelcontextprotocol/protocolVersion': '2026-07-28',
      'io.modelcontextprotocol/clientCapabilities': {},
    })
    expect(callsByMethod('initialize')).toHaveLength(0)
    expect(callsByMethod('notifications/initialized')).toHaveLength(0)
  })

  it('preserves the dashboard actor injection contract', async () => {
    getStoredTokenMeta.mockReturnValue({
      source: 'dev',
      actor: 'dashboard',
      role: 'admin',
    })
    fetchWithTimeout
      .mockResolvedValueOnce(new Response(JSON.stringify({
        token: 'test-stored-token', actor: 'dashboard', role: 'admin',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(okToolResponse())
    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_keeper_up', { name: 'sonsukku' })

    const [, init] = callsByMethod('tools/call')[0]!
    const body = JSON.parse(init.body as string)
    expect(body.params.arguments).toEqual({
      name: 'sonsukku',
      _agent_name: 'dashboard',
    })
  })

  it('does not inject an actor for a token without actor metadata', async () => {
    getStoredToken.mockReturnValue('codex-token')
    getStoredTokenMeta.mockReturnValue(null)
    isRemoteAccess.mockReturnValue(true)
    authHeaders.mockReturnValue({ Authorization: 'Bearer codex-token' })
    fetchWithTimeout.mockResolvedValueOnce(okToolResponse())

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_keeper_list', {})

    const [, init] = callsByMethod('tools/call')[0]!
    const body = JSON.parse(init.body as string)
    expect(body.params.arguments).toEqual({})
  })

  it('does not let _agent_name override a bearer credential owner', async () => {
    getStoredToken.mockReturnValue('dashboard-token')
    getStoredTokenMeta.mockReturnValue({
      source: 'manual',
      actor: 'dashboard',
      scope: null,
    })
    authHeaders.mockReturnValue({ Authorization: 'Bearer dashboard-token' })
    fetchWithTimeout.mockResolvedValueOnce(okToolResponse())

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_transition', {
      task_id: 'task-223',
      agent_name: 'dashboard-admin-deft-cobra',
      _agent_name: 'dashboard-admin-deft-cobra',
    })

    const [, init] = callsByMethod('tools/call')[0]!
    const body = JSON.parse(init.body as string)
    expect(body.params.arguments).toEqual({
      task_id: 'task-223',
      agent_name: 'dashboard-admin-deft-cobra',
    })
    expect(authHeaders).toHaveBeenLastCalledWith({ actorName: null })
  })

  // Pagination stops on absence of a cursor, and the guard is progress rather
  // than a page budget: #26771 capped at 50 pages, which refused a server with
  // 51 legitimate pages and let a non-progressing one run 50 round trips first.
  it('rejects a server that repeats a cursor instead of advancing', async () => {
    const page = () => new Response(JSON.stringify({
      result: { tools: [{ name: 'one', description: '', inputSchema: {} }], nextCursor: 'same' },
    }), { status: 200 })
    fetchWithTimeout.mockResolvedValueOnce(page()).mockResolvedValueOnce(page())

    const { listAllMcpTools } = await import('./mcp')
    await expect(listAllMcpTools()).rejects.toThrow(/repeated cursor same/)
    // Two round trips, not fifty: the second page is where non-progress shows.
    expect(callsByMethod('tools/list')).toHaveLength(2)
  })

  it('follows more pages than the retired fixed cap allowed', async () => {
    const PAGES = 60
    for (let i = 0; i < PAGES; i++) {
      const last = i === PAGES - 1
      fetchWithTimeout.mockResolvedValueOnce(new Response(JSON.stringify({
        result: {
          tools: [{ name: `tool-${i}`, description: '', inputSchema: {} }],
          ...(last ? {} : { nextCursor: `cursor-${i}` }),
        },
      }), { status: 200 }))
    }

    const { listAllMcpTools } = await import('./mcp')
    await expect(listAllMcpTools()).resolves.toHaveLength(PAGES)
  })

  it('gives every tools/list page a distinct request id', async () => {
    fetchWithTimeout
      .mockResolvedValueOnce(new Response(JSON.stringify({
        result: { tools: [{ name: 'one', description: '', inputSchema: {} }], nextCursor: 'next' },
      }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        result: { tools: [{ name: 'two', description: '', inputSchema: {} }] },
      }), { status: 200 }))

    const { listAllMcpTools } = await import('./mcp')
    await listAllMcpTools()

    const ids = callsByMethod('tools/list')
      .map(([, init]) => JSON.parse(init.body as string).id)
    expect(new Set(ids).size).toBe(ids.length)
    // A wall-clock id is a number; these are uuids.
    for (const id of ids) expect(typeof id).toBe('string')
  })

  it('uses current metadata on every tools/list page', async () => {
    fetchWithTimeout
      .mockResolvedValueOnce(new Response(JSON.stringify({
        result: { tools: [{ name: 'one', description: '', inputSchema: {} }], nextCursor: 'next' },
      }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        result: { tools: [{ name: 'two', description: '', inputSchema: {} }] },
      }), { status: 200 }))

    const { listAllMcpTools } = await import('./mcp')
    await expect(listAllMcpTools()).resolves.toHaveLength(2)

    const calls = callsByMethod('tools/list')
    expect(calls).toHaveLength(2)
    for (const [, init] of calls) {
      const headers = init.headers as Record<string, string>
      const body = JSON.parse(init.body as string)
      expect(headers['Mcp-Protocol-Version']).toBe('2026-07-28')
      expect(headers['Mcp-Method']).toBe('tools/list')
      expect(headers['Mcp-Name']).toBeUndefined()
      expect(body.params._meta['io.modelcontextprotocol/protocolVersion'])
        .toBe('2026-07-28')
    }
  })

  it('does not retry an HTTP failure as a session recovery', async () => {
    fetchWithTimeout.mockResolvedValueOnce(new Response('missing', {
      status: 404,
      headers: { 'Mcp-Session-Id': 'legacy-replacement' },
    }))

    const { callMcpTool } = await import('./mcp')
    await expect(callMcpTool('masc_status', {})).rejects.toThrow('POST /mcp: 404')
    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)
  })

  it('rejects a response completed under an older auth revision', async () => {
    let revision = 0
    currentStoredTokenRevision.mockImplementation(() => revision)
    const response = deferred<Response>()
    fetchWithTimeout.mockImplementationOnce(() => response.promise)

    const { callMcpTool } = await import('./mcp')
    const request = callMcpTool('masc_status', {})
    await vi.waitFor(() => expect(fetchWithTimeout).toHaveBeenCalledTimes(1))

    revision = 1
    response.resolve(okToolResponse())
    await expect(request).rejects.toThrow('MCP authentication changed during request')
  })

  it('reports transport failures without legacy session telemetry', async () => {
    fetchWithTimeout.mockRejectedValueOnce(
      new ApiRequestError({ method: 'POST', path: '/mcp', timeout: true, timeoutMs: 30000 }))

    const { callMcpTool } = await import('./mcp')
    await expect(callMcpTool('masc_keeper_msg', { message: 'ping' }))
      .rejects.toThrow('timeout after 30000ms')

    expect(reportToolHostFailure).toHaveBeenCalledWith(expect.objectContaining({
      client_name: 'masc-dashboard',
      tool_name: 'masc_keeper_msg',
      transport: 'mcp_http',
      phase: 'tools/call',
      cause_code: 'tool_host_timeout',
      timeout_ms: 30000,
    }))
    expect(reportToolHostFailure.mock.calls[0]![0].session_id).toBeUndefined()
  })

  // The transport says whether a request reached a tool. These cases pin that
  // the decision reads the thrown value, not its prose.
  it('reports a fetch that never reached the host', async () => {
    fetchWithTimeout.mockRejectedValueOnce(new TypeError('Load failed'))

    const { callMcpTool } = await import('./mcp')
    await expect(callMcpTool('masc_keeper_msg', { message: 'ping' })).rejects.toThrow()

    expect(reportToolHostFailure).toHaveBeenCalledWith(expect.objectContaining({
      tool_name: 'masc_keeper_msg',
      phase: 'tools/call',
      cause_code: 'tool_host_transport_unavailable',
    }))
    expect(reportToolHostFailure.mock.calls[0]![0].timeout_ms).toBeUndefined()
  })

  it('does not report a non-timeout ApiRequestError', async () => {
    fetchWithTimeout.mockRejectedValueOnce(
      new ApiRequestError({ status: 500, detail: 'internal error' }))

    const { callMcpTool } = await import('./mcp')
    await expect(callMcpTool('masc_keeper_msg', { message: 'ping' })).rejects.toThrow()

    expect(reportToolHostFailure).not.toHaveBeenCalled()
  })

  // The regression the typed check removes: a tool error whose own text
  // contains transport wording was reported as a host failure.
  it('does not report a tool error whose message reads like a transport failure', async () => {
    fetchWithTimeout.mockRejectedValueOnce(
      new Error('tool refused: load failed while parsing the uploaded fixture'))

    const { callMcpTool } = await import('./mcp')
    await expect(callMcpTool('masc_keeper_msg', { message: 'ping' })).rejects.toThrow()

    expect(reportToolHostFailure).not.toHaveBeenCalled()
  })

  it('fails closed after a 403 until client state is reset', async () => {
    fetchWithTimeout.mockResolvedValueOnce(new Response('forbidden', { status: 403 }))
    const { callMcpTool, resetMcpClientState } = await import('./mcp')

    await expect(callMcpTool('masc_status', {})).rejects.toThrow('MCP 연결이 차단')
    await expect(callMcpTool('masc_status', {})).rejects.toThrow('MCP 연결이 차단')
    expect(fetchWithTimeout).toHaveBeenCalledTimes(1)

    resetMcpClientState()
    fetchWithTimeout.mockResolvedValueOnce(okToolResponse())
    await expect(callMcpTool('masc_status', {})).resolves.toBe('ok')
  })

  it('does not carry a 403 block into a newer auth revision', async () => {
    let revision = 0
    currentStoredTokenRevision.mockImplementation(() => revision)
    fetchWithTimeout.mockResolvedValueOnce(new Response('forbidden', { status: 403 }))
    const { callMcpTool } = await import('./mcp')

    await expect(callMcpTool('masc_status', {})).rejects.toThrow('MCP 연결이 차단')
    revision = 1
    fetchWithTimeout.mockResolvedValueOnce(okToolResponse())
    await expect(callMcpTool('masc_status', {})).resolves.toBe('ok')
    expect(fetchWithTimeout).toHaveBeenCalledTimes(2)
  })

  it('bootstraps a loopback dev token before the single MCP request', async () => {
    getStoredToken.mockReturnValue(null)
    getStoredTokenMeta.mockReturnValue(null)
    fetchWithTimeout
      .mockResolvedValueOnce(new Response(JSON.stringify({
        token: 'loopback-dev-token', actor: 'dashboard', role: 'admin',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(okToolResponse())

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_status', {})

    expect(setStoredToken).toHaveBeenCalledWith('loopback-dev-token', {
      source: 'dev', actor: 'dashboard', role: 'admin',
    })
    expect(fetchWithTimeout.mock.calls.map(call => call[0]))
      .toEqual(['/api/v1/dashboard/dev-token', '/mcp'])
  })

  /* The loopback dev-token is Admin (#28354), and `ensureDevToken` refuses any
     other role rather than storing a credential it cannot use. Until this case
     existed the refusal branch had no test of its own — it was reached by
     accident, because the fixtures above still served the pre-#28354 `worker`
     role, which silently turned four tests that meant to exercise bootstrap,
     identity binding, and token refresh into four assertions about a bootstrap
     that never ran. Pin the refusal here so those tests can state their own
     subject. */
  it('refuses a dev-token payload that is not the Admin contract', async () => {
    getStoredToken.mockReturnValue(null)
    getStoredTokenMeta.mockReturnValue(null)
    fetchWithTimeout
      .mockResolvedValueOnce(new Response(JSON.stringify({
        token: 'loopback-dev-token', actor: 'dashboard', role: 'worker',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(okToolResponse())

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_status', {})

    expect(setStoredToken).not.toHaveBeenCalled()
  })

  it('binds identity to a bearer bootstrapped during the call', async () => {
    let token: string | null = null
    let meta: { source: 'dev'; actor: 'dashboard'; role: 'admin' } | null = null
    let revision = 0
    getStoredToken.mockImplementation(() => token)
    getStoredTokenMeta.mockImplementation(() => meta)
    currentStoredTokenRevision.mockImplementation(() => revision)
    setStoredToken.mockImplementationOnce((nextToken, nextMeta) => {
      token = nextToken
      meta = nextMeta
      revision += 1
    })
    fetchWithTimeout
      .mockResolvedValueOnce(new Response(JSON.stringify({
        token: 'loopback-dev-token', actor: 'dashboard', role: 'admin',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(okToolResponse())

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_transition', {
      task_id: 'task-223',
      agent_name: 'target-keeper',
      _agent_name: 'foreign-caller',
    })

    const [, init] = callsByMethod('tools/call')[0]!
    const body = JSON.parse(init.body as string)
    expect(body.params.arguments).toEqual({
      task_id: 'task-223',
      agent_name: 'target-keeper',
      _agent_name: 'dashboard',
    })
    expect(authHeaders).toHaveBeenLastCalledWith({ actorName: 'dashboard' })
  })

  it('uses distinct platform UUIDs for consecutive tool request identities', async () => {
    fetchWithTimeout
      .mockResolvedValueOnce(okToolResponse('first'))
      .mockResolvedValueOnce(okToolResponse('second'))

    const { callMcpTool } = await import('./mcp')
    await expect(callMcpTool('masc_status', {})).resolves.toBe('first')
    await expect(callMcpTool('masc_status', {})).resolves.toBe('second')

    const requestIds = callsByMethod('tools/call').map(([, init]) => {
      const body = JSON.parse(init.body as string) as { id: unknown }
      return body.id
    })
    expect(requestIds).toHaveLength(2)
    expect(requestIds.every(id => typeof id === 'string')).toBe(true)
    expect(requestIds[0]).not.toBe(requestIds[1])
  })

  it('uses Web Crypto random bytes when randomUUID is unavailable', async () => {
    const getRandomValues = vi.fn((bytes: Uint8Array) => {
      bytes.forEach((_, index) => { bytes[index] = index })
      return bytes
    })
    vi.stubGlobal('crypto', { getRandomValues })
    fetchWithTimeout.mockResolvedValueOnce(okToolResponse())

    const { callMcpTool } = await import('./mcp')
    await expect(callMcpTool('masc_status', {})).resolves.toBe('ok')

    const toolCall = callsByMethod('tools/call')[0]
    if (!toolCall) throw new Error('tools/call request missing')
    const body = JSON.parse(toolCall[1].body as string) as { id: unknown }
    expect(getRandomValues).toHaveBeenCalled()
    expect(body.id).toBe('00010203-0405-4607-8809-0a0b0c0d0e0f')
  })

  it('refreshes a managed token once on a typed MCP auth result', async () => {
    let token: string | null = 'stale-dev-token'
    let meta: { source: 'dev'; actor: 'dashboard'; role: 'admin' } | null = {
      source: 'dev', actor: 'dashboard', role: 'admin',
    }
    let revision = 0
    getStoredToken.mockImplementation(() => token)
    getStoredTokenMeta.mockImplementation(() => meta)
    currentStoredTokenRevision.mockImplementation(() => revision)
    clearStoredToken.mockImplementationOnce(() => {
      token = null
      meta = null
      revision += 1
    })
    setStoredToken.mockImplementationOnce((nextToken, nextMeta) => {
      token = nextToken
      meta = nextMeta
      revision += 1
    })
    fetchWithTimeout
      .mockResolvedValueOnce(new Response(JSON.stringify({
        token: 'stale-dev-token', actor: 'dashboard', role: 'admin',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(`data: ${JSON.stringify({
        result: {
          isError: true,
          content: [{ type: 'text', text: 'authentication rejected' }],
          structuredContent: { auth_error_code: 'actor_mismatch' },
        },
      })}\n`, { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        token: 'fresh-dev-token', actor: 'dashboard', role: 'admin',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(okToolResponse())

    const { callMcpTool } = await import('./mcp')
    await expect(callMcpTool('masc_status', {})).resolves.toBe('ok')

    expect(callsByMethod('tools/call')).toHaveLength(2)
    expect(fetchWithTimeout.mock.calls.map(call => call[0]))
      .toEqual([
        '/api/v1/dashboard/dev-token',
        '/mcp',
        '/api/v1/dashboard/dev-token',
        '/mcp',
      ])
    expect(token).toBe('fresh-dev-token')
    expect(reportToolHostFailure).not.toHaveBeenCalled()
  })

  it('refreshes a managed token once on a typed HTTP 401', async () => {
    let token: string | null = 'stale-dev-token'
    let meta: { source: 'dev'; actor: 'dashboard'; role: 'admin' } | null = {
      source: 'dev', actor: 'dashboard', role: 'admin',
    }
    let revision = 0
    getStoredToken.mockImplementation(() => token)
    getStoredTokenMeta.mockImplementation(() => meta)
    currentStoredTokenRevision.mockImplementation(() => revision)
    clearStoredToken.mockImplementationOnce(() => {
      token = null
      meta = null
      revision += 1
    })
    setStoredToken.mockImplementationOnce((nextToken, nextMeta) => {
      token = nextToken
      meta = nextMeta
      revision += 1
    })
    apiRequestErrorFromResponse.mockImplementationOnce(async (_method, _path, res) => {
      const payload = await res.json() as {
        error?: { message?: string; data?: { auth_error_code?: string } }
      }
      return new ApiRequestError({
        status: res.status,
        detail: payload.error?.message,
        authErrorCode: payload.error?.data?.auth_error_code,
      })
    })
    fetchWithTimeout
      .mockResolvedValueOnce(new Response(JSON.stringify({
        token: 'stale-dev-token', actor: 'dashboard', role: 'admin',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        jsonrpc: '2.0',
        id: null,
        error: {
          code: -32001,
          message: 'authentication rejected',
          data: { auth_error_code: 'token_expired' },
        },
      }), { status: 401, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        token: 'fresh-dev-token', actor: 'dashboard', role: 'admin',
      }), { status: 200, headers: { 'Content-Type': 'application/json' } }))
      .mockResolvedValueOnce(okToolResponse())

    const { callMcpTool } = await import('./mcp')
    await expect(callMcpTool('masc_status', {})).resolves.toBe('ok')

    expect(callsByMethod('tools/call')).toHaveLength(2)
    expect(fetchWithTimeout.mock.calls.map(call => call[0]))
      .toEqual([
        '/api/v1/dashboard/dev-token',
        '/mcp',
        '/api/v1/dashboard/dev-token',
        '/mcp',
      ])
    expect(token).toBe('fresh-dev-token')
    expect(reportToolHostFailure).not.toHaveBeenCalled()
  })
})
