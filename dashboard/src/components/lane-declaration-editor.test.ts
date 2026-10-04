import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { LaneDeclarationError, type LaneDeclarationDocument } from '../api/lane-declarations'

const lane = vi.hoisted(() => ({ fetchLaneAddons: vi.fn(), attachLaneAddon: vi.fn(), observeLaneAddon: vi.fn() }))
const workspace = vi.hoisted(() => ({ refreshExecution: vi.fn() }))
vi.mock('../store', async original => ({ ...await original<typeof import('../store')>(), ...workspace }))
const files = vi.hoisted(() => ({ fetchLaneDeclaration: vi.fn(), saveLaneDeclaration: vi.fn() }))
vi.mock('../api/lane-addons', async original => ({ ...await original<typeof import('../api/lane-addons')>(), ...lane }))
vi.mock('../api/lane-declarations', async original => ({ ...await original<typeof import('../api/lane-declarations')>(), ...files }))
import { LaneAddonsPanel } from './lane-addons-panel'
import { Status } from './status'
import { navigate } from '../router'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
import { resetLaneDeclarationSessionsForTesting } from '../lib/lane-declaration-sessions'
vi.mock('./agents-unified', () => ({ AgentsUnified: () => html`<p>Fixture agents route</p>` }))
let epochSequence = 0
let epoch = ''
let generation = 0
function observeWorkspace(root: string | null) {
  expect(hydrateExecutionSnapshot({ execution_publication_epoch: epoch, execution_publication_generation: ++generation,
    status: { project: 'lane-fixture', workspace_root: root } } as Parameters<typeof hydrateExecutionSnapshot>[0])).toBe(true)
}
async function openNew(screen: ReturnType<typeof render>) {
  await waitFor(() => expect((screen.getByRole('button', { name: 'New TOML' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: 'New TOML' }))
}

const path = '/workspace/.masc/config/lane-addons/custom.toml'
const original = '# preserve this comment\nid = "custom"\nrun_id = "run"\nmanifest_path = "../custom/lane.toml"\n[binding]\nsources = []\n'
const document: LaneDeclarationDocument = {
  file_name: 'custom.toml', source_path: path, source_text: original, source_revision: 'raw-revision-1',
  desired_revision: 'semantic-revision-1', validation: { valid: true, messages: [] },
}
const snapshot = {
  configuration: { directory: '/workspace/.masc/config/lane-addons', complete: true, issues: [], declarations: [
    { id: 'custom', source_path: path, enabled: true, desired_revision: 'semantic-revision-1', applied_revision: null, instance_id: null },
  ] }, instances: [], rows: [], coverage: [],
}
function receipt(source_text: string, source_revision = 'raw-revision-2') {
  return { document: { ...document, source_text, source_revision },
    write: { state: 'saved', durability: 'durable', detail: null }, application: 'pending_reconciliation' }
}
function source(screen: ReturnType<typeof render>) { return screen.getByLabelText('TOML source') as HTMLTextAreaElement }
async function open(screen: ReturnType<typeof render>) {
  const table = await screen.findByRole('table', { name: 'TOML declarations' })
  fireEvent.click(within(table).getByRole('button', { name: `Edit TOML ${path}` }))
  await waitFor(() => expect(source(screen).value).toBe(original))
}
beforeEach(() => {
  resetLaneDeclarationSessionsForTesting()
  epoch = `lane-draft-fixture-${++epochSequence}`
  generation = 0
  expect(invalidateExecutionSnapshotGeneration(epoch, 0)).toBe(true)
  observeWorkspace('/workspace')
  lane.fetchLaneAddons.mockResolvedValue(snapshot)
  files.fetchLaneDeclaration.mockResolvedValue(document)
})
afterEach(() => { cleanup(); resetLaneDeclarationSessionsForTesting(); vi.resetAllMocks() })

describe('Lane declaration editing through the status surface', () => {
  it('explains unavailable editing and verifies authority before admitting a fresh configuration', async () => {
    observeWorkspace(null)
    let finish!: () => void
    workspace.refreshExecution.mockReturnValueOnce(new Promise<void>(resolve => { finish = resolve }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    await screen.findByRole('table', { name: 'TOML declarations' })
    expect((screen.getByRole('button', { name: 'New TOML' }) as HTMLButtonElement).disabled).toBe(true)
    await screen.findByText(/TOML editing is unavailable until the workspace is confirmed/)
    fireEvent.click(screen.getByRole('button', { name: 'Verify workspace' }))
    expect(workspace.refreshExecution).toHaveBeenCalledWith({ force: true })
    expect((screen.getByRole('button', { name: 'Checking workspace…' }) as HTMLButtonElement).disabled).toBe(true)
    let finishInventory!: (value: typeof snapshot) => void
    lane.fetchLaneAddons.mockReturnValueOnce(new Promise(resolve => { finishInventory = resolve }))
    await act(async () => { observeWorkspace('/workspace'); finish(); await Promise.resolve() })
    await screen.findByText(/Reading the current workspace’s TOML configuration/)
    expect((screen.getByRole('button', { name: 'New TOML' }) as HTMLButtonElement).disabled).toBe(true)
    await act(async () => { finishInventory(snapshot); await Promise.resolve() })
    await openNew(screen)
    expect(screen.getByLabelText('TOML source')).toBeTruthy()
  })

  it('keeps verification failures actionable without admitting an unknown workspace', async () => {
    observeWorkspace(null)
    workspace.refreshExecution.mockRejectedValueOnce(new Error('Workspace observation unavailable'))
    const screen = render(html`<${LaneAddonsPanel} />`)
    fireEvent.click(screen.getByRole('button', { name: 'Verify workspace' }))
    await screen.findByText(/Workspace observation unavailable.*verification can be retried/)
    expect((screen.getByRole('button', { name: 'Verify workspace' }) as HTMLButtonElement).disabled).toBe(false)
    expect((screen.getByRole('button', { name: 'New TOML' }) as HTMLButtonElement).disabled).toBe(true)
    expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
  })

  it('restores new-file and existing-file drafts after actual Status route unmounts', async () => {
    navigate('monitoring', { section: 'lane-addons' })
    const screen = render(html`<${Status} />`)
    await open(screen)
    const existingDraft = '# retained existing\n' + original
    fireEvent.input(source(screen), { target: { value: existingDraft } })
    await openNew(screen)
    fireEvent.input(screen.getByLabelText('File name'), { target: { value: 'new-file.toml' } })
    const newDraft = '# retained new file\n' + original
    fireEvent.input(source(screen), { target: { value: newDraft } })
    act(() => navigate('monitoring', { section: 'agents' }))
    await screen.findByText('Fixture agents route')
    expect(screen.queryByLabelText('TOML source')).toBeNull()
    const leave = new Event('beforeunload', { cancelable: true })
    window.dispatchEvent(leave)
    expect(leave.defaultPrevented).toBe(true)
    act(() => navigate('monitoring', { section: 'lane-addons' }))
    await waitFor(() => expect(source(screen).value).toBe(newDraft))
    expect((screen.getByLabelText('File name') as HTMLInputElement).value).toBe('new-file.toml')
    fireEvent.click(within(screen.getByRole('table', { name: 'TOML declarations' })).getByRole('button', { name: `Edit TOML ${path}` }))
    await waitFor(() => expect(source(screen).value).toBe(existingDraft))
    await openNew(screen)
    expect(source(screen).value).toBe(newDraft)
    expect(files.fetchLaneDeclaration).toHaveBeenCalledTimes(1)
  })

  it('finishes an original read while Status has unmounted the editor', async () => {
    let finish!: (value: LaneDeclarationDocument) => void
    files.fetchLaneDeclaration.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    navigate('monitoring', { section: 'lane-addons' })
    const screen = render(html`<${Status} />`)
    fireEvent.click(await screen.findByRole('button', { name: `Edit TOML ${path}` }))
    await screen.findByText('Reading original TOML…')
    act(() => navigate('monitoring', { section: 'agents' }))
    await screen.findByText('Fixture agents route')
    await act(async () => { finish(document); await Promise.resolve() })
    act(() => navigate('monitoring', { section: 'lane-addons' }))
    await waitFor(() => expect(source(screen).value).toBe(original))
    expect(files.fetchLaneDeclaration).toHaveBeenCalledTimes(1)
  })

  it('retains the receipt and edits typed during a save after a routed unmount', async () => {
    let finish!: (value: ReturnType<typeof receipt>) => void
    files.saveLaneDeclaration.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    navigate('monitoring', { section: 'lane-addons' })
    const screen = render(html`<${Status} />`)
    await open(screen)
    const submitted = '# submitted\n' + original, newer = '# newer while pending\n' + original
    fireEvent.input(source(screen), { target: { value: submitted } })
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await screen.findByRole('button', { name: 'Saving TOML…' })
    fireEvent.input(source(screen), { target: { value: newer } })
    act(() => navigate('monitoring', { section: 'agents' }))
    await screen.findByText('Fixture agents route')
    await act(async () => { finish(receipt(submitted)); await Promise.resolve() })
    act(() => navigate('monitoring', { section: 'lane-addons' }))
    await screen.findByText(/Your newer draft edits are not saved/)
    expect(source(screen).value).toBe(newer)
    expect(files.saveLaneDeclaration).toHaveBeenCalledTimes(1)
  })

  it('migrates a late create and rotates the new-file key without a mounted callback', async () => {
    let finish!: (value: ReturnType<typeof receipt>) => void
    files.saveLaneDeclaration.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    let screen = render(html`<${LaneAddonsPanel} />`)
    await openNew(screen)
    fireEvent.input(screen.getByLabelText('File name'), { target: { value: 'custom.toml' } })
    fireEvent.input(source(screen), { target: { value: original } })
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await screen.findByRole('button', { name: 'Saving TOML…' })
    screen.unmount()
    await act(async () => { finish({ ...receipt(original), write: { state: 'created', durability: 'durable', detail: null } }); await Promise.resolve() })
    screen = render(html`<${LaneAddonsPanel} />`)
    await screen.findByText(/File created. Lane application is pending reconciliation/)
    expect(source(screen).value).toBe(original)
    expect((screen.getByLabelText('File name') as HTMLInputElement).disabled).toBe(true)
    await openNew(screen)
    expect((screen.getByLabelText('File name') as HTMLInputElement).value).toBe('')
    expect(source(screen).value).toContain('id = ""')
    expect(files.saveLaneDeclaration).toHaveBeenCalledTimes(1)
  })

  it('isolates workspaces even when their configured directory is identical and rejects an old A response after A-B-A', async () => {
    let finish!: (value: LaneDeclarationDocument) => void
    files.fetchLaneDeclaration.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    fireEvent.click(await screen.findByRole('button', { name: `Edit TOML ${path}` }))
    await screen.findByText('Reading original TOML…')
    act(() => observeWorkspace('/workspace-b'))
    await waitFor(() => expect(screen.queryByLabelText('TOML source')).toBeNull())
    files.fetchLaneDeclaration.mockResolvedValueOnce({ ...document, source_text: '# workspace B\n' + original })
    await waitFor(() => expect((screen.getByRole('button', { name: 'New TOML' }) as HTMLButtonElement).disabled).toBe(false))
    fireEvent.click(await screen.findByRole('button', { name: `Edit TOML ${path}` }))
    await waitFor(() => expect(source(screen).value).toContain('# workspace B'))
    const bDraft = '# workspace B draft\n' + original
    fireEvent.input(source(screen), { target: { value: bDraft } })
    act(() => observeWorkspace('/workspace'))
    await waitFor(() => expect(screen.queryByText('Reading original TOML…')).not.toBeNull())
    await act(async () => { finish(document); await Promise.resolve() })
    await screen.findByText(/Workspace authority changed while the request was pending/)
    expect(source(screen).value).toBe('')
    expect((screen.getByRole('button', { name: 'Save TOML' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: 'Read current file' }))
    await waitFor(() => expect(source(screen).value).toBe(original))
    act(() => observeWorkspace('/workspace-b'))
    await waitFor(() => expect(source(screen).value).toBe(bDraft))
    expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
  })

  it.each(['/workspace-b', null])('requires a new comparison when an idle draft returns from %s', async away => {
    const screen = render(html`<${LaneAddonsPanel} />`)
    await open(screen)
    const draft = '# retained idle draft\n' + original
    fireEvent.input(source(screen), { target: { value: draft } })
    files.fetchLaneDeclaration.mockResolvedValueOnce({ ...document, source_revision: 'old-comparison' })
    fireEvent.click(screen.getByRole('button', { name: 'Read current file' }))
    await screen.findByLabelText('Current file comparison')
    act(() => observeWorkspace(away))
    await waitFor(() => expect(screen.queryByLabelText('TOML source')).toBeNull())
    act(() => observeWorkspace('/workspace'))
    await waitFor(() => expect(source(screen).value).toBe(draft))
    expect(screen.queryByLabelText('Current file comparison')).toBeNull()
    expect((screen.getByRole('button', { name: 'Save TOML' }) as HTMLButtonElement).disabled).toBe(true)
    const fresh = { ...document, source_revision: 'new-authority-revision' }
    files.fetchLaneDeclaration.mockResolvedValueOnce(fresh)
    fireEvent.click(screen.getByRole('button', { name: 'Read current file' }))
    await screen.findByText(fresh.source_revision, { exact: false })
    expect((screen.getByRole('button', { name: 'Save TOML' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: 'Use current file revision' }))
    files.saveLaneDeclaration.mockResolvedValueOnce(receipt(draft))
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await waitFor(() => expect(files.saveLaneDeclaration).toHaveBeenCalledWith({
      mode: 'save', file_name: 'custom.toml', source_text: draft, expected_source_revision: fresh.source_revision,
    }))
  })

  it('blocks save after a comparison until its revision is explicitly adopted', async () => {
    const screen = render(html`<${LaneAddonsPanel} />`)
    await open(screen)
    const draft = '# compared draft\n' + original
    fireEvent.input(source(screen), { target: { value: draft } })
    files.fetchLaneDeclaration.mockResolvedValueOnce({ ...document, source_revision: 'newer-revision' })
    fireEvent.click(screen.getByRole('button', { name: 'Read current file' }))
    await screen.findByLabelText('Current file comparison')
    expect((screen.getByRole('button', { name: 'Save TOML' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Use current file revision' }))
    expect((screen.getByRole('button', { name: 'Save TOML' }) as HTMLButtonElement).disabled).toBe(false)
    expect(source(screen).value).toBe(draft)
  })

  it('keeps an old-workspace write outcome uncertain in its own draft and never saves without current authority', async () => {
    let finish!: (value: ReturnType<typeof receipt>) => void
    files.saveLaneDeclaration.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    await open(screen)
    const draft = '# write in A\n' + original
    fireEvent.input(source(screen), { target: { value: draft } })
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await screen.findByRole('button', { name: 'Saving TOML…' })
    act(() => observeWorkspace(null))
    await screen.findByText(/Workspace authority is being verified/)
    expect(screen.queryByLabelText('TOML source')).toBeNull()
    expect((screen.getByRole('button', { name: 'New TOML' }) as HTMLButtonElement).disabled).toBe(true)
    await act(async () => { finish(receipt(draft)); await Promise.resolve() })
    act(() => observeWorkspace('/workspace-b'))
    await waitFor(() => expect((screen.getByRole('button', { name: 'New TOML' }) as HTMLButtonElement).disabled).toBe(false))
    expect(screen.queryByLabelText('TOML source')).toBeNull()
    act(() => observeWorkspace('/workspace'))
    await screen.findByText(/Workspace authority changed while the request was pending/)
    expect(source(screen).value).toBe(draft)
    expect((screen.getByRole('button', { name: 'Save TOML' }) as HTMLButtonElement).disabled).toBe(true)
    expect(files.saveLaneDeclaration).toHaveBeenCalledTimes(1)
  })

  it.each(['read', 'save'] as const)('discards an old comparison after a pending %s crosses A-B-A and requires a fresh read', async pending => {
    const screen = render(html`<${LaneAddonsPanel} />`)
    await open(screen)
    const draft = '# retained draft\n' + original
    fireEvent.input(source(screen), { target: { value: draft } })
    const oldComparison = { ...document, source_text: '# old comparison\n' + original, source_revision: 'old-comparison-revision' }
    files.fetchLaneDeclaration.mockResolvedValueOnce(oldComparison)
    fireEvent.click(screen.getByRole('button', { name: 'Read current file' }))
    await screen.findByText(oldComparison.source_revision, { exact: false })
    expect(screen.getByRole('button', { name: 'Use current file revision' })).toBeTruthy()

    let finish!: () => void
    if (pending === 'read') {
      files.fetchLaneDeclaration.mockReturnValueOnce(new Promise(resolve => { finish = () => resolve(oldComparison) }))
      fireEvent.click(screen.getByRole('button', { name: 'Read current file' }))
      await screen.findByRole('button', { name: 'Reading current file…' })
    } else {
      fireEvent.click(screen.getByRole('button', { name: 'Use current file revision' }))
      files.saveLaneDeclaration.mockReturnValueOnce(new Promise(resolve => { finish = () => resolve(receipt(draft)) }))
      fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
      await screen.findByRole('button', { name: 'Saving TOML…' })
    }
    act(() => observeWorkspace('/workspace-b'))
    await waitFor(() => expect(screen.queryByLabelText('TOML source')).toBeNull())
    act(() => observeWorkspace('/workspace'))
    await waitFor(() => expect(source(screen).value).toBe(draft))
    await act(async () => { finish(); await Promise.resolve() })
    await screen.findByText(/Workspace authority changed while the request was pending/)
    expect(screen.queryByLabelText('Current file comparison')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Use current file revision' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Replace draft with current file' })).toBeNull()
    expect((screen.getByRole('button', { name: 'Save TOML' }) as HTMLButtonElement).disabled).toBe(true)
    expect(source(screen).value).toBe(draft)

    const fresh = { ...document, source_text: '# fresh comparison\n' + original, source_revision: 'fresh-authority-revision' }
    files.fetchLaneDeclaration.mockResolvedValueOnce(fresh)
    fireEvent.click(screen.getByRole('button', { name: 'Read current file' }))
    await screen.findByText(fresh.source_revision, { exact: false })
    fireEvent.click(screen.getByRole('button', { name: 'Use current file revision' }))
    expect(source(screen).value).toBe(draft)
    files.saveLaneDeclaration.mockResolvedValueOnce(receipt(draft, 'saved-fresh-revision'))
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await waitFor(() => expect(files.saveLaneDeclaration).toHaveBeenLastCalledWith({ mode: 'save', file_name: 'custom.toml', source_text: draft, expected_source_revision: fresh.source_revision }))
    await screen.findByText(/File saved/)
  })

  it('creates a user TOML file without Attach and separates the file receipt from application', async () => {
    files.saveLaneDeclaration.mockResolvedValue({ ...receipt(original), write: { state: 'created', durability: 'durable', detail: null } })
    const screen = render(html`<${LaneAddonsPanel} />`)
    await openNew(screen)
    const name = await screen.findByLabelText('File name')
    fireEvent.input(name, { target: { value: 'custom.toml' } })
    fireEvent.input(source(screen), { target: { value: original } })
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await waitFor(() => expect(files.saveLaneDeclaration).toHaveBeenCalledWith({ mode: 'create', file_name: 'custom.toml', source_text: original }))
    await screen.findByText(/File created. Lane application is pending reconciliation/)
    expect(screen.getByText('Not yet applied')).toBeTruthy()
    expect(source(screen).value).toBe(original)
    expect(lane.attachLaneAddon).not.toHaveBeenCalled()
    expect(lane.observeLaneAddon).not.toHaveBeenCalled()
  })
  it('resumes an unsaved new-file draft after closing and starts fresh after creating it', async () => {
    const screen = render(html`<${LaneAddonsPanel} />`)
    await openNew(screen)
    fireEvent.input(await screen.findByLabelText('File name'), { target: { value: 'custom.toml' } })
    fireEvent.input(source(screen), { target: { value: original } })
    fireEvent.click(screen.getByRole('button', { name: 'Close editor' }))
    await openNew(screen)
    await waitFor(() => expect(source(screen).value).toBe(original))
    expect((screen.getByLabelText('File name') as HTMLInputElement).value).toBe('custom.toml')
    files.saveLaneDeclaration.mockResolvedValue(receipt(original))
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await screen.findByText(/File saved. Lane application is pending reconciliation/)
    await openNew(screen)
    await waitFor(() => expect((screen.getByLabelText('File name') as HTMLInputElement).value).toBe(''))
    expect(source(screen).value).not.toBe(original)
  })
  it('keeps newer create-time edits when reopening the now-existing file', async () => {
    let finish: ((value: unknown) => void) | undefined
    files.saveLaneDeclaration.mockImplementation(() => new Promise(resolve => { finish = resolve }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    await openNew(screen)
    fireEvent.input(await screen.findByLabelText('File name'), { target: { value: 'custom.toml' } })
    fireEvent.input(source(screen), { target: { value: original } })
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await screen.findByRole('button', { name: 'Saving TOML…' })
    const newer = '# unsaved after create\n' + original
    fireEvent.input(source(screen), { target: { value: newer } })
    finish?.({ ...receipt(original), write: { state: 'created', durability: 'durable', detail: null } })
    await screen.findByText(/Your newer draft edits are not saved/)
    fireEvent.click(screen.getByRole('button', { name: 'Close editor' }))
    fireEvent.click(within(screen.getByRole('table', { name: 'TOML declarations' })).getByRole('button', { name: `Edit TOML ${path}` }))
    await waitFor(() => expect(source(screen).value).toBe(newer))
    expect(files.fetchLaneDeclaration).not.toHaveBeenCalled()
  })
  it('preserves the reopened file draft when an earlier create response arrives late', async () => {
    let finishCreate: ((value: unknown) => void) | undefined
    files.saveLaneDeclaration.mockImplementationOnce(() => new Promise(resolve => { finishCreate = resolve }))
    lane.fetchLaneAddons.mockResolvedValueOnce({ ...snapshot,
      configuration: { ...snapshot.configuration, declarations: [] } })
    const current = { ...document, source_revision: 'raw-read-after-create' }
    files.fetchLaneDeclaration.mockResolvedValue(current)
    const screen = render(html`<${LaneAddonsPanel} />`)
    await screen.findByText('No readable TOML declarations.')
    await openNew(screen)
    fireEvent.input(await screen.findByLabelText('File name'), { target: { value: 'custom.toml' } })
    fireEvent.input(source(screen), { target: { value: original } })
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await screen.findByRole('button', { name: 'Saving TOML…' })
    fireEvent.click(screen.getByRole('button', { name: 'Close editor' }))
    fireEvent.click(screen.getByRole('button', { name: 'Refresh', exact: true }))
    await open(screen)
    const newer = '# edited after discovering the created file\n' + original
    fireEvent.input(source(screen), { target: { value: newer } })
    finishCreate?.({ ...receipt(original, 'raw-create-receipt'), write: { state: 'created', durability: 'durable', detail: null } })
    await waitFor(() => expect(lane.fetchLaneAddons).toHaveBeenCalledTimes(3))
    expect(source(screen).value).toBe(newer)
    expect((screen.getByRole('button', { name: 'Save TOML' }) as HTMLButtonElement).disabled).toBe(false)
    files.saveLaneDeclaration.mockResolvedValueOnce(receipt(newer, 'raw-saved-after-reopen'))
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await waitFor(() => expect(files.saveLaneDeclaration).toHaveBeenLastCalledWith({
      mode: 'save', file_name: 'custom.toml', source_text: newer, expected_source_revision: 'raw-read-after-create',
    }))
  })
  it('keeps both the create-time draft and the separately reopened draft recoverable', async () => {
    let finishCreate: ((value: unknown) => void) | undefined
    files.saveLaneDeclaration.mockImplementationOnce(() => new Promise(resolve => { finishCreate = resolve }))
    lane.fetchLaneAddons.mockResolvedValueOnce({ ...snapshot,
      configuration: { ...snapshot.configuration, declarations: [] } })
    let screen = render(html`<${LaneAddonsPanel} />`)
    await screen.findByText('No readable TOML declarations.')
    await openNew(screen)
    fireEvent.input(await screen.findByLabelText('File name'), { target: { value: 'custom.toml' } })
    fireEvent.input(source(screen), { target: { value: original } })
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await screen.findByRole('button', { name: 'Saving TOML…' })
    const createDraft = '# unsaved while creating\n' + original
    fireEvent.input(source(screen), { target: { value: createDraft } })
    fireEvent.click(screen.getByRole('button', { name: 'Close editor' }))
    fireEvent.click(screen.getByRole('button', { name: 'Refresh', exact: true }))
    await open(screen)
    const reopenedDraft = '# separate reopened edits\n' + original
    fireEvent.input(source(screen), { target: { value: reopenedDraft } })
    screen.unmount()
    await act(async () => {
      finishCreate?.({ ...receipt(original), write: { state: 'created', durability: 'durable', detail: null } })
      await Promise.resolve()
    })
    screen = render(html`<${LaneAddonsPanel} />`)
    const retained = await screen.findByLabelText('Retained create draft 1')
    expect((retained as HTMLTextAreaElement).value).toBe(createDraft)
    expect((retained as HTMLTextAreaElement).readOnly).toBe(true)
    expect((retained as HTMLTextAreaElement).disabled).toBe(false)
    expect(source(screen).readOnly).toBe(false)
    expect(within(screen.getByLabelText('Retained create draft 1 comparison')).getByText('raw-revision-2')).toBeTruthy()
    expect(source(screen).value).toBe(reopenedDraft)
    fireEvent.click(screen.getByRole('button', { name: 'Close editor' }))
    fireEvent.click(screen.getByRole('button', { name: 'Refresh', exact: true }))
    fireEvent.click(within(screen.getByRole('table', { name: 'TOML declarations' })).getByRole('button', { name: `Edit TOML ${path}` }))
    await waitFor(() => expect(source(screen).value).toBe(reopenedDraft))
    expect((screen.getByLabelText('Retained create draft 1') as HTMLTextAreaElement).value).toBe(createDraft)
    files.saveLaneDeclaration.mockResolvedValueOnce(receipt(reopenedDraft))
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await screen.findByText(/File saved. Lane application is pending reconciliation/)
    expect((screen.getByLabelText('Retained create draft 1') as HTMLTextAreaElement).value).toBe(createDraft)
    const leave = new Event('beforeunload', { cancelable: true })
    window.dispatchEvent(leave)
    expect(leave.defaultPrevented).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: 'Discard retained create draft 1' }))
    await waitFor(() => expect(screen.queryByLabelText('Retained create draft 1')).toBeNull())
    expect(source(screen).value).toBe(reopenedDraft)
  })
  it('recovers a lost create response through the file list while retaining the new-file draft', async () => {
    files.saveLaneDeclaration.mockRejectedValue(new Error('Create response lost'))
    const screen = render(html`<${LaneAddonsPanel} />`)
    await openNew(screen)
    fireEvent.input(await screen.findByLabelText('File name'), { target: { value: 'custom.toml' } })
    fireEvent.input(source(screen), { target: { value: original } })
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await screen.findByText(/Create response lost/)
    const newer = '# kept while checking\n' + original
    fireEvent.input(source(screen), { target: { value: newer } })
    fireEvent.click(screen.getByRole('button', { name: 'Refresh', exact: true }))
    fireEvent.click(within(screen.getByRole('table', { name: 'TOML declarations' })).getByRole('button', { name: `Edit TOML ${path}` }))
    await waitFor(() => expect(source(screen).value).toBe(original))
    expect(files.fetchLaneDeclaration).toHaveBeenCalledWith(path, expect.any(AbortSignal))
    expect(files.saveLaneDeclaration).toHaveBeenCalledTimes(1)
    await openNew(screen)
    await waitFor(() => expect(source(screen).value).toBe(newer))
  })
  it('reads invalid original text from the issue entry and preserves a rejected correction', async () => {
    const malformed = '# unfinished edit\nid = "'
    lane.fetchLaneAddons.mockResolvedValue({ ...snapshot, configuration: { ...snapshot.configuration, declarations: [],
      issues: [{ id: null, source_path: path, message: 'Unterminated string' }] } })
    files.fetchLaneDeclaration.mockResolvedValue({ ...document, source_text: malformed, desired_revision: null,
      validation: { valid: false, messages: ['Unterminated string'] } })
    files.saveLaneDeclaration.mockRejectedValue(new LaneDeclarationError({ code: 'invalid_declaration', error: 'Missing run_id', current: null }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    fireEvent.click(await screen.findByRole('button', { name: `Edit TOML ${path}` }))
    await waitFor(() => expect(source(screen).value).toBe(malformed))
    const correction = 'id = "custom"\n'
    fireEvent.input(source(screen), { target: { value: correction } })
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await screen.findByText(/Missing run_id.*Your draft is preserved/)
    expect(source(screen).value).toBe(correction)
    expect(files.saveLaneDeclaration).toHaveBeenCalledWith({ mode: 'save', file_name: 'custom.toml', source_text: correction, expected_source_revision: 'raw-revision-1' })
    expect(screen.queryByText(/File saved/)).toBeNull()
  })
  it('offers issue editing only for exact declaration files in the configured directory', async () => {
    const directory = snapshot.configuration.directory
    const paths = [directory, `${directory}/nested/broken.toml`, `${directory}-other/broken.toml`,
      `${directory}/readme.txt`, `${directory}/.toml`, path]
    lane.fetchLaneAddons.mockResolvedValue({ ...snapshot, configuration: { ...snapshot.configuration,
      complete: false, declarations: [], issues: paths.map(source_path => ({
        source_path, id: null, message: 'Configuration read failed',
      })) } })
    const screen = render(html`<${LaneAddonsPanel} />`)
    await screen.findByText('Configuration read: incomplete')
    for (const sourcePath of paths.slice(0, -1)) {
      expect(screen.queryByRole('button', { name: `Edit TOML ${sourcePath}`, exact: true })).toBeNull()
    }
    fireEvent.click(screen.getByRole('button', { name: `Edit TOML ${path}`, exact: true }))
    await waitFor(() => expect(source(screen).value).toBe(original))
    expect(files.fetchLaneDeclaration).toHaveBeenCalledTimes(1)
    expect(files.fetchLaneDeclaration).toHaveBeenCalledWith(path, expect.any(AbortSignal))
  })
  it('keeps the draft on conflict and only adopts a new raw revision after an explicit choice', async () => {
    const current = { ...document, source_text: '# another writer\n' + original, source_revision: 'raw-external', desired_revision: document.desired_revision }
    files.saveLaneDeclaration.mockRejectedValueOnce(new LaneDeclarationError({ code: 'revision_conflict', error: 'File changed', current }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    await open(screen)
    const draft = '# my pending change\n' + original
    fireEvent.input(source(screen), { target: { value: draft } })
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await screen.findByText(/File changed.*Your draft is preserved/)
    expect(screen.getByLabelText('Current file source').textContent).toBe(current.source_text)
    expect(source(screen).value).toBe(draft)
    fireEvent.click(screen.getByRole('button', { name: 'Refresh', exact: true }))
    await waitFor(() => expect(lane.fetchLaneAddons).toHaveBeenCalledTimes(2))
    expect(source(screen).value).toBe(draft)
    expect(files.saveLaneDeclaration).toHaveBeenCalledTimes(1)
    fireEvent.click(screen.getByRole('button', { name: 'Use current file revision' }))
    expect(source(screen).value).toBe(draft)
    files.saveLaneDeclaration.mockResolvedValue(receipt(draft, 'raw-next'))
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await waitFor(() => expect(files.saveLaneDeclaration).toHaveBeenLastCalledWith({ mode: 'save', file_name: 'custom.toml', source_text: draft, expected_source_revision: 'raw-external' }))
    await screen.findByText(/File saved. Lane application is pending reconciliation/)
    expect(screen.getByText('Not yet applied')).toBeTruthy()
  })
  it('preserves edits made while a save is pending and keeps them dirty afterward', async () => {
    let finish: ((value: unknown) => void) | undefined
    files.saveLaneDeclaration.mockImplementation(() => new Promise(resolve => { finish = resolve }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    await open(screen)
    const submitted = '# submitted\n' + original
    const newer = '# newer draft\n' + original
    fireEvent.input(source(screen), { target: { value: submitted } })
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await screen.findByRole('button', { name: 'Saving TOML…' })
    fireEvent.input(source(screen), { target: { value: newer } })
    finish?.(receipt(submitted))
    await screen.findByText(/Your newer draft edits are not saved/)
    expect(source(screen).value).toBe(newer)
    expect((screen.getByRole('button', { name: 'Save TOML' }) as HTMLButtonElement).disabled).toBe(false)
  })
  it('keeps a file draft across closing and another new-file session', async () => {
    const screen = render(html`<${LaneAddonsPanel} />`)
    await open(screen)
    const draft = '# keep me\n' + original
    fireEvent.input(source(screen), { target: { value: draft } })
    fireEvent.click(screen.getByRole('button', { name: 'Close editor' }))
    await openNew(screen)
    await screen.findByLabelText('File name')
    fireEvent.input(source(screen), { target: { value: '# separate new draft' } })
    fireEvent.click(within(screen.getByRole('table', { name: 'TOML declarations' })).getByRole('button', { name: `Edit TOML ${path}` }))
    await waitFor(() => expect(source(screen).value).toBe(draft))
    expect(files.fetchLaneDeclaration).toHaveBeenCalledTimes(1)
  })
  it('keeps a draft when a save response fails and reads the current file without replacing it', async () => {
    files.saveLaneDeclaration.mockRejectedValue(new Error('Connection closed'))
    const screen = render(html`<${LaneAddonsPanel} />`)
    await open(screen)
    const draft = '# maybe committed\n' + original
    fireEvent.input(source(screen), { target: { value: draft } })
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await screen.findByText(/The file may already have changed/)
    files.fetchLaneDeclaration.mockResolvedValue({ ...document, source_text: draft, source_revision: 'raw-after-network-loss' })
    fireEvent.click(screen.getByRole('button', { name: 'Read current file' }))
    await screen.findByLabelText('Current file comparison')
    expect(source(screen).value).toBe(draft)
    expect(files.saveLaneDeclaration).toHaveBeenCalledTimes(1)
    fireEvent.click(screen.getByRole('button', { name: 'Use current file revision' }))
    expect((screen.getByRole('button', { name: 'Save TOML' }) as HTMLButtonElement).disabled).toBe(true)
  })
  it('does not claim durable storage when a file receipt reports unconfirmed durability', async () => {
    files.saveLaneDeclaration.mockResolvedValue({ ...receipt('# changed\n' + original),
      write: { state: 'saved', durability: 'unconfirmed', detail: 'Directory sync failed' } })
    const screen = render(html`<${LaneAddonsPanel} />`)
    await open(screen)
    fireEvent.input(source(screen), { target: { value: '# changed\n' + original } })
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await screen.findByText(/Durability is unconfirmed.*Lane application is pending reconciliation.*Directory sync failed/)
    expect(screen.getByText('Not yet applied')).toBeTruthy()
  })
  it('keeps saving unavailable after a failed original read and permits a successful retry', async () => {
    files.fetchLaneDeclaration.mockRejectedValueOnce(new Error('File cannot be read'))
    const screen = render(html`<${LaneAddonsPanel} />`)
    const table = await screen.findByRole('table', { name: 'TOML declarations' })
    fireEvent.click(within(table).getByRole('button', { name: `Edit TOML ${path}` }))
    await screen.findByText('File cannot be read')
    expect(source(screen).disabled).toBe(true)
    expect((screen.getByRole('button', { name: 'Save TOML' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: 'Read current file' }))
    await waitFor(() => expect(source(screen).value).toBe(original))
    expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
  })
})
