import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { parseLaneInventory } from '../api/lane-inventory'
import fixture from '../api/fixtures/lane-inventory.json'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
const api = vi.hoisted(() => ({ fetchLaneInventory: vi.fn() }))
vi.mock('../api/lane-inventory', async original => ({ ...await original<typeof import('../api/lane-inventory')>(), ...api }))
import { LaneInventoryPanel } from './lane-inventory-panel'
let generation = 0
const epoch = 'lane-inventory-test'
function workspace(root: string) {
  hydrateExecutionSnapshot({ execution_publication_epoch: epoch, execution_publication_generation: ++generation,
    status: { project: 'fixture', workspace_root: root } } as Parameters<typeof hydrateExecutionSnapshot>[0])
}
afterEach(() => { cleanup(); vi.resetAllMocks() })
beforeEach(() => { invalidateExecutionSnapshotGeneration(epoch, 0); generation = 0; workspace('/fixture/default') })
describe('operator Lane inventory', () => {
  it('shows original installation model routes while the package is off and no worker is present', async () => {
    const row = {
      id: 'declaration//fixture/curator.toml', label: 'Curator installation', purpose: 'Curator',
      selection: { kind: 'declaration', source_path: '/fixture/curator.toml' },
      state: { kind: 'package', instances: [], declaration: { kind: 'valid', enabled: false,
        installation_id: 'custom-curator', run_id: 'scope-not-observation', package_id: 'workspace-curator',
        title: 'Curator', source_revision: 'source', desired_revision: 'desired', application: { kind: 'inactive' },
        exact_outputs: [
          { output: 'classification', source: 'declared', configuration: { kind: 'configured',
            admitted_slots: ['http.first'], cli_slots: ['cli.fallback'], declared_slots: ['http.first', 'refused'],
            declared_cli_slots: ['cli.fallback'], dropped_slots: ['refused'], admission_error: 'runtime refused' } },
          { output: 'briefing', source: 'declared', configuration: { kind: 'unavailable', detail: 'registry unavailable' } },
          { output: 'removed-output', source: 'table_only', configuration: { kind: 'off',
            declared_slots: ['retained'], declared_cli_slots: [] } },
        ] } },
    }
    api.fetchLaneInventory.mockResolvedValue(parseLaneInventory({ ...fixture, rows: [...fixture.rows, row] }))
    const screen = render(html`<${LaneInventoryPanel} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Inspect Curator installation' }))
    const routes = within(screen.getByRole('region', { name: 'Exact-output model routes' }))
    expect(routes.getByText('custom-curator')).toBeTruthy()
    const classification = within(routes.getByRole('region', { name: 'Model route for classification' }))
    for (const text of ['Admitted HTTP: http.first', 'CLI fallbacks: cli.fallback',
      'Declared HTTP: http.first → refused', 'Declared CLI: cli.fallback', 'Dropped HTTP: refused', 'runtime refused']) {
      expect(classification.getByText(text)).toBeTruthy()
    }
    expect(routes.getByRole('region', { name: 'Model route for briefing' }).textContent)
      .toContain('unavailable: registry unavailable')
    const removed = routes.getByRole('region', { name: 'Model route for removed-output' })
    expect(removed.textContent).toContain('Table only')
    expect(removed.textContent).toContain('Model route off')
    expect(routes.getByRole('link', { name: 'Open Runtime configuration' }).getAttribute('href')).toContain('view=config')
    expect(within(screen.getByRole('region', { name: 'Details for Curator installation' }))
      .getByText('Configured off · Off · worker cleanup confirmed')).toBeTruthy()
  })
  it.each([
    [{ kind: 'inactive' }, 'Off · worker cleanup confirmed'],
    [{ kind: 'cleaning' }, 'Worker cleanup pending'],
    [{ kind: 'failed', messages: ['cleanup refused'] }, 'Application failed · cleanup refused'],
    [{ kind: 'unknown', messages: ['not observed'] }, 'Application unknown · not observed'],
  ])('shows the host application even with no worker rows: %j', async (application, expected) => {
    const row = {
      id: 'declaration//fixture/off.toml', label: 'Off package', purpose: 'Observed application',
      selection: { kind: 'declaration', source_path: '/fixture/off.toml' },
      state: { kind: 'package', instances: [], declaration: { kind: 'valid', enabled: false,
        installation_id: 'off', run_id: 'world', package_id: 'observer', title: 'Observer',
        source_revision: 'file-bytes', desired_revision: 'desired', exact_outputs: [], application } },
    }
    api.fetchLaneInventory.mockResolvedValue(parseLaneInventory({ ...fixture, rows: [...fixture.rows, row] }))
    const screen = render(html`<${LaneInventoryPanel} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Inspect Off package' }))
    const detail = within(screen.getByRole('region', { name: 'Details for Off package' }))
    expect(detail.getByText(`Configured off · ${expected}`)).toBeTruthy()
    expect(api.fetchLaneInventory).toHaveBeenCalledTimes(1)
  })
  it('shows off and unknown machine activity alongside retained screen observations without offering an activity toggle', async () => {
    const raw = structuredClone(fixture)
    Object.assign(raw.rows.find(item => item.id === 'machine/msx')!.state, { activity: 'off', publication: 'stable' })
    Object.assign(raw.rows.find(item => item.id === 'machine/dos')!.state, { activity: 'unobserved', publication: 'running' })
    api.fetchLaneInventory.mockResolvedValue(parseLaneInventory(raw))
    const screen = render(html`<${LaneInventoryPanel} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Inspect MSX' }))
    let detail = within(screen.getByRole('region', { name: 'Details for MSX' }))
    expect(detail.getByText('Off · machine state retained')).toBeTruthy()
    expect(detail.getByText('Stable screen published')).toBeTruthy()
    expect(detail.queryByRole('switch')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Inspect DOS' }))
    detail = within(screen.getByRole('region', { name: 'Details for DOS' }))
    expect(detail.getByText('Activity configuration unavailable')).toBeTruthy()
    expect(detail.getByText('Machine running')).toBeTruthy()
    expect(detail.queryByRole('switch')).toBeNull()
    expect(api.fetchLaneInventory).toHaveBeenCalledTimes(1)
  })
  it('names the machine publication unavailable when the worker observation cannot be read', async () => {
    const raw = structuredClone(fixture)
    Object.assign(raw.rows.find(item => item.id === 'machine/msx')!.state, { activity: 'on', publication: 'unavailable' })
    api.fetchLaneInventory.mockResolvedValue(parseLaneInventory(raw))
    const screen = render(html`<${LaneInventoryPanel} />`)
    fireEvent.click(await screen.findByRole('button', { name: 'Inspect MSX' }))
    const detail = within(screen.getByRole('region', { name: 'Details for MSX' }))
    expect(detail.getByText('New execution and input enabled')).toBeTruthy()
    expect(detail.getByText('Worker observation unavailable')).toBeTruthy()
    expect(api.fetchLaneInventory).toHaveBeenCalledTimes(1)
  })
  it('shows browser off and unavailable without losing executor or live observations', async () => {
    const raw = structuredClone(fixture)
    const automation = raw.rows.find(item => item.id === 'browser/automation')!
    const stagehand = raw.rows.find(item => item.id === 'browser/stagehand')!
    const live = raw.rows.find(item => item.id === 'browser/live')!
    Object.assign(automation.state, { activity: 'off', registered: true })
    Object.assign(stagehand.state, { activity: 'unobserved', registered: true })
    Object.assign(live.state, { activity: 'off', connected_clients: 2 })
    api.fetchLaneInventory.mockResolvedValue(parseLaneInventory(raw))
    const screen = render(html`<${LaneInventoryPanel} />`)
    fireEvent.click(await screen.findByRole('button', { name: `Inspect ${automation.label}` }))
    expect(screen.getAllByText('Off · configuration and sessions retained').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Executor registered · session activity unverified').length).toBeGreaterThan(0)
    expect(screen.getAllByText(/Status and close remain available while off/).length).toBeGreaterThan(0)
    fireEvent.input(screen.getByRole('searchbox'), { target: { value: 'browser/stagehand' } })
    fireEvent.click(screen.getByRole('button', { name: `Inspect ${stagehand.label}` }))
    expect(screen.getAllByText('Activity configuration unavailable').length).toBeGreaterThan(0)
    fireEvent.input(screen.getByRole('searchbox'), { target: { value: 'browser/live' } })
    fireEvent.click(screen.getByRole('button', { name: `Inspect ${live.label}` }))
    expect(screen.getAllByText('2 connected clients').length).toBeGreaterThan(0)
    expect(api.fetchLaneInventory).toHaveBeenCalledTimes(1)
  })
  it('searches all families and offers existing owner destinations without inventing controls', async () => {
    api.fetchLaneInventory.mockResolvedValue(parseLaneInventory(fixture))
    const screen = render(html`<${LaneInventoryPanel} />`)
    await screen.findByRole('button', { name: 'Inspect Board Attention' })
    fireEvent.click(screen.getByRole('button', { name: 'Inspect Board Attention' }))
    expect(screen.getByRole('link', { name: 'Runtime settings · Lane candidates' }).getAttribute('href')).toContain('view=config')
    fireEvent.input(screen.getByRole('searchbox'), { target: { value: 'machine/dos' } })
    expect(screen.getAllByRole('button', { name: /^Inspect / })).toHaveLength(1)
    fireEvent.click(screen.getByRole('button', { name: /^Inspect / }))
    expect(screen.getByRole('region', { name: 'DOS 활동 설정' })).toBeTruthy()
    expect(screen.getByRole('button', { name: '활동 설정 열기' }).getAttribute('aria-expanded')).toBe('false')
  })
  it('shows off with retained candidates and work finishing independently', async () => {
    const raw = structuredClone(fixture)
    const lane = raw.exact_snapshot.lanes.find(item => item.lane_id === 'librarian_exact')!
    const row = raw.rows.find(item => item.id === 'exact/librarian_exact')!
    Object.assign(lane, { configured: true, configuration_state: 'off', status: 'off',
      admitted_slots: [], cli_slots: [], dropped_slots: [], admission_error: null,
      declared_slots: ['first', 'second'], declared_cli_slots: ['cli'], running_count: 1 })
    Object.assign(row.state, { configuration: { kind: 'off', declared_slots: ['first', 'second'], declared_cli_slots: ['cli'] } })
    api.fetchLaneInventory.mockResolvedValue(parseLaneInventory(raw))
    const screen = render(html`<${LaneInventoryPanel} />`)
    fireEvent.click(await screen.findByRole('button', { name: `Inspect ${row.label}` }))
    expect(screen.getAllByText('Off · candidate configuration retained; accepted runs finish').length).toBeGreaterThan(0)
    expect(screen.getAllByText(/off · 1 running/).length).toBeGreaterThan(0)
    expect(screen.getByRole('link', { name: 'Runtime settings · Lane candidates' })).toBeTruthy()
  })
  it('labels the retained reading after refresh fails and retries on demand', async () => {
    api.fetchLaneInventory.mockResolvedValueOnce(parseLaneInventory(fixture)).mockRejectedValueOnce(new Error('inventory offline'))
    const screen = render(html`<${LaneInventoryPanel} />`)
    await screen.findByRole('button', { name: 'Inspect Board Attention' })
    fireEvent.click(screen.getByRole('button', { name: 'Refresh Lanes' }))
    await screen.findByText(/Showing the previous reading; current state is unverified/)
    expect(screen.getByRole('button', { name: 'Inspect Board Attention' })).toBeTruthy()
  })
  it('does not accept late rows from another workspace or retain its visible rows', async () => {
    invalidateExecutionSnapshotGeneration(epoch, 0); workspace('/fixture/a')
    let resolveOld!: (value: ReturnType<typeof parseLaneInventory>) => void
    api.fetchLaneInventory.mockImplementationOnce(() => new Promise(resolve => { resolveOld = resolve }))
      .mockResolvedValue(parseLaneInventory(fixture))
    const screen = render(html`<${LaneInventoryPanel} />`)
    await waitFor(() => expect(api.fetchLaneInventory).toHaveBeenCalledTimes(1))
    workspace('/fixture/b')
    await waitFor(() => expect(api.fetchLaneInventory).toHaveBeenCalledTimes(2))
    await screen.findByRole('button', { name: 'Inspect Board Attention' })
    const old = parseLaneInventory(fixture)
    resolveOld({ ...old, rows: old.rows.map(row => ({ ...row, label: 'Wrong workspace row' })) })
    await waitFor(() => expect(screen.queryByText('Wrong workspace row')).toBeNull())
  })
  it('does not read or keep rows while workspace authority is unknown', async () => {
    api.fetchLaneInventory.mockResolvedValue(parseLaneInventory(fixture))
    const screen = render(html`<${LaneInventoryPanel} />`)
    await screen.findByRole('button', { name: 'Inspect Board Attention' })
    invalidateExecutionSnapshotGeneration('new-connection', 0)
    await screen.findByText('Verify the current workspace to read its Lanes.')
    expect(screen.queryByRole('button', { name: 'Inspect Board Attention' })).toBeNull()
    expect(api.fetchLaneInventory).toHaveBeenCalledTimes(1)
    invalidateExecutionSnapshotGeneration('another-connection', 0)
    expect(api.fetchLaneInventory).toHaveBeenCalledTimes(1)
  })
})
