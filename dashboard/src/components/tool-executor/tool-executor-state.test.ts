// @vitest-environment happy-dom
import { beforeEach, expect, it, vi } from 'vitest'
const mocks = vi.hoisted(() => ({ list: vi.fn(), call: vi.fn(), toast: vi.fn() }))
vi.mock('../../api/mcp', () => ({ listAllMcpTools: mocks.list, callMcpTool: mocks.call }))
vi.mock('../common/toast', () => ({ showToast: mocks.toast }))
vi.mock('../../store', async () => { const { signal } = await import('@preact/signals'); return { shellAuthSummary: signal({ effective_role: 'worker' }) } })
import type { McpToolSchema } from '../../types/json-schema'
import { setStoredToken } from '../../api/core'
import { filteredTools, loadToolSchemas, schemasLoading, schemasError, selectTool, executeTool, lastResult, executing } from './tool-executor-state'
const schema = (name: string): McpToolSchema => ({ name, description: name, inputSchema: { type: 'object' } })
let epoch = 0
beforeEach(() => { setStoredToken(`synthetic-owner-${++epoch}`); mocks.list.mockReset(); mocks.call.mockReset(); mocks.toast.mockClear() })
it('retires the previous credential schema cache', async () => {
 mocks.list.mockResolvedValueOnce([schema('a')]); await loadToolSchemas(true)
 setStoredToken('synthetic-b'); expect(filteredTools.value).toEqual([])
 mocks.list.mockResolvedValueOnce([schema('b')]); await loadToolSchemas()
 expect(mocks.list).toHaveBeenCalledTimes(2)
 expect(filteredTools.value.map(t => t.name)).toEqual(['b'])
})
it('admits replacement loading and ignores old failure', async () => {
 let rejectOld!: (error: Error) => void
 mocks.list.mockImplementationOnce(() => new Promise((_, reject) => { rejectOld = reject }))
 const old = loadToolSchemas(true); setStoredToken('synthetic-replacement')
 mocks.list.mockResolvedValueOnce([schema('replacement')]); await loadToolSchemas()
 const calls = mocks.list.mock.calls.length
 rejectOld(new Error('old failure')); await old
 expect(calls).toBe(2)
 expect(filteredTools.value.map(t => t.name)).toEqual(['replacement'])
 expect(schemasError.value).toBeNull(); expect(schemasLoading.value).toBe(false)
 expect(mocks.toast).not.toHaveBeenCalled()
})

it('does not publish a result into a replacement selection', async () => {
 let resolve!: (text: string) => void
 mocks.call.mockImplementationOnce(() => new Promise<string>(r => { resolve = r }))
 selectTool(schema('first')); const pending = executeTool()
 await vi.waitFor(() => expect(mocks.call).toHaveBeenCalledTimes(1))
 selectTool(schema('second')); resolve('old output'); await pending
 expect(lastResult.value).toBeNull(); expect(executing.value).toBe(false)
 expect(mocks.toast).not.toHaveBeenCalled()
})
it('admits a new credential execution without old cleanup clearing its busy state', async () => {
 let resolveOld!: (text: string) => void
 let resolveNew!: (text: string) => void
 mocks.call.mockImplementationOnce(() => new Promise<string>(r => { resolveOld = r }))
 mocks.call.mockImplementationOnce(() => new Promise<string>(r => { resolveNew = r }))
 selectTool(schema('first')); const old = executeTool()
 await vi.waitFor(() => expect(mocks.call).toHaveBeenCalledTimes(1))
 setStoredToken('synthetic-execution-replacement'); selectTool(schema('second'))
 const replacement = executeTool(); await vi.waitFor(() => expect(mocks.call).toHaveBeenCalledTimes(2)); const calls = mocks.call.mock.calls.length
 resolveOld('old output'); await old
 const busy = executing.value; const result = lastResult.value
 resolveNew?.('new output'); await replacement
 expect(calls).toBe(2); expect(busy).toBe(true); expect(result).toBeNull()
 expect(lastResult.value?.toolName).toBe('second')
})
