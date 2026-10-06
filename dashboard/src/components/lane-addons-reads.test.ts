import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { parseLaneAddonSnapshot, parseLaneAddonSlice } from '../api/lane-addons'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
const api = vi.hoisted(() => ({ fetchLaneAddons: vi.fn(), fetchLaneAddonSlice: vi.fn(), observeLaneAddon: vi.fn() }))
vi.mock('../api/lane-addons', async original => ({ ...await original<typeof import('../api/lane-addons')>(), ...api }))
import { LaneAddonsPanel } from './lane-addons-panel'

function snapshot(id: string) {
  return parseLaneAddonSnapshot({ configuration: null, rows: [], coverage: [], instances: [{
    instance_id: id, run_id: id, addon_id: 'test-package', title: id, revision: 'r1', incarnation: id,
    phase: { kind: 'attached' }, configuration: null, action_schema: null, observation_seq: 0, rows_count: 0,
    package: { outputs: {}, binding_schema: null, presentation: { description: null, readings: [] } },
  }] })
}
const slice = parseLaneAddonSlice({ complete: true, coverage: [], rows: [{
  id: 'event', lane_id: 'worker/output', kind: 'value', title: 'Frozen observation', observed_at: 1,
  subject_id: 'subject', actor: null, clock: null, fields: {}, evidence: [], related_ids: [],
}] })
function deferred<T>() {
  let resolve!: (value: T) => void, reject!: (reason: Error) => void
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}
let sequence = 0, generation = 0, epoch = ''
function workspace(root: string) {
  expect(hydrateExecutionSnapshot({ execution_publication_epoch: epoch, execution_publication_generation: ++generation,
    status: { project: 'read-ownership', workspace_root: root } } as Parameters<typeof hydrateExecutionSnapshot>[0])).toBe(true)
}
beforeEach(() => {
  epoch = `reads-${++sequence}`; generation = 0; invalidateExecutionSnapshotGeneration(epoch, 0); workspace('/A')
  api.fetchLaneAddons.mockResolvedValue(snapshot('worker'))
})
afterEach(() => { cleanup(); vi.resetAllMocks() })
type View = ReturnType<typeof render>
const click = (view: View, name: string) => fireEvent.click(view.getByRole('button', { name, exact: true }))
async function mounted() {
  const view = render(html`<${LaneAddonsPanel} />`)
  await view.findByRole('radio'); return view
}

it('keeps a pending Slice alive across inventory refresh and displays both results', async () => {
  const pending = deferred<typeof slice>()
  api.fetchLaneAddonSlice.mockReturnValue(pending.promise)
  const view = await mounted()
  click(view, 'Slice')
  const signal = api.fetchLaneAddonSlice.mock.calls[0]![1] as AbortSignal
  api.fetchLaneAddons.mockResolvedValue(snapshot('refreshed-worker')); click(view, 'Refresh')
  await view.findByRole('radio', { name: 'refreshed-worker' })
  expect(signal.aborted).toBe(false)
  expect(view.getByText('Reading requested slice…')).toBeTruthy()
  await act(async () => { pending.resolve(slice); await pending.promise })
  expect(view.getAllByText('Frozen observation', { exact: false }).length).toBeGreaterThan(0)
  expect(view.queryByText('Reading requested slice…')).toBeNull()
})

it('keeps an inventory refresh alive when a Slice is requested', async () => {
  const pending = deferred<ReturnType<typeof snapshot>>()
  api.fetchLaneAddonSlice.mockResolvedValue(slice)
  const view = await mounted()
  api.fetchLaneAddons.mockReturnValue(pending.promise); click(view, 'Refresh')
  const signal = api.fetchLaneAddons.mock.calls[1]![0] as AbortSignal
  click(view, 'Slice'); await view.findAllByText('Frozen observation', { exact: false })
  expect(signal.aborted).toBe(false)
  expect(view.getByText('Reading retained observations…')).toBeTruthy()
  await act(async () => { pending.resolve(snapshot('refreshed-worker')); await pending.promise })
  expect(view.getByRole('radio', { name: 'refreshed-worker' })).toBeTruthy()
  expect(view.queryByText('Reading retained observations…')).toBeNull()
})

