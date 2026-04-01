import { afterEach, describe, expect, it, vi } from 'vitest'

const { fetchWithTimeout, reportToolHostFailure } = vi.hoisted(() => ({
  fetchWithTimeout: vi.fn(),
  reportToolHostFailure: vi.fn().mockResolvedValue({ ok: true }),
}))

vi.mock('./core', () => ({
  fetchWithTimeout,
  DEFAULT_MCP_TIMEOUT_MS: 30000,
  getStoredToken: () => null,
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
