import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'

const api = vi.hoisted(() => ({
  fetchExactLaneRuns: vi.fn(), fetchVerificationRuns: vi.fn(), fetchFusionRuns: vi.fn(), fetchStandaloneLanes: vi.fn(),
}))
const addons = vi.hoisted(() => ({ fetchLaneAddons: vi.fn() }))
const files = vi.hoisted(() => ({ fetchLaneDeclaration: vi.fn(), saveLaneDeclaration: vi.fn() }))
vi.mock('../api/lane-addons', async original => ({ ...await original<typeof import('../api/lane-addons')>(), ...addons }))
vi.mock('../api/lane-declarations', async original => ({ ...await original<typeof import('../api/lane-declarations')>(), ...files }))
vi.mock('../api/dashboard', () => api)
vi.mock('../api/dashboard-keeper-prompt', () => ({ fetchKeeperRawTraces: vi.fn().mockResolvedValue([]) }))
vi.mock('../sse-store', () => ({ registerInternalAgentRefresh: vi.fn(() => vi.fn()) }))

import { InternalAgentsMonitor } from './internal-agents-monitor'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration, keepers, shellRuntimeResolution } from '../store'
import { replaceRoute, route } from '../router'
import { laneTargetParams } from '../lib/lane-navigation'
import { RuntimeExactLaneEditor } from './runtime-exact-lane-editor'
import { parseLaneInventory } from '../api/lane-inventory'
import fixture from '../api/fixtures/lane-inventory.json'
import { LaneAddonsPanel } from './lane-addons-panel'
import { parseLaneAddonSnapshot } from '../api/lane-addons'
import { resetLaneDeclarationSessionsForTesting } from '../lib/lane-declaration-sessions'
import { resetLanePackageActivitiesForTesting } from '../lib/lane-package-activity-session'

beforeEach(() => {
  resetLaneDeclarationSessionsForTesting(); resetLanePackageActivitiesForTesting()
  invalidateExecutionSnapshotGeneration('f7-filter-audit', 0)
  hydrateExecutionSnapshot({ execution_publication_epoch: 'f7-filter-audit', execution_publication_generation: 1,
    status: { project: 'fixture', workspace_root: '/fixture/navigation' } } as Parameters<typeof hydrateExecutionSnapshot>[0])
  api.fetchExactLaneRuns.mockResolvedValue({ runs: [
    { runId: 'curator-run', runKind: 'exact_output', lane: 'workspace_curator_exact', subjectId: null,
      actor: '/fixture/navigation', startedAt: 1, status: 'succeeded', elapsedSeconds: 1 },
    { runId: 'candle-run', runKind: 'exact_output', lane: 'candle_appraiser', subjectId: null,
      actor: '/fixture/navigation', startedAt: 2, status: 'succeeded', elapsedSeconds: 1 },
  ], count: 2, total: 2, hasMore: false, generatedAt: 'now' })
  api.fetchVerificationRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
  api.fetchFusionRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
  api.fetchStandaloneLanes.mockResolvedValue({ schema: 'masc.standalone_llm_lanes.v2', generatedAt: 'now',
    observedAtUnix: 1, observationOnly: true, exactRunProjectionCount: 0, exactRunSourceTotal: 0,
    exactRunProjectionTruncated: false, lanes: [] })
  replaceRoute('monitoring', laneTargetParams({ kind: 'exact', lane: 'workspace_curator_exact', workspace: '/fixture/navigation' }, true))
})
afterEach(() => {
  cleanup(); replaceRoute('overview', {}); vi.clearAllMocks()
  keepers.value = []; shellRuntimeResolution.value = null
  resetLaneDeclarationSessionsForTesting(); resetLanePackageActivitiesForTesting()
})

