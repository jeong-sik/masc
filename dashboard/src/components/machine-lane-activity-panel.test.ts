import { createHash } from 'node:crypto'
import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { parseLaneInventory } from '../api/lane-inventory'
import inventory from '../api/fixtures/lane-inventory.json'
import { executionWorkspaceAuthority, hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
import { committedRuntimeTomlConfigFixture } from '../lib/runtime-config-receipt.test-fixture'
import { RuntimeTomlRevisionConflict, RuntimeTomlSaveRejected, type RuntimeTomlConfig } from '../api/dashboard-runtime'
import { readMachineActivity, writeMachineActivity } from '../lib/machine-lane-activity'
import { machineLaneActivitySessionFor, resetMachineLaneActivitySessionsForTesting } from '../lib/machine-lane-activity-session'
import { runtimeTomlSessionFor, resetRuntimeTomlSessionsForTesting } from '../lib/runtime-toml-session'
import { announceRuntimeTomlWritten, runtimeTomlSourceGeneration } from '../lib/runtime-toml-source-generation'
import { MachineLaneActivityPanel } from './machine-lane-activity-panel'
import { LaneInventoryPanel } from './lane-inventory-panel'

const api = vi.hoisted(() => ({ fetchRuntimeTomlConfig: vi.fn(), previewRuntimeTomlConfig: vi.fn(), saveRuntimeTomlConfig: vi.fn(), fetchRuntimeResolved: vi.fn() }))
const projectionApi = vi.hoisted(() => ({ fetchStandaloneLanes: vi.fn() }))
const followup = vi.hoisted(() => ({ resumeSavedModelSetup: vi.fn(), refreshRuntimeConfigConsumers: vi.fn() }))
const inventoryApi = vi.hoisted(() => ({ fetchLaneInventory: vi.fn() }))
const dispatch = vi.hoisted(() => ({ waitForSaveToken: vi.fn() }))
vi.mock('../api/lane-inventory', async original => ({ ...await original<typeof import('../api/lane-inventory')>(), ...inventoryApi }))
vi.mock('../api/dashboard-runtime', async original => ({ ...await original<typeof import('../api/dashboard-runtime')>(), ...api,
  saveRuntimeTomlConfig: async (...args: [string, string, { beforeDispatch?: () => void }?]) => {
    await dispatch.waitForSaveToken(); args[2]?.beforeDispatch?.(); return api.saveRuntimeTomlConfig(...args)
  },
}))
vi.mock('../api/dashboard-standalone-lanes', async original => ({ ...await original<typeof import('../api/dashboard-standalone-lanes')>(), ...projectionApi }))
vi.mock('../lib/model-setup-resume', async original => ({ ...await original<typeof import('../lib/model-setup-resume')>(), resumeSavedModelSetup: followup.resumeSavedModelSetup }))
vi.mock('../lib/runtime-config-refresh', () => ({ refreshRuntimeConfigConsumers: followup.refreshRuntimeConfigConsumers }))

const lane = 'msx' as const
const title = parseLaneInventory(inventory).rows.find(row => row.id === 'machine/msx')!.label
const source = '# notes stay\n[machines.msx]\nenabled = true # preserve this comment\n\n[machines.dos]\nenabled = false\n\n[providers.extra]\nvalue = "keep"\n'
const off = source.replace('enabled = true', 'enabled = false')
const revision = (text: string) => createHash('sha256').update('runtime_config_source\0' + text).digest('hex')
function config(text = source, path = '/workspace/runtime.toml'): RuntimeTomlConfig {
  return { ok: true, path, file_name: 'runtime.toml', source_text: text, source_revision: revision(text),
    provider_protocols: [{ protocol: 'openai-compatible-http', transport: 'endpoint', semantics: 'http_provider',
      credential_policy: 'optional', requires_non_interactive: false, provider_fields: [], required_provider_fields: [] }], reserved_provider_ids: [] }
}
function receipt(text: string) {
  const value = committedRuntimeTomlConfigFixture({ ...config(text), path: '/workspace/runtime.toml' })
  value.source_revision = revision(text); value.commit.source_revision = revision(text)
  value.application.skills = { state: 'unchanged', input_source_revision: revision(text), snapshot_revision: 's', catalog_revision: 'c', config_state: 'configured' }
  return value
}
function document(text: string, path = '/workspace/runtime.toml') {
  return { source_path: path, source_text: text, source_revision: revision(text) }
}
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(done => { resolve = done }); return { promise, resolve } }
let epoch = 0, generation = 0, stored = source
function workspace(root: string) {
  hydrateExecutionSnapshot({ execution_publication_epoch: `machine-activity-${epoch}`, execution_publication_generation: ++generation,
    status: { project: 'fixture', workspace_root: root } } as Parameters<typeof hydrateExecutionSnapshot>[0])
  return executionWorkspaceAuthority.peek()!
}
beforeEach(() => {
  vi.resetAllMocks(); resetMachineLaneActivitySessionsForTesting(); resetRuntimeTomlSessionsForTesting()
  ++epoch; generation = 0; invalidateExecutionSnapshotGeneration(`machine-activity-${epoch}`, 0); workspace('/fixture/A'); stored = source
  api.fetchRuntimeTomlConfig.mockImplementation(async () => config(stored))
  api.previewRuntimeTomlConfig.mockResolvedValue({ ok: true, can_save: true })
  api.fetchRuntimeResolved.mockResolvedValue({ runtimes: [] })
  projectionApi.fetchStandaloneLanes.mockResolvedValue(parseLaneInventory(inventory).exact_snapshot)
  api.saveRuntimeTomlConfig.mockImplementation(async (text, expected) => {
    if (expected !== revision(stored)) throw new RuntimeTomlRevisionConflict('changed', document(stored))
    stored = text; return receipt(text)
  })
  followup.resumeSavedModelSetup.mockResolvedValue({ kind: 'active', exactOutputAvailable: true })
  followup.refreshRuntimeConfigConsumers.mockResolvedValue(undefined)
  inventoryApi.fetchLaneInventory.mockResolvedValue(parseLaneInventory(inventory))
})
afterEach(() => { cleanup(); resetMachineLaneActivitySessionsForTesting(); resetRuntimeTomlSessionsForTesting() })
async function draft() {
  const authority = executionWorkspaceAuthority.peek()!, session = machineLaneActivitySessionFor(authority, lane)
  await session.read(authority); session.toggle(authority); return { authority, session }
}

