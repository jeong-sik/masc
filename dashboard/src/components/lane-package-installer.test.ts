import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { getStaticTOMLValue, parseTOML } from 'toml-eslint-parser'
const api = vi.hoisted(() => ({ fetchLanePackageCatalog: vi.fn(), fetchLanePackagePreview: vi.fn() }))
const lane = vi.hoisted(() => ({ fetchLaneAddons: vi.fn() }))
const files = vi.hoisted(() => ({ saveLaneDeclaration: vi.fn(), fetchLaneDeclaration: vi.fn() }))
vi.mock('../api/lane-package-catalog', async original => ({ ...await original<typeof import('../api/lane-package-catalog')>(), ...api }))
vi.mock('../api/lane-addons', async original => ({ ...await original<typeof import('../api/lane-addons')>(), ...lane }))
vi.mock('../api/lane-declarations', async original => ({ ...await original<typeof import('../api/lane-declarations')>(), ...files }))
import { LaneAddonsPanel } from './lane-addons-panel'
import { parseLaneAddonSnapshot } from '../api/lane-addons'
import { executionWorkspaceAuthority, hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
import { resetLaneDeclarationSessionsForTesting } from '../lib/lane-declaration-sessions'
import { lanePackageInstallationFor, resetLanePackageInstallationsForTesting } from '../lib/lane-package-installation-session'
const directory = '/workspace/.masc/config/lane-addons'
const object = (properties: Record<string, unknown>, required = Object.keys(properties)) => ({ type: 'object', properties, required, additionalProperties: false })
const schema = object({ sources: { type: 'array', minItems: 1, items: object({
  source_id: { type: 'string', minLength: 1 }, kind: { type: 'string', const: 'lane_output' },
  installation_id: { type: 'string', minLength: 1 }, selection: { type: 'string', const: 'latest_completed' },
  output_id: { type: 'string', minLength: 1 },
}, ['source_id', 'kind', 'installation_id', 'selection']) }, count: { type: 'integer', minimum: 0 }, enabled: { type: 'boolean' } })
const preview = { manifest_path: '/workspace/packages/report/lane.toml', package: { title: 'Report package', revision: 'fresh-2', image: 'image:2', binding_schema: schema },
  image: { state: 'unverified', detail: 'Fixture does not inspect Docker' } }
const catalog = { directory: '/workspace/packages', parent: '/workspace', entries: [
  { kind: 'package', manifest_path: preview.manifest_path, title: 'Listed package', revision: 'listed-1', description: 'Input form package' },
  { kind: 'issue', path: '/workspace/packages/bad/lane.toml', message: 'Invalid manifest' },
] }
const instance = (id: string, run_id = 'run') => ({ instance_id: id, run_id, addon_id: 'producer', title: `Producer ${id}`, revision: 'p1',
  incarnation: `inc-${id}`, action_schema: null, binding: {}, package: { binding_schema: null, presentation: { description: null, readings: [] }, outputs: { results: { all_lanes: true } } },
  configuration: { id, source_path: `${directory}/${id}.toml`, revision: 'applied' },
  phase: { kind: 'attached' }, observation_seq: 0, rows_count: 0 })
const snapshot = { configuration: { directory, complete: true, issues: [], declarations: ['producer', 'other-run'].map(id => ({
  id, source_path: `${directory}/${id}.toml`, enabled: true, desired_revision: 'applied', applied_revision: 'applied', instance_id: id,
})) }, instances: [instance('producer'), instance('other-run', 'different-run')], rows: [], coverage: [] }
let sequence = 0, generation = 0, epoch = ''
function workspace(root: string | null) {
  expect(hydrateExecutionSnapshot({ execution_publication_epoch: epoch, execution_publication_generation: ++generation,
    status: { project: 'package-test', workspace_root: root } } as Parameters<typeof hydrateExecutionSnapshot>[0])).toBe(true)
}
beforeEach(() => {
  resetLaneDeclarationSessionsForTesting(); resetLanePackageInstallationsForTesting(); epoch = `package-${++sequence}`; generation = 0
  invalidateExecutionSnapshotGeneration(epoch, 0); workspace('/workspace')
  lane.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot(snapshot)); api.fetchLanePackageCatalog.mockResolvedValue(catalog); api.fetchLanePackagePreview.mockResolvedValue(preview)
  files.saveLaneDeclaration.mockImplementation(async request => ({ document: { file_name: request.file_name, source_path: `${directory}/${request.file_name}`,
    source_text: request.source_text, source_revision: 'saved', desired_revision: 'desired', validation: { valid: true, messages: [] } },
    write: { state: 'created', durability: 'durable', detail: null }, application: 'pending_reconciliation' }))
})
afterEach(() => { cleanup(); resetLanePackageInstallationsForTesting(); resetLaneDeclarationSessionsForTesting(); vi.resetAllMocks() })
type Screen = ReturnType<typeof render>
const input = (screen: Screen, name: string | RegExp, value: string) => fireEvent.input(screen.getByLabelText(name), { target: { value } })
async function choose(screen: Screen) {
  fireEvent.click(await screen.findByRole('button', { name: 'Install package' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Choose Listed package' }))
  await screen.findByText('Image unverified: Fixture does not inspect Docker')
}
function fill(screen: Screen) {
  input(screen, 'Installation ID', 'new-report')
  fireEvent.input(within(screen.getByRole('region', { name: 'Package installer' })).getByLabelText('Run ID'), { target: { value: 'run' } })
  fireEvent.click(screen.getByRole('button', { name: 'Add binding.sources item' }))
  input(screen, /^binding.sources\[1\].source_id \*$/, 'upstream')
  const output = screen.getByLabelText(/^Use a current output for binding.sources\[1\]/)
  expect(within(output).queryByRole('option', { name: /other-run/ })).toBeNull()
  fireEvent.change(output, { target: { value: '1' } })
  input(screen, /^binding.count \*$/, '0')
  fireEvent.change(screen.getByLabelText(/^binding.enabled \*$/), { target: { value: 'false' } })
}
describe('Web package discovery to explicit declaration save', () => {
  it('retains unsubmitted folder and manifest paths across remount and workspace return', async () => {
    let screen = render(html`<${LaneAddonsPanel} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Install package' }))
    await screen.findByRole('button', { name: 'Choose Listed package' })
    input(screen, 'Workspace folder', '/workspace/unfinished folder')
    input(screen, 'Package manifest path', '/workspace/unfinished/lane.toml')
    screen.unmount(); screen = render(html`<${LaneAddonsPanel} />`)
    expect((await screen.findByLabelText('Workspace folder') as HTMLInputElement).value).toBe('/workspace/unfinished folder')
    expect((screen.getByLabelText('Package manifest path') as HTMLInputElement).value).toBe('/workspace/unfinished/lane.toml')
    await act(() => workspace('/workspace-b'))
    fireEvent.click(await screen.findByRole('button', { name: 'Install package' }))
    expect((await screen.findByLabelText('Workspace folder') as HTMLInputElement).value).toBe('')
    input(screen, 'Workspace folder', '/workspace-b/separate')
    await act(() => workspace('/workspace'))
    expect((await screen.findByLabelText('Workspace folder') as HTMLInputElement).value).toBe('/workspace/unfinished folder')
    expect((screen.getByLabelText('Package manifest path') as HTMLInputElement).value).toBe('/workspace/unfinished/lane.toml')
    expect(api.fetchLanePackagePreview).not.toHaveBeenCalled()
    expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
  })
  it('keeps a failed recheck visible and does not prepare from the known stale preview', async () => {
    const screen = render(html`<${LaneAddonsPanel} />`); await choose(screen); fill(screen)
    api.fetchLanePackagePreview.mockRejectedValueOnce(new Error('manifest missing'))
    fireEvent.click(screen.getByRole('button', { name: 'Recheck package' }))
    await screen.findByText('manifest missing')
    expect((screen.getByLabelText('Installation ID') as HTMLInputElement).value).toBe('new-report')
    fireEvent.click(screen.getByRole('button', { name: 'Prepare TOML draft' }))
    await screen.findByText(/Recheck this package in the current workspace/)
    expect(screen.queryByLabelText('TOML source')).toBeNull()
    expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
  })
  it('edits schema alternatives and optional enums without JSON textareas or lost branch inputs', async () => {
    const alternatives = { type: 'object', oneOf: [
      object({ kind: { type: 'string', const: 'file' }, path: { type: 'string', minLength: 1 } }),
      object({ kind: { type: 'string', const: 'port' }, reference: { type: 'string', minLength: 1 }, mode: { type: 'string', enum: ['x', 'y'] } }, ['kind', 'reference']),
    ] }
    api.fetchLanePackagePreview.mockResolvedValue({ ...preview, package: { ...preview.package, binding_schema: alternatives } })
    const screen = render(html`<${LaneAddonsPanel} />`); await choose(screen)
    const wizard = within(screen.getByRole('region', { name: 'Package installer' }))
    input(screen, 'Installation ID', 'alternative'); fireEvent.input(wizard.getByLabelText('Run ID'), { target: { value: 'run' } })
    const branch = screen.getByLabelText('binding alternative *')
    expect(within(branch).getByRole('option', { name: 'kind: "file"' })).toBeTruthy()
    fireEvent.change(branch, { target: { value: '0' } }); input(screen, 'binding.path *', '/kept')
    fireEvent.change(branch, { target: { value: '1' } }); input(screen, 'binding.reference *', 'producer')
    fireEvent.click(screen.getByLabelText('Include binding.mode'))
    fireEvent.change(screen.getByLabelText('binding.mode', { exact: true }), { target: { value: '1' } })
    fireEvent.change(branch, { target: { value: '0' } }); expect((screen.getByLabelText('binding.path *') as HTMLTextAreaElement).value).toBe('/kept')
    fireEvent.change(branch, { target: { value: '1' } }); expect((screen.getByLabelText('binding.reference *') as HTMLTextAreaElement).value).toBe('producer')
    fireEvent.click(screen.getByRole('button', { name: 'Prepare TOML draft' }))
    expect(getStaticTOMLValue(parseTOML((screen.getByLabelText('TOML source') as HTMLTextAreaElement).value))).toMatchObject({
      binding: { kind: 'port', reference: 'producer', mode: 'y' },
    })
    expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
  })
  it('uses an observed producer and typed nested fields, preserving an existing raw draft', async () => {
    const screen = render(html`<${LaneAddonsPanel} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'New TOML' }))
    input(screen, 'File name', 'older.toml'); input(screen, 'TOML source', '# existing raw draft')
    await choose(screen); fill(screen)
    expect(api.fetchLanePackagePreview).toHaveBeenCalledWith(preview.manifest_path, expect.any(AbortSignal))
    expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Prepare TOML draft' }))
    const source = screen.getByLabelText('TOML source') as HTMLTextAreaElement
    const expected = { enabled: true, id: 'new-report', run_id: 'run', manifest_path: preview.manifest_path,
      binding: { sources: [{ source_id: 'upstream', kind: 'lane_output', installation_id: 'producer', selection: 'latest_completed', output_id: 'results' }], count: 0, enabled: false } }
    expect(getStaticTOMLValue(parseTOML(source.value))).toEqual(expected)
    expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
    const drafts = screen.getByLabelText('Open drafts') as HTMLSelectElement
    const older = within(drafts).getByRole('option', { name: 'older.toml' }) as HTMLOptionElement
    const prepared = drafts.value
    fireEvent.change(drafts, { target: { value: older.value } }); expect(source.value).toBe('# existing raw draft')
    fireEvent.change(drafts, { target: { value: prepared } })
    fireEvent.click(screen.getByRole('button', { name: 'Save TOML' }))
    await waitFor(() => expect(files.saveLaneDeclaration).toHaveBeenCalledTimes(1))
    expect(getStaticTOMLValue(parseTOML(files.saveLaneDeclaration.mock.calls[0]![0].source_text))).toEqual(expected)
    expect(files.saveLaneDeclaration.mock.calls[0]![0].mode).toBe('create')
  })
  it('retains invalid numeric text and source fields across unmount and reports validation before drafting', async () => {
    let screen = render(html`<${LaneAddonsPanel} />`); await choose(screen); fill(screen)
    input(screen, /^binding.count \*$/, '1e'); screen.unmount()
    screen = render(html`<${LaneAddonsPanel} />`)
    await screen.findByLabelText(/^binding.count \*$/)
    expect((screen.getByLabelText(/^binding.count \*$/) as HTMLInputElement).value).toBe('1e')
    fireEvent.click(screen.getByRole('button', { name: 'Prepare TOML draft' }))
    await screen.findByText(/enter a complete finite number/)
    expect(screen.queryByLabelText('TOML source')).toBeNull(); expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
  })
  it('ignores late preview after cancellation and refuses retained inputs until authority is rechecked', async () => {
    const screen = render(html`<${LaneAddonsPanel} />`); await choose(screen); fill(screen)
    let finish!: (value: unknown) => void
    api.fetchLanePackagePreview.mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
    fireEvent.click(screen.getByRole('button', { name: 'Recheck package' }))
    fireEvent.click(screen.getByRole('button', { name: 'Close installer' }))
    await act(async () => finish({ ...preview, package: { ...preview.package, title: 'LATE' } }))
    expect(screen.queryByText(/Configure LATE/)).toBeNull()
    await act(() => workspace('/workspace-b'))
    await waitFor(() => expect(screen.queryByLabelText('Installation ID')).toBeNull())
    await act(() => workspace('/workspace'))
    fireEvent.click(await screen.findByRole('button', { name: 'Install package' }))
    await screen.findByText(/A fresh package preview is required/)
    expect((screen.getByLabelText('Installation ID') as HTMLInputElement).value).toBe('new-report')
    await waitFor(() => expect((screen.getByRole('button', { name: 'Prepare TOML draft' }) as HTMLButtonElement).disabled).toBe(false))
    fireEvent.click(screen.getByRole('button', { name: 'Prepare TOML draft' }))
    await screen.findByText(/Recheck this package in the current workspace/)
    expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Recheck package' }))
    await waitFor(() => expect(screen.queryByText(/A fresh package preview is required/)).toBeNull())
    fireEvent.click(screen.getByRole('button', { name: 'Prepare TOML draft' }))
    await screen.findByLabelText('TOML source')
  })
  it('keeps old input sets when an explicitly rechecked package changes its schema', async () => {
    const screen = render(html`<${LaneAddonsPanel} />`); await choose(screen); fill(screen)
    api.fetchLanePackagePreview.mockResolvedValueOnce({ ...preview, package: { ...preview.package, binding_schema: object({ topic: { type: 'string' } }) } })
    fireEvent.click(screen.getByRole('button', { name: 'Recheck package' }))
    const retained = await screen.findByLabelText('Retained package inputs') as HTMLSelectElement
    const old = within(retained).getByRole('option', { name: /new-report/ }) as HTMLOptionElement
    fireEvent.change(retained, { target: { value: old.value } })
    expect((screen.getByLabelText('Installation ID') as HTMLInputElement).value).toBe('new-report')
    const authority = executionWorkspaceAuthority.peek()!
    const owner = lanePackageInstallationFor(authority, directory)
    expect(owner.state.peek().drafts.get(owner.state.peek().selected!)!.previewAuthority).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Prepare TOML draft' }))
    await screen.findByText(/Recheck this package in the current workspace/)
  })
})
