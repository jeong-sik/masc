// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from 'vitest'
vi.mock('../common/toast', () => ({ showToast: vi.fn(), showActionToast: vi.fn() }))
vi.mock('../../api/tool-host-failure', () => ({ reportToolHostFailure: vi.fn() }))
vi.mock('../../store', async () => { const { signal } = await import('@preact/signals'); return { shellAuthSummary: signal({ effective_role: 'worker' }) } })
import { clearStoredToken } from '../../api/core'
import { resetMcpClientState } from '../../api/mcp'
import { executeTool, selectTool, lastResult, executing } from './tool-executor-state'
afterEach(() => { vi.unstubAllGlobals(); clearStoredToken(); resetMcpClientState() })
it('publishes the successful execution admitted by its own bootstrap', async () => {
 clearStoredToken(); resetMcpClientState()
 selectTool({ name: 'bootstrap_tool', description: 'synthetic', inputSchema: { type: 'object' } })
 const fetchMock = vi.fn().mockResolvedValueOnce(new Response(JSON.stringify({ token: 'synthetic-normal-bootstrap', actor: 'dashboard', role: 'admin' }), { status: 200 }))
 .mockResolvedValueOnce(new Response(JSON.stringify({ result: { content: [{ type: 'text', text: 'completed output' }] } }), { status: 200 }))
 vi.stubGlobal('fetch', fetchMock)
 await executeTool()
 expect(fetchMock).toHaveBeenCalledTimes(2)
 expect(executing.value).toBe(false)
 expect(lastResult.value?.text).toBe('completed output')
})
