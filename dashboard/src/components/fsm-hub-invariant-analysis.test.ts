import { describe, it, expect } from 'vitest'
import { deriveOperationalInsight, invariantRows } from './fsm-hub-invariant-analysis'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'
import type { CompositeObservation, ObservedLaneSummary } from './fsm-hub-types'

function makeSnapshot(overrides: Partial<KeeperCompositeSnapshot> = {}): KeeperCompositeSnapshot {
  return {
    correlation_id: 'corr-1',
    run_id: 'run-1',
    ts: 1000000,
    phase: 'running',
    turn_phase: 'idle',
    decision: { stage: 'undecided' },
    runtime: { state: 'idle' },
    measurement: { captured: false },
    invariants: {
      no_runtime_before_measurement: true,
      event_priority_monotone: true,
      phase_derivation_agreement: true,
    },
    fsm_guard_violations: 0,
    fsm_guard_violation_breakdown: [],
    is_live: true,
    last_outcome: null,
    recommended_actions: [],
    ...overrides,
  }
}

// ================================================================
// invariantRows
// ================================================================

describe('invariantRows', () => {
  it('returns one row per current invariant', () => {
    const rows = invariantRows(makeSnapshot())
    expect(rows).toHaveLength(3)
  })

  it('marks all invariants as ok when all true', () => {
    const rows = invariantRows(makeSnapshot())
    expect(rows.every(r => r.ok)).toBe(true)
  })

  it('marks broken invariant as not ok', () => {
    const rows = invariantRows(makeSnapshot({
      invariants: {
        no_runtime_before_measurement: false,
        event_priority_monotone: true,
        phase_derivation_agreement: true,
      },
    }))
    expect(rows.filter(r => r.ok).length).toBe(2)
  })

  it('includes labels for each invariant', () => {
    const rows = invariantRows(makeSnapshot())
    const labels = rows.map(r => r.label)
    expect(labels).toContain('Runtime 순서')
    expect(labels).toContain('이벤트 우선순위')
    expect(labels).toContain('Phase 유도 일치')
  })

  it('includes detail string for each row', () => {
    const rows = invariantRows(makeSnapshot())
    rows.forEach(row => {
      expect(typeof row.detail).toBe('string')
      expect(row.detail.length).toBeGreaterThan(0)
    })
  })

})

// ================================================================
// deriveOperationalInsight
// ================================================================

