import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, it, expect, vi } from 'vitest'

const { fetchKeepersCompositeMock, dispatchOperatorActionMock, showToastMock } = vi.hoisted(() => ({
  fetchKeepersCompositeMock: vi.fn(),
  dispatchOperatorActionMock: vi.fn(),
  showToastMock: vi.fn(),
}))

vi.mock('../api/keeper', () => ({
  fetchKeepersComposite: fetchKeepersCompositeMock,
}))

vi.mock('../operator-store', () => ({
  dispatchOperatorAction: dispatchOperatorActionMock,
}))

vi.mock('./common/toast', () => ({
  showToast: showToastMock,
}))

import {
  buildRuntimeAssistPrompt,
  chipClassFor,
  filterKeeperSnapshots,
  fleetCellPresentation,
  FLEET_HISTORY_LEN,
  inferKeeperNameFrom,
  latestRuntimeActivityEpoch,
  pushObservation,
  runtimeAttentionForSnapshot,
  sparkClassFor,
  tallyInvariantViolations,
  tallyRuntimeAttention,
  type KeeperFleetHistory,
  FleetFsmMatrix,
} from './fleet-fsm-matrix'
import { fleetCompositeSnapshot } from '../composite-signals'
import type {
  FleetCompositeSnapshot,
  KeeperCompositeExecution,
  KeeperCompositeSnapshot,
} from '../api/keeper'

function snapshot(
  overrides: Partial<KeeperCompositeSnapshot> & {
    name?: string
    allHold?: boolean
    violate?: Partial<KeeperCompositeSnapshot['invariants']>
  } = {},
): KeeperCompositeSnapshot {
  const name = overrides.name ?? 'alpha'
  const allHold = overrides.allHold ?? true
  const base: KeeperCompositeSnapshot = {
    keeper: name,
    correlation_id: `keeper:${name}:42`,
    run_id: `r-0-${name}`,
    ts: 1_713_000_000,
    phase: 'Running',
    turn_phase: 'idle',
    decision: { stage: 'undecided' },
    cascade: { state: 'idle' },
    compaction: { stage: 'accumulating' },
    measurement: { captured: true },
    invariants: {
      phase_turn_alignment: allHold,
      no_cascade_before_measurement: allHold,
      compaction_atomicity: allHold,
      event_priority_monotone: allHold,
      ...overrides.violate,
    },
    is_live: false,
    last_outcome: null,
    recommended_actions: [],
  }
  return { ...base, ...overrides }
}

function execution(
  overrides: Partial<KeeperCompositeExecution> = {},
): KeeperCompositeExecution {
  return {
    latest_receipt_present: true,
    recorded_at: '2026-04-25T07:30:00Z',
    outcome: 'ok',
    terminal_reason_code: 'completed',
    operator_disposition: 'pass',
    operator_disposition_reason: 'healthy',
    model_used: 'auto',
    stop_reason: 'completed',
    tool_contract_result: 'satisfied_execution',
    duration_ms: 12_000,
    error: null,
    cascade: null,
    tool_surface: null,
    ...overrides,
  }
}

function fleetSnapshot(
  snapshots: KeeperCompositeSnapshot[] = [snapshot()],
): FleetCompositeSnapshot {
  return {
    generated_at: 1_713_000_000,
    count: snapshots.length,
    snapshots,
  }
}

afterEach(() => {
  cleanup()
  vi.useRealTimers()
  fetchKeepersCompositeMock.mockReset()
  dispatchOperatorActionMock.mockReset()
  showToastMock.mockReset()
  fleetCompositeSnapshot.value = null
})

describe('chipClassFor', () => {
  it('maps known states to the right semantic tone', () => {
    // After the design-system migration the chip strings use semantic
    // tokens (`--ok`, `--bad-light`, `--warn`, `--accent`) rather than
    // raw Tailwind color names.
    expect(chipClassFor('Running')).toContain('var(--ok')
    expect(chipClassFor('Failing')).toContain('var(--bad-light')
    expect(chipClassFor('Compacting')).toContain('var(--warn')
    expect(chipClassFor('exhausted')).toContain('var(--bad-light')
    // KCB (LT-16-KCB Phase 3)
    expect(chipClassFor('warning')).toContain('var(--warn')
    expect(chipClassFor('cooling')).toContain('var(--accent')
  })

  it('falls back to the default chip for unknown states', () => {
    const cls = chipClassFor('unknown_state_variant')
    expect(cls).toContain('bg-[var(--color-bg-elevated)]')
  })
})