it('focuses the same Exact Lane again after another Runtime settings section', async () => {
  const lane = parseLaneInventory(fixture).exact_snapshot.lanes.find(row => row.laneId === 'librarian_exact')!
  const view = (selectedLane?: string) => html`<div><button type="button">Other section</button>
    <${RuntimeExactLaneEditor} sourceText="" lanes=${[lane]} runtimes=${[]} selectedLane=${selectedLane}
      slotsDisabled=${true} deadlineDisabled=${true} onSlotAction=${vi.fn()} onDeadlineChange=${vi.fn()} /></div>`
  const rendered = render(view(lane.laneId))
  const selected = screen.getByRole('region', { name: `Lane configuration ${lane.laneId}` })
  await waitFor(() => expect(document.activeElement).toBe(selected))
  rendered.rerender(view(undefined))
  screen.getByRole('button', { name: 'Other section' }).focus()
  rendered.rerender(view(lane.laneId))
  await waitFor(() => expect(document.activeElement).toBe(selected))
})

it('retries the selected declaration file after its installation identity is restored', async () => {
  const directory = '/fixture/navigation/.masc/config/lane-addons', path = `${directory}/pkg.toml`
  const document = { file_name: 'pkg.toml', source_path: path, source_text: 'id = "replacement"\n',
    source_revision: 'r1', desired_revision: 'semantic', validation: { valid: true, messages: [] } }
  addons.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot({ configuration: { directory, complete: true,
    issues: [], declarations: [{ id: 'pkg', source_path: path, enabled: true, desired_revision: 'semantic',
      applied_revision: null, instance_id: null }] }, instances: [], rows: [], coverage: [] }))
  files.fetchLaneDeclaration.mockResolvedValue(document)
  replaceRoute('monitoring', laneTargetParams({ kind: 'declaration', workspace: '/fixture/navigation', path, installation: 'pkg' }))
  render(html`<${LaneAddonsPanel} />`)
  await screen.findByText('The file read belongs to a different installation. The replacement was not opened.')
  const previousReads = files.fetchLaneDeclaration.mock.calls.length
  files.fetchLaneDeclaration.mockResolvedValue({ ...document, source_text: 'id = "pkg"\n', source_revision: 'r2' })
  fireEvent.click(screen.getByRole('button', { name: 'Read target again' }))
  await waitFor(() => expect(addons.fetchLaneAddons).toHaveBeenCalledTimes(2))
  await waitFor(() => expect(files.fetchLaneDeclaration.mock.calls.length).toBeGreaterThan(previousReads))
  await screen.findByRole('region', { name: 'Lane TOML editor' })
  // Reading a restored identity does not silently adopt its new save basis.
  await screen.findByRole('region', { name: 'Current file comparison' })
  expect((screen.getByLabelText('TOML source') as HTMLTextAreaElement).value).toBe('id = "replacement"\n')
  expect((screen.getByRole('button', { name: 'Save TOML' }) as HTMLButtonElement).disabled).toBe(true)
  expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
})

it('does not read a target from another workspace or a malformed direct link', async () => {
  replaceRoute('monitoring', laneTargetParams({ kind: 'declaration', workspace: '/fixture/other',
    path: '/fixture/other/.masc/config/lane-addons/pkg.toml', installation: 'pkg' }))
  render(html`<${LaneAddonsPanel} />`)
  await screen.findByText(/This Lane link belongs to another workspace/)
  expect(addons.fetchLaneAddons).not.toHaveBeenCalled(); expect(files.fetchLaneDeclaration).not.toHaveBeenCalled()
  replaceRoute('monitoring', { section: 'lane-addons', lane_target: '{broken' })
  await screen.findByText('The Lane link has an invalid or incomplete target.')
  expect(addons.fetchLaneAddons).not.toHaveBeenCalled(); expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
})