it('Clear slice cancels only the pending Slice and cannot cancel an inventory refresh', async () => {
  const pending = deferred<typeof slice>(), inventory = deferred<ReturnType<typeof snapshot>>()
  api.fetchLaneAddonSlice.mockReturnValue(pending.promise)
  const view = await mounted()
  click(view, 'Slice'); const sliceSignal = api.fetchLaneAddonSlice.mock.calls[0]![1] as AbortSignal
  api.fetchLaneAddons.mockReturnValue(inventory.promise); click(view, 'Refresh')
  const inventorySignal = api.fetchLaneAddons.mock.calls[1]![0] as AbortSignal
  click(view, 'Clear slice')
  expect(sliceSignal.aborted).toBe(true); expect(inventorySignal.aborted).toBe(false)
  expect(view.getByText('Reading retained observations…')).toBeTruthy()
  expect(view.queryByText('Reading requested slice…')).toBeNull()
  await act(async () => { pending.resolve(slice); await pending.promise })
  expect(view.queryAllByText('Frozen observation', { exact: false })).toHaveLength(0)
  await act(async () => { inventory.resolve(snapshot('refreshed-worker')); await inventory.promise })
  expect(view.getByRole('radio', { name: 'refreshed-worker' })).toBeTruthy()
})

it('does not clear an inventory failure when a Slice succeeds', async () => {
  const view = await mounted()
  api.fetchLaneAddons.mockRejectedValue(new Error('Inventory unavailable')); click(view, 'Refresh')
  await view.findByText('Inventory unavailable')
  api.fetchLaneAddonSlice.mockResolvedValue(slice); click(view, 'Slice')
  await view.findAllByText('Frozen observation', { exact: false })
  expect(view.getByText('Inventory unavailable')).toBeTruthy()
  expect(view.getByText('Showing retained data after a failed request; current state is unverified.')).toBeTruthy()
})

it('does not clear a Slice failure when inventory refresh succeeds', async () => {
  const view = await mounted()
  api.fetchLaneAddonSlice.mockRejectedValue(new Error('Slice unavailable')); click(view, 'Slice')
  await view.findByText('Slice unavailable')
  api.fetchLaneAddons.mockResolvedValue(snapshot('refreshed-worker')); click(view, 'Refresh')
  await view.findByRole('radio', { name: 'refreshed-worker' })
  expect(view.getByText('Slice unavailable')).toBeTruthy()
  expect(view.queryByText('Showing retained data after a failed request; current state is unverified.')).toBeNull()
  click(view, 'Clear slice'); expect(view.queryByText('Slice unavailable')).toBeNull()
})

it('preserves a failed action when unrelated observations are refreshed', async () => {
  const view = await mounted()
  api.observeLaneAddon.mockRejectedValue(new Error('Observe request failed')); click(view, 'Observe')
  await view.findByText('Observe request failed')
  api.fetchLaneAddons.mockResolvedValue(snapshot('refreshed-worker')); click(view, 'Refresh')
  await view.findByRole('radio', { name: 'refreshed-worker' })
  api.fetchLaneAddonSlice.mockResolvedValue(slice); click(view, 'Slice')
  await view.findAllByText('Frozen observation', { exact: false })
  expect(view.getByText('Observe request failed')).toBeTruthy()
})

it.each(['inventory', 'slice'] as const)('supersedes only older %s reads without allowing a late finally or error to replace the pending state', async kind => {
  const view = await mounted()
  const first = deferred<unknown>(), second = deferred<unknown>()
  const fetch = kind === 'inventory' ? api.fetchLaneAddons : api.fetchLaneAddonSlice
  const button = kind === 'inventory' ? 'Refresh' : 'Slice'
  const loading = kind === 'inventory' ? 'Reading retained observations…' : 'Reading requested slice…'
  fetch.mockReturnValueOnce(first.promise).mockReturnValueOnce(second.promise)
  click(view, button)
  const oldSignal = fetch.mock.lastCall![kind === 'inventory' ? 0 : 1] as AbortSignal
  click(view, button)
  expect(oldSignal.aborted).toBe(true)
  await act(async () => { first.reject(new Error('Superseded failure')); await first.promise.catch(() => {}) })
  expect(view.queryByText('Superseded failure')).toBeNull(); expect(view.getByText(loading)).toBeTruthy()
  await act(async () => { second.resolve(kind === 'inventory' ? snapshot('latest-worker') : slice); await second.promise })
  expect(view.queryByText(loading)).toBeNull()
})

