import { afterEach, describe, expect, it, vi } from 'vitest'

vi.setConfig({
  testTimeout: 60_000,
  hookTimeout: 60_000,
})

const { fetchWithTimeout, reportToolHostFailure, authHeaders, currentDashboardActor } = vi.hoisted(() => ({
  fetchWithTimeout: vi.fn(),
  reportToolHostFailure: vi.fn().mockResolvedValue({ ok: true }),
  authHeaders: vi.fn().mockReturnValue({}),
  currentDashboardActor: vi.fn().mockReturnValue('dashboard'),
}))

vi.mock('./core', () => ({
  fetchWithTimeout,
  DEFAULT_MCP_TIMEOUT_MS: 30000,
  authHeaders,
  currentDashboardActor,
}))

vi.mock('./dashboard', () => ({
  reportToolHostFailure,
}))

afterEach(async () => {
  const { resetMcpClientState } = await import('./mcp')
  resetMcpClientState()
  vi.clearAllMocks()
  vi.resetModules()
})

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
  })

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
  })
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
  })

  it('preserves an explicit agent_name field when the caller already set one', async () => {
    setupMcpSessionMocks('sess-explicit')

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_join', { agent_name: 'codex-tool-matrix' })

    const toolCall = findCallByMethod('tools/call')
    expect(toolCall).toBeDefined()
    const body = JSON.parse(toolCall![1].body as string)
    expect(body.params.arguments).toEqual({
      agent_name: 'codex-tool-matrix',
    })
  })

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