describe('inferKeeperNameFrom', () => {
  it('uses the explicit keeper identity when present', () => {
    const snap = snapshot({
      keeper: 'analyst',
      correlation_id: 'agent:analyst-session:42',
    })
    expect(inferKeeperNameFrom(snap)).toBe('analyst')
  })

  it('extracts the keeper name from a canonical correlation_id for old payloads', () => {
    const snap = snapshot({ name: 'gen12-payroll' })
    delete snap.keeper
    expect(inferKeeperNameFrom(snap)).toBe('gen12-payroll')
  })

  it('falls back to the correlation_id verbatim on non-canonical ids', () => {
    const snap = snapshot({ correlation_id: 'not-a-keeper-id' })
    delete snap.keeper
    expect(inferKeeperNameFrom(snap)).toBe('not-a-keeper-id')
  })
})

describe('tallyInvariantViolations', () => {
  it('returns all zeros when every keeper satisfies every invariant', () => {
    const s = [snapshot({ name: 'a' }), snapshot({ name: 'b' })]
    expect(tallyInvariantViolations(s)).toEqual({
      phase_turn_alignment: 0,
      no_cascade_before_measurement: 0,
      compaction_atomicity: 0,
      event_priority_monotone: 0,
    })
  })

  it('counts one per keeper per violated invariant', () => {
    const s = [
      snapshot({ name: 'a', violate: { phase_turn_alignment: false } }),
      snapshot({ name: 'b', violate: { phase_turn_alignment: false, compaction_atomicity: false } }),
      snapshot({ name: 'c' }),
    ]
    const t = tallyInvariantViolations(s)
    expect(t.phase_turn_alignment).toBe(2)
    expect(t.compaction_atomicity).toBe(1)
    expect(t.no_cascade_before_measurement).toBe(0)
    expect(t.event_priority_monotone).toBe(0)
  })

  it('treats an empty fleet as clean', () => {
    expect(tallyInvariantViolations([])).toEqual({
      phase_turn_alignment: 0,
      no_cascade_before_measurement: 0,
      compaction_atomicity: 0,
      event_priority_monotone: 0,
    })
  })
})

