import { describe, it, expect } from 'vitest'
import {
  buildCompositeFsmSpec,
  buildTurnFsmSpec,
  normalizeTurnFsmState,
  turnFsmTlaSymbol,
  TURN_FSM_STATES,
} from './keeper-fsm-specs'

// State alphabets the dashboard renders. These must stay in lockstep with
// the OCaml runtime: KSM ← keeper_state_machine.ml `type phase` (8 ctors),
// KTC ← keeper_registry.ml `type turn_phase` (6 ctors), KDP/KCL ← the
// matching keeper_registry.ml sub-FSM types. If you change one of these
// arrays you almost certainly need a matching change on the OCaml side and
// in dashboard/src/api/schemas/keeper-composite.ts.
const KSM_STATES = [
  'offline', 'running', 'failing',
  'draining', 'paused', 'stopped', 'crashed',
  'restarting',
]
const KTC_STATES = ['idle', 'prompting', 'routing', 'executing', 'finalizing', 'exhausted']
const KDP_STATES = ['undecided', 'guard_ok', 'tool_policy_selected']
const KCL_STATES = ['idle', 'selecting', 'trying', 'done', 'exhausted']

describe('buildCompositeFsmSpec', () => {
  const defaultParams = {
    phase: 'running',
    turnPhase: 'idle',
    decisionStage: 'undecided',
    runtimeState: 'idle',
  }

  it('creates parent nodes for all 4 sub-FSM clusters', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const parentIds = spec.nodes.filter(n => !n.parent).map(n => n.id)
    expect(parentIds).toEqual(['KSM', 'KTC', 'KDP', 'KCL'])
  })

  it('creates the KSM cluster with all 8 keeper-phase states', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const ids = spec.nodes.filter(n => n.parent === 'KSM').map(n => n.id.split(':')[1])
    expect(ids).toEqual(KSM_STATES)
  })

  it('creates the KTC cluster with all 6 turn-phase states', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const ids = spec.nodes.filter(n => n.parent === 'KTC').map(n => n.id.split(':')[1])
    expect(ids).toEqual(KTC_STATES)
  })

  it('creates the KDP cluster with all 4 decision-stage states', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const ids = spec.nodes.filter(n => n.parent === 'KDP').map(n => n.id.split(':')[1])
    expect(ids).toEqual(KDP_STATES)
  })

  it('creates the KCL cluster with all 5 runtime states', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const ids = spec.nodes.filter(n => n.parent === 'KCL').map(n => n.id.split(':')[1])
    expect(ids).toEqual(KCL_STATES)
  })

  it('total node count = 4 parents + 22 children = 26', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const childCount = KSM_STATES.length + KTC_STATES.length + KDP_STATES.length
      + KCL_STATES.length
    expect(childCount).toBe(22)
    expect(spec.nodes).toHaveLength(4 + childCount)
  })

  it('returns empty edges by design (cross-cluster causality lives in the TLA+ spec)', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    expect(spec.edges).toEqual([])
  })

  it('uses breadthfirst layout and LR direction', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    expect(spec.layout).toBe('breadthfirst')
    expect(spec.direction).toBe('LR')
  })

  it('marks the active KSM child as active when the phase is running', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    expect(spec.nodes.find(n => n.id === 'KSM:running')!.type).toBe('active')
  })

  it('marks the active KSM child as err for failure-class phases', () => {
    for (const phase of ['failing', 'stopped', 'crashed']) {
      const spec = buildCompositeFsmSpec({ ...defaultParams, phase })
      expect(spec.nodes.find(n => n.id === `KSM:${phase}`)!.type).toBe('err')
    }
  })

  it('marks the active KSM child as warn for buffer-class phases', () => {
    for (const phase of ['draining', 'paused', 'restarting']) {
      const spec = buildCompositeFsmSpec({ ...defaultParams, phase })
      expect(spec.nodes.find(n => n.id === `KSM:${phase}`)!.type).toBe('warn')
    }
  })

  it('marks inactive KSM children as dim', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    expect(spec.nodes.find(n => n.id === 'KSM:stopped')!.type).toBe('dim')
  })

  it('marks an exhausted runtime as err', () => {
    const spec = buildCompositeFsmSpec({ ...defaultParams, runtimeState: 'exhausted' })
    expect(spec.nodes.find(n => n.id === 'KCL:exhausted')!.type).toBe('err')
  })

  it('does not set activeNodeId (compound graph, no single active node)', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    expect(spec.activeNodeId).toBeUndefined()
  })

  it('uses the cluster:state node id format', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    for (const child of spec.nodes.filter(n => n.parent === 'KSM')) {
      expect(child.id).toMatch(/^KSM:/)
    }
  })
})

