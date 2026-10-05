import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
const lane = vi.hoisted(() => ({ fetchLaneAddons: vi.fn(), detachLaneAddon: vi.fn() }))
const files = vi.hoisted(() => ({ fetchLaneDeclaration: vi.fn(), saveLaneDeclaration: vi.fn() }))
vi.mock('../api/lane-addons', async original => ({ ...await original<typeof import('../api/lane-addons')>(), ...lane }))
vi.mock('../api/lane-declarations', async original => ({ ...await original<typeof import('../api/lane-declarations')>(), ...files }))
import { LaneAddonsPanel } from './lane-addons-panel'
import { LaneDeclarationError, type LaneDeclarationDocument } from '../api/lane-declarations'
import { parseLaneAddonSnapshot } from '../api/lane-addons'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
import { resetLaneDeclarationSessionsForTesting } from '../lib/lane-declaration-sessions'
import { resetLanePackageActivitiesForTesting } from '../lib/lane-package-activity-session'

const directory = '/workspace/.masc/config/lane-addons', path = `${directory}/pkg.toml`
const original = '# retained comment\nid = "pkg"\nrun_id = "run"\nmanifest_path = "../pkg/lane.toml"\n[binding]\nsources = []\n'
const document: LaneDeclarationDocument = { file_name: 'pkg.toml', source_path: path, source_text: original,
  source_revision: 'r1', desired_revision: 'semantic', validation: { valid: true, messages: [] } }