describe('runtimeAttentionForSnapshot', () => {
  const generatedAt = Date.parse('2026-04-25T07:40:00Z') / 1000

  it('flags a Running-but-not-live keeper with pause_human evidence as blocked', () => {
    const snap = snapshot({
      is_live: false,
      execution: execution({
        outcome: 'error',
        terminal_reason_code: 'api_error',
        operator_disposition: 'pause_human',
        operator_disposition_reason: 'tool_required_unsatisfied',
        tool_contract_result: 'unknown',
        error: {
          kind: 'api',
          message_preview: 'Timeout after 1170s',
          message_truncated: false,
        },
      }),
    })

    const attention = runtimeAttentionForSnapshot(snap, generatedAt)
    expect(attention.level).toBe('blocked')
    expect(attention.label).toBe('정체')
    expect(attention.reason).toContain('is_live=false')
    expect(attention.reason).toContain('operator=pause_human')
    expect(attention.reason).toContain('reason=tool_required_unsatisfied')
    expect(attention.title).toContain('latest activity 10m ago')
  })

  it('prefers backend runtime_attention over narrower frontend heuristics', () => {
    const snap = snapshot({
      is_live: false,
      execution: execution({
        outcome: 'ok',
        terminal_reason_code: 'completed',
        operator_disposition: 'pass',
        operator_disposition_reason: 'healthy',
        tool_contract_result: 'passive_only',
      }),
      runtime_attention: {
        state: 'blocked',
        needs_attention: true,
        blocked: true,
        fiber_stop_requested: false,
        reason: 'passive_only',
        raw_phase: 'Running',
        is_live: false,
        source: 'execution_receipt',
      },
    })

    const attention = runtimeAttentionForSnapshot(snap, generatedAt)
    expect(attention.level).toBe('blocked')
    expect(attention.cause).toContain('execution_receipt')
    expect(attention.cause).toContain('passive_only')
    expect(attention.reason).toContain('backend runtime_attention')
  })

  it('maps backend stop-requested attention to shutdown follow-up', () => {
    const snap = snapshot({
      is_live: true,
      runtime_attention: {
        state: 'stop_requested',
        needs_attention: true,
        blocked: false,
        fiber_stop_requested: true,
        reason: 'fiber stop requested',
        raw_phase: 'Running',
        is_live: true,
        source: 'composite_snapshot',
      },
    })

    const attention = runtimeAttentionForSnapshot(snap, generatedAt)
    expect(attention.level).toBe('blocked')
    expect(attention.label).toBe('정지 요청')
    expect(attention.reason).toContain('backend runtime_attention')
    expect(attention.reason).toContain('stop_requested')
    expect(attention.cause).toContain('fiber stop requested')
    expect(attention.nextStep).toContain('shutdown 완료')
  })

  it('keeps recent healthy non-live keepers waiting instead of stale', () => {
    const snap = snapshot({
      is_live: false,
      phase: 'Running',
      execution: execution({
        recorded_at: '2026-04-25T07:38:30Z',
      }),
      runtime_attention: {
        state: 'ok',
        needs_attention: false,
        blocked: false,
        fiber_stop_requested: false,
        reason: null,
        raw_phase: 'Running',
        is_live: false,
        source: 'composite_snapshot',
      },
    })

    const attention = runtimeAttentionForSnapshot(snap, generatedAt)
    expect(snap.phase).toBe('Running')
    expect(attention.level).toBe('ok')
    expect(attention.label).toBe('대기')
    expect(attention.reason).toContain('healthy idle')
  })

  it('keeps raw lifecycle separate by flagging stale liveness without changing phase', () => {
    const snap = snapshot({
      is_live: false,
      phase: 'Running',
    })

    const attention = runtimeAttentionForSnapshot(snap, generatedAt)
    expect(snap.phase).toBe('Running')
    expect(attention.level).toBe('stale')
    expect(attention.reason).toContain('is_live=false')
  })

  it('flags a live idle composite after the operator threshold', () => {
    const snap = snapshot({
      is_live: true,
      execution: execution({
        recorded_at: '2026-04-25T07:20:00Z',
      }),
    })

    const attention = runtimeAttentionForSnapshot(snap, generatedAt)
    expect(attention.level).toBe('idle')
    expect(attention.label).toBe('무전환')
    expect(attention.reason).toContain('idle composite')
  })

  it('counts live, blocked, stale, and idle runtime truth separately', () => {
    const live = snapshot({
      name: 'live',
      is_live: true,
      turn_phase: 'executing',
      execution: execution(),
    })
    const blocked = snapshot({
      name: 'blocked',
      is_live: false,
      execution: execution({
        outcome: 'error',
        terminal_reason_code: 'api_error',
        operator_disposition: 'pause_human',
      }),
    })
    const stale = snapshot({
      name: 'stale',
      is_live: false,
    })
    const idle = snapshot({
      name: 'idle',
      is_live: true,
      execution: execution({ recorded_at: '2026-04-25T07:20:00Z' }),
    })

    expect(tallyRuntimeAttention([live, blocked, stale, idle], generatedAt)).toEqual({
      live: 2,
      blocked: 1,
      stale: 1,
      idle: 1,
      total: 4,
    })
  })

  it('uses the newest receipt or last outcome timestamp as activity evidence', () => {
    const snap = snapshot({
      last_outcome: {
        turn_id: 7,
        ended_at: generatedAt - 300,
        decision_stage: 'guard_ok',
        cascade_state: 'done',
        selected_model: 'custom:mock',
      },
      execution: execution({
        recorded_at: '2026-04-25T07:20:00Z',
      }),
    })

    expect(latestRuntimeActivityEpoch(snap)).toBe(generatedAt - 300)
  })

  it('names missing required keeper tools in blocker cause and next step', () => {
    const snap = snapshot({
      is_live: false,
      execution: execution({
        outcome: 'error',
        terminal_reason_code: 'completion_contract_violation:require_tool_use',
        operator_disposition: 'pause_human',
        operator_disposition_reason: 'tool_required_unsatisfied',
        tool_contract_result: 'missing_required_tool_use',
        tool_surface: {
          tool_requirement: 'required',
          tool_gate_enabled: true,
          missing_required_tools: ['keeper_bash'],
          required_tools: ['keeper_bash'],
        },
      }),
    })

    const attention = runtimeAttentionForSnapshot(snap, generatedAt)
    expect(attention.level).toBe('blocked')
    expect(attention.cause).toContain('missing_required_tool_use (keeper_bash)')
    expect(attention.nextStep).toContain('keeper_bash')
  })

  it('routes provider timeout blockers away from generic approval guidance', () => {
    const snap = snapshot({
      is_live: true,
      execution: execution({
        outcome: 'error',
        terminal_reason_code: 'api_error_timeout',
        operator_disposition: 'pause_human',
        operator_disposition_reason: 'tool_required_unsatisfied',
        tool_contract_result: 'unknown',
        error: {
          kind: 'api',
          message_preview: 'Timeout after 1785s',
          message_truncated: false,
        },
      }),
    })

    const attention = runtimeAttentionForSnapshot(snap, generatedAt)
    expect(attention.level).toBe('blocked')
    expect(attention.nextStep).toBe('provider timeout budget/cascade lane 확인')
  })
})