it('does not open a file when the fresh inventory assigns it to another installation', async () => {
  const directory = '/fixture/navigation/.masc/config/lane-addons', path = `${directory}/pkg.toml`
  addons.fetchLaneAddons.mockResolvedValue(parseLaneAddonSnapshot({ configuration: { directory, complete: true,
    issues: [], declarations: [{ id: 'replacement', source_path: path, enabled: true, desired_revision: 'semantic',
      applied_revision: null, instance_id: null }] }, instances: [], rows: [], coverage: [] }))
  replaceRoute('monitoring', laneTargetParams({ kind: 'declaration', workspace: '/fixture/navigation', path, installation: 'pkg' }))
  render(html`<${LaneAddonsPanel} />`)
  await screen.findByText('The selected file now belongs to a different installation. Its replacement was not opened.')
  expect(files.fetchLaneDeclaration).not.toHaveBeenCalled(); expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
})

const directory = '/fixture/navigation/.masc/config/lane-addons', path = `${directory}/pkg.toml`
const declarationDocument = { file_name: 'pkg.toml', source_path: path, source_text: 'id = "pkg"\n',
  source_revision: 'same-bytes', desired_revision: 'semantic', validation: { valid: true, messages: [] as string[] } }
const declarations = parseLaneAddonSnapshot({ configuration: { directory, complete: true, issues: [], declarations: [
  { id: 'pkg', source_path: path, enabled: true, desired_revision: 'semantic', applied_revision: null, instance_id: null },
] }, instances: [], rows: [], coverage: [] })
function declarationRoute() {
  replaceRoute('monitoring', laneTargetParams({ kind: 'declaration', workspace: '/fixture/navigation', path, installation: 'pkg' }))
}
it('can retry an initial inventory failure without discarding the selected file target', async () => {
  addons.fetchLaneAddons.mockRejectedValueOnce(new Error('inventory unavailable')).mockResolvedValue(declarations)
  files.fetchLaneDeclaration.mockResolvedValue(declarationDocument); declarationRoute()
  render(html`<${LaneAddonsPanel} />`)
  await screen.findByText('inventory unavailable')
  fireEvent.click(screen.getByRole('button', { name: 'Read target again' }))
  await screen.findByRole('region', { name: 'Lane TOML editor' })
  expect(route.value.params.lane_target).toBeDefined(); expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
})
it('refreshes validation metadata for unchanged file bytes while retaining unsaved text', async () => {
  addons.fetchLaneAddons.mockResolvedValue(declarations)
  files.fetchLaneDeclaration.mockResolvedValue({ ...declarationDocument, desired_revision: null,
    validation: { valid: false, messages: ['manifest is missing'] } }); declarationRoute()
  render(html`<${LaneAddonsPanel} />`)
  await screen.findByText('manifest is missing')
  const source = screen.getByLabelText('TOML source') as HTMLTextAreaElement
  fireEvent.input(source, { target: { value: '# unsaved\n'+declarationDocument.source_text } })
  files.fetchLaneDeclaration.mockResolvedValue(declarationDocument)
  fireEvent.click(screen.getByRole('button', { name: 'Read current file' }))
  await waitFor(() => expect(screen.queryByText('manifest is missing')).toBeNull())
  expect(source.value).toBe('# unsaved\n'+declarationDocument.source_text)
  expect(screen.queryByRole('region', { name: 'Current file comparison' })).toBeNull()
  expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
})
it('releases the linked target when the operator starts a different declaration', async () => {
  addons.fetchLaneAddons.mockResolvedValue(declarations); files.fetchLaneDeclaration.mockResolvedValue(declarationDocument); declarationRoute()
  render(html`<${LaneAddonsPanel} />`); await screen.findByRole('region', { name: 'Lane TOML editor' })
  fireEvent.input(screen.getByLabelText('TOML source'), { target: { value: '# retained\n'+declarationDocument.source_text } })
  fireEvent.click(screen.getByRole('button', { name: 'New TOML' }))
  await waitFor(() => expect(route.value.params.lane_target).toBeUndefined())
  addons.fetchLaneAddons.mockResolvedValue({ ...declarations, configuration: { ...declarations.configuration!, declarations: [] } })
  fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
  await screen.findByText('No readable TOML declarations.')
  expect(screen.getByRole('region', { name: 'Lane TOML editor' })).toBeTruthy()
  fireEvent.change(screen.getByLabelText('Open drafts'), { target: { value: path } })
  expect((screen.getByLabelText('TOML source') as HTMLTextAreaElement).value).toBe('# retained\n'+declarationDocument.source_text)
})
it('uses the targeted run source for unavailable state instead of a previous successful filter', async () => {
  api.fetchExactLaneRuns.mockRejectedValue(new Error('exact unavailable'))
  replaceRoute('monitoring', { section: 'internal-agents' })
  render(html`<${InternalAgentsMonitor} />`)
  const filters = within(screen.getByRole('group', { name: 'Internal agent filters' }))
  fireEvent.click(await filters.findByRole('button', { name: 'Fusion 0' }))
  await screen.findByText('No internal agent runs for this filter.')
  replaceRoute('monitoring', laneTargetParams({ kind: 'exact', lane: 'librarian_exact', workspace: '/fixture/navigation' }, true))
  await screen.findByText('Run observations unavailable for this filter.')
  expect(filters.getByRole('button', { name: 'Fusion 0' }).getAttribute('aria-pressed')).toBe('false')
  expect(screen.queryByText('No internal agent runs for this filter.')).toBeNull()
})

