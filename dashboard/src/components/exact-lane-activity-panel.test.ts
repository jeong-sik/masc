import { createHash } from 'node:crypto'
import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { parseLaneInventory } from '../api/lane-inventory'
import inventory from '../api/fixtures/lane-inventory.json'
import { executionWorkspaceAuthority, hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
import { committedRuntimeTomlConfigFixture } from '../lib/runtime-config-receipt.test-fixture'
import { RuntimeTomlRevisionConflict, type RuntimeTomlConfig } from '../api/dashboard-runtime'
import { readExactActivity, writeExactActivity } from '../lib/exact-lane-activity'
import { exactLaneActivitySessionFor, resetExactLaneActivitySessionsForTesting } from '../lib/exact-lane-activity-session'
import { runtimeTomlSessionFor, resetRuntimeTomlSessionsForTesting } from '../lib/runtime-toml-session'
import { announceRuntimeTomlWritten } from '../lib/runtime-toml-source-generation'
import { ExactLaneActivityPanel } from './exact-lane-activity-panel'
import { LaneInventoryPanel } from './lane-inventory-panel'
import { RuntimeTomlEditor } from './runtime-toml-editor'

const api = vi.hoisted(() => ({ fetchRuntimeTomlConfig: vi.fn(), previewRuntimeTomlConfig: vi.fn(), saveRuntimeTomlConfig: vi.fn(), fetchRuntimeResolved: vi.fn() }))
const projectionApi = vi.hoisted(() => ({ fetchStandaloneLanes: vi.fn() }))
const followup = vi.hoisted(() => ({ resumeSavedModelSetup: vi.fn(), refreshRuntimeConfigConsumers: vi.fn() }))
const inventoryApi = vi.hoisted(() => ({ fetchLaneInventory: vi.fn() }))
vi.mock('../api/lane-inventory', async original => ({ ...await original<typeof import('../api/lane-inventory')>(), ...inventoryApi }))
vi.mock('../api/dashboard-runtime', async original => ({ ...await original<typeof import('../api/dashboard-runtime')>(), ...api }))
vi.mock('../api/dashboard-standalone-lanes', async original => ({ ...await original<typeof import('../api/dashboard-standalone-lanes')>(), ...projectionApi }))
vi.mock('../lib/model-setup-resume', async original => ({ ...await original<typeof import('../lib/model-setup-resume')>(), resumeSavedModelSetup: followup.resumeSavedModelSetup }))
vi.mock('../lib/runtime-config-refresh', () => ({ refreshRuntimeConfigConsumers: followup.refreshRuntimeConfigConsumers }))

const lane = parseLaneInventory(inventory).exact_snapshot.lanes.find(row => row.laneId === 'librarian_exact')!
const required = parseLaneInventory(inventory).exact_snapshot.lanes.find(row => row.laneId === 'board_attention_exact')!
const source = '# notes stay\n[runtime.exact_output_lanes.librarian_exact]\nslots = ["first", "second"]\ncli_slots = ["client"]\nenabled = true # preserve this comment\n\n[providers.extra]\nvalue = "keep"\n'
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
  hydrateExecutionSnapshot({ execution_publication_epoch: `exact-activity-${epoch}`, execution_publication_generation: ++generation,
    status: { project: 'fixture', workspace_root: root } } as Parameters<typeof hydrateExecutionSnapshot>[0])
  return executionWorkspaceAuthority.peek()!
}
beforeEach(() => {
  vi.resetAllMocks(); resetExactLaneActivitySessionsForTesting(); resetRuntimeTomlSessionsForTesting()
  ++epoch; generation = 0; invalidateExecutionSnapshotGeneration(`exact-activity-${epoch}`, 0); workspace('/fixture/A'); stored = source
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
afterEach(() => { cleanup(); resetExactLaneActivitySessionsForTesting(); resetRuntimeTomlSessionsForTesting() })
async function draft() {
  const authority = executionWorkspaceAuthority.peek()!, session = exactLaneActivitySessionFor(authority, lane)
  await session.read(authority); session.toggle(authority); return { authority, session }
}

describe('Exact activity operator flow', () => {
  it.each(['Runtime', 'All Lanes'].flatMap(surface => [false, true].map(remount => ({ surface, remount }))))(
    'refreshes $surface after a delayed resume (remount: $remount)', async ({ surface, remount }) => {
    const resume = deferred<{ kind: 'active'; exactOutputAvailable: boolean }>()
    let published = false
    followup.resumeSavedModelSetup.mockReturnValueOnce(resume.promise)
    const snapshot = () => {
      const value = parseLaneInventory(inventory)
      value.exact_snapshot.lanes = value.exact_snapshot.lanes.map(row => row.laneId === lane.laneId
        ? { ...row, status: published ? 'off' : 'unavailable' } : row)
      return value
    }
    inventoryApi.fetchLaneInventory.mockImplementation(async () => snapshot())
    projectionApi.fetchStandaloneLanes.mockImplementation(async () => snapshot().exact_snapshot)
    const mount = async () => {
      const view = render(surface === 'Runtime' ? html`<${RuntimeTomlEditor} />` : html`<${LaneInventoryPanel} />`)
      if (surface === 'Runtime') fireEvent.click(await view.findByTestId('runtime-toml-nav-lanes'))
      else fireEvent.click(await view.findByRole('button', { name: `Inspect ${lane.label}` }))
      const panel = within(await view.findByRole('region', { name: `${lane.label} 활동 설정` }))
      const open = panel.queryByRole('button', { name: /활동 설정 열기/ })
      if (open) fireEvent.click(open)
      return { view, panel }
    }
    const first = await mount()
    fireEvent.click(await first.panel.findByRole('switch'))
    fireEvent.click(first.panel.getByRole('button', { name: '활동 설정 저장' }))
    await waitFor(() => expect(followup.resumeSavedModelSetup).toHaveBeenCalledTimes(1))
    if (remount) first.view.unmount()
    const next = remount ? await mount() : first
    expect(await next.view.findByText(/관측 상태: unavailable/)).toBeTruthy()
    await act(async () => { published = true; resume.resolve({ kind: 'active', exactOutputAvailable: true }) })
    // Query the current DOM, including any projection-triggered remount.
    await waitFor(() => expect(next.view.getByText(/관측 상태: off/)).toBeTruthy())
    expect(next.view.getByText(/Exact registry 적용됨/)).toBeTruthy()
    expect(next.view.getByRole('button', { name: '활동 설정 닫기' })).toBeTruthy()
  })
  it('follows a fresh file when there is no unsaved activity change', async () => {
    const authority = executionWorkspaceAuthority.peek()!, session = exactLaneActivitySessionFor(authority, lane)
    await session.read(authority)
    stored = off; await session.read(authority)
    expect(session.state.value.draft?.enabled).toBe(false)
    expect(session.state.value.draft?.base.source_revision).toBe(revision(off))
    session.toggle(authority); expect(await session.save(authority)).toBe(true)
    expect(stored).toBe(source)
  })
  it('allows repairing a Required lane declared off, then prevents turning it off again', async () => {
    stored = '[runtime.exact_output_lanes.board_attention_exact]\nslots=["first"]\nenabled=false\n'
    const view = render(html`<${ExactLaneActivityPanel} lane=${required} />`)
    fireEvent.click(view.getByRole('button', { name: '활동 설정 열기' }))
    const toggle = await view.findByRole('switch')
    expect(toggle.hasAttribute('disabled')).toBe(false)
    fireEvent.click(toggle)
    expect(toggle.getAttribute('aria-checked')).toBe('true'); expect(toggle.hasAttribute('disabled')).toBe(true)
    expect(view.getByRole('button', { name: '활동 설정 저장' }).hasAttribute('disabled')).toBe(false)
  })
  it('rereads an activity response overtaken by a known file write', async () => {
    const authority = executionWorkspaceAuthority.peek()!, session = exactLaneActivitySessionFor(authority, lane)
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
  it('finishes an activity save after navigation without restarting an unmounted inventory read', async () => {
    const response = deferred<ReturnType<typeof receipt>>()
    api.saveRuntimeTomlConfig.mockReturnValueOnce(response.promise)
    const view = render(html`<${LaneInventoryPanel} />`)
    fireEvent.click(await view.findByRole('button', { name: `Inspect ${lane.label}` }))
    fireEvent.click(view.getByRole('button', { name: '활동 설정 열기' }))
    fireEvent.click(await view.findByRole('switch'))
    fireEvent.click(view.getByRole('button', { name: '활동 설정 저장' }))
    await waitFor(() => expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    view.unmount()
    await act(async () => { stored = off; response.resolve(receipt(off)) })
    const session = exactLaneActivitySessionFor(executionWorkspaceAuthority.peek()!, lane)
    await waitFor(() => expect(session.state.value.current?.source_text).toBe(off))
    expect(inventoryApi.fetchLaneInventory).toHaveBeenCalledTimes(1)
  })
  it('retains a local draft across closing and remount; writes only on explicit Save', async () => {
    const view = render(html`<${ExactLaneActivityPanel} lane=${lane} />`)
    expect(api.fetchRuntimeTomlConfig).not.toHaveBeenCalled()
    fireEvent.click(view.getByRole('button', { name: '활동 설정 열기' }))
    const toggle = await view.findByRole('switch', { name: `${lane.label} 활동 초안` })
    fireEvent.click(toggle); expect(toggle.getAttribute('aria-checked')).toBe('false')
    expect(api.previewRuntimeTomlConfig).not.toHaveBeenCalled(); expect(api.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    view.unmount()
    const reopened = render(html`<${ExactLaneActivityPanel} lane=${lane} />`)
    await waitFor(() => expect(reopened.getByRole('switch').hasAttribute('disabled')).toBe(false))
    expect(reopened.getByRole('switch').getAttribute('aria-checked')).toBe('false')
    fireEvent.click(reopened.getByRole('button', { name: '활동 설정 저장' }))
    await waitFor(() => expect(reopened.getByText(/파일 설정: 꺼짐/)).toBeTruthy())
    expect(stored).toBe(off); expect(api.saveRuntimeTomlConfig).toHaveBeenCalledWith(off, revision(source), expect.any(Object))
    expect(reopened.getByText(/파일 설정: 꺼짐/)).toBeTruthy()
    expect(reopened.getByText(/Exact registry 적용됨/)).toBeTruthy()
  })
  it('keeps candidates, comments and newer unrelated edits when explicitly reapplying a conflict', async () => {
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
  it('refuses Required off and optional empty on without POST', async () => {
    stored = '[runtime.exact_output_lanes.board_attention_exact]\nslots=["first"]\n'
    const authority = executionWorkspaceAuthority.peek()!, session = exactLaneActivitySessionFor(authority, required)
    await session.read(authority); session.toggle(authority)
    expect(session.state.value.error).toMatch(/필수/); expect(await session.save(authority)).toBe(false)
    stored = '[runtime.exact_output_lanes.librarian_exact]\nenabled=false\n'
    const optional = exactLaneActivitySessionFor(authority, lane); await optional.read(authority); optional.toggle(authority)
    expect(optional.state.value.error).toMatch(/후보/); expect(await optional.save(authority)).toBe(false)
    expect(api.previewRuntimeTomlConfig).not.toHaveBeenCalled(); expect(api.saveRuntimeTomlConfig).not.toHaveBeenCalled()
  })
  it('keeps preview refusal as a known no-write outcome and supports retry', async () => {
    const { session, authority } = await draft()
    api.previewRuntimeTomlConfig.mockResolvedValueOnce({ ok: true, can_save: false })
    expect(await session.save(authority)).toBe(false); expect(api.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    expect(session.state.value.uncertain).toBe(false); expect(session.state.value.draft?.enabled).toBe(false)
    expect(await session.save(authority)).toBe(true)
  })
  it('does not let a late A read overwrite a fresh A read after A-B-A', async () => {
    const first = deferred<RuntimeTomlConfig>(), authority = executionWorkspaceAuthority.peek()!
    const session = exactLaneActivitySessionFor(authority, lane)
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
    await session.read(authority); session.reapply(authority)
    expect(await session.save(authority)).toBe(false); expect(session.modified()).toBe(false)
    expect(stored).toBe(off)
  })
  it('preserves registry-kept and resume failure results across file readback', async () => {
    const { session, authority } = await draft()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async text => {
      stored = text; const value = receipt(text); value.application.exact_output_registry = { status: 'kept', requires_restart: false, next_boot_publishes: false, reason: 'fixture kept' }; return value
    })
    followup.resumeSavedModelSetup.mockResolvedValueOnce({ kind: 'failed', reason: 'activation_failed' })
    expect(await session.save(authority)).toBe(true)
    expect(session.state.value.current?.source_text).toBe(off)
    expect(session.state.value.receipt?.application.exact_output_registry.status).toBe('kept')
    expect(session.state.value.followupError).toMatch(/재개를 확인하지 못했습니다/)
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
    expect(session.state.value.receipt).toBeNull(); expect(session.state.value.uncertain).toBe(true)
  })
})

describe('parsed activity edit', () => {
  it.each([
    '[runtime.exact_output_lanes."librarian_exact"] # header\nslots=["one"]\nenabled=true # note\n',
    '[runtime.exact_output_lanes]\nlibrarian_exact = { slots=["one"], enabled=true } # note\n',
    'runtime.exact_output_lanes.librarian_exact.slots=["one"]\n',
    '[runtime]\nexact_output_lanes={librarian_exact={slots=["one"]}}\n',
  ])('handles table spellings without reprinting candidates: %s', text => {
    const changed = writeExactActivity(text, lane, false)
    expect(readExactActivity(changed, lane)).toEqual({ enabled: false, slots: ['one'], cliSlots: [] })
    expect(changed).toContain('slots=["one"]')
    if (text.includes('# note')) expect(changed).toContain('# note')
  })
  it.each(['[bad', '[runtime]\n', '[runtime.exact_output_lanes]\nlibrarian_exact="bad"\n',
    '[runtime.exact_output_lanes.librarian_exact]\nenabled="false"\n',
    '[runtime.exact_output_lanes.librarian_exact]\nslots="one"\n'])('refuses unavailable/invalid activity: %s', text => {
    expect(() => readExactActivity(text, lane)).toThrow()
  })
})
