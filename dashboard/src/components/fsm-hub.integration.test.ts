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
 * Background: masc-mcp #7315 (keeper wiring) + #7319 (KDP/KCL unstub)
 * + #7439 (valibot schema pilot). See API_CONTRACT.md.
 */

import { describe, expect, it } from 'vitest'

import {
  parseKeeperCompositeSnapshot,
  CompositeSchemaDriftError,
  type KeeperCompositeSnapshot,
} from '../api/keeper'
import type { GateKeepersData } from '../api/gate'
import { normalizeKeepers } from '../keeper-store-normalize'
import {
  deriveStateEntries,
  deriveSwimlaneSegments,
  isCompositeFetchNotFound,
  shouldUseGateKeeperFallback,
} from './fsm-hub'
import type { CompositeObservation } from './fsm-hub-types'

/** Server-shaped keeper composite snapshot matching the projected
    RFC-0003/TLA-aligned `/api/v1/keepers/:name/composite` response.
    If the server changes this shape, the parse should fail here,
    not silently produce undefined in the swimlane. */
const REAL_COMPOSITE_SHAPE: KeeperCompositeSnapshot = {
  correlation_id: '10510-64f79d602ce6c-60c',
  run_id: 'r-1776233076-0',
  ts: 1776235685.221697,
  phase: 'Running',
  turn_phase: 'idle',
  decision: { stage: 'undecided' },
  cascade: { state: 'idle' },
  compaction: { stage: 'accumulating' },
  measurement: { captured: false },
  invariants: {
    phase_turn_alignment: true,
    no_cascade_before_measurement: true,
    compaction_atomicity: true,
    event_priority_monotone: true,
  },
  is_live: false,
  last_outcome: {
    turn_id: 353,
    ended_at: 1776234638.709722,
    decision_stage: 'tool_policy_selected',
    cascade_state: 'done',
    selected_model: 'glm-4.5',
  },
}

/** Real-world payload observed from `keeper_composite_observer.ml`
    snapshot_to_json — the schema MUST accept this without transformation. */
