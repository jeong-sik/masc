import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { parseLaneAddonSnapshot, type LaneAddonActionRequest } from '../api/lane-addons'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
const api = vi.hoisted(() => ({ fetchLaneAddons: vi.fn(), fetchLaneAddonSlice: vi.fn(), observeLaneAddon: vi.fn(),
  requestLaneAddonAction: vi.fn(), fetchLaneAddonAction: vi.fn() }))
vi.mock('../api/lane-addons', async original => ({ ...await original<typeof import('../api/lane-addons')>(), ...api }))
import { LaneAddonsPanel } from './lane-addons-panel'
let generation = 0
let epoch = ''
let epochSequence = 0
function workspace(root: string | null) {
  expect(hydrateExecutionSnapshot({ execution_publication_epoch: epoch, execution_publication_generation: ++generation,
    status: { project: 'audit', workspace_root: root } } as Parameters<typeof hydrateExecutionSnapshot>[0])).toBe(true)
}
function snapshot(id: string, actions = false) {
  return parseLaneAddonSnapshot({ configuration: null, rows: [], coverage: [], instances: [{
    instance_id: id, run_id: id, addon_id: 'test-package', title: id, revision: 'r1', incarnation: id,
    phase: { kind: 'attached' }, configuration: null, action_schema: actions
      ? { type: 'object', properties: { action: { type: 'object' } } } : null, observation_seq: 0, rows_count: 0,
    package: { outputs: {}, binding_schema: null, presentation: { description: null, readings: [] } },
  }] })
}
beforeEach(() => { generation = 0; epoch = `missing-feature-audit-${++epochSequence}`;
  invalidateExecutionSnapshotGeneration(epoch, 0); workspace('/audit/A') })
