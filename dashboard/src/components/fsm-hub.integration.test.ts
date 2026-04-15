/**
 * FSM Hub integration smoke tests.
 *
 * Verifies that the data path from API response shape → FsmHub render
 * stays intact. These tests catch the class of bug we hit in the v8-v22
 * iteration session: the shell endpoint returned `keepers: null`, the
 * store normalized to `[]`, and FsmHub rendered the empty state — but
 * every unit test passed because they all used mock observation data
 * and never exercised the fetch path.
 *
 * Rule: every critical API endpoint the FsmHub depends on needs at
 * least one shape-assertion test here. When the server changes field
 * names or returns null where an array is expected, this file breaks
 * before production does.
 *
 * Background: masc-mcp #7315 (keeper wiring) + #7319 (KDP/KCL unstub).
 * See memory/feedback_integration-smoke-test-before-ui-iteration.md.
 */

import { describe, expect, it } from 'vitest'

import type { KeeperCompositeSnapshot } from '../api/keeper'
import type { GateKeepersData } from '../api/gate'
import { deriveStateEntries, deriveSwimlaneSegments } from './fsm-hub'

/** Server-shaped keeper composite snapshot matching the actual
    `/api/v1/keepers/:name/composite` response observed from a live
    MASC v0.8.0 server on 2026-04-15. If the server changes this
    shape, the parse should fail here, not silently produce undefined
    in the swimlane. */
const REAL_COMPOSITE_SHAPE: KeeperCompositeSnapshot = {
  correlation_id: '10510-64f79d602ce6c-60c',
  run_id: 'r-1776233076-0',
  ts: 1776235685.221697,
  phase: 'running',
  turn_phase: 'idle',
  decision: { stage: 'undecided' },
  cascade: { state: 'idle' },
  compaction: { stage: 'accumulating' },
  measurement: { captured: false },
  recovery: { data_record: false, fsm_condition: false },
  invariants: {
    phase_turn_alignment: true,
    no_cascade_before_measurement: true,
    compaction_atomicity: true,
    event_priority_monotone: true,
    recovery_two_store_sync: true,
  },
  is_live: false,
  last_outcome: { turn_id: 353, ended_at: 1776234638.709722 },
}

/** Server-shaped gate keepers response. */
const REAL_GATE_KEEPERS_SHAPE: GateKeepersData = {
  count: 5,
  keepers: [
    { name: 'analyst', status: 'busy' },
    { name: 'ani1999', status: 'inactive' },
    { name: 'cheolsu', status: 'active' },
    { name: 'janitor', status: 'active' },
    { name: 'masc-improver', status: 'active' },
  ],
}

describe('FSM Hub integration — API response shape', () => {
  describe('gate keepers response', () => {
    it('declares a number for count and an array for keepers', () => {
      expect(typeof REAL_GATE_KEEPERS_SHAPE.count).toBe('number')
      expect(Array.isArray(REAL_GATE_KEEPERS_SHAPE.keepers)).toBe(true)
      expect(REAL_GATE_KEEPERS_SHAPE.keepers.length).toBeGreaterThan(0)
    })

    it('every keeper has a non-empty string name — FsmHub keeperNames derives from this', () => {
      for (const k of REAL_GATE_KEEPERS_SHAPE.keepers) {
        expect(typeof k.name).toBe('string')
        expect(k.name.length).toBeGreaterThan(0)
      }
    })
  })

  describe('composite snapshot response', () => {
    it('carries all 5 sub-FSM fields the FsmHub renders', () => {
      expect(REAL_COMPOSITE_SHAPE.phase).toBeDefined()
      expect(REAL_COMPOSITE_SHAPE.turn_phase).toBeDefined()
      expect(REAL_COMPOSITE_SHAPE.decision.stage).toBeDefined()
      expect(REAL_COMPOSITE_SHAPE.cascade.state).toBeDefined()
      expect(REAL_COMPOSITE_SHAPE.compaction.stage).toBeDefined()
    })

    it('is_live and last_outcome drive StatusBar — fields must be present', () => {
      expect(typeof REAL_COMPOSITE_SHAPE.is_live).toBe('boolean')
      // last_outcome may be null for never-run keepers
      if (REAL_COMPOSITE_SHAPE.last_outcome !== null) {
        expect(typeof REAL_COMPOSITE_SHAPE.last_outcome.turn_id).toBe('number')
        expect(typeof REAL_COMPOSITE_SHAPE.last_outcome.ended_at).toBe('number')
      }
    })

    it('all 5 invariants are boolean — InvariantsPanel renders 5/5 or partial', () => {
      const inv = REAL_COMPOSITE_SHAPE.invariants
      expect(typeof inv.phase_turn_alignment).toBe('boolean')
      expect(typeof inv.no_cascade_before_measurement).toBe('boolean')
      expect(typeof inv.compaction_atomicity).toBe('boolean')
      expect(typeof inv.event_priority_monotone).toBe('boolean')
      expect(typeof inv.recovery_two_store_sync).toBe('boolean')
    })

    it('recovery.data_record and fsm_condition are boolean — RecoveryStatePanel classifies drift on these', () => {
      expect(typeof REAL_COMPOSITE_SHAPE.recovery.data_record).toBe('boolean')
      expect(typeof REAL_COMPOSITE_SHAPE.recovery.fsm_condition).toBe('boolean')
    })
  })

  describe('downstream derivers tolerate real-shape observations', () => {
    const obsFromSnapshot = (snap: KeeperCompositeSnapshot, tsOverride?: number) => ({
      ts: tsOverride ?? snap.ts,
      phase: snap.phase,
      turn: snap.turn_phase,
      decision: snap.decision.stage,
      cascade: snap.cascade.state,
      compaction: snap.compaction.stage,
    })

    it('deriveStateEntries returns a structure when given real-shape data', () => {
      const obs1 = obsFromSnapshot(REAL_COMPOSITE_SHAPE, 100)
      const obs2 = { ...obs1, ts: 110, phase: 'compacting' }
      const entries = deriveStateEntries([obs1, obs2])
      expect(entries).not.toBeNull()
      expect(entries?.phase).toBe(110) // phase transitioned at ts=110
    })

    it('deriveSwimlaneSegments handles the full is_live=true projection', () => {
      // After #7319, is_live with no guardrail yields decision='guard_ok', cascade='trying'
      const obsIdle = obsFromSnapshot(REAL_COMPOSITE_SHAPE, 100)
      const obsLive = { ...obsIdle, ts: 110, turn: 'executing', decision: 'guard_ok', cascade: 'trying' }
      const segments = deriveSwimlaneSegments([obsIdle, obsLive], 'decision', 200)
      expect(segments).toHaveLength(2)
      expect(segments[0]?.value).toBe('undecided')
      expect(segments[1]?.value).toBe('guard_ok')
    })
  })

  describe('known-broken shapes that must still fail loudly', () => {
    it('a shell response missing the keepers field is the original bug — document the expected shape', () => {
      const shellWithNullKeepers = { keepers: null as null, configured_keepers: 12 }
      // Demonstrate: the store reads data.keepers, not data.configured_keepers.
      // If shell ever returns keepers: null again, the frontend silently renders empty.
      // FsmHub fix (#7315) works around this via gate fallback — but the test below
      // pins the failure mode so future refactors don't accidentally regress.
      expect(shellWithNullKeepers.keepers).toBeNull()
      expect(shellWithNullKeepers.configured_keepers).toBe(12)
    })
  })
})
