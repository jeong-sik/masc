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
  expect(files.saveLaneDeclaration).not.toHaveBeenCalled()
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