const snapshot = parseLaneAddonSnapshot({ configuration: { directory, complete: true, issues: [], declarations: [
  { id: 'pkg', source_path: path, enabled: true, desired_revision: 'semantic', applied_revision: null, instance_id: null },
] }, instances: [], rows: [], coverage: [] })
function receipt(text: string, durability: 'durable' | 'unconfirmed' = 'durable') {
  return { document: { ...document, source_text: text, source_revision: 'r2' },
    write: { state: 'saved', durability, detail: null }, application: 'pending_reconciliation' }
}
let sequence = 0, generation = 0, epoch = ''
function workspace(root: string) {
  expect(hydrateExecutionSnapshot({ execution_publication_epoch: epoch, execution_publication_generation: ++generation,
    status: { project: 'activity-fixture', workspace_root: root } } as Parameters<typeof hydrateExecutionSnapshot>[0])).toBe(true)
}
beforeEach(() => {
  resetLanePackageActivitiesForTesting(); resetLaneDeclarationSessionsForTesting()
  epoch = `activity-${++sequence}`; generation = 0; invalidateExecutionSnapshotGeneration(epoch, 0); workspace('/workspace')
  lane.fetchLaneAddons.mockResolvedValue(snapshot); files.fetchLaneDeclaration.mockResolvedValue(document)
  files.saveLaneDeclaration.mockImplementation(async request => receipt(request.source_text))
})
afterEach(() => { cleanup(); resetLanePackageActivitiesForTesting(); resetLaneDeclarationSessionsForTesting(); vi.resetAllMocks() })
type Screen = ReturnType<typeof render>
const panel = (screen: Screen) => within(screen.getByRole('region', { name: 'Package activity pkg' }))
const toggle = (screen: Screen) => panel(screen).getByRole('switch', { name: 'Activity draft for pkg' })
async function open(screen: Screen) {
  fireEvent.click(await screen.findByRole('button', { name: 'Configure activity for pkg' }))
  await waitFor(() => expect((toggle(screen) as HTMLButtonElement).disabled).toBe(false))
}
async function save(screen: Screen) {
  fireEvent.click(panel(screen).getByRole('button', { name: 'Save activity' }))
}
describe('Web package on/off without deleting configuration', () => {
  it('refreshes a remounted inventory when its retained pending save completes', async () => {
    let finish!: (value: ReturnType<typeof receipt>) => void
    files.saveLaneDeclaration.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    let screen = render(html`<${LaneAddonsPanel} />`); await open(screen); fireEvent.click(toggle(screen)); await save(screen)
    await panel(screen).findByRole('button', { name: 'Saving activity…' })
    screen.unmount(); screen = render(html`<${LaneAddonsPanel} />`)
    await screen.findByRole('region', { name: 'Package activity pkg' })
    expect(panel(screen).getByText('Observed configuration: On · not yet applied')).toBeTruthy()
    lane.fetchLaneAddons.mockResolvedValue({ ...snapshot, configuration: { ...snapshot.configuration!, declarations: [
      { ...snapshot.configuration!.declarations[0], enabled: false, instance_id: 'still-observed' },
    ] } })
    await act(() => finish(receipt(`enabled = false\n${original}`)))
    await panel(screen).findByText('Observed configuration: Off requested · worker cleanup not yet confirmed')
    expect(files.saveLaneDeclaration).toHaveBeenCalledTimes(1)
  })
  it('changes only activity with explicit CAS save and leaves the raw draft independent', async () => {
    const screen = render(html`<${LaneAddonsPanel} />`)
    fireEvent.click(await screen.findByRole('button', { name: `Edit TOML ${path}` }))
    const raw = await screen.findByLabelText('TOML source') as HTMLTextAreaElement
    await waitFor(() => expect(raw.value).toBe(original))
    fireEvent.input(raw, { target: { value: '# unsaved raw edit\n'+original } })
    await open(screen)
    expect(globalThis.document.activeElement?.textContent).toBe('Package on/off · pkg')
    fireEvent.click(toggle(screen)); expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
    await save(screen)
    await panel(screen).findByText(/Activity configuration saved/)
    expect(files.saveLaneDeclaration).toHaveBeenCalledWith({ mode: 'save', file_name: 'pkg.toml',
      source_text: `enabled = false\n${original}`, expected_source_revision: 'r1' })
    expect(raw.value).toBe('# unsaved raw edit\n'+original)
    expect(lane.detachLaneAddon).not.toHaveBeenCalled()
    expect(panel(screen).getByText(/Worker application or cleanup is still pending/)).toBeTruthy()
  })
  it('reapplies only activity after a conflict, preserving the newest binding and comments', async () => {
    const current = { ...document, source_revision: 'external', source_text: original.replace('sources = []', 'sources = []\nnewer = "keep"') }
    files.saveLaneDeclaration.mockRejectedValueOnce(new LaneDeclarationError({ code: 'revision_conflict', error: 'conflict', current }))
    const screen = render(html`<${LaneAddonsPanel} />`); await open(screen); fireEvent.click(toggle(screen)); await save(screen)
    await panel(screen).findByText(/nothing was saved by this request/)
    expect((panel(screen).getByRole('button', { name: 'Save activity' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(panel(screen).getByRole('button', { name: 'Reapply activity only' })); await save(screen)
    await waitFor(() => expect(files.saveLaneDeclaration).toHaveBeenCalledTimes(2))
    expect(files.saveLaneDeclaration.mock.calls[1]![0]).toMatchObject({ expected_source_revision: 'external', source_text: `enabled = false\n${current.source_text}` })
  })
  it('preserves activity drafts through remount and workspace return without leaking them to B', async () => {
    let screen = render(html`<${LaneAddonsPanel} />`); await open(screen); fireEvent.click(toggle(screen)); screen.unmount()
    screen = render(html`<${LaneAddonsPanel} />`)
    await waitFor(() => expect(toggle(screen).getAttribute('aria-checked')).toBe('false'))
    await act(() => workspace('/workspace-b'))
    await waitFor(() => expect(screen.queryByRole('region', { name: 'Package activity pkg' })).toBeNull())
    await act(() => workspace('/workspace'))
    await waitFor(() => expect((toggle(screen) as HTMLButtonElement).disabled).toBe(false))
    expect(toggle(screen).getAttribute('aria-checked')).toBe('false')
    expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
  })
  it('retains an uncertain old save when workspace changes and ignores its late receipt', async () => {
    let finish!: (value: ReturnType<typeof receipt>) => void
    files.saveLaneDeclaration.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    const screen = render(html`<${LaneAddonsPanel} />`); await open(screen); fireEvent.click(toggle(screen)); await save(screen)
    await panel(screen).findByRole('button', { name: 'Saving activity…' })
    await act(() => workspace('/workspace-b'))
    await waitFor(() => expect(screen.queryByRole('region', { name: 'Package activity pkg' })).toBeNull())
    files.fetchLaneDeclaration.mockRejectedValueOnce(new Error('read unavailable'))
    await act(() => workspace('/workspace'))
    await screen.findByRole('region', { name: 'Package activity pkg' })
    await panel(screen).findByText('read unavailable')
    await act(() => finish(receipt(`enabled = false\n${original}`)))
    expect(panel(screen).getByText(/previous save outcome is uncertain/)).toBeTruthy()
    expect((panel(screen).getByRole('button', { name: 'Save activity' }) as HTMLButtonElement).disabled).toBe(true)
    expect(panel(screen).queryByText(/Activity configuration saved/)).toBeNull()
  })
  it('keeps a pending save uncertain across A-B-A rereads and refreshes inventory when it settles', async () => {
    let finish!: (value: ReturnType<typeof receipt>) => void
    files.saveLaneDeclaration.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    const screen = render(html`<${LaneAddonsPanel} />`); await open(screen); fireEvent.click(toggle(screen)); await save(screen)
    await panel(screen).findByRole('button', { name: 'Saving activity…' })
    const fileReads = files.fetchLaneDeclaration.mock.calls.length
    await act(() => workspace('/workspace-b'))
    await waitFor(() => expect(screen.queryByRole('region', { name: 'Package activity pkg' })).toBeNull())
    await act(() => workspace('/workspace'))
    await screen.findByRole('region', { name: 'Package activity pkg' })
    // The reread succeeds, but it began while the save was still in flight.
    await waitFor(() => expect(files.fetchLaneDeclaration.mock.calls.length).toBeGreaterThan(fileReads))
    await waitFor(() => expect((panel(screen).getByRole('button', { name: 'Read current activity' }) as HTMLButtonElement).disabled).toBe(false))
    await panel(screen).findByText(/previous save outcome is uncertain/)
    expect((panel(screen).getByRole('button', { name: 'Save activity' }) as HTMLButtonElement).disabled).toBe(true)
    const inventoryReads = lane.fetchLaneAddons.mock.calls.length
    lane.fetchLaneAddons.mockResolvedValue({ ...snapshot, configuration: { ...snapshot.configuration!, declarations: [
      { ...snapshot.configuration!.declarations[0], enabled: false, instance_id: 'still-observed' },
    ] } })
    await act(() => finish(receipt(`enabled = false\n${original}`)))
    await panel(screen).findByText('Observed configuration: Off requested · worker cleanup not yet confirmed')
    expect(lane.fetchLaneAddons.mock.calls.length).toBeGreaterThan(inventoryReads)
    expect(panel(screen).queryByText(/Activity configuration saved/)).toBeNull()
    expect((panel(screen).getByRole('button', { name: 'Save activity' }) as HTMLButtonElement).disabled).toBe(true)
    // A read begun after the write settled observes it and clears the uncertainty.
    files.fetchLaneDeclaration.mockResolvedValueOnce({ ...document, source_text: `enabled = false\n${original}`, source_revision: 'r2' })
    fireEvent.click(panel(screen).getByRole('button', { name: 'Read current activity' }))
    await waitFor(() => expect(panel(screen).queryByText(/previous save outcome is uncertain/)).toBeNull())
    expect(files.saveLaneDeclaration).toHaveBeenCalledTimes(1)
  })
  it.each(['transport', 'durability'])('requires a fresh file read after uncertain %s and does not blindly repeat the save', async kind => {
    if (kind === 'transport') files.saveLaneDeclaration.mockRejectedValueOnce(new Error('lost response'))
    else files.saveLaneDeclaration.mockImplementationOnce(async request => receipt(request.source_text, 'unconfirmed'))
    const screen = render(html`<${LaneAddonsPanel} />`); await open(screen); fireEvent.click(toggle(screen)); await save(screen)
    await panel(screen).findByText(/previous save outcome is uncertain/)
    expect((panel(screen).getByRole('button', { name: 'Save activity' }) as HTMLButtonElement).disabled).toBe(true)
    files.fetchLaneDeclaration.mockResolvedValueOnce({ ...document, source_text: `enabled = false\n${original}`, source_revision: 'observed-after-unknown' })
    fireEvent.click(panel(screen).getByRole('button', { name: 'Read current activity' }))
    await panel(screen).findByRole('button', { name: 'Reapply activity only' })
    fireEvent.click(panel(screen).getByRole('button', { name: 'Reapply activity only' }))
    expect((panel(screen).getByRole('button', { name: 'Save activity' }) as HTMLButtonElement).disabled).toBe(true)
    expect(files.saveLaneDeclaration).toHaveBeenCalledTimes(1)
  })
  it.each(['different-id','invalid','read-failure'])('refuses activity when the current file is %s', async kind => {
    if (kind === 'read-failure') files.fetchLaneDeclaration.mockRejectedValueOnce(new Error('permission denied'))
    else files.fetchLaneDeclaration.mockResolvedValueOnce({ ...document, source_text: kind === 'different-id' ? original.replace('"pkg"','"replacement"') : original,
      validation: { valid: kind !== 'invalid', messages: ['broken binding'] } })
    const screen = render(html`<${LaneAddonsPanel} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Configure activity for pkg' }))
    await panel(screen).findByRole('alert')
    expect((panel(screen).getByRole('button', { name: 'Save activity' }) as HTMLButtonElement).disabled).toBe(true)
    expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
  })
  it('follows an externally changed clean file on reopen and can turn an Off declaration back On', async () => {
    const screen = render(html`<${LaneAddonsPanel} />`); await open(screen)
    fireEvent.click(panel(screen).getByRole('button', { name: 'Close activity' }))
    files.fetchLaneDeclaration.mockResolvedValueOnce({ ...document, source_text: `enabled = false\n${original}`, source_revision: 'off-current' })
    await open(screen); expect(toggle(screen).getAttribute('aria-checked')).toBe('false')
    fireEvent.click(toggle(screen)); await save(screen)
    await waitFor(() => expect(files.saveLaneDeclaration).toHaveBeenCalledTimes(1))
    expect(files.saveLaneDeclaration.mock.calls[0]![0]).toMatchObject({ expected_source_revision: 'off-current', source_text: `enabled = true\n${original}` })
  })
  it('refreshes file activity and inventory together while keeping worker cleanup unconfirmed', async () => {
    const screen = render(html`<${LaneAddonsPanel} />`); await open(screen)
    files.fetchLaneDeclaration.mockResolvedValueOnce({ ...document, source_text: `enabled = false\n${original}`, source_revision: 'external-off' })
    lane.fetchLaneAddons.mockResolvedValueOnce({ ...snapshot, configuration: { ...snapshot.configuration!, declarations: [
      { ...snapshot.configuration!.declarations[0], enabled: false, instance_id: 'still-observed' },
    ] } })
    fireEvent.click(panel(screen).getByRole('button', { name: 'Read current activity' }))
    await panel(screen).findByText('Observed configuration: Off requested · worker cleanup not yet confirmed')
    expect(panel(screen).getByText('File activity (last read): Off')).toBeTruthy()
    expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
  })
})
