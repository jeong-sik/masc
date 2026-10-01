import { expect, it, vi } from 'vitest'
const api = vi.hoisted(() => ({ read: vi.fn(), refresh: vi.fn() }))
vi.mock('../../api/mcp', () => ({ callMcpTool: vi.fn() }))
vi.mock('../../api/core', () => ({ currentDashboardActor: () => 'operator', get: api.read }))
vi.mock('../../operator-store', () => ({
  dispatchOperatorAction: async () => ({ status: 'ok' }),
  confirmOperatorPendingAction: vi.fn(),
}))
vi.mock('../../namespace-truth-store', async () => {
  const { signal } = await import('@preact/signals')
  return {
    namespaceTruth: signal(null), namespaceTruthInitializing: signal(false),
    namespaceTruthError: signal(null), refreshNamespaceTruth: api.refresh,
  }
})
vi.mock('../../store', async () => {
  const { signal } = await import('@preact/signals')
  return { serverStatus: signal(null), shellAuthSummary: signal({ effective_role: 'admin' }) }
})
vi.mock('../common/toast', () => ({ showToast: vi.fn() }))
vi.mock('../common/confirm-dialog', () => ({ requestConfirm: vi.fn() }))
import { namespaceTruth, namespaceTruthError } from '../../namespace-truth-store'
import { flowState, resumeWorkspace } from './flow-control-state'

it('keeps direct readback authoritative across stale and failed reactive projections', async () => {
  const answer = { ok: true, initializing: false, paused: false }
  api.read.mockResolvedValue(answer)
  api.refresh.mockResolvedValue(undefined)
  await resumeWorkspace()
  expect(flowState.value).toBe('running')
  let release!: (value: typeof answer) => void
  api.read.mockImplementationOnce(() => new Promise(resolve => { release = resolve }))
  namespaceTruth.value = { root: { status: { paused: true } } } as typeof namespaceTruth.value
  expect(flowState.value).toBe('running')
  release(answer)
  await vi.waitFor(() => expect(flowState.value).toBe('running'))
  const before = api.read.mock.calls.length
  namespaceTruthError.value = 'projection unavailable'
  expect(flowState.value).toBe('running')
  await vi.waitFor(() => expect(api.read.mock.calls.length).toBeGreaterThan(before))
  expect(flowState.value).toBe('running')
})
