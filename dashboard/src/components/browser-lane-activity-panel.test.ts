import { createHash } from 'node:crypto'
import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { parseLaneInventory } from '../api/lane-inventory'
import inventory from '../api/fixtures/lane-inventory.json'
import { executionWorkspaceAuthority, hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
import { committedRuntimeTomlConfigFixture } from '../lib/runtime-config-receipt.test-fixture'
import { RuntimeTomlRevisionConflict, RuntimeTomlSaveRejected, type RuntimeTomlConfig } from '../api/dashboard-runtime'
import { readBrowserActivity, writeBrowserActivity } from '../lib/browser-lane-activity'
import { browserLaneActivitySessionFor, resetBrowserLaneActivitySessionsForTesting } from '../lib/browser-lane-activity-session'
import { runtimeTomlSessionFor, resetRuntimeTomlSessionsForTesting } from '../lib/runtime-toml-session'
import { announceRuntimeTomlWritten } from '../lib/runtime-toml-source-generation'
import { BrowserLaneActivityPanel } from './browser-lane-activity-panel'
import { LaneInventoryPanel } from './lane-inventory-panel'

const api = vi.hoisted(() => ({ fetchRuntimeTomlConfig: vi.fn(), previewRuntimeTomlConfig: vi.fn(), saveRuntimeTomlConfig: vi.fn(), fetchRuntimeResolved: vi.fn() }))
const projectionApi = vi.hoisted(() => ({ fetchStandaloneLanes: vi.fn() }))
const followup = vi.hoisted(() => ({ resumeSavedModelSetup: vi.fn(), refreshRuntimeConfigConsumers: vi.fn() }))
const inventoryApi = vi.hoisted(() => ({ fetchLaneInventory: vi.fn() }))
vi.mock('../api/lane-inventory', async original => ({ ...await original<typeof import('../api/lane-inventory')>(), ...inventoryApi }))
vi.mock('../api/dashboard-runtime', async original => ({ ...await original<typeof import('../api/dashboard-runtime')>(), ...api }))
vi.mock('../api/dashboard-standalone-lanes', async original => ({ ...await original<typeof import('../api/dashboard-standalone-lanes')>(), ...projectionApi }))
vi.mock('../lib/model-setup-resume', async original => ({ ...await original<typeof import('../lib/model-setup-resume')>(), resumeSavedModelSetup: followup.resumeSavedModelSetup }))
vi.mock('../lib/runtime-config-refresh', () => ({ refreshRuntimeConfigConsumers: followup.refreshRuntimeConfigConsumers }))

const lane = 'automation' as const
const title = parseLaneInventory(inventory).rows.find(row => row.id === 'browser/automation')!.label
const source = '# notes stay\n[browser.automation]\ngeckodriver = "/tools/geckodriver"\nbinary = "/tools/firefox"\nenabled = true # preserve this comment\n\n[browser.stagehand]\nenabled = false\n\n[providers.extra]\nvalue = "keep"\n'
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
  hydrateExecutionSnapshot({ execution_publication_epoch: `browser-activity-${epoch}`, execution_publication_generation: ++generation,
    status: { project: 'fixture', workspace_root: root } } as Parameters<typeof hydrateExecutionSnapshot>[0])
  return executionWorkspaceAuthority.peek()!
}
beforeEach(() => {
  vi.resetAllMocks(); resetBrowserLaneActivitySessionsForTesting(); resetRuntimeTomlSessionsForTesting()
  ++epoch; generation = 0; invalidateExecutionSnapshotGeneration(`browser-activity-${epoch}`, 0); workspace('/fixture/A'); stored = source
  api.fetchRuntimeTomlConfig.mockImplementation(async () => config(stored))
  api.previewRuntimeTomlConfig.mockResolvedValue({ ok: true, can_save: true })
  api.fetchRuntimeResolved.mockResolvedValue({ runtimes: [] })
  projectionApi.fetchStandaloneLanes.mockResolvedValue(parseLaneInventory(inventory).exact_snapshot)
  api.saveRuntimeTomlConfig.mockImplementation(async (text, expected, options) => {
    options?.beforeDispatch?.()
    if (expected !== revision(stored)) throw new RuntimeTomlRevisionConflict('changed', document(stored))
    stored = text; return receipt(text)
  })
  followup.resumeSavedModelSetup.mockResolvedValue({ kind: 'active', exactOutputAvailable: true })
  followup.refreshRuntimeConfigConsumers.mockResolvedValue(undefined)
  inventoryApi.fetchLaneInventory.mockResolvedValue(parseLaneInventory(inventory))
})
afterEach(() => { cleanup(); resetBrowserLaneActivitySessionsForTesting(); resetRuntimeTomlSessionsForTesting() })
async function draft() {
  const authority = executionWorkspaceAuthority.peek()!, session = browserLaneActivitySessionFor(authority, lane)
  await session.read(authority); session.toggle(authority); return { authority, session }
}

