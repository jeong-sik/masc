import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  callMcpTool: vi.fn(),
  shellAuthSummary: { value: null as unknown },
  showToast: vi.fn(),
}))
vi.mock('../../api/mcp', () => ({ callMcpTool: mocks.callMcpTool }))
vi.mock('../../store', () => ({
  shellAuthSummary: mocks.shellAuthSummary,
}))
vi.mock('../common/toast', () => ({ showToast: mocks.showToast }))

let runGarbageCollection: typeof import('./flow-control-state').runGarbageCollection

describe('flow-control-state', () => {
  beforeEach(async () => {
    vi.resetModules()
    vi.resetAllMocks()
    mocks.shellAuthSummary.value = {
      effective_role: 'admin', auth_error_code: null, auth_error_detail: null,
    }
    ;({ runGarbageCollection } = await import('./flow-control-state'))
  })

  it('rejects garbage collection for a worker', async () => {
    mocks.shellAuthSummary.value = { effective_role: 'worker' }
    await runGarbageCollection()
    expect(mocks.callMcpTool).not.toHaveBeenCalled()
    expect(mocks.showToast).toHaveBeenCalledWith('Current role is worker; admin role is required.', 'error', 6000)
  })

  it('runs garbage collection for an admin', async () => {
    mocks.shellAuthSummary.value = { effective_role: 'admin' }
    mocks.callMcpTool.mockResolvedValue('{ "removed": 0 }')
    await runGarbageCollection()
    expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_gc', {})
  })
})
