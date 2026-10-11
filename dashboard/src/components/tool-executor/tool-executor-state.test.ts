// @vitest-environment happy-dom
import { beforeEach, expect, it, vi } from 'vitest'
const mocks = vi.hoisted(() => ({ list: vi.fn(), toast: vi.fn() }))
vi.mock('../../api/mcp', () => ({ listAllMcpTools: mocks.list, callMcpTool: vi.fn() }))
vi.mock('../common/toast', () => ({ showToast: mocks.toast }))
vi.mock('../../store', async () => { const { signal } = await import('@preact/signals'); return { shellAuthSummary: signal(null) } })
import { setStoredToken } from '../../api/core'
import { filteredTools, loadToolSchemas, schemasLoading, schemasError } from './tool-executor-state'
const schema = (name: string) => ({ name, description: name, inputSchema: { type: 'object' } })
let epoch = 0
beforeEach(() => { setStoredToken(`synthetic-owner-${++epoch}`); mocks.list.mockReset(); mocks.toast.mockClear() })
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