describe('fleetCellPresentation', () => {
  const generatedAt = Date.parse('2026-04-25T07:40:00Z') / 1000

  it('overlays runtime blocker truth on the KSM chip without rewriting raw phase', () => {
    const snap = snapshot({
      phase: 'Running',
      is_live: false,
      execution: execution({
        outcome: 'error',
        terminal_reason_code: 'api_error',
        operator_disposition: 'pause_human',
        operator_disposition_reason: 'tool_required_unsatisfied',
      }),
    })
    const attention = runtimeAttentionForSnapshot(snap, generatedAt)
    const cell = fleetCellPresentation('phase', snap.phase, attention)

    expect(snap.phase).toBe('Running')
    expect(cell.runtimePhaseConflict).toBe(true)
    expect(cell.label).toBe('가동 중 · 정체')
    expect(cell.className).toContain('var(--bad-light)')
    expect(cell.title).toContain('KSM Running')
    expect(cell.title).toContain('runtime 정체')
    expect(cell.title).toContain('operator pause: tool_required_unsatisfied')
  })

  it('keeps non-KSM lanes tied to their raw FSM state', () => {
    const snap = snapshot({
      is_live: false,
      execution: execution(),
    })
    const attention = runtimeAttentionForSnapshot(snap, generatedAt)
    const cell = fleetCellPresentation('turn', snap.turn_phase, attention)

    expect(cell.runtimePhaseConflict).toBe(false)
    expect(cell.label).toBe('대기')
    expect(cell.className).toContain('var(--white-5)')
  })
})

describe('buildRuntimeAssistPrompt', () => {
  const generatedAt = Date.parse('2026-04-25T07:40:00Z') / 1000

  it('carries cause, evidence, and supervised resolve instructions into the keeper prompt', () => {
    const snap = snapshot({
      name: 'blocked',
      phase: 'Running',
      is_live: false,
      execution: execution({
        outcome: 'error',
        terminal_reason_code: 'api_error',
        operator_disposition: 'pause_human',
        operator_disposition_reason: 'tool_required_unsatisfied',
      }),
    })
    const attention = runtimeAttentionForSnapshot(snap, generatedAt)
    const prompt = buildRuntimeAssistPrompt('blocked', snap, attention)

    expect(prompt).toContain('감독형 런타임 진단 요청: blocked')
    expect(prompt).toContain('cause=')
    expect(prompt).toContain('operator pause: tool_required_unsatisfied')
    expect(prompt).toContain('evidence=')
    expect(prompt).toContain('KSM=Running')
    expect(prompt).toContain('resolve 후보')
    expect(prompt).toContain('keeper_probe')
    expect(prompt).toContain('keeper_recover')
  })
})

