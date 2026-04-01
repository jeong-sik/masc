import { afterEach, describe, expect, it, vi } from 'vitest'

let storedToken: string | null = null

const { fetchWithTimeout, reportToolHostFailure } = vi.hoisted(() => ({
  fetchWithTimeout: vi.fn(),
  reportToolHostFailure: vi.fn().mockResolvedValue({ ok: true }),
}))

vi.mock('./core', () => ({
  fetchWithTimeout,
  DEFAULT_MCP_TIMEOUT_MS: 30000,
  getStoredToken: () => storedToken,
}))

vi.mock('./dashboard', () => ({
  reportToolHostFailure,
}))

afterEach(async () => {
  const { resetMcpClientState } = await import('./mcp')
  resetMcpClientState()
  storedToken = null
  vi.clearAllMocks()
  vi.resetModules()
})

/** Mock MCP session init (initialize + notification) and a successful tools/call response */
function setupSuccessfulMcpSession(sessionId: string) {
  fetchWithTimeout
    .mockResolvedValueOnce(
      new Response('{}', {
        status: 200,
        headers: { 'Mcp-Session-Id': sessionId },
      }),
    )
    .mockResolvedValueOnce(new Response('', { status: 202 }))
    .mockResolvedValueOnce(
      new Response('data: {"result":{"content":[{"type":"text","text":"ok"}]}}\n', {
        status: 200,
      }),
    )
}

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

  it('includes Authorization header when token is available', async () => {
    storedToken = 'test-bearer-token'
    setupSuccessfulMcpSession('sess-auth')

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_status', {})

    const initHeaders = fetchWithTimeout.mock.calls[0]?.[1]?.headers as Record<string, string>
    expect(initHeaders['Authorization']).toBe('Bearer test-bearer-token')

    const toolHeaders = fetchWithTimeout.mock.calls[2]?.[1]?.headers as Record<string, string>
    expect(toolHeaders['Authorization']).toBe('Bearer test-bearer-token')
  })

  it('omits Authorization header when no token is stored', async () => {
    storedToken = null
    setupSuccessfulMcpSession('sess-noauth')

    const { callMcpTool } = await import('./mcp')
    await callMcpTool('masc_status', {})

    const initHeaders = fetchWithTimeout.mock.calls[0]?.[1]?.headers as Record<string, string>
    expect(initHeaders['Authorization']).toBeUndefined()
  })
})
