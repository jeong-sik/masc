import { beforeEach, afterEach, expect, it, vi } from 'vitest'
import { waitFor } from '@testing-library/preact'
const api = vi.hoisted(() => ({ fetchRuntimeProviders: vi.fn(), fetchRuntimeResolved: vi.fn() }))
vi.mock('../api/dashboard', () => api)
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
import { loadRuntimeCatalog, reloadRuntimeCatalog, resetRuntimeCatalog, runtimeCatalogState } from './runtime-catalog-resource'
import { loadRuntimeResolved, reloadRuntimeResolved, resetRuntimeResolved, runtimeResolvedState } from './runtime-resolved-resource'
let epoch = 0, generation = 0
function workspace(root: string | null) {
  hydrateExecutionSnapshot({ execution_publication_epoch: `runtime-cache-${epoch}`, execution_publication_generation: ++generation,
    status: { project: 'fixture', workspace_root: root } } as Parameters<typeof hydrateExecutionSnapshot>[0])
}
beforeEach(() => {
  resetRuntimeCatalog(); resetRuntimeResolved(); vi.resetAllMocks(); generation = 0
  invalidateExecutionSnapshotGeneration(`runtime-cache-${++epoch}`, 0); workspace('/fixture/A')
})
afterEach(() => { resetRuntimeCatalog(); resetRuntimeResolved() })
const cases = [
  { name: 'catalog', api: api.fetchRuntimeProviders, load: loadRuntimeCatalog, reload: reloadRuntimeCatalog,
    state: runtimeCatalogState, reset: resetRuntimeCatalog, payload: (id: string) => ({ providers: [{ provider: id, runtime_id: id, models: [] }] }),
    value: (id: string) => [{ provider: id, runtime_id: id, models: [] }] },
  { name: 'resolved', api: api.fetchRuntimeResolved, load: loadRuntimeResolved, reload: reloadRuntimeResolved,
    state: runtimeResolvedState, reset: resetRuntimeResolved, payload: (id: string) => ({ config_path: id, runtimes: [], lanes: [], assignments: [] }),
    value: (id: string) => ({ config_path: id, runtimes: [], lanes: [], assignments: [] }) },
]
it.each(cases)('$name hides loaded A immediately and automatically reads B for existing consumers', async item => {
  let finishB!: (value: unknown) => void
  item.api.mockResolvedValueOnce(item.payload('A')).mockImplementationOnce(() => new Promise(resolve => { finishB = resolve }))
  await item.reload()
  expect(item.state.value).toEqual({ status: 'loaded', data: item.value('A') })
  workspace('/fixture/B')
  expect(item.state.value.status).not.toBe('loaded')
  await waitFor(() => expect(item.api).toHaveBeenCalledTimes(2))
  finishB(item.payload('B'))
  await waitFor(() => expect(item.state.value).toEqual({ status: 'loaded', data: item.value('B') }))
})
it.each(cases)('$name refuses a late A response after B becomes current', async item => {
  let finishA!: (value: unknown) => void
  item.api.mockImplementationOnce(() => new Promise(resolve => { finishA = resolve })).mockResolvedValue(item.payload('B'))
  const pending = item.reload().catch(() => {})
  await waitFor(() => expect(item.api).toHaveBeenCalledTimes(1))
  workspace('/fixture/B')
  finishA(item.payload('A')); await pending
  await waitFor(() => expect(item.state.value).toEqual({ status: 'loaded', data: item.value('B') }))
})
it.each(cases)('$name withdraws data and refuses reads until authority is restored', async item => {
  item.api.mockResolvedValueOnce(item.payload('A')).mockResolvedValue(item.payload('B'))
  await item.reload(); workspace(null)
  item.load()
  expect(item.state.value.status).toBe('error')
  expect(item.api).toHaveBeenCalledTimes(1)
  workspace('/fixture/B')
  await waitFor(() => expect(item.state.value).toEqual({ status: 'loaded', data: item.value('B') }))
})

it.each(cases)('$name waits for demand, and repeated unknown-workspace loads remain stable', async item => {
  workspace(null)
  expect(item.state.value.status).toBe('idle')
  item.load(); const unavailable = item.state.value
  item.load(); item.load()
  expect(item.state.value).toBe(unavailable)
  expect(item.api).not.toHaveBeenCalled()
  await expect(item.reload()).rejects.toThrow('작업공간')
  expect(item.api).not.toHaveBeenCalled()
})

it.each(cases)('$name keeps a failed B reading explicit without retrying on every render', async item => {
  item.api.mockResolvedValueOnce(item.payload('A')).mockRejectedValueOnce(new Error('B unavailable'))
    .mockResolvedValue(item.payload('B recovered'))
  await item.reload(); workspace('/fixture/B')
  await waitFor(() => expect(item.state.value).toEqual({ status: 'error', message: 'B unavailable' }))
  await item.load(); await item.load()
  expect(item.api).toHaveBeenCalledTimes(2)
  await item.reload()
  expect(item.state.value).toEqual({ status: 'loaded', data: item.value('B recovered') })
})

it.each(cases)('$name ignores old errors and finally without clearing B request deduplication', async item => {
  let failA!: (error: Error) => void, finishB!: (value: unknown) => void
  item.api.mockImplementationOnce(() => new Promise((_resolve, reject) => { failA = reject }))
    .mockImplementationOnce(() => new Promise(resolve => { finishB = resolve }))
  const old = item.reload().catch(() => {})
  await waitFor(() => expect(item.api).toHaveBeenCalledTimes(1))
  const signalA = item.api.mock.calls[0]![0].signal as AbortSignal
  workspace('/fixture/B')
  await waitFor(() => expect(item.api).toHaveBeenCalledTimes(2))
  expect(signalA.aborted).toBe(true)
  failA(new Error('late A failure')); await old
  expect(item.state.value.status).toBe('loading')
  item.load(); expect(item.api).toHaveBeenCalledTimes(2)
  finishB(item.payload('B'))
  await waitFor(() => expect(item.state.value).toEqual({ status: 'loaded', data: item.value('B') }))
})

it.each(cases)('$name cannot revive an old A response after A-B-A', async item => {
  let finishOldA!: (value: unknown) => void
  item.api.mockImplementationOnce(() => new Promise(resolve => { finishOldA = resolve }))
    .mockResolvedValueOnce(item.payload('B')).mockResolvedValueOnce(item.payload('new A'))
  const old = item.reload().catch(() => {})
  await waitFor(() => expect(item.api).toHaveBeenCalledTimes(1))
  workspace('/fixture/B')
  await waitFor(() => expect(item.state.value).toEqual({ status: 'loaded', data: item.value('B') }))
  workspace('/fixture/A')
  await waitFor(() => expect(item.state.value).toEqual({ status: 'loaded', data: item.value('new A') }))
  finishOldA(item.payload('old A')); await old
  expect(item.state.value).toEqual({ status: 'loaded', data: item.value('new A') })
})

it.each(cases)('$name cancels demand on reset and can register it again later', async item => {
  item.api.mockResolvedValueOnce(item.payload('A')).mockResolvedValue(item.payload('B'))
  await item.reload(); item.reset(); workspace('/fixture/B')
  await Promise.resolve()
  expect(item.state.value.status).toBe('idle')
  expect(item.api).toHaveBeenCalledTimes(1)
  item.load()
  await waitFor(() => expect(item.state.value).toEqual({ status: 'loaded', data: item.value('B') }))
})