describe('sparkClassFor', () => {
  it('extracts a single bg-* utility from the full chip class', () => {
    // Bracketed Tailwind arbitrary values that wrap CSS vars cannot
    // live inside a JS regex literal because `[...]` starts a
    // character class; use startsWith on the extracted prefix.
    expect(sparkClassFor('Running').startsWith('bg-[var(--ok-10)]')).toBe(true)
    expect(sparkClassFor('Failing').startsWith('bg-[var(--bad-10)]')).toBe(true)
  })

  it('falls back to the muted white token on unknown states', () => {
    // DEFAULT_CHIP carries `bg-[var(--color-bg-elevated)]`; sparkClassFor preserves it.
    expect(sparkClassFor('__not_a_state__').startsWith('bg-[var(--color-bg-elevated)]')).toBe(true)
  })
})

describe('pushObservation', () => {
  it('seeds a new keeper with one observation per axis', () => {
    const next = pushObservation({}, [snapshot({ name: 'alpha' })])
    const alpha = next.alpha!
    expect(alpha.phase).toEqual(['Running'])
    expect(alpha.turn).toEqual(['idle'])
    expect(alpha.decision).toEqual(['undecided'])
    expect(alpha.cascade).toEqual(['idle'])
    expect(alpha.compaction).toEqual(['accumulating'])
  })

  it('appends new observations while preserving prior ones', () => {
    const t1 = pushObservation({}, [snapshot({ name: 'alpha', phase: 'Running' })])
    const t2 = pushObservation(t1, [snapshot({ name: 'alpha', phase: 'Failing' })])
    expect(t2.alpha!.phase).toEqual(['Running', 'Failing'])
  })

  it('caps each axis series at the history window', () => {
    let h: KeeperFleetHistory = {}
    for (let i = 0; i < FLEET_HISTORY_LEN + 7; i++) {
      h = pushObservation(h, [snapshot({ name: 'a' })], FLEET_HISTORY_LEN)
    }
    expect(h.a!.phase.length).toBe(FLEET_HISTORY_LEN)
  })

  it('drops keepers that disappear from the latest snapshot', () => {
    const t1 = pushObservation({}, [
      snapshot({ name: 'alpha' }),
      snapshot({ name: 'beta' }),
    ])
    expect(Object.keys(t1).sort()).toEqual(['alpha', 'beta'])
    const t2 = pushObservation(t1, [snapshot({ name: 'alpha' })])
    expect(Object.keys(t2)).toEqual(['alpha'])
  })

  it('returns a fresh top-level object for identity-based re-renders', () => {
    const prior = {}
    const next = pushObservation(prior, [snapshot({ name: 'alpha' })])
    expect(next).not.toBe(prior)
  })

  it('includes the KCB breaker axis in a fresh seed (default=clean)', () => {
    const next = pushObservation({}, [snapshot({ name: 'alpha' })])
    // The snapshot helper omits `circuit_breaker`, mirroring a pinned
    // backend that has not yet shipped LT-16-KCB Phase 2. The matrix
    // must still seed a value instead of leaving the axis undefined.
    expect(next.alpha!.breaker).toEqual(['clean'])
  })

  it('tracks KCB warning→cooling over successive polls', () => {
    const warn = snapshot({ name: 'beta', circuit_breaker: { state: 'warning' } })
    const cool = snapshot({ name: 'beta', circuit_breaker: { state: 'cooling' } })
    const t1 = pushObservation({}, [warn])
    const t2 = pushObservation(t1, [cool])
    expect(t2.beta!.breaker).toEqual(['warning', 'cooling'])
  })
})

