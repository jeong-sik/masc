// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from 'vitest'
vi.mock('../common/toast', () => ({ showToast: vi.fn(), showActionToast: vi.fn() }))
vi.mock('../../api/tool-host-failure', () => ({ reportToolHostFailure: vi.fn() }))
vi.mock('../../store', async () => { const { signal } = await import('@preact/signals'); return { shellAuthSummary: signal(null) } })
import { clearStoredToken } from '../../api/core'
import { resetMcpClientState } from '../../api/mcp'
import { loadToolSchemas, filteredTools, schemasError } from './tool-executor-state'
afterEach(() => { vi.unstubAllGlobals(); clearStoredToken(); resetMcpClientState() })
it('publishes schemas obtained through its own normal loopback bootstrap', async () => {
 clearStoredToken(); resetMcpClientState()
 const fetchMock = vi.fn().mockResolvedValueOnce(new Response(JSON.stringify({ token: 'synthetic-normal-bootstrap', actor: 'dashboard', role: 'admin' }), { status: 200 }))
 .mockResolvedValueOnce(new Response(JSON.stringify({ result: { tools: [{ name: 'bootstrap_tool', description: 'synthetic', inputSchema: { type: 'object' } }] } }), { status: 200 }))
 vi.stubGlobal('fetch', fetchMock)
 await loadToolSchemas(true)
 expect(fetchMock).toHaveBeenCalledTimes(2)
 expect(schemasError.value).toBeNull()
 expect(filteredTools.value.map(tool => tool.name)).toEqual(['bootstrap_tool'])
})
