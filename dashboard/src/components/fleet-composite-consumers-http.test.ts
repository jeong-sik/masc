import { html } from 'htm/preact'
import { act, cleanup, render } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from '../api/core'
import { hydrateExecutionSnapshot } from '../store'
import { acceptedExecutionWorkspace } from '../execution-workspace-authority'
import { publishDashboardObservationChange, publishDashboardObservationRecovery } from '../lib/observation-refresh'
import { fleetCompositeData } from '../fleet-composite-resource'
import { AgentRoster } from './agent-roster'
import { KeeperWorkspaceRoster } from './keeper-workspace/keeper-workspace-roster'
import { RegistrySurface } from './registry/registry-surface'
import { IdeKeeperWorkPanel } from './ide/ide-keeper-work-panel'
import { FleetFsmMatrix } from './fleet-fsm-matrix'
import { LaneQueuePanel, resetLaneQueueObservations } from './lanes/lane-queue-panel'

// These independent reads are outside the fixed fleet query under test.
vi.mock('./keeper-turns-state', async original => ({ ...await original<typeof import('./keeper-turns-state')>(),
  subscribeKeeperTurnsRefresh: () => () => {} }))
vi.mock('../keeper-waiting-inventory-store', async original => ({ ...await original<typeof import('../keeper-waiting-inventory-store')>(),
  subscribeKeeperWaitingInventory: () => () => {} }))
vi.mock('./schedule/schedule-state', async original => ({ ...await original<typeof import('./schedule/schedule-state')>(),
  subscribeScheduledAutomationRefresh: () => () => {} }))
vi.mock('../api/keeper', async original => ({ ...await original<typeof import('../api/keeper')>(),
  fetchKeeperLifecycle: async () => ({ keeper: 'shared-keeper', total: 0, events: [] }) }))
vi.mock('../lib/runtime-resolved-resource', async original => ({ ...await original<typeof import('../lib/runtime-resolved-resource')>(),
  loadRuntimeResolved: () => {} }))
vi.mock('./keeper-deletions', () => ({ KeeperDeletions: () => null }))

let generation = 0
const settle = () => act(async () => { await vi.advanceTimersByTimeAsync(0); await vi.dynamicImportSettled() })
function workspace(label: string) {
  expect(hydrateExecutionSnapshot({ execution_publication_epoch: 'fleet-consumer-fixture',
    execution_publication_generation: ++generation, observer_instance_id: `fleet-${label}`,
    projection_diagnostics: { read_completeness: 'complete', read_error: null },
    status: { project: label, workspace_root: `/workspace-${label}` }, agents: [], tasks: [], messages: [],
    keepers: [{ name: 'shared-keeper', status: 'active', phase: 'Running', registered: true, keepalive_running: true }],
    execution_queue: [], worker_support_briefs: [], continuity_briefs: [],
  })).toBe(true)
}
function answer(label: string): Response {
  return Response.json({ generated_at: 1, count: 1, snapshots: [{ keeper: 'shared-keeper',
    correlation_id: `shared-keeper-${label}`, run_id: `run-${label}`, ts: Date.now() / 1_000,
    phase: 'running', turn_phase: 'executing', decision: { stage: 'undecided' }, runtime: { state: 'running' },
    measurement: { captured: true }, invariants: { event_priority_monotone: true, phase_derivation_agreement: true },
    fsm_guard_violations: 0, is_live: true, last_outcome: null,
    live_turn: { turn_id: 1, started_at: 1, last_progress_at: 1, last_progress_kind: 'tool',
      selected_model: `${label}-real-wire-model`, active_tool_count: 2 },
    runtime_attention: { state: 'ok', needs_attention: false, blocked: false, fiber_stop_requested: false,
      reason: null, raw_phase: 'running', is_live: true, source: 'composite_snapshot' } }] })
}
const consumers = [
  { id: 'agent', Component: AgentRoster, props: {} },
  { id: 'workspace', Component: KeeperWorkspaceRoster, props: { activeName: 'shared-keeper' } },
  { id: 'registry', Component: RegistrySurface, props: {} },
  { id: 'ide', Component: IdeKeeperWorkPanel, props: { keeperName: 'shared-keeper' } },
  { id: 'matrix', Component: FleetFsmMatrix, props: {} },
  { id: 'lane', Component: LaneQueuePanel, props: {} },
] as const
function surfaces(ids = consumers.map(consumer => consumer.id)) {
  return html`<div>${consumers.filter(consumer => ids.includes(consumer.id)).map(({ id, Component, props }) =>
    html`<${Component} key=${id} ...${props} />`)}</div>`
}