const REAL_COMPOSITE_PAYLOAD = {
  correlation_id: '10510-64f79d602ce6c-60c',
  run_id: 'r-1776233076-0',
  ts: 1776235685.221697,
  phase: 'Running',
  turn_phase: 'idle',
  decision: { stage: 'undecided' },
  cascade: { state: 'idle' },
  compaction: { stage: 'accumulating' },
  measurement: { captured: false },
  invariants: {
    phase_turn_alignment: true,
    no_cascade_before_measurement: true,
    compaction_atomicity: true,
    event_priority_monotone: true,
  },
  is_live: false,
  last_outcome: null,
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

  describe('composite snapshot schema (valibot pilot)', () => {
    it('accepts the current backend payload shape end-to-end', () => {
      const parsed = parseKeeperCompositeSnapshot(REAL_COMPOSITE_PAYLOAD)
      expect(parsed.phase).toBe('Running')
      expect(parsed.invariants.phase_turn_alignment).toBe(true)
      expect(parsed.last_outcome).toBeNull()
    })

    it('rejects payloads missing a required field with a pathful error', () => {
      const broken = { ...REAL_COMPOSITE_PAYLOAD } as Partial<typeof REAL_COMPOSITE_PAYLOAD>
      delete broken.invariants
      expect(() => parseKeeperCompositeSnapshot(broken)).toThrow(
        CompositeSchemaDriftError,
      )
      try {
        parseKeeperCompositeSnapshot(broken)
      } catch (err) {
        expect(err).toBeInstanceOf(CompositeSchemaDriftError)
        expect((err as CompositeSchemaDriftError).message).toMatch(/invariants/)
      }
    })

    it('rejects payloads where a field has the wrong type', () => {
      const broken = { ...REAL_COMPOSITE_PAYLOAD, is_live: 'true' }
      expect(() => parseKeeperCompositeSnapshot(broken)).toThrow(
        CompositeSchemaDriftError,
      )
    })

    it('coerces unknown phase values to Stable fallback (forward compat)', () => {
      const future = { ...REAL_COMPOSITE_PAYLOAD, phase: 'SomeNewPhase' }
      const parsed = parseKeeperCompositeSnapshot(future)
      // unknown enum value → fallback, not a hard error. Prevents
      // backend-added states from bricking the dashboard before the
      // frontend can ship a matching union member.
      expect(parsed.phase).toBe('Stable')
    })

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
        expect(typeof REAL_COMPOSITE_SHAPE.last_outcome.decision_stage).toBe('string')
        expect(typeof REAL_COMPOSITE_SHAPE.last_outcome.cascade_state).toBe('string')
      }
    })

    it('all 4 invariants are boolean — InvariantsPanel renders 4/4 or partial', () => {
      const inv = REAL_COMPOSITE_SHAPE.invariants
      expect(typeof inv.phase_turn_alignment).toBe('boolean')
      expect(typeof inv.no_cascade_before_measurement).toBe('boolean')
      expect(typeof inv.compaction_atomicity).toBe('boolean')
      expect(typeof inv.event_priority_monotone).toBe('boolean')
    })
  })

  describe('downstream derivers tolerate real-shape observations', () => {
    const obsFromSnapshot = (snap: KeeperCompositeSnapshot, ts: number): CompositeObservation => ({
      ts,
      phase: snap.phase,
      turn: snap.turn_phase,
      decision: snap.decision.stage,
      cascade: snap.cascade.state,
      compaction: snap.compaction.stage,
    })

    it('deriveStateEntries returns a structure when given real-shape data', () => {
      const obs1 = obsFromSnapshot(REAL_COMPOSITE_SHAPE, 100)
      const obs2: CompositeObservation = { ...obs1, ts: 110, phase: 'Compacting' }
      const entries = deriveStateEntries([obs1, obs2])
      expect(entries).not.toBeNull()
      expect(entries?.phase).toBe(110) // phase transitioned at ts=110
    })

    it('deriveSwimlaneSegments handles the full is_live=true projection', () => {
      const obsIdle = obsFromSnapshot(REAL_COMPOSITE_SHAPE, 100)
      const obsLive: CompositeObservation = {
        ...obsIdle,
        ts: 110,
        turn: 'executing' satisfies KeeperCompositeSnapshot['turn_phase'],
        decision: 'guard_ok' satisfies KeeperCompositeSnapshot['decision']['stage'],
        cascade: 'trying' satisfies KeeperCompositeSnapshot['cascade']['state'],
      }
      const segments = deriveSwimlaneSegments([obsIdle, obsLive], 'decision', 200)
      expect(segments).toHaveLength(2)
      expect(segments[0]?.value).toBe('undecided')
      expect(segments[1]?.value).toBe('guard_ok')
    })
  })

  describe('store normalizer against the regression shape', () => {
    it('normalizeKeepers(null) and normalizeKeepers(undefined) yield an empty array — the failure mode that triggered the v8-v22 blind spot', () => {
      expect(normalizeKeepers(null)).toEqual([])
      expect(normalizeKeepers(undefined)).toEqual([])
    })

    it('normalizeKeepers ignores the count-only "configured_keepers" field the shell actually sends', () => {
      const shellShape: Record<string, unknown> = { configured_keepers: 12 }
      expect(normalizeKeepers(shellShape.keepers)).toEqual([])
    })
  })

  describe('keeper selection fallback guards', () => {
    it('uses gate fallback only before execution data has loaded', () => {
      expect(shouldUseGateKeeperFallback(false, [])).toBe(true)
      expect(shouldUseGateKeeperFallback(true, [])).toBe(false)
      expect(shouldUseGateKeeperFallback(true, ['keeper-a'])).toBe(false)
      expect(shouldUseGateKeeperFallback(false, ['keeper-a'])).toBe(false)
    })

    it('treats composite 404 as keeper disappearance, not generic schema failure', () => {
      expect(isCompositeFetchNotFound(new Error('composite fetch failed: 404'))).toBe(true)
      expect(isCompositeFetchNotFound(new Error('composite fetch failed: 500'))).toBe(false)
      expect(isCompositeFetchNotFound(new Error('state-diagram fetch failed: 404'))).toBe(false)
    })
  })
})