describe('Browser activity operator flow', () => {
  it('does not expose an invalid conflict document as an editable source', async () => {
    const { authority, session } = await draft(), previous = session.state.value.draft
    api.saveRuntimeTomlConfig.mockRejectedValueOnce(new RuntimeTomlRevisionConflict(
      'changed path', document('[broken', '/another/runtime.toml')))
    expect(await session.save(authority)).toBe(false)
    expect(session.state.value.uncertain).toBe(false)
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
    expect(session.state.value.uncertain).toBe(false)
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
    expect(session.state.value.uncertain).toBe(false)
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
    expect(session.state.value.uncertain).toBe(false)
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
    expect(session.state.value.uncertain).toBe(false)
    expect(session.state.value.current).toBeNull()
    expect(session.state.value.receipt?.commit.durability).toBe('durable')
    pending.resolve(); await saving
    expect(session.state.value.uncertain).toBe(false)
  })
  it('still marks an unresolved sent save unknown when authority changes', async () => {
    const { authority, session } = await draft(), pending = deferred<ReturnType<typeof receipt>>()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async (_text, _revision, options) => {
      options?.beforeDispatch?.(); return pending.promise
    })
    const saving = session.save(authority)
    await waitFor(() => expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    workspace('/fixture/B')
    expect(session.state.value.uncertain).toBe(true)
    pending.resolve(receipt(off)); await saving
    expect(session.state.value.uncertain).toBe(true)
    expect(session.state.value.receipt).toBeNull()
  })
  it.each(['preview', 'before dispatch', 'dispatched'] as const)('marks a save uncertain only after its POST is dispatched: authority changes at %s', async stage => {
    const { session, authority } = await draft(), gate = deferred<void>(), response = deferred<ReturnType<typeof receipt>>()
    const dispatched = stage === 'dispatched'
    if (stage === 'preview') api.previewRuntimeTomlConfig.mockImplementationOnce(async () => { await gate.promise; return { ok: true, can_save: true } })
    else api.saveRuntimeTomlConfig.mockImplementationOnce(async (_text, _revision, options) => {
      if (!dispatched) await gate.promise
      options?.beforeDispatch?.(); return response.promise
    })
    const saving = session.save(authority)
    await waitFor(() => expect(stage === 'preview' ? api.previewRuntimeTomlConfig : api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    workspace('/fixture/B')
    expect(session.state.value.uncertain).toBe(dispatched)
    gate.resolve(); response.resolve(receipt(off)); expect(await saving).toBe(false)
    expect(session.state.value.uncertain).toBe(dispatched)
    const fresh = workspace('/fixture/A')
    api.fetchRuntimeTomlConfig.mockRejectedValueOnce(new Error('runtime.toml unavailable'))
    await session.read(fresh); session.discard(fresh)
    expect(session.modified()).toBe(false)
    const unload = new Event('beforeunload', { cancelable: true }); window.dispatchEvent(unload)
    expect(unload.defaultPrevented).toBe(dispatched)
  })
  it('follows a fresh file when there is no unsaved activity change', async () => {
    const authority = executionWorkspaceAuthority.peek()!, session = browserLaneActivitySessionFor(authority, lane)
    await session.read(authority)
    stored = off; await session.read(authority)
    expect(session.state.value.draft?.enabled).toBe(false)
    expect(session.state.value.draft?.base.source_revision).toBe(revision(off))
    session.toggle(authority); expect(await session.save(authority)).toBe(true)
    expect(stored).toBe(source)
  })

  it('rereads an activity response overtaken by a known file write', async () => {
    const authority = executionWorkspaceAuthority.peek()!, session = browserLaneActivitySessionFor(authority, lane)
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
    fireEvent.input(view.getByRole('searchbox', { name: 'Find a Lane' }), { target: { value: 'browser/automation' } })
    fireEvent.click(await view.findByRole('button', { name: `Inspect ${title}` }))
    fireEvent.click(view.getByRole('button', { name: '활동 설정 열기' }))
    fireEvent.click(await view.findByRole('switch'))
    fireEvent.click(view.getByRole('button', { name: '활동 설정 저장' }))
    await waitFor(() => expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    view.unmount()
    await act(async () => { stored = off; response.resolve(receipt(off)) })
    const session = browserLaneActivitySessionFor(executionWorkspaceAuthority.peek()!, lane)
    await waitFor(() => expect(session.state.value.current?.source_text).toBe(off))
    expect(inventoryApi.fetchLaneInventory).toHaveBeenCalledTimes(1)
  })
  it('retains a local draft across closing and remount; writes only on explicit Save', async () => {
    const view = render(html`<${BrowserLaneActivityPanel} lane=${lane} title=${title} />`)
    expect(api.fetchRuntimeTomlConfig).not.toHaveBeenCalled()
    fireEvent.click(view.getByRole('button', { name: '활동 설정 열기' }))
    const toggle = await view.findByRole('switch', { name: `${title} 활동 초안` })
    fireEvent.click(toggle); expect(toggle.getAttribute('aria-checked')).toBe('false')
    expect(api.previewRuntimeTomlConfig).not.toHaveBeenCalled(); expect(api.saveRuntimeTomlConfig).not.toHaveBeenCalled()
    view.unmount()
    const reopened = render(html`<${BrowserLaneActivityPanel} lane=${lane} title=${title} />`)
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
    expect(session.state.value.uncertain).toBe(false); expect(session.state.value.draft?.enabled).toBe(false)
    expect(await session.save(authority)).toBe(true)
  })
  it('does not let a late A read overwrite a fresh A read after A-B-A', async () => {
    const first = deferred<RuntimeTomlConfig>(), authority = executionWorkspaceAuthority.peek()!
    const session = browserLaneActivitySessionFor(authority, lane)
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
  it('keeps the current Browser basis retryable after a typed pre-write rejection', async () => {
    const { session, authority } = await draft(), before = session.state.value.current
    const reads = api.fetchRuntimeTomlConfig.mock.calls.length
    api.saveRuntimeTomlConfig.mockRejectedValueOnce(new RuntimeTomlSaveRejected('HTTP 400: fixture admission refused'))
    expect(await session.save(authority)).toBe(false)
    expect(session.state.value.current).toBe(before)
    expect(session.state.value.uncertain).toBe(false)
    expect(session.state.value.draft?.enabled).toBe(false)
    expect(session.state.value.error).toContain('저장 전에 거절')
    expect(session.state.value.error).not.toContain('불확실')
    expect(api.fetchRuntimeTomlConfig).toHaveBeenCalledTimes(reads)
    expect(await session.save(authority)).toBe(true)
    expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(2)
  })
  it('does not resurrect Browser current source after an external write and late known rejection', async () => {
    const { session, authority } = await draft(), response = deferred<void>()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async () => {
      await response.promise
      throw new RuntimeTomlSaveRejected('HTTP 400: fixture admission refused')
    })
    const saving = session.save(authority)
    await waitFor(() => expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1))
    announceRuntimeTomlWritten()
    expect(session.state.value.current).toBeNull()
    response.resolve()
    expect(await saving).toBe(false)
    expect(session.state.value.current).toBeNull()
    expect(session.state.value.uncertain).toBe(false)
    expect(session.ready(authority)).toBe(false)
  })
  it('requires a read after an unanswered write and does not blindly repeat it', async () => {
    const { session, authority } = await draft()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async (text, _revision, options) => {
      options?.beforeDispatch?.(); stored = text; throw new Error('connection lost')
    })
    expect(await session.save(authority)).toBe(false); expect(session.state.value.current).toBeNull()
    expect(await session.save(authority)).toBe(false); expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
    await session.read(authority); session.reapply(authority)
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
    const { session, authority } = await draft()
    api.saveRuntimeTomlConfig.mockImplementationOnce(async (_text, _revision, options) => { options?.beforeDispatch?.(); return receipt(source) })
    expect(await session.save(authority)).toBe(false); expect(session.state.value.current).toBeNull()
    expect(session.state.value.receipt).toBeNull(); expect(session.state.value.uncertain).toBe(true)
  })
})

describe('Browser inventory and backend isolation', () => {
  it.each([false, true])('refreshes inventory after save without model resume (remount: %s)', async remount => {
    const response = deferred<ReturnType<typeof receipt>>()
    api.saveRuntimeTomlConfig.mockReturnValueOnce(response.promise)
    inventoryApi.fetchLaneInventory.mockImplementation(async () => {
      const value = parseLaneInventory(inventory)
      return { ...value, rows: value.rows.map(row => row.selection.kind === 'browser' && row.selection.lane === lane
        && row.state.kind === 'browser_executor'
        ? { ...row, state: { ...row.state, activity: readBrowserActivity(stored, lane).enabled ? 'on' as const : 'off' as const } } : row) }
    })
    const mount = async () => {
      const view = render(html`<${LaneInventoryPanel} />`)
      fireEvent.input(view.getByRole('searchbox', { name: 'Find a Lane' }), { target: { value: 'browser/automation' } })
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
    expect(within(next.view.getByRole('region', { name: `Details for ${title}` })).getByText(/Off · configuration and sessions retained/)).toBeTruthy()
    expect(next.view.getByRole('button', { name: '활동 설정 닫기' })).toBeTruthy()
    expect(followup.resumeSavedModelSetup).not.toHaveBeenCalled()
    expect(api.saveRuntimeTomlConfig).toHaveBeenCalledTimes(1)
  })
  it('retains a different backend draft but withdraws its stale save basis', async () => {
    const { session, authority } = await draft(), other = browserLaneActivitySessionFor(authority, 'stagehand')
    await other.read(authority); other.toggle(authority)
    expect(await session.save(authority)).toBe(true)
    expect(other.state.value.draft?.enabled).toBe(true)
    expect(other.state.value.current).toBeNull(); expect(await other.save(authority)).toBe(false)
    await other.read(authority); other.reapply(authority)
    expect(await other.save(authority)).toBe(true)
    expect(readBrowserActivity(stored, 'automation').enabled).toBe(false)
    expect(readBrowserActivity(stored, 'stagehand').enabled).toBe(true)
    expect(stored).toContain('geckodriver = "/tools/geckodriver"')
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
  it.each(['live', 'automation', 'stagehand'] as const)('allows %s off/on without configuring an executor', async selected => {
    stored = '# no Browser installation\n'
    const authority = executionWorkspaceAuthority.peek()!, session = browserLaneActivitySessionFor(authority, selected)
    await session.read(authority); session.toggle(authority)
    expect(await session.save(authority)).toBe(true)
    expect(readBrowserActivity(stored, selected).enabled).toBe(false)
    session.toggle(authority); expect(await session.save(authority)).toBe(true)
    expect(readBrowserActivity(stored, selected).enabled).toBe(true)
    expect(followup.resumeSavedModelSetup).not.toHaveBeenCalled()
  })
})

describe('Browser source editing', () => {
  it.each([
    '[browser."automation"] # header\ngeckodriver="/tools/driver"\nenabled=true # note\n',
    '[browser]\nautomation = { geckodriver="/tools/driver", enabled=true } # note\n',
    'browser.automation.geckodriver="/tools/driver"\n',
    '[browser]\nautomation={geckodriver="/tools/driver"}\n',
  ])('edits canonical activity without reprinting paths: %s', text => {
    const changed = writeBrowserActivity(text, lane, false)
    expect(readBrowserActivity(changed, lane)).toEqual({ enabled: false })
    expect(changed).toContain('geckodriver="/tools/driver"')
    if (text.includes('# note')) expect(changed).toContain('# note')
  })
  it.each([
    '[browser]\ngeckodriver="/tools/driver"\nbinary="/tools/firefox"\n[later]\nkeep="untouched"\n',
    'browser={geckodriver="/tools/driver",binary="/tools/firefox",live={enabled=false}}\n',
    'browser.geckodriver="/tools/driver"\nbrowser.binary="/tools/firefox"\n',
    '[browser]\n"geckodriver"="""/tools/driver"""\nbinary="/tools/firefox"\nstagehand={enabled=false}\n',
  ])('moves accepted flat paths into automation on its first activity edit: %s', text => {
    const changed = writeBrowserActivity(text, lane, false)
    expect(readBrowserActivity(changed, lane)).toEqual({ enabled: false })
    expect(changed).toContain('/tools/driver'); expect(changed).toContain('/tools/firefox')
    expect(readBrowserActivity(changed, 'live')).toEqual(readBrowserActivity(text, 'live'))
    expect(readBrowserActivity(changed, 'stagehand')).toEqual(readBrowserActivity(text, 'stagehand'))
    expect(writeBrowserActivity(changed, lane, true)).toBe(changed.replace('enabled = false', 'enabled = true'))
  })
  it('keeps flat paths untouched when editing another backend', () => {
    const text = '[browser]\ngeckodriver="/tools/driver" # note\n[providers.note]\nprompt="""[browser.live]\nenabled=false"""\n'
    const changed = writeBrowserActivity(text, 'live', false)
    expect(changed).toContain(text)
    expect(readBrowserActivity(changed, 'automation').enabled).toBe(true)
    expect(readBrowserActivity(changed, 'live').enabled).toBe(false)
  })
  it.each(['[bad', 'browser="bad"\n', 'browser=2026-10-05\n', '[browser]\nautomation="bad"\n',
    '[browser.automation]\nenabled="false"\n', '[browser]\ngeckodriver="/driver"\nautomation={enabled=false}\n',
    '[browser]\ngeckodriver=42\n',
  ])('refuses invalid activity/ambiguous paths: %s', text => {
    expect(() => writeBrowserActivity(text, lane, false)).toThrow()
  })
})