beforeEach(() => {
  vi.useFakeTimers()
  setStoredToken('actual-fleet-consumer-credential', { source: 'manual' })
  workspace('A')
  resetLaneQueueObservations()
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  vi.spyOn(console, 'warn').mockImplementation(() => {})
})
afterEach(async () => {
  cleanup()
  resetLaneQueueObservations()
  acceptedExecutionWorkspace.value = null
  clearStoredToken()
  await settle()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe('all six actual fleet query consumers', () => {
  it('joins one HTTP read, renders real IDE fields, and performs no healthy periodic HTTP', async () => {
    const fetch = vi.fn(async (path: string) => {
      expect(path).toBe('/api/v1/keepers/composite')
      return answer('A')
    })
    vi.stubGlobal('fetch', fetch)
    const view = render(surfaces())
    await settle()
    expect(fetch.mock.calls.map(([path]) => path)).toEqual(['/api/v1/keepers/composite'])
    expect(view.container.querySelector('[aria-label="Keeper live turn"]')?.textContent).toContain('A-real-wire-model')
    await act(async () => { await vi.advanceTimersByTimeAsync(61_000) })
    expect(fetch).toHaveBeenCalledTimes(1)
    publishDashboardObservationChange({ topic: 'keeper_composite' })
    await settle()
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('withdraws A composite values in all consumers while B is pending and refused', async () => {
    let scope = 'A'
    let complete!: (response: Response) => void
    const fetch = vi.fn(async (path: string) => {
      expect(path).toBe('/api/v1/keepers/composite')
      return scope === 'A' ? answer('A') : new Promise<Response>(resolve => { complete = resolve })
    })
    vi.stubGlobal('fetch', fetch)
    const view = render(surfaces())
    await settle()
    expect(view.container.textContent).toContain('A-real-wire-model')
    scope = 'B'
    await act(async () => { workspace('B') })
    expect(fleetCompositeData.value).toBeNull()
    expect(view.container.textContent).not.toContain('A-real-wire-model')
    await settle()
    await act(async () => { complete(Response.json({ error: 'access refused' }, { status: 403 })) })
    await settle()
    expect(view.container.textContent).not.toContain('A-real-wire-model')
    publishDashboardObservationChange({ topic: 'keeper_composite' })
    window.dispatchEvent(new Event('focus'))
    publishDashboardObservationRecovery()
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('keeps a remaining mounted consumer read alive and physically aborts after the last consumer unmounts', async () => {
    const reads: AbortSignal[] = []
    const fetch = vi.fn((path: string, init: RequestInit) => {
      expect(path).toBe('/api/v1/keepers/composite')
      reads.push(init.signal as AbortSignal)
      return new Promise<Response>(() => {})
    })
    vi.stubGlobal('fetch', fetch)
    const view = render(surfaces())
    await settle()
    expect(fetch).toHaveBeenCalledTimes(1)
    view.rerender(surfaces(['ide']))
    await settle()
    expect(reads[0]!.aborted).toBe(false)
    view.unmount()
    expect(reads[0]!.aborted).toBe(true)
    expect(fetch).toHaveBeenCalledTimes(1)
  })
})