afterEach(() => { cleanup(); vi.resetAllMocks() })
it('hides old-workspace actions after new-workspace read fails', async () => {
  api.fetchLaneAddons.mockResolvedValueOnce(snapshot('A-worker')).mockRejectedValue(new Error('B inventory failed'))
  api.observeLaneAddon.mockResolvedValue({})
  const screen = render(html`<${LaneAddonsPanel} />`)
  await screen.findByRole('radio')
  workspace('/audit/B')
  await screen.findByText('B inventory failed', { exact: true })
  expect(screen.queryByRole('button', { name: 'Observe', exact: true })).toBeNull()
  expect(screen.queryByRole('button', { name: 'Remove worker', exact: true })).toBeNull()
  expect(screen.queryByText('No Lane instances or retained observations.')).toBeNull()
  expect(screen.getByText('No observations loaded for the current workspace.')).toBeTruthy()
  expect(api.observeLaneAddon).not.toHaveBeenCalled()
})
it('hides rows and refuses queries when workspace authority is withdrawn', async () => {
  api.fetchLaneAddons.mockResolvedValue(snapshot('A-worker'))
  const screen = render(html`<${LaneAddonsPanel} />`)
  await screen.findByRole('radio')
  await act(() => workspace(null))
  expect(screen.queryByRole('radio')).toBeNull()
  expect((screen.getByRole('button', { name: 'Attach', exact: true }) as HTMLButtonElement).disabled).toBe(true)
  expect((screen.getByRole('button', { name: 'Slice', exact: true }) as HTMLButtonElement).disabled).toBe(true)
  expect(api.fetchLaneAddons).toHaveBeenCalledTimes(1)
})
it('keeps a late A mutation receipt from replacing a completed B receipt', async () => {
  let root = 'A-worker'
  let finishA!: (value: unknown) => void
  api.fetchLaneAddons.mockImplementation(() => Promise.resolve(snapshot(root)))
  api.observeLaneAddon.mockImplementationOnce(() => new Promise(resolve => { finishA = resolve }))
    .mockResolvedValue({ workspace: 'B receipt' })
  const screen = render(html`<${LaneAddonsPanel} />`)
  await screen.findByRole('radio')
  fireEvent.click(screen.getByRole('button', { name: 'Observe', exact: true }))
  root = 'B-worker'; await act(() => workspace('/audit/B'))
  await screen.findAllByText('B-worker', { exact: false })
  fireEvent.click(screen.getByRole('button', { name: 'Observe', exact: true }))
  await screen.findByText(/B receipt/)
  await act(async () => { finishA({ workspace: 'A late receipt' }); await Promise.resolve() })
  expect(screen.queryByText(/A late receipt/)).toBeNull()
  expect(screen.getByText(/B receipt/)).toBeTruthy()
  expect(api.fetchLaneAddons).toHaveBeenCalledTimes(3)
})
function actionReceipt(request: LaneAddonActionRequest) {
  return { ...request, incarnation: request.expected_incarnation, requester: 'audit', executor: null,
    input_sha256: 'fixture', state: 'queued', result: null, detail: null }
}
it('keeps pending action IDs with A without blocking B and restores the receipt on return', async () => {
  let root = 'A-worker'
  let finishA!: (value: ReturnType<typeof actionReceipt>) => void
  api.fetchLaneAddons.mockImplementation(() => Promise.resolve(snapshot(root, true)))
  api.requestLaneAddonAction.mockImplementationOnce(() => new Promise(resolve => { finishA = resolve }))
    .mockImplementation((request: LaneAddonActionRequest) => Promise.resolve(actionReceipt(request)))
  const screen = render(html`<${LaneAddonsPanel} />`)
  fireEvent.change(await screen.findByLabelText('Action instance'), { target: { value: 'A-worker:A-worker' } })
  fireEvent.click(screen.getByRole('button', { name: 'Send new request' }))
  await screen.findByText('Awaiting acceptance receipt')
  const requestA = api.requestLaneAddonAction.mock.calls[0]![0] as LaneAddonActionRequest
  root = 'B-worker'; await act(() => workspace('/audit/B'))
  await screen.findAllByText('B-worker', { exact: false })
  expect(screen.queryByText(`Request ID: ${requestA.request_id}`)).toBeNull()
  fireEvent.change(screen.getByLabelText('Action instance'), { target: { value: 'B-worker:B-worker' } })
  expect((screen.getByRole('button', { name: 'Send new request' }) as HTMLButtonElement).disabled).toBe(false)
  fireEvent.click(screen.getByRole('button', { name: 'Send new request' }))
  await screen.findByText('Queued')
  await act(async () => { finishA(actionReceipt(requestA)); await Promise.resolve() })
  expect(screen.queryByText(`Request ID: ${requestA.request_id}`)).toBeNull()
  root = 'A-worker'; await act(() => workspace('/audit/A'))
  await screen.findByText(`Request ID: ${requestA.request_id}`)
  expect(screen.getByText('Queued')).toBeTruthy()
  expect(api.requestLaneAddonAction).toHaveBeenCalledTimes(2)
})
it('cancels A status reads and permits a new check without losing its controller to old finally', async () => {
  let root = 'A-worker'
  let finishOld!: (value: ReturnType<typeof actionReceipt>) => void
  let finishNew!: (value: ReturnType<typeof actionReceipt>) => void
  api.fetchLaneAddons.mockImplementation(() => Promise.resolve(snapshot(root, true)))
  api.requestLaneAddonAction.mockImplementation((request: LaneAddonActionRequest) => Promise.resolve(actionReceipt(request)))
  api.fetchLaneAddonAction.mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve }))
    .mockImplementationOnce(() => new Promise(resolve => { finishNew = resolve }))
  const screen = render(html`<${LaneAddonsPanel} />`)
  fireEvent.change(await screen.findByLabelText('Action instance'), { target: { value: 'A-worker:A-worker' } })
  fireEvent.click(screen.getByRole('button', { name: 'Send new request' }))
  await screen.findByText('Queued')
  const requestA = api.requestLaneAddonAction.mock.calls[0]![0] as LaneAddonActionRequest
  fireEvent.click(screen.getByRole('button', { name: 'Check request status' }))
  await screen.findByRole('button', { name: 'Checking request status…' })
  const oldSignal = api.fetchLaneAddonAction.mock.calls[0]![1] as AbortSignal
  root = 'B-worker'; await act(() => workspace('/audit/B'))
  await screen.findAllByText('B-worker', { exact: false })
  expect(oldSignal.aborted).toBe(true)
  root = 'A-worker'; await act(() => workspace('/audit/A'))
  const check = await screen.findByRole('button', { name: 'Check request status' }) as HTMLButtonElement
  expect(check.disabled).toBe(false); fireEvent.click(check)
  await screen.findByRole('button', { name: 'Checking request status…' })
  await act(async () => { finishOld(actionReceipt(requestA)); await Promise.resolve() })
  expect((screen.getByRole('button', { name: 'Checking request status…' }) as HTMLButtonElement).disabled).toBe(true)
  const newSignal = api.fetchLaneAddonAction.mock.calls[1]![1] as AbortSignal
  expect(newSignal.aborted).toBe(false)
  await act(async () => { finishNew(actionReceipt(requestA)); await Promise.resolve() })
  expect((screen.getByRole('button', { name: 'Check request status' }) as HTMLButtonElement).disabled).toBe(false)
})
it('does not mix frozen A observations into B inventory', async () => {
  api.fetchLaneAddons.mockResolvedValueOnce(snapshot('A-worker')).mockResolvedValue(snapshot('B-worker'))
  api.fetchLaneAddonSlice.mockResolvedValue({ complete: true, coverage: [], rows: [{
    id: 'A-event', lane_id: 'A-worker/output', kind: 'value', title: 'Frozen A observation', observed_at: 1,
    subject_id: 'A-subject', actor: null, clock: null, fields: { source: 'workspace A' }, evidence: [], related_ids: [],
  }] })
  const screen = render(html`<${LaneAddonsPanel} />`)
  await screen.findByRole('radio')
  fireEvent.click(screen.getByRole('button', { name: 'Slice', exact: true }))
  await screen.findAllByText('Frozen A observation', { exact: false })
  workspace('/audit/B')
  await screen.findAllByText('B-worker', { exact: false })
  expect(screen.queryAllByText('Frozen A observation', { exact: false })).toHaveLength(0)
})