describe('filterKeeperSnapshots', () => {
  const alpha = snapshot({ name: 'gen12-alpha' })
  const beta = snapshot({
    name: 'gen14-beta',
    phase: 'Overflowed',
    cascade: { state: 'trying' },
  })
  const gamma = snapshot({
    name: 'gen12-gamma',
    turn_phase: 'prompting',
  })
  const rows: readonly KeeperCompositeSnapshot[] = [alpha, beta, gamma]

  it('returns the input reference unchanged on an empty query', () => {
    expect(filterKeeperSnapshots(rows, '')).toBe(rows)
  })

  it('returns the input reference unchanged on a whitespace-only query', () => {
    expect(filterKeeperSnapshots(rows, '   ')).toBe(rows)
  })

  it('matches keeper name substring case-insensitively', () => {
    const out = filterKeeperSnapshots(rows, 'GEN12')
    expect(out.map(inferKeeperNameFrom)).toEqual(['gen12-alpha', 'gen12-gamma'])
  })

  it('matches phase (KSM) axis value', () => {
    const out = filterKeeperSnapshots(rows, 'overflowed')
    expect(out.map(inferKeeperNameFrom)).toEqual(['gen14-beta'])
  })

  it('matches cascade (KCL) axis value', () => {
    const out = filterKeeperSnapshots(rows, 'trying')
    expect(out.map(inferKeeperNameFrom)).toEqual(['gen14-beta'])
  })

  it('matches turn (KTC) axis value', () => {
    const out = filterKeeperSnapshots(rows, 'prompting')
    expect(out.map(inferKeeperNameFrom)).toEqual(['gen12-gamma'])
  })

  it('returns an empty array when nothing matches', () => {
    expect(filterKeeperSnapshots(rows, 'nothing-here')).toEqual([])
  })

  it('does not mutate the input array', () => {
    const input: KeeperCompositeSnapshot[] = [alpha, beta, gamma]
    const before = input.slice()
    filterKeeperSnapshots(input, 'gen12')
    expect(input).toEqual(before)
    expect(input.length).toBe(3)
  })

  it('trims the query before matching', () => {
    const out = filterKeeperSnapshots(rows, '  gen14-beta  ')
    expect(out.map(inferKeeperNameFrom)).toEqual(['gen14-beta'])
  })

  it('returns a new array (not input ref) when filtering actually runs', () => {
    const out = filterKeeperSnapshots(rows, 'gen12')
    expect(out).not.toBe(rows)
    expect(out.length).toBe(2)
  })
})

