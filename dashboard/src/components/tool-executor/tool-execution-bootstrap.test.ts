// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from 'vitest'
vi.mock('../common/toast', () => ({ showToast: vi.fn(), showActionToast: vi.fn() }))
vi.mock('../../api/tool-host-failure', () => ({ reportToolHostFailure: vi.fn() }))
vi.mock('../../store', async () => { const { signal } = await import('@preact/signals'); return { shellAuthSummary: signal({ effective_role: 'worker' }) } })
import { clearStoredToken, setStoredToken, subscribeStoredTokenChanges } from '../../api/core'
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

it('does not submit after an external credential replaces a waiting bootstrap', async () => {
 clearStoredToken(); resetMcpClientState()
 let resolve!: (response: Response) => void
 const fetchMock = vi.fn().mockReturnValueOnce(new Promise<Response>(r => { resolve = r }))
 vi.stubGlobal('fetch', fetchMock)
 selectTool({ name: 'old_tool', description: '', inputSchema: { type: 'object' } })
 const pending = executeTool()
 expect(fetchMock).toHaveBeenCalledTimes(1)
 setStoredToken('synthetic-external-owner')
 expect(lastResult.value).toBeNull()
 resolve(new Response(JSON.stringify({ token: 'synthetic-obsolete-bootstrap', actor: 'dashboard', role: 'admin' }), { status: 200 }))
 await pending
 expect(fetchMock).toHaveBeenCalledTimes(1)
 expect(lastResult.value).toBeNull()
})
it('does not submit a tool whose selection was replaced during bootstrap publication', async () => {
 clearStoredToken(); resetMcpClientState()
 const fetchMock = vi.fn().mockResolvedValueOnce(new Response(JSON.stringify({ token: 'synthetic-selection-bootstrap', actor: 'dashboard', role: 'admin' }), { status: 200 }))
 vi.stubGlobal('fetch', fetchMock)
 selectTool({ name: 'old_tool', description: '', inputSchema: { type: 'object' } })
 const release = subscribeStoredTokenChanges(() => selectTool({ name: 'new_tool', description: '', inputSchema: { type: 'object' } }))
 try {
  await executeTool()
  expect(fetchMock).toHaveBeenCalledTimes(1)
  expect(lastResult.value).toBeNull()
 } finally { release() }
})

it('publishes the receipt after its own expired credential recovery', async () => {
 clearStoredToken(); resetMcpClientState()
 setStoredToken('synthetic-expired-dev', { source: 'dev', actor: 'dashboard', role: 'admin' })
 const bootstrap = (token: string) => new Response(JSON.stringify({ token, actor: 'dashboard', role: 'admin' }), { status: 200 })
 const fetchMock = vi.fn()
  .mockResolvedValueOnce(bootstrap('synthetic-expired-dev'))
  .mockResolvedValueOnce(new Response(JSON.stringify({ error: 'expired', auth_error_code: 'token_expired' }), { status: 401 }))
  .mockResolvedValueOnce(bootstrap('synthetic-recovered-dev'))
  .mockResolvedValueOnce(new Response(JSON.stringify({ result: { content: [{ type: 'text', text: 'recovered output' }] } }), { status: 200 }))
 vi.stubGlobal('fetch', fetchMock)
 selectTool({ name: 'recovery_tool', description: '', inputSchema: { type: 'object' } })
 await executeTool()
 expect(fetchMock).toHaveBeenCalledTimes(4)
 expect(lastResult.value?.text).toBe('recovered output')
 expect(executing.value).toBe(false)
})

it.each(['credential', 'selection'] as const)('does not retry after %s replacement during recovery', async replacement => {
 clearStoredToken(); resetMcpClientState()
 setStoredToken('synthetic-expired-dev', { source: 'dev', actor: 'dashboard', role: 'admin' })
 let resolve!: (response: Response) => void
 const bootstrap = (token: string) => new Response(JSON.stringify({ token, actor: 'dashboard', role: 'admin' }), { status: 200 })
 const fetchMock = vi.fn()
  .mockResolvedValueOnce(bootstrap('synthetic-expired-dev'))
  .mockResolvedValueOnce(new Response(JSON.stringify({ error: 'expired', auth_error_code: 'token_expired' }), { status: 401 }))
  .mockReturnValueOnce(new Promise<Response>(r => { resolve = r }))
 vi.stubGlobal('fetch', fetchMock)
 selectTool({ name: 'recovery_tool', description: '', inputSchema: { type: 'object' } })
 const pending = executeTool()
 await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(3))
 if (replacement === 'credential') setStoredToken('synthetic-external-recovery-owner')
 else selectTool({ name: 'replacement_tool', description: '', inputSchema: { type: 'object' } })
 resolve(bootstrap('synthetic-recovered-dev'))
 await pending
 expect(fetchMock).toHaveBeenCalledTimes(3)
 expect(lastResult.value).toBeNull()
 expect(executing.value).toBe(false)
})