it('reads verifier_exact availability from verification runs, not the exact-run endpoint', async () => {
  // Exact-lane runs never name verifier_exact, so their endpoint failing says
  // nothing about this Lane's observations.
  api.fetchExactLaneRuns.mockRejectedValue(new Error('exact unavailable'))
  replaceRoute('monitoring', laneTargetParams({ kind: 'exact', lane: 'verifier_exact', workspace: '/fixture/navigation' }, true))
  render(html`<${InternalAgentsMonitor} />`)
  await screen.findByText('No internal agent runs for this filter.')
  expect(screen.queryByText('Run observations unavailable for this filter.')).toBeNull()
})

it('shows all Lane runs when leaving a target with the Show all action', async () => {
  replaceRoute('monitoring', { section: 'internal-agents' })
  render(html`<${InternalAgentsMonitor} />`)
  const filters = within(screen.getByRole('group', { name: 'Internal agent filters' }))
  fireEvent.click(await filters.findByRole('button', { name: 'Fusion 0' }))
  replaceRoute('monitoring', laneTargetParams({ kind: 'exact', lane: 'workspace_curator_exact', workspace: '/fixture/navigation' }, true))
  await screen.findByRole('button', { name: /succeeded Workspace Curator/ })
  fireEvent.click(screen.getByRole('button', { name: 'Show all Lane runs' }))
  await waitFor(() => expect(route.value.params.lane_target).toBeUndefined())
  expect(filters.getByRole('button', { name: 'All 2' }).getAttribute('aria-pressed')).toBe('true')
  expect(screen.getByRole('button', { name: /succeeded Workspace Curator/ })).toBeTruthy()
  expect(screen.getByRole('button', { name: /succeeded Candle Appraiser/ })).toBeTruthy()
})

it('keeps the chosen filter when leaving a selected Lane through the real router', async () => {
  render(html`<${InternalAgentsMonitor} />`)
  await screen.findByRole('button', { name: /succeeded Workspace Curator/ })
  expect(screen.queryByRole('button', { name: /succeeded Candle Appraiser/ })).toBeNull()
  const filters = within(screen.getByRole('group', { name: 'Internal agent filters' }))
  fireEvent.click(filters.getByRole('button', { name: 'Candle Appraiser 1' }))
  await waitFor(() => expect(route.value.params.lane_target).toBeUndefined())
  await screen.findByRole('button', { name: /succeeded Candle Appraiser/ })
  expect(within(screen.getByRole('group', { name: 'Internal agent filters' }))
    .getByRole('button', { name: 'Candle Appraiser 1' }).getAttribute('aria-pressed')).toBe('true')
  expect(screen.queryByRole('button', { name: /succeeded Workspace Curator/ })).toBeNull()
})
