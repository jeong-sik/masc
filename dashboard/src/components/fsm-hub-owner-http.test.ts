import { html } from 'htm/preact'
import { act, cleanup, render } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clearStoredToken, setStoredToken } from '../api/core'
import { acceptedExecutionWorkspace } from '../execution-workspace-authority'
import { executionLoaded, keepers } from '../store'
import { publishDashboardObservationChange, publishDashboardObservationRecovery } from '../lib/observation-refresh'
import { FsmHub } from './fsm-hub'

const keeper = 'same-keeper'
const settle = () => act(async () => { await vi.advanceTimersByTimeAsync(0); await vi.dynamicImportSettled() })
function workspace(label: string) {
  acceptedExecutionWorkspace.value = { epoch: `fsm-${label}`, workspaceRoot: `/workspace-${label}`,
    connectionGeneration: 1, observerInstanceId: `fsm-instance-${label}` }
}
function answer(phase: 'running' | 'stopped') {
  return Response.json({ keeper, correlation_id: 'correlation', run_id: 'run', ts: 1, phase, turn_phase: 'idle',
    decision: { stage: 'undecided' }, runtime: { state: 'idle' }, measurement: { captured: false },
    invariants: { event_priority_monotone: phase !== 'running', phase_derivation_agreement: true },
    fsm_guard_violations: 0, is_live: false, last_outcome: null,
    runtime_attention: { state: 'ok', needs_attention: false, blocked: false, fiber_stop_requested: false,
      reason: null, raw_phase: phase, is_live: false, source: 'composite_snapshot' } })
}
beforeEach(() => {
  vi.useFakeTimers()
  setStoredToken('fsm-owner-token', { source: 'manual' })
  workspace('A')
  executionLoaded.value = true
  keepers.value = [{ name: keeper, status: 'active' }]
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
  vi.spyOn(console, 'warn').mockImplementation(() => {})
})
afterEach(async () => {
  cleanup()
  acceptedExecutionWorkspace.value = null
  keepers.value = []
  executionLoaded.value = false
  clearStoredToken()
  await settle()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe('FSM original observation owner actual HTTP', () => {
  it.each([false, true])('resets same-name history and invariant counters across workspace replacement, refused=%s', async refused => {
    let scope = 'A'
    let finish!: (response: Response) => void
    const reads: AbortSignal[] = []
    const fetch = vi.fn(async (path: string, init: RequestInit) => {
      expect(path).toBe('/api/v1/keepers/same-keeper/composite')
      reads.push(init.signal as AbortSignal)
      return scope === 'A' ? answer('running') : scope === 'ready-B' ? answer('stopped')
        : new Promise<Response>(resolve => { finish = resolve })
    })
    vi.stubGlobal('fetch', fetch)
    const view = render(html`<${FsmHub} />`)
    await settle()
    expect(view.container.textContent).toContain('1/30 관측')
    scope = 'B'
    await act(async () => { workspace('B') })
    expect(view.container.textContent).not.toContain('1/30 관측')
    await settle()
    await act(async () => { finish(refused ? Response.json({ error: 'refused' }, { status: 403 }) : answer('stopped')) })
    await settle()
    if (refused) {
      expect(view.container.textContent).not.toContain('1/30 관측')
      scope = 'ready-B'
      await act(async () => { setStoredToken('new-B-credential', { source: 'manual' }) })
      await settle()
    }
    expect(view.container.textContent).toContain('1/30 관측')
    expect(view.container.textContent).not.toContain('2/30 관측')
    expect(view.container.querySelectorAll('[title*="누적: 0/1 위반"]')).toHaveLength(2)
    expect(fetch).toHaveBeenCalledTimes(refused ? 3 : 2)
  })

  it.each([401, 403])('preserves the cold Gate Effect transport HTTP %i refusal without source/focus/recovery retries', async status => {
    executionLoaded.value = false
    keepers.value = []
    const fetch = vi.fn(async (path: string) => {
      expect(path).toBe('/api/v1/gate/keepers?detailed=true')
      return Response.json({ error: 'refused' }, { status })
    })
    vi.stubGlobal('fetch', fetch)
    render(html`<${FsmHub} />`)
    await settle()
    publishDashboardObservationChange({ topic: 'gate' })
    window.dispatchEvent(new Event('focus'))
    publishDashboardObservationRecovery()
    await act(async () => { await vi.advanceTimersByTimeAsync(300_000) })
    expect(fetch).toHaveBeenCalledTimes(1)
    await act(async () => { setStoredToken('actual-next-gate-credential', { source: 'manual' }) })
    await settle()
    expect(fetch).toHaveBeenCalledTimes(2)
  })
})