describe('buildTurnFsmSpec', () => {
  it('exposes the 7 UI turn-FSM states (6 backend turn_phase ctors + awaiting_tool_result)', () => {
    expect(TURN_FSM_STATES).toEqual([
      'idle', 'prompting', 'routing', 'executing',
      'awaiting_tool_result', 'finalizing', 'exhausted',
    ])
  })

  it('creates one node per turn-FSM state', () => {
    const spec = buildTurnFsmSpec('executing')
    expect(spec.nodes.map(n => n.id)).toEqual([...TURN_FSM_STATES])
  })

  it('marks the active state active and sets activeNodeId', () => {
    const spec = buildTurnFsmSpec('executing')
    expect(spec.nodes.find(n => n.id === 'executing')!.type).toBe('active')
    expect(spec.activeNodeId).toBe('executing')
  })

  it('marks the exhausted terminal state as err whether active or not', () => {
    expect(buildTurnFsmSpec('idle').nodes.find(n => n.id === 'exhausted')!.type).toBe('err')
    expect(buildTurnFsmSpec('exhausted').nodes.find(n => n.id === 'exhausted')!.type).toBe('err')
  })

  it('normalizes the canonical backend turn phases to themselves', () => {
    for (const s of ['idle', 'prompting', 'routing', 'executing', 'finalizing', 'exhausted']) {
      expect(normalizeTurnFsmState(s)).toBe(s)
    }
  })

  it('is case-insensitive and trims whitespace', () => {
    expect(normalizeTurnFsmState('  Executing ')).toBe('executing')
  })

  it('maps the TLA awaiting_tool symbol to the UI awaiting_tool_result state and back', () => {
    expect(normalizeTurnFsmState('awaiting_tool')).toBe('awaiting_tool_result')
    expect(turnFsmTlaSymbol('awaiting_tool_result')).toBe('awaiting_tool')
  })

  it('round-trips every UI state through turnFsmTlaSymbol (only awaiting_tool_result is renamed)', () => {
    for (const s of TURN_FSM_STATES) {
      const expected = s === 'awaiting_tool_result' ? 'awaiting_tool' : s
      expect(turnFsmTlaSymbol(s)).toBe(expected)
    }
  })

  it('returns null (no active node) for unknown / legacy turn phases', () => {
    expect(normalizeTurnFsmState('mystery')).toBeNull()
    expect(normalizeTurnFsmState('streaming')).toBeNull()
    expect(normalizeTurnFsmState('phase_gating')).toBeNull()
    expect(normalizeTurnFsmState('')).toBeNull()
    expect(normalizeTurnFsmState(null)).toBeNull()
    expect(normalizeTurnFsmState(undefined)).toBeNull()
    expect(buildTurnFsmSpec('mystery').activeNodeId).toBeNull()
  })

  it('includes the StartTurn entry edge', () => {
    const spec = buildTurnFsmSpec('executing')
    expect(spec.edges).toEqual(expect.arrayContaining([
      expect.objectContaining({ source: 'idle', target: 'prompting', label: 'StartTurn' }),
    ]))
  })

  // Drift guard: mirrors `lib/keeper/keeper_registry_types.ml:259-291`
  // `module Turn_phase_transition`. Each GADT constructor is a valid
  // turn_phase transition the OCaml runtime can take, and the FSM
  // visualization must list every one of them. If the OCaml GADT gains
  // or loses a constructor, this test fails until both sides are aligned.
  it('exposes every (from, to) pair from the OCaml Turn_phase_transition GADT', () => {
    const spec = buildTurnFsmSpec('executing')
    const expected = new Set([
      'idle->prompting',
      'prompting->routing', 'prompting->executing', 'prompting->finalizing', 'prompting->exhausted',
      'routing->prompting', 'routing->executing', 'routing->exhausted',
      'executing->prompting', 'executing->routing', 'executing->finalizing', 'executing->exhausted',
      'finalizing->prompting', 'finalizing->routing', 'finalizing->executing', 'finalizing->exhausted',
      'exhausted->prompting', 'exhausted->routing', 'exhausted->executing',
    ])
    const seen = new Set(spec.edges.map(e => `${e.source}->${e.target}`))
    expect(seen).toEqual(expected)
  })
})
