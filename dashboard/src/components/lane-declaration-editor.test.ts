import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { LaneDeclarationError, type LaneDeclarationDocument } from '../api/lane-declarations'

const lane = vi.hoisted(() => ({ fetchLaneAddons: vi.fn(), attachLaneAddon: vi.fn(), observeLaneAddon: vi.fn() }))
const files = vi.hoisted(() => ({ fetchLaneDeclaration: vi.fn(), saveLaneDeclaration: vi.fn() }))
vi.mock('../api/lane-addons', async original => ({ ...await original<typeof import('../api/lane-addons')>(), ...lane }))
vi.mock('../api/lane-declarations', async original => ({ ...await original<typeof import('../api/lane-declarations')>(), ...files }))
import { LaneAddonsPanel } from './lane-addons-panel'

const path = '/workspace/.masc/config/lane-addons/custom.toml'
const original = '# preserve this comment\nid = "custom"\nrun_id = "run"\nmanifest_path = "../custom/lane.toml"\n[binding]\nsources = []\n'
const document: LaneDeclarationDocument = {
  file_name: 'custom.toml', source_path: path, source_text: original, source_revision: 'raw-revision-1',
  desired_revision: 'semantic-revision-1', validation: { valid: true, messages: [] },
}
const snapshot = {
  configuration: { directory: '/workspace/.masc/config/lane-addons', complete: true, issues: [], declarations: [
    { id: 'custom', source_path: path, desired_revision: 'semantic-revision-1', applied_revision: null, instance_id: null },
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
  lane.fetchLaneAddons.mockResolvedValue(snapshot)
  files.fetchLaneDeclaration.mockResolvedValue(document)
})
afterEach(() => { cleanup(); vi.resetAllMocks() })

describe('Lane declaration editing through the status surface', () => {
  it('creates a user TOML file without Attach and separates the file receipt from application', async () => {
    files.saveLaneDeclaration.mockResolvedValue({ ...receipt(original), write: { state: 'created', durability: 'durable', detail: null } })
    const screen = render(html`<${LaneAddonsPanel} />`)
    fireEvent.click(screen.getByRole('button', { name: 'New TOML' }))
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
    fireEvent.click(screen.getByRole('button', { name: 'New TOML' }))
    fireEvent.input(await screen.findByLabelText('File name'), { target: { value: 'custom.toml' } })
    fireEvent.input(source(screen), { target: { value: original } })
    fireEvent.click(screen.getByRole('button', { name: 'Close editor' }))
    fireEvent.click(screen.getByRole('button', { name: 'New TOML' }))
    await waitFor(() => expect(source(screen).value).toBe(original))
    expect((screen.getByLabelText('File name') as HTMLInputElement).value).toBe('custom.toml')
    files.saveLaneDeclaration.mockResolvedValue(receipt(original))
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await screen.findByText(/File saved. Lane application is pending reconciliation/)
    fireEvent.click(screen.getByRole('button', { name: 'New TOML' }))
    await waitFor(() => expect((screen.getByLabelText('File name') as HTMLInputElement).value).toBe(''))
    expect(source(screen).value).not.toBe(original)
  })
  it('keeps newer create-time edits when reopening the now-existing file', async () => {
    let finish: ((value: unknown) => void) | undefined
    files.saveLaneDeclaration.mockImplementation(() => new Promise(resolve => { finish = resolve }))
    const screen = render(html`<${LaneAddonsPanel} />`)
    fireEvent.click(screen.getByRole('button', { name: 'New TOML' }))
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
  it('recovers a lost create response through the file list while retaining the new-file draft', async () => {
    files.saveLaneDeclaration.mockRejectedValue(new Error('Create response lost'))
    const screen = render(html`<${LaneAddonsPanel} />`)
    fireEvent.click(screen.getByRole('button', { name: 'New TOML' }))
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
    fireEvent.click(screen.getByRole('button', { name: 'New TOML' }))
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
    fireEvent.click(screen.getByRole('button', { name: 'New TOML' }))
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
