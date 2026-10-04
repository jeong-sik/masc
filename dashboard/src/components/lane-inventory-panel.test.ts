import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
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
  it('searches all families and offers existing owner destinations without inventing controls', async () => {
    api.fetchLaneInventory.mockResolvedValue(parseLaneInventory(fixture))
    const screen = render(html`<${LaneInventoryPanel} />`)
    await screen.findByRole('button', { name: 'Inspect Board Attention' })
    fireEvent.click(screen.getByRole('button', { name: 'Inspect Board Attention' }))
    expect(screen.getByRole('link', { name: 'Runtime settings · Lane candidates' }).getAttribute('href')).toContain('view=config')
    fireEvent.input(screen.getByRole('searchbox'), { target: { value: 'machine/dos' } })
    expect(screen.getAllByRole('button', { name: /^Inspect / })).toHaveLength(1)
    fireEvent.click(screen.getByRole('button', { name: /^Inspect / }))
    expect(screen.getByText('Manage this machine through its TUI detail or operator tools.')).toBeTruthy()
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
