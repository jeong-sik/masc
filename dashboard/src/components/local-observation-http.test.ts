import { html } from 'htm/preact'
import { act, cleanup, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from '../api/core'
import { acceptedExecutionWorkspace } from '../execution-workspace-authority'
import { publishDashboardObservationChange, publishDashboardObservationRecovery } from '../lib/observation-refresh'
import { useKeeperCompositeEvidence, useKeeperRuntimeTraceEvidence } from './keeper-detail-hooks'
import { KeeperSandboxLivePanel } from './keeper-sandbox-live'
import { RuntimeObservablesPanel } from './runtime-observables-panel'

const keeperName = 'same-keeper'
const settle = () => act(async () => {
  await vi.advanceTimersByTimeAsync(0)
  await vi.dynamicImportSettled()
})
function workspace(label: string) {
  acceptedExecutionWorkspace.value = { epoch: `epoch-${label}`, workspaceRoot: `/workspace-${label}`,
    connectionGeneration: 1, observerInstanceId: `instance-${label}` }
}
function CompositeProbe() {
  const state = useKeeperCompositeEvidence(keeperName)
  return html`<output data-kind=${state.kind}>${state.kind === 'fresh' || state.kind === 'stale' ? state.data.correlation_id : ''}</output>`
}
function TraceProbe() {
  const state = useKeeperRuntimeTraceEvidence(keeperName)
  return html`<output data-kind=${state.kind}>${state.kind === 'fresh' || state.kind === 'stale' ? state.data.trace_id : ''}</output>`
}
function SandboxProbe() { return html`<${KeeperSandboxLivePanel} keeperName=${keeperName} />` }
const surfaces = [
  { name: 'Keeper composite evidence', Component: CompositeProbe, topic: 'keeper_composite',
    path: '/api/v1/keepers/same-keeper/composite', answer: () => Response.json({ keeper: keeperName,
      correlation_id: 'A-evidence', run_id: 'run', ts: 1, phase: 'running', turn_phase: 'idle',
      decision: { stage: 'undecided' }, runtime: { state: 'idle' }, measurement: { captured: true },
      invariants: { event_priority_monotone: true, phase_derivation_agreement: true },
      fsm_guard_violations: 0, is_live: true, last_outcome: null,
      runtime_attention: { state: 'ok', needs_attention: false, blocked: false, fiber_stop_requested: false,
        reason: null, raw_phase: 'running', is_live: true, source: 'composite_snapshot' } }) },
  { name: 'Keeper runtime trace evidence', Component: TraceProbe, topic: 'keeper_runtime_trace',
    path: '/api/v1/keepers/same-keeper/runtime-trace?limit=200', answer: () => Response.json({
      keeper: keeperName, trace_id: 'A-evidence', health: 'ok', manifest_rows: [], receipts: [] }) },
  { name: 'Keeper sandbox', Component: SandboxProbe, topic: 'keeper_sandbox',
    path: '/api/v1/gate/keeper-status?name=same-keeper', answer: () => Response.json({ keeper_last_error: null,
      sandbox_live: { sandbox_profile: 'microvm', configured_network_mode: 'inherit', effective_mode: 'persistent_vm',
        managed_container_kind: 'keeper-vm', containers: [], container_error: null, why_no_container: 'A-evidence' } }) },
  { name: 'Runtime observables', Component: RuntimeObservablesPanel, topic: 'runtime_observables',
    path: '/api/v1/dashboard/runtime-observables', answer: () => Response.json({
      last_write_unixtime: 1, age_seconds: 1, console_sink: { queue_depth: 1, dropped_total: 0 },
      transition_audit: { queue_depth: 0 }, fd: { open: 1, limit: 10, active_operations: [], resource_errors: [] },
      stores: [{ store: 'A-evidence', bytes: 1, files: 1 }], event_bus: [],
      pool: { idle: 1, inflight: 0, reuse_total: 0, evict_total: 0, evict_failure_total: 0, create_total: 1 } }) },
] as const

beforeEach(() => {
  vi.useFakeTimers()
  localStorage.clear()
  setStoredToken('local-observation-credential', { source: 'manual' })
  workspace('A')
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
})
afterEach(() => {
  cleanup()
  acceptedExecutionWorkspace.value = null
  clearStoredToken()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe.each(surfaces)('$name owner reset', ({ Component, topic, path, answer }) => {
  it('withdraws A evidence while B is pending and after B refuses the read', async () => {
    const pending: Array<(response: Response) => void> = []
    let scope = 'A'
    const fetch = vi.fn((url: string) => {
      expect(url).toBe(path)
      return scope === 'A' ? Promise.resolve(answer()) : new Promise<Response>(resolve => { pending.push(resolve) })
    })
    vi.stubGlobal('fetch', fetch)
    render(html`<${Component} />`)
    await settle()
    expect(screen.queryByText('A-evidence')).not.toBeNull()
    expect(fetch).toHaveBeenCalledTimes(1)
    scope = 'B'
    await act(async () => { workspace('B') })
    expect(screen.queryByText('A-evidence')).toBeNull()
    await settle()
    expect(pending).toHaveLength(1)
    await act(async () => { pending[0]!(Response.json({ error: 'access refused' }, { status: 403 })) })
    await settle()
    expect(screen.queryByText('A-evidence')).toBeNull()
    publishDashboardObservationChange({ topic, keeperName })
    window.dispatchEvent(new Event('focus'))
    publishDashboardObservationRecovery()
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(2)
  })
})

describe.each(surfaces.slice(0, 2))('$name original refusal cause', ({ Component, topic, path }) => {
  it.each([401, 403])('keeps HTTP %i terminal for the same owner across source, focus and recovery', async status => {
    const fetch = vi.fn(async (url: string) => {
      expect(url).toBe(path)
      return Response.json({ error: 'access refused' }, { status })
    })
    vi.stubGlobal('fetch', fetch)
    render(html`<${Component} />`)
    await settle()
    expect(fetch).toHaveBeenCalledTimes(1)
    publishDashboardObservationChange({ topic, keeperName })
    window.dispatchEvent(new Event('focus'))
    publishDashboardObservationRecovery()
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(1)
    setStoredToken('actual-new-credential', { source: 'manual' })
    await settle()
    expect(fetch).toHaveBeenCalledTimes(2)
  })
})
