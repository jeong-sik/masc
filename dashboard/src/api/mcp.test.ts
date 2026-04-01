import { afterEach, describe, expect, it, vi } from 'vitest'

const { fetchWithTimeout, reportToolHostFailure, authHeaders } = vi.hoisted(() => ({
  fetchWithTimeout: vi.fn(),
  reportToolHostFailure: vi.fn().mockResolvedValue({ ok: true }),
  authHeaders: vi.fn().mockReturnValue({}),
}))

vi.mock('./core', () => ({
  fetchWithTimeout,
  DEFAULT_MCP_TIMEOUT_MS: 30000,
  authHeaders,
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
  const calls = fetchWithTimeout.mock.calls as Array<[string, { headers: Record<string, string>; body: string }]>
  return calls.find(([, opts]) => {
    try { return JSON.parse(opts.body).method === method }
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
    const initHeaders = initCall![1].headers
    expect(initHeaders['Authorization']).toBe('Bearer test-token-123')
    expect(initHeaders['X-MASC-Agent']).toBe('dashboard')
    expect(initHeaders['Content-Type']).toBe('application/json')

    const toolCall = findCallByMethod('tools/call')
    expect(toolCall).toBeDefined()
    expect(toolCall![1].headers['Authorization']).toBe('Bearer test-token-123')
  })

  it('works without token when authHeaders returns empty', async () => {
    authHeaders.mockReturnValue({})
    setupMcpSessionMocks('sess-noauth')

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_status', {})

    const initCall = findCallByMethod('initialize')
    expect(initCall).toBeDefined()
    expect(initCall![1].headers['Authorization']).toBeUndefined()
    expect(initCall![1].headers['Content-Type']).toBe('application/json')
  })
})

describe('callMcpTool', () => {
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
})