describe('FleetFsmMatrix streaming fallback', () => {
  it('uses an existing streamed snapshot without starting fallback polling', async () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-04-25T00:00:00Z'))
    fetchKeepersCompositeMock.mockResolvedValue(
      fleetSnapshot([snapshot({ name: 'fallback' })]),
    )
    fleetCompositeSnapshot.value = fleetSnapshot([snapshot({ name: 'streamed' })])

    render(html`<${FleetFsmMatrix} pollIntervalMs=${1000} />`)
    await act(async () => {})

    expect(screen.getByText('streamed')).toBeTruthy()
    expect(fetchKeepersCompositeMock).not.toHaveBeenCalled()

    await act(async () => {
      await vi.advanceTimersByTimeAsync(1000)
    })

    expect(fetchKeepersCompositeMock).not.toHaveBeenCalled()
  })

  it('falls back to fetching immediately when no streamed snapshot exists', async () => {
    fetchKeepersCompositeMock.mockResolvedValue(
      fleetSnapshot([snapshot({ name: 'fallback' })]),
    )

    render(html`<${FleetFsmMatrix} pollIntervalMs=${1000} />`)

    expect(await screen.findByText('fallback')).toBeTruthy()
    expect(fetchKeepersCompositeMock).toHaveBeenCalledTimes(1)
  })

  it('renders KSM runtime conflict directly in the lifecycle cell', async () => {
    fetchKeepersCompositeMock.mockResolvedValue(
      fleetSnapshot([
        snapshot({
          name: 'blocked',
          phase: 'Running',
          is_live: false,
          execution: execution({
            outcome: 'error',
            terminal_reason_code: 'api_error',
            operator_disposition: 'pause_human',
          }),
        }),
      ]),
    )

    render(html`<${FleetFsmMatrix} pollIntervalMs=${1000} />`)

    const cell = await screen.findByText('가동 중 · 정체')
    expect(cell.getAttribute('data-axis')).toBe('phase')
    expect(cell.getAttribute('data-runtime-phase-conflict')).toBe('true')
  })

  it('requests supervised AI diagnosis with the row cause and evidence', async () => {
    const onRequestRuntimeAssist = vi.fn()
    fetchKeepersCompositeMock.mockResolvedValue(
      fleetSnapshot([
        snapshot({
          name: 'blocked',
          phase: 'Running',
          is_live: false,
          execution: execution({
            outcome: 'error',
            terminal_reason_code: 'api_error',
            operator_disposition: 'pause_human',
            operator_disposition_reason: 'tool_required_unsatisfied',
          }),
        }),
      ]),
    )

    render(html`
      <${FleetFsmMatrix}
        pollIntervalMs=${1000}
        onRequestRuntimeAssist=${onRequestRuntimeAssist}
      />
    `)

    const button = await screen.findByRole('button', { name: '감독형 진단 요청' })
    await act(async () => {
      fireEvent.click(button)
    })

    expect(onRequestRuntimeAssist).toHaveBeenCalledTimes(1)
    expect(onRequestRuntimeAssist).toHaveBeenCalledWith(
      expect.objectContaining({
        keeperName: 'blocked',
        attention: expect.objectContaining({
          level: 'blocked',
          cause: expect.stringContaining('tool_required_unsatisfied'),
        }),
        message: expect.stringContaining('resolve 후보'),
      }),
    )
  })

  it('runs backend-recommended probe actions through the operator action path', async () => {
    dispatchOperatorActionMock.mockResolvedValue({
      status: 'ok',
      confirm_required: false,
    })
    fetchKeepersCompositeMock.mockResolvedValue(
      fleetSnapshot([
        snapshot({
          name: 'blocked',
          phase: 'Running',
          is_live: false,
          execution: execution({
            outcome: 'error',
            terminal_reason_code: 'api_error',
            operator_disposition: 'pause_human',
            operator_disposition_reason: 'tool_required_unsatisfied',
          }),
          recommended_actions: [
            {
              action_type: 'keeper_probe',
              target_type: 'keeper',
              target_id: 'blocked',
              severity: 'warn',
              reason: 'Inspect tool-contract blocker: tool_required_unsatisfied',
              confirm_required: false,
              suggested_payload: {
                source: 'fleet_fsm',
                keeper: 'blocked',
              },
            },
          ],
        }),
      ]),
    )

    render(html`<${FleetFsmMatrix} pollIntervalMs=${1000} />`)

    const button = await screen.findByRole('button', { name: 'Inspect tool-contract blocker: tool_required_unsatisfied' })
    await act(async () => {
      fireEvent.click(button)
    })

    await waitFor(() => {
      expect(dispatchOperatorActionMock).toHaveBeenCalledWith(
        expect.objectContaining({
          action_type: 'keeper_probe',
          target_type: 'keeper',
          target_id: 'blocked',
          payload: expect.objectContaining({
            source: 'fleet_fsm',
            keeper: 'blocked',
          }),
        }),
      )
    })
    expect(fetchKeepersCompositeMock).toHaveBeenCalledTimes(2)
  })

  it('surfaces recover as a supervised preview instead of auto-confirming it', async () => {
    dispatchOperatorActionMock.mockResolvedValue({
      status: 'ok',
      confirm_required: true,
      confirm_token: 'confirm-1',
    })
    fetchKeepersCompositeMock.mockResolvedValue(
      fleetSnapshot([
        snapshot({
          name: 'blocked',
          phase: 'Running',
          is_live: false,
          execution: execution({
            outcome: 'error',
            terminal_reason_code: 'api_error',
            operator_disposition: 'unknown',
          }),
          recommended_actions: [
            {
              action_type: 'keeper_recover',
              target_type: 'keeper',
              target_id: 'blocked',
              severity: 'bad',
              reason: 'Controlled keeper recovery for runtime stall: api_error',
              confirm_required: true,
              suggested_payload: {
                source: 'fleet_fsm',
                keeper: 'blocked',
              },
            },
          ],
        }),
      ]),
    )

    render(html`<${FleetFsmMatrix} pollIntervalMs=${1000} />`)

    const button = await screen.findByRole('button', { name: 'Controlled keeper recovery for runtime stall: api_error' })
    await act(async () => {
      fireEvent.click(button)
    })

    await waitFor(() => {
      expect(dispatchOperatorActionMock).toHaveBeenCalledTimes(1)
    })
    expect(showToastMock).toHaveBeenCalledWith(
      expect.stringContaining('승인 대기 중'),
      'success',
    )
  })
})