describe('Machine activity operator flow', () => {
  it('does not expose an invalid conflict document as an editable source', async () => {
    const { authority, session } = await draft(), previous = session.state.value.draft
    api.saveRuntimeTomlConfig.mockRejectedValueOnce(new RuntimeTomlRevisionConflict(
      'changed path', document('[broken', '/another/runtime.toml')))
    expect(await session.save(authority)).toBe(false)
    expect(session.state.value.uncertain).toBeNull()
    expect(session.state.value.current).toBeNull()
    expect(session.state.value.draft).toBe(previous)
    expect(session.ready(authority)).toBe(false)
    expect(await session.save(authority)).toBe(false)
    expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
  })

  it('retains a known conflict at another file until explicit discard', async () => {
    const { authority, session } = await draft(), previous = session.state.value.draft
    const current = document(source, '/another/runtime.toml')
    api.saveRuntimeTomlConfig.mockRejectedValueOnce(new RuntimeTomlRevisionConflict('changed path', current))
    const reads = api.fetchRuntimeTomlConfig.mock.calls.length
    expect(await session.save(authority)).toBe(false)
    expect(session.state.value.uncertain).toBeNull()
    expect(session.state.value.current).toEqual(current)
    expect(session.state.value.draft).toBe(previous)
    expect(api.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(reads)
    session.reapply(authority)
    expect(session.state.value.draft).toBe(previous)
    expect(await session.save(authority)).toBe(false)
    expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    session.discard(authority)
    expect(session.state.value.draft?.base).toEqual(current)
    expect(session.modified()).toBe(false)
  })
  it('keeps invalidation after a late preview failure without dispatching a save', async () => {
    const { authority, session } = await draft(), pending = deferred<void>()
    api.previewRuntimeTomlConfig.mockImplementationOnce(async () => {
      await pending.promise
      throw new Error('late preview unavailable')
    })
    const saving = session.save(authority)
    await waitFor(() => expect(api.previewRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    announceRuntimeTomlWritten()
    expect(session.state.value.current).toBeNull()
    pending.resolve(); expect(await saving).toBe(false)
    expect(session.state.value.current).toBeNull()
    expect(session.state.value.uncertain).toBeNull()
    expect(session.ready(authority)).toBe(false)
    expect(await session.save(authority)).toBe(false)
    expect(api.saveRuntimeTomlConfig).not.toHaveBeenCalled()
  })
  it('does not adopt a conflict response superseded by another source generation', async () => {
    const { authority, session } = await draft(), pending = deferred<void>()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async () => {
      await pending.promise
      throw new RuntimeTomlRevisionConflict('changed path', document(source, '/another/runtime.toml'))
    })
    const saving = session.save(authority)
    await waitFor(() => expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    announceRuntimeTomlWritten()
    pending.resolve(); expect(await saving).toBe(false)
    expect(session.state.value.uncertain).toBeNull()
    expect(session.state.value.current).toBeNull()
    expect(session.ready(authority)).toBe(false)
    expect(await session.save(authority)).toBe(false)
    expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
  })

  it('keeps a verified durable receipt certain when authority changes during follow-up', async () => {
    const { authority, session } = await draft(), pending = deferred<void>()
    followup.refreshRuntimeConfigConsumers.mockReturnValueOnce(pending.promise)
    const saving = session.save(authority)
    await waitFor(() => expect(session.state.value.receipt?.commit.durability).toBe('durable'))
    expect(session.state.value.phase).toBe('followup')
    expect(session.ready(authority)).toBe(false)
    const reads = api.fetchRuntimeTomlConfig.mock.calls.length
    await session.read(authority)
    expect(api.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(reads)
    expect(await session.save(authority)).toBe(false)
    expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    workspace('/fixture/B')
    expect(session.state.value.uncertain).toBeNull()
    expect(session.state.value.current).toBeNull()
    expect(session.state.value.receipt?.commit.durability).toBe('durable')
    pending.resolve(); await saving
    expect(session.state.value.uncertain).toBeNull()
  })
  it('still marks an unresolved sent save unknown when authority changes', async () => {
    const { authority, session } = await draft(), pending = deferred<ReturnType<typeof receipt>>()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async (_text, _revision, options) => {
      options?.beforeDispatch?.(); return pending.promise
    })
    const saving = session.save(authority)
    await waitFor(() => expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    workspace('/fixture/B')
    expect(session.state.value.uncertain).not.toBeNull()
    pending.resolve(receipt(off)); await saving
    expect(session.state.value.uncertain).not.toBeNull()
    expect(session.state.value.receipt).toBeNull()
  })
  it('settles a late raw refusal for a save sent before a workspace switch', async () => {
    const { session, authority } = await draft(), answer = deferred<void>()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async () => {
      await answer.promise; throw new RuntimeTomlSaveRejected('write refused before replacement')
    })
    const saving = session.save(authority)
    await waitFor(() => expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    workspace('/fixture/B')
    expect(session.state.value.uncertain).not.toBeNull()
    answer.resolve(); expect(await saving).toBe(false)
    expect(session.state.value.uncertain).toBeNull()
    expect(session.state.value.current).toBeNull()
    const fresh = workspace('/fixture/A')
    expect(session.ready(fresh)).toBe(false)
    await session.read(fresh)
    expect(session.state.value.draft?.enabled).toBe(false)
    expect(await session.save(fresh)).toBe(true)
    expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(2)
    expect(stored).toBe(off)
  })
  it('settles a late revision conflict without adopting its file after a workspace switch', async () => {
    const { session, authority } = await draft(), answer = deferred<void>()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async () => {
      await answer.promise; stored = source + '# elsewhere\n'
      throw new RuntimeTomlRevisionConflict('changed', document(stored))
    })
    const saving = session.save(authority)
    await waitFor(() => expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    workspace('/fixture/B')
    answer.resolve(); expect(await saving).toBe(false)
    expect(session.state.value.uncertain).toBeNull()
    expect(session.state.value.current).toBeNull()
    const fresh = workspace('/fixture/A')
    expect(session.ready(fresh)).toBe(false)
    await session.read(fresh)
    expect(session.state.value.current?.source_text).toBe(source + '# elsewhere\n')
    expect(await session.save(fresh)).toBe(false)
    session.reapply(fresh); expect(await session.save(fresh)).toBe(true)
    expect(stored).toBe(off + '# elsewhere\n')
  })
  it('lets a late refusal settle only the save that sent it', async () => {
    const { session, authority } = await draft(), answer = deferred<void>()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async () => {
      await answer.promise; throw new RuntimeTomlSaveRejected('late refusal')
    })
    const first = session.save(authority)
    await waitFor(() => expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    workspace('/fixture/B'); const fresh = workspace('/fixture/A')
    await session.read(fresh); session.reapply(fresh)
    api.saveRuntimeTomlConfig.mockRejectedValueOnce(new Error('connection lost'))
    expect(await session.save(fresh)).toBe(false)
    const second = session.state.value.uncertain
    expect(second).not.toBeNull()
    answer.resolve(); expect(await first).toBe(false)
    expect(session.state.value.uncertain).toBe(second)
  })
  it('follows a fresh file when there is no unsaved activity change', async () => {
    const authority = executionWorkspaceAuthority.peek()!, session = machineLaneActivitySessionFor(authority, lane)
    await session.read(authority)
    stored = off; await session.read(authority)
    expect(session.state.value.draft?.enabled).toBe(false)
    expect(session.state.value.draft?.base.source_revision).toBe(revision(off))
    session.toggle(authority); expect(await session.save(authority)).toBe(true)
    expect(stored).toBe(source)
  })

  it('rereads an activity response overtaken by a known file write', async () => {
    const authority = executionWorkspaceAuthority.peek()!, session = machineLaneActivitySessionFor(authority, lane)
    const old = deferred<RuntimeTomlConfig>(); api.fetchRuntimeTomlConfig.mockReturnValueOnce(old.promise)
    const reading = session.read(authority)
    stored = off; announceRuntimeTomlWritten(); old.resolve(config(source)); await reading
    expect(session.state.value.current?.source_text).toBe(off)
    expect(session.state.value.draft?.enabled).toBe(false)
    expect(api.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(2)
  })
  it('does not let an old raw comparison erase the invalidation from an activity save', async () => {
    const authority = executionWorkspaceAuthority.peek()!, raw = runtimeTomlSessionFor(authority)
    await raw.ensure(authority); raw.edit('draft', source + '# unsaved\n')
    const { session } = await draft(), old = deferred<RuntimeTomlConfig>()
    api.fetchRuntimeTomlConfig.mockReturnValueOnce(old.promise)
    const comparison = raw.read(authority, 'compare')
    expect(await session.save(authority)).toBe(true)
    old.resolve(config(source)); await comparison
    expect(raw.state.value.currentSource).toBeNull(); expect(raw.state.value.needsRead).toBe(true)
    expect(raw.state.value.draft).toBe(source + '# unsaved\n')
    await raw.read(authority, 'compare'); expect(raw.state.value.currentSource?.source_text).toBe(off)
  })
  it('finishes an activity save after navigation while completing its own readback without restarting an unmounted inventory component', async () => {
    const response = deferred<ReturnType<typeof receipt>>()
    api.saveRuntimeTomlConfig.mockReturnValueOnce(response.promise)
    const view = render(html`<${LaneInventoryPanel} />`)
    fireEvent.input(view.getByRole('searchbox', { name: 'Find a Lane' }), { target: { value: 'machine/msx' } })
    fireEvent.click(await view.findByRole('button', { name: `Inspect ${title}` }))
    fireEvent.click(view.getByRole('button', { name: '활동 설정 열기' }))
    fireEvent.click(await view.findByRole('switch'))
    fireEvent.click(view.getByRole('button', { name: '활동 설정 저장' }))
    await waitFor(() => expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    view.unmount()
    await act(async () => { stored = off; response.resolve(receipt(off)) })
    const session = machineLaneActivitySessionFor(executionWorkspaceAuthority.peek()!, lane)
    await waitFor(() => expect(session.state.value.current?.source_text).toBe(off))
    expect(inventoryApi.fetchLaneInventory).toHaveBeenCalledTimes(3)
  })
  it('retains a local draft across closing and remount; writes only on explicit Save', async () => {
    const view = render(html`<${MachineLaneActivityPanel} lane=${lane} title=${title} />`)
    expect(api.fetchRuntimeTomlConfig).not.toHaveBeenCalled()
    fireEvent.click(view.getByRole('button', { name: '활동 설정 열기' }))
    const toggle = await view.findByRole('switch', { name: `${title} 활동 초안` })
    fireEvent.click(toggle); expect(toggle.getAttribute('aria-checked')).toBe('false')
    expect(api.previewRuntimeTomlConfig).not.toHaveBeenCalled(); expect(api.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    view.unmount()
    const reopened = render(html`<${MachineLaneActivityPanel} lane=${lane} title=${title} />`)
    await waitFor(() => expect(reopened.getByRole('switch').hasAttribute('disabled')).toBe(false))
    expect(reopened.getByRole('switch').getAttribute('aria-checked')).toBe('false')
    fireEvent.click(reopened.getByRole('button', { name: '활동 설정 저장' }))
    await waitFor(() => expect(reopened.getByText(/파일 설정: 꺼짐/)).toBeTruthy())
    expect(stored).toBe(off); expect(api.saveRuntimeTomlConfig).toHaveBeenCalledWith(off, revision(source), expect.objectContaining({ expectedSourcePath: '/workspace/runtime.toml' }))
    expect(reopened.getByText(/파일 설정: 꺼짐/)).toBeTruthy()
    expect(reopened.getByText(/Exact registry 적용됨/)).toBeTruthy()
  })
  it('keeps backend paths, comments and newer unrelated edits when explicitly reapplying a conflict', async () => {
    const { session, authority } = await draft(); stored = source + 'extra = 9\n'
    expect(await session.save(authority)).toBe(false)
    expect(stored).toBe(source + 'extra = 9\n'); expect(session.state.value.draft?.enabled).toBe(false)
    expect(await session.save(authority)).toBe(false); expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    session.reapply(authority); expect(await session.save(authority)).toBe(true)
    expect(stored).toBe(off + 'extra = 9\n')
    expect(api.saveRuntimeTomlConfig).toHaveBeenLastCalledWith(stored, revision(source + 'extra = 9\n'), expect.any(Object))
  })
  it('does not replace the raw TOML editor draft, and invalidates its old save basis', async () => {
    const authority = executionWorkspaceAuthority.peek()!, raw = runtimeTomlSessionFor(authority)
    await raw.ensure(authority); raw.edit('draft', source + 'unsaved = true\n')
    const { session } = await draft(); expect(await session.save(authority)).toBe(true)
    expect(raw.state.value.draft).toBe(source + 'unsaved = true\n')
    expect(raw.state.value.needsRead).toBe(true)
    expect(raw.state.value.projectionRevision).toBe(1)
  })

  it('keeps preview refusal as a known no-write outcome and supports retry', async () => {
    const { session, authority } = await draft()
    api.previewRuntimeTomlConfig.mockResolvedValueOnce({ ok: true, can_save: false })
    expect(await session.save(authority)).toBe(false); expect(api.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    expect(session.state.value.uncertain).toBeNull(); expect(session.state.value.draft?.enabled).toBe(false)
    expect(await session.save(authority)).toBe(true)
  })
  it('retains a known no-write raw refusal and allows an explicit corrected retry', async () => {
    const { session, authority } = await draft()
    const before = session.state.peek(), generation = runtimeTomlSourceGeneration.peek()
    const reads = api.fetchRuntimeTomlConfig.mock.calls.length
    const observations = inventoryApi.fetchLaneInventory.mock.calls.length
    api.saveRuntimeTomlConfig.mockRejectedValueOnce(new RuntimeTomlSaveRejected('write refused before replacement'))
    expect(await session.save(authority)).toBe(false)
    expect(session.state.value.uncertain).toBeNull()
    expect(session.state.value.draft).toEqual(before.draft)
    expect(session.state.value.current).toEqual(before.current)
    expect(session.state.value.observation).toEqual(before.observation)
    expect(session.state.value.error).toContain('write refused before replacement')
    expect(runtimeTomlSourceGeneration.peek()).toBe(generation)
    expect(api.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(reads)
    expect(inventoryApi.fetchLaneInventory).toHaveBeenCalledTimes(observations)
    expect(followup.refreshRuntimeConfigConsumers).not.toHaveBeenCalled()
    expect(session.ready(authority)).toBe(true)
    expect(await session.save(authority)).toBe(true)
    expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(2)
    expect(api.saveRuntimeTomlConfig).toHaveBeenLastCalledWith(off, revision(source), expect.any(Object))
    expect(stored).toBe(off)
  })
  it('does not let a late A read overwrite a fresh A read after A-B-A', async () => {
    const first = deferred<RuntimeTomlConfig>(), authority = executionWorkspaceAuthority.peek()!
    const session = machineLaneActivitySessionFor(authority, lane)
    api.fetchRuntimeTomlConfig.mockReturnValueOnce(first.promise)
    const old = session.read(authority); workspace('/fixture/B'); const fresh = workspace('/fixture/A')
    await session.read(fresh); session.toggle(fresh)
    first.resolve(config(off)); await old
    expect(session.state.value.current?.source_text).toBe(source)
    expect(session.state.value.draft?.enabled).toBe(false); expect(session.ready(fresh)).toBe(true)
  })
  it('does not send a save after authority changes during preview', async () => {
    const { session, authority } = await draft(), preview = deferred<{ ok: boolean; can_save: boolean }>()
    api.previewRuntimeTomlConfig.mockReturnValueOnce(preview.promise)
    const saving = session.save(authority); workspace('/fixture/B'); workspace('/fixture/A')
    preview.resolve({ ok: true, can_save: true }); expect(await saving).toBe(false)
    expect(api.saveRuntimeTomlConfig).not.toHaveBeenCalled(); expect(session.state.value.draft?.enabled).toBe(false)
  })
  it.each(['preview', 'save token'] as const)('keeps an unsent save certain when authority changes during the %s wait', async wait => {
    const { session, authority } = await draft(), gate = deferred<void>()
    if (wait === 'preview') api.previewRuntimeTomlConfig.mockImplementationOnce(async () => {
      await gate.promise; return { ok: true, can_save: true }
    })
    else dispatch.waitForSaveToken.mockReturnValueOnce(gate.promise)
    const saving = session.save(authority)
    await waitFor(() => expect(wait === 'preview' ? api.previewRuntimeTomlConfig : dispatch.waitForSaveToken).toHaveBeenCalledTimes(1))
    workspace('/fixture/B')
    expect(session.state.value.uncertain).toBeNull()
    gate.resolve(); expect(await saving).toBe(false)
    expect(api.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    const fresh = workspace('/fixture/A'); await session.read(fresh)
    expect(session.state.value.draft?.enabled).toBe(false)
    expect(await session.save(fresh)).toBe(true)
    expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1); expect(stored).toBe(off)
  })
  it('ignores a late save receipt after leaving the workspace', async () => {
    const { session, authority } = await draft(), response = deferred<ReturnType<typeof receipt>>()
    api.saveRuntimeTomlConfig.mockReturnValueOnce(response.promise)
    const saving = session.save(authority); await waitFor(() => expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    workspace('/fixture/B'); const fresh = workspace('/fixture/A'); await session.read(fresh)
    response.resolve(receipt(off)); expect(await saving).toBe(false)
    expect(session.state.value.receipt).toBeNull(); expect(session.state.value.current?.source_text).toBe(source)
    expect(followup.resumeSavedModelSetup).not.toHaveBeenCalled()
  })
  it('requires a read after an unanswered write and does not blindly repeat it', async () => {
    const { session, authority } = await draft()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async text => { stored = text; throw new Error('connection lost') })
    expect(await session.save(authority)).toBe(false); expect(session.state.value.current).toBeNull()
    expect(await session.save(authority)).toBe(false); expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    await session.read(authority)
    expect(session.state.value.uncertain?.stage).toBe('answered'); expect(session.state.value.notice).toMatch(/보낸 내용이 파일에 보입니다/)
    session.reapply(authority)
    expect(await session.save(authority)).toBe(false); expect(session.modified()).toBe(false)
    expect(stored).toBe(off)
  })

  it('keeps uncertain durability separate from the freshly observed file', async () => {
    const { session, authority } = await draft()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async text => { stored = text; const value = receipt(text); value.commit.durability = 'unconfirmed'; return value })
    expect(await session.save(authority)).toBe(true)
    expect(session.state.value.receipt?.commit.durability).toBe('unconfirmed')
    expect(session.state.value.draft?.base.source_text).toBe(source)
    expect(await session.save(authority)).toBe(false)
    session.reapply(authority); expect(session.modified()).toBe(false)
  })
  it('does not adopt another file path without discard', async () => {
    const { session, authority } = await draft()
    api.fetchRuntimeTomlConfig.mockResolvedValueOnce(config(source, '/another/runtime.toml'))
    await session.read(authority); session.reapply(authority)
    expect(session.state.value.error).toMatch(/다른 파일/)
    expect(await session.save(authority)).toBe(false)
    session.discard(authority); expect(session.state.value.draft?.base.source_path).toBe('/another/runtime.toml')
  })
  it('rejects a mismatched receipt without claiming a saved setting', async () => {
    const { session, authority } = await draft(); api.saveRuntimeTomlConfig.mockResolvedValueOnce(receipt(source))
    expect(await session.save(authority)).toBe(false); expect(session.state.value.current).toBeNull()
    expect(session.state.value.receipt).toBeNull(); expect(session.state.value.uncertain?.stage).toBe('answered')
  })
})

describe('Machine inventory and backend isolation', () => {
  it.each(['workspace', 'source'] as const)('rechecks %s authority after the save token wait', async changed => {
    const { session, authority } = await draft(), token = deferred<void>()
    dispatch.waitForSaveToken.mockReturnValueOnce(token.promise)
    const saving = session.save(authority)
    await waitFor(() => expect(dispatch.waitForSaveToken).toHaveBeenCalledTimes(1))
    if (changed === 'workspace') { workspace('/fixture/B'); workspace('/fixture/A') }
    else { stored = source + '# written elsewhere\n'; announceRuntimeTomlWritten() }
    token.resolve(undefined)
    expect(await saving).toBe(false)
    expect(api.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    expect(session.state.value.current).toBeNull()
    expect(session.state.value.draft?.enabled).toBe(false)
  })
  it('withdraws a save basis changed in another screen while preview is pending', async () => {
    const { session, authority } = await draft(), preview = deferred<{ ok: boolean; can_save: boolean }>()
    api.previewRuntimeTomlConfig.mockReturnValueOnce(preview.promise)
    const saving = session.save(authority)
    stored = source + '# another screen saved\n'; announceRuntimeTomlWritten()
    preview.resolve({ ok: true, can_save: true })
    expect(await saving).toBe(false); expect(api.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    expect(session.state.value.current).toBeNull(); expect(session.state.value.uncertain).toBeNull()
    await session.read(authority); session.reapply(authority)
    expect(await session.save(authority)).toBe(true)
    expect(stored).toBe(off + '# another screen saved\n')
  })
  it('separates a valid file from failed server observation and permits a validated save', async () => {
    inventoryApi.fetchLaneInventory.mockRejectedValue(new Error('inventory offline'))
    const { session, authority } = await draft()
    expect(session.state.value.current?.source_text).toBe(source)
    expect(session.state.value.observation).toEqual({ kind: 'failed', error: expect.stringContaining('inventory offline') })
    expect(await session.save(authority)).toBe(true)
    expect(session.state.value.current?.source_text).toBe(off)
    expect(session.state.value.observation).toEqual({ kind: 'failed', error: expect.stringContaining('inventory offline') })
  })
  it('settles an editable file read while the server observation is still pending', async () => {
    const authority = executionWorkspaceAuthority.peek()!, session = machineLaneActivitySessionFor(authority, lane)
    const slow = deferred<ReturnType<typeof parseLaneInventory>>()
    inventoryApi.fetchLaneInventory.mockReturnValueOnce(slow.promise)
    const reading = session.read(authority)
    await waitFor(() => expect(session.state.value.phase).toBe('idle'))
    expect(session.state.value.current?.source_text).toBe(source)
    expect(session.state.value.observation).toEqual({ kind: 'reading' })
    session.toggle(authority); expect(await session.save(authority)).toBe(true)
    expect(stored).toBe(off)
    const settled = session.state.value.observation
    expect(settled.kind).toBe('observed')
    const late = parseLaneInventory(inventory)
    slow.resolve({ ...late, observed_at: late.observed_at - 60 })
    await reading
    expect(session.state.value.observation).toBe(settled)
  })
  it('shows file/server disagreement and unobserved activity without claiming Off', async () => {
    inventoryApi.fetchLaneInventory.mockImplementation(async () => {
      const value = parseLaneInventory(inventory)
      return { ...value, rows: value.rows.map(row => row.selection.kind === 'machine'
        && row.selection.machine === lane && row.state.kind === 'machine'
        ? { ...row, state: { ...row.state, activity: 'off' as const } } : row) }
    })
    const view = render(html`<${MachineLaneActivityPanel} lane=${lane} title=${title} />`)
    fireEvent.click(view.getByRole('button', { name: '활동 설정 열기' }))
    await view.findByText('파일 설정: 켜짐')
    expect(view.getByText('서버 활동 (마지막 조회): 꺼짐')).toBeTruthy()
    expect(view.getByText(/파일 설정과 마지막 서버 활동이 다릅니다/)).toBeTruthy()
    inventoryApi.fetchLaneInventory.mockResolvedValue({ ...parseLaneInventory(inventory),
      rows: parseLaneInventory(inventory).rows.map(row => row.state.kind === 'machine'
        ? { ...row, state: { ...row.state, activity: 'unobserved' as const } } : row) })
    fireEvent.click(view.getByRole('button', { name: '현재 설정 읽기' }))
    await view.findByText('서버 활동 (마지막 조회): 미확인')
    expect(view.queryByText(/파일 설정과 마지막 서버 활동이 다릅니다/)).toBeNull()
  })
  it('retains uncertainty even when readback finds the old revision; explicit reapply enables retry', async () => {
    const { session, authority } = await draft()
    api.saveRuntimeTomlConfig.mockRejectedValueOnce(new Error('lost before reply'))
    expect(await session.save(authority)).toBe(false)
    expect(session.state.value.current).toBeNull()
    expect(session.state.value.uncertain?.stage).toBe('answered')
    expect(await session.save(authority)).toBe(false)
    expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    await session.read(authority)
    expect(session.state.value.current?.source_text).toBe(source)
    expect(session.state.value.uncertain?.stage).toBe('answered'); expect(session.state.value.notice).toMatch(/아직 저장 전 그대로/)
    expect(await session.save(authority)).toBe(false); expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    session.reapply(authority); expect(await session.save(authority)).toBe(true); expect(stored).toBe(off)
  })
  it('keeps a saved receipt when file readback fails, and recovers on explicit read', async () => {
    const { session, authority } = await draft()
    api.fetchRuntimeTomlConfig.mockRejectedValueOnce(new Error('file unavailable'))
    expect(await session.save(authority)).toBe(true)
    expect(session.state.value.receipt).not.toBeNull()
    expect(session.state.value.current).toBeNull()
    expect(session.state.value.error).toContain('file unavailable')
    await session.read(authority)
    expect(session.state.value.current?.source_text).toBe(off)
    expect(session.state.value.receipt).not.toBeNull()
  })
  it.each([false, true])('refreshes inventory after save without model resume (remount: %s)', async remount => {
    const response = deferred<ReturnType<typeof receipt>>()
    api.saveRuntimeTomlConfig.mockReturnValueOnce(response.promise)
    inventoryApi.fetchLaneInventory.mockImplementation(async () => {
      const value = parseLaneInventory(inventory)
      return { ...value, rows: value.rows.map(row => row.selection.kind === 'machine' && row.selection.machine === lane
        && row.state.kind === 'machine'
        ? { ...row, state: { ...row.state, activity: readMachineActivity(stored, lane).enabled ? 'on' as const : 'off' as const } } : row) }
    })
    const mount = async () => {
      const view = render(html`<${LaneInventoryPanel} />`)
      fireEvent.input(view.getByRole('searchbox', { name: 'Find a Lane' }), { target: { value: 'machine/msx' } })
      fireEvent.click(await view.findByRole('button', { name: `Inspect ${title}` }))
      const panel = within(await view.findByRole('region', { name: `${title} 활동 설정` }))
      const open = panel.queryByRole('button', { name: /활동 설정 열기/ })
      if (open) fireEvent.click(open)
      return { view, panel }
    }
    const first = await mount()
    fireEvent.click(await first.panel.findByRole('switch'))
    fireEvent.click(first.panel.getByRole('button', { name: '활동 설정 저장' }))
    await waitFor(() => expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    if (remount) first.view.unmount()
    const next = remount ? await mount() : first
    await act(async () => { stored = off; response.resolve(receipt(off)) })
    await next.panel.findByText('파일 설정: 꺼짐')
    expect(await within(next.view.getByRole('region', { name: `Details for ${title}` })).findByText(/Off · machine state retained/)).toBeTruthy()
    expect(next.view.getByRole('button', { name: '활동 설정 닫기' })).toBeTruthy()
    expect(followup.resumeSavedModelSetup).not.toHaveBeenCalled()
    expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
  })
  it('retains a different backend draft but withdraws its stale save basis', async () => {
    const { session, authority } = await draft(), other = machineLaneActivitySessionFor(authority, 'dos')
    await other.read(authority); other.toggle(authority)
    expect(await session.save(authority)).toBe(true)
    expect(other.state.value.draft?.enabled).toBe(true)
    expect(other.state.value.current).toBeNull(); expect(await other.save(authority)).toBe(false)
    expect(other.state.value.notice).toContain('현재 파일 확인이 필요')
    await other.read(authority)
    expect(other.state.value.notice).toBeNull()
    other.reapply(authority)
    expect(await other.save(authority)).toBe(true)
    expect(readMachineActivity(stored, 'msx').enabled).toBe(false)
    expect(readMachineActivity(stored, 'dos').enabled).toBe(true)
    expect(stored).toContain('value = "keep"')
  })
  it('keeps the receipt and rereads the file when consumer refresh fails', async () => {
    const { session, authority } = await draft()
    followup.refreshRuntimeConfigConsumers.mockRejectedValueOnce(new Error('catalog offline'))
    expect(await session.save(authority)).toBe(true)
    expect(session.state.value.current?.source_text).toBe(off)
    expect(session.state.value.receipt?.commit.durability).toBe('durable')
    expect(session.state.value.followupError).toContain('catalog offline')
    expect(followup.resumeSavedModelSetup).not.toHaveBeenCalled()
  })
  it.each(['msx', 'dos'] as const)('allows %s off/on without loading a machine', async selected => {
    stored = '# no Machine installation\n'
    const authority = executionWorkspaceAuthority.peek()!, session = machineLaneActivitySessionFor(authority, selected)
    await session.read(authority); session.toggle(authority)
    expect(await session.save(authority)).toBe(true)
    expect(readMachineActivity(stored, selected).enabled).toBe(false)
    session.toggle(authority); expect(await session.save(authority)).toBe(true)
    expect(readMachineActivity(stored, selected).enabled).toBe(true)
    expect(followup.resumeSavedModelSetup).not.toHaveBeenCalled()
  })
})

describe('Machine configuration editing', () => {
  it.each([
    '[machines.msx]\nenabled=true # note\n',
    '[machines."msx"]\n"enabled" = true\t# note\r\n',
    '[machines]\nmsx = { enabled=true } # note\n',
    'machines.msx.enabled = true # note\n',
    'machines = { msx = { enabled = true }, dos = {enabled=false} } # note\n',
    '[machines]\nmsx={} # note\n',
    '[machines]\nmsx.enabled=true # note\n',
    '# note\n[providers.fixture]\nprompt="""[machines.msx]\nenabled=false"""\n',
  ])('edits only selected activity and preserves comments in accepted TOML: %s', text => {
    const changed = writeMachineActivity(text, 'msx', false)
    expect(readMachineActivity(changed, 'msx')).toEqual({ enabled: false })
    expect(readMachineActivity(changed, 'dos')).toEqual(readMachineActivity(text, 'dos'))
    expect(changed).toContain('# note')
    expect(readMachineActivity(writeMachineActivity(changed, 'msx', true), 'msx')).toEqual({ enabled: true })
  })
  it.each(['msx', 'dos'] as const)('defaults omitted %s to on', machine => {
    expect(readMachineActivity('', machine)).toEqual({ enabled: true })
    expect(readMachineActivity('[machines]\n', machine)).toEqual({ enabled: true })
  })
  it.each(['[bad', 'machines="bad"', 'machines=2026-10-05', 'machines=[]',
    '[machines.other]', '[machines.msx]\nenabled="false"', '[machines.dos]\nenabled=0',
    '[machines.msx]\nextra=true', '[machines.dos]\nextra=true', '[machines]\nmsx=false',
  ])('refuses malformed or unsupported machine settings: %s', text => {
    expect(() => readMachineActivity(text, 'msx')).toThrow()
    expect(() => writeMachineActivity(text, 'msx', false)).toThrow()
  })
})