describe('deriveOperationalInsight', () => {
  const now = 1000000
  const noObservations: CompositeObservation[] = []

  it('reports error tone when invariant is broken', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({
        invariants: {
          no_runtime_before_measurement: false,
          event_priority_monotone: true,
          phase_derivation_agreement: true,
        },
      }),
      noObservations,
      now,
    )
    expect(insight.tone).toBe('error')
    expect(insight.headline).toContain('Spec drift')
  })

  it('reports error when Failing and runtime exhausted', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({
        phase: 'failing',
        runtime: { state: 'exhausted' },
      }),
      noObservations,
      now,
    )
    expect(insight.tone).toBe('error')
    expect(insight.headline).toContain('runtime exhaustion')
  })

  it('reports warn when a lane is stalled', () => {
    const stalledLanes: ObservedLaneSummary[] = [{
      field: 'phase',
      label: 'Phase',
      value: 'Running',
      tone: 'warn',
      meaning: 'stalled',
      stalled: true,
      observedForSec: 300,
      transitionCount: 0,
    }]
    const insight = deriveOperationalInsight(
      makeSnapshot(),
      noObservations,
      now,
      stalledLanes,
    )
    expect(insight.tone).toBe('warn')
    expect(insight.headline).toContain('not moving')
  })

  it('reports warn for Draining phase', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({
        phase: 'draining',
      }),
      noObservations,
      now,
    )
    expect(insight.tone).toBe('warn')
  })

  // Backend wire format (keeper_state_machine.ml:21-35) emits the 13 raw KSM
  // phases lowercase. A 7-phase composite projection with a 'Stable' carrier
  // is specced (KeeperCompositeLifecycle.tla:143) but not currently emitted,
  // so the dashboard surfaces `collapsed_from` directly whenever the backend
  // sets it — see deriveOperationalInsight + nextExpectedStep.

  it('reports raw collapsed_from source in detail, evidence, and nextStep', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({
        phase: 'draining',
        collapsed_from: 'paused',
      }),
      noObservations,
      now,
    )
    expect(insight.tone).toBe('warn')
    expect(insight.detail).toContain('raw keeper phase is paused')
    expect(insight.evidence).toContain('raw paused')
    expect(insight.nextStep).toContain('paused')
  })

  it('reports ok when not live with last_outcome', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({
        is_live: false,
        last_outcome: {
          turn_id: 1,
          ended_at: now - 60,
          decision_stage: 'undecided',
          runtime_state: 'done',
          selected_model: null,
        },
      }),
      noObservations,
      now,
    )
    expect(insight.tone).toBe('ok')
    expect(insight.headline).toContain('대기')
  })

  it('reports ok when not live without last_outcome', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({ is_live: false }),
      noObservations,
      now,
    )
    expect(insight.tone).toBe('ok')
    expect(insight.detail).toContain('아직 완료된 turn')
  })

  it('reports info when runtime is selecting', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({
        runtime: { state: 'selecting' },
      }),
      noObservations,
      now,
    )
    expect(insight.tone).toBe('info')
    expect(insight.headline).toContain('Provider')
  })

  it('reports info when runtime is trying', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({
        runtime: { state: 'trying' },
      }),
      noObservations,
      now,
    )
    expect(insight.tone).toBe('info')
    expect(insight.headline).toContain('Provider')
  })

  it('reports info for normal live turn (happy path)', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({
        is_live: true,
        turn_phase: 'executing',
        runtime: { state: 'done' },
      }),
      noObservations,
      now,
    )
    expect(insight.tone).toBe('info')
    expect(insight.headline).toContain('progressing normally')
  })

  it('includes evidence array with KSM/KTC/KDP', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({ turn_phase: 'executing' }),
      noObservations,
      now,
    )
    expect(insight.evidence.length).toBeGreaterThanOrEqual(2)
    expect(insight.evidence.some(e => e.includes('KSM'))).toBe(true)
  })

  it('includes nextStep string', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot(),
      noObservations,
      now,
    )
    expect(typeof insight.nextStep).toBe('string')
    expect(insight.nextStep.length).toBeGreaterThan(0)
  })

  it('uses precomputedLanes when provided', () => {
    const stalledLanes: ObservedLaneSummary[] = [{
      field: 'turn_phase',
      label: 'Turn',
      value: 'executing',
      tone: 'warn',
      meaning: 'stalled',
      stalled: true,
      observedForSec: 600,
      transitionCount: 0,
    }]
    const insight = deriveOperationalInsight(
      makeSnapshot(),
      noObservations,
      now,
      stalledLanes,
    )
    // Stalled lane takes priority over normal path
    expect(insight.tone).toBe('warn')
    expect(insight.headline).toContain('not moving')
  })

  // ── nextExpectedStep coverage ──

  it('gives correct nextStep for not-live without outcome', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({ is_live: false }),
      noObservations,
      now,
    )
    expect(insight.nextStep).toContain('첫 live turn')
  })

  it('gives correct nextStep for Failing+exhausted', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({ phase: 'failing', runtime: { state: 'exhausted' } }),
      noObservations,
      now,
    )
    expect(insight.nextStep).toContain('recovery')
  })

  it('gives correct nextStep for Stable with last_outcome', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({
        phase: 'Stable',
        is_live: false,
        last_outcome: {
          turn_id: 1,
          ended_at: now - 60,
          decision_stage: 'undecided',
          runtime_state: 'done',
          selected_model: null,
        },
      }),
      noObservations,
      now,
    )
    // !is_live with last_outcome → nextExpectedStep runs
    // phase=Stable, no special case → default return
    expect(insight.nextStep.length).toBeGreaterThan(0)
  })

  it('gives correct nextStep for prompting turn', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({ turn_phase: 'prompting' }),
      noObservations,
      now,
    )
    expect(insight.nextStep).toContain('prompt')
  })

  it('gives correct nextStep for finalizing turn', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({ turn_phase: 'finalizing' }),
      noObservations,
      now,
    )
    expect(insight.nextStep).toContain('idle')
  })

  it('gives correct nextStep for routing turn', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({ turn_phase: 'routing' }),
      noObservations,
      now,
    )
    expect(insight.nextStep).toContain('runtime routing')
  })

  it('gives correct nextStep for exhausted turn', () => {
    const insight = deriveOperationalInsight(
      makeSnapshot({ turn_phase: 'exhausted' }),
      noObservations,
      now,
    )
    expect(insight.nextStep).toContain('소진')
  })
})