it('aborts both readers on workspace change and ignores late old-workspace results', async () => {
  const view = await mounted()
  const inventory = deferred<ReturnType<typeof snapshot>>(), pending = deferred<typeof slice>()
  api.fetchLaneAddonSlice.mockReturnValue(pending.promise)
  api.fetchLaneAddons.mockReturnValueOnce(inventory.promise).mockResolvedValue(snapshot('B-worker'))
  click(view, 'Refresh'); const inventorySignal = api.fetchLaneAddons.mock.lastCall![0] as AbortSignal
  click(view, 'Slice'); const sliceSignal = api.fetchLaneAddonSlice.mock.lastCall![1] as AbortSignal
  await act(() => workspace('/B')); await view.findByRole('radio', { name: 'B-worker' })
  expect(inventorySignal.aborted).toBe(true); expect(sliceSignal.aborted).toBe(true)
  await act(async () => { inventory.resolve(snapshot('late-A-worker')); pending.resolve(slice); await Promise.all([inventory.promise, pending.promise]) })
  expect(view.queryByRole('radio', { name: 'late-A-worker' })).toBeNull()
  expect(view.queryAllByText('Frozen observation', { exact: false })).toHaveLength(0)
})

it('aborts both readers on unmount', async () => {
  const view = await mounted()
  api.fetchLaneAddons.mockReturnValue(new Promise(() => {})); api.fetchLaneAddonSlice.mockReturnValue(new Promise(() => {}))
  click(view, 'Refresh'); const inventorySignal = api.fetchLaneAddons.mock.lastCall![0] as AbortSignal
  click(view, 'Slice'); const sliceSignal = api.fetchLaneAddonSlice.mock.lastCall![1] as AbortSignal
  view.unmount()
  await waitFor(() => { expect(inventorySignal.aborted).toBe(true); expect(sliceSignal.aborted).toBe(true) })
})

it('invalid Slice input cancels only its older pending query and keeps the validation error', async () => {
  const view = await mounted()
  const pending = deferred<typeof slice>(), inventory = deferred<ReturnType<typeof snapshot>>()
  api.fetchLaneAddonSlice.mockReturnValue(pending.promise); click(view, 'Slice')
  const sliceSignal = api.fetchLaneAddonSlice.mock.lastCall![1] as AbortSignal
  api.fetchLaneAddons.mockReturnValue(inventory.promise); click(view, 'Refresh')
  const inventorySignal = api.fetchLaneAddons.mock.lastCall![0] as AbortSignal
  fireEvent.input(view.getByLabelText('Since (Unix seconds)'), { target: { value: 'invalid' } }); click(view, 'Slice')
  expect(sliceSignal.aborted).toBe(true); expect(inventorySignal.aborted).toBe(false)
  expect(api.fetchLaneAddonSlice).toHaveBeenCalledTimes(1)
  await act(async () => { pending.resolve(slice); await pending.promise })
  expect(view.getByText('Use finite Unix seconds with since ≤ until.')).toBeTruthy()
  expect(view.queryAllByText('Frozen observation', { exact: false })).toHaveLength(0)
  await act(async () => { inventory.resolve(snapshot('refreshed-worker')); await inventory.promise })
  expect(view.getByRole('radio', { name: 'refreshed-worker' })).toBeTruthy()
})

it('does not claim retained inventory exists when both initial reads fail', async () => {
  api.fetchLaneAddons.mockRejectedValue(new Error('Initial inventory unavailable'))
  api.fetchLaneAddonSlice.mockRejectedValue(new Error('Initial slice unavailable'))
  const view = render(html`<${LaneAddonsPanel} />`)
  await view.findByText('Initial inventory unavailable'); click(view, 'Slice')
  await view.findByText('Initial slice unavailable')
  expect(view.getByText('Initial inventory unavailable')).toBeTruthy()
  expect(view.getByText(/No observations have been loaded/)).toBeTruthy()
  expect(view.queryByText(/The latest loaded inventory remains visible/)).toBeNull()
})
