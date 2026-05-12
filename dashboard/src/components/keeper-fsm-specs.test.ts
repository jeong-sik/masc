import { describe, it, expect } from 'vitest'
import {
  buildCompositeFsmSpec,
  buildCompactionSpec,
  buildTurnFsmSpec,
  normalizeTurnFsmState,
  turnFsmTlaSymbol,
  TURN_FSM_STATES,
} from './keeper-fsm-specs'

// State alphabets the dashboard renders. These must stay in lockstep with
// the OCaml runtime: KSM ← keeper_state_machine.ml `type phase` (13 ctors),
// KTC ← keeper_registry.ml `type turn_phase` (7 ctors), KDP/KCL/KMC ← the
// matching keeper_registry.ml sub-FSM types. If you change one of these
// arrays you almost certainly need a matching change on the OCaml side and
// in dashboard/src/api/schemas/keeper-composite.ts.
const KSM_STATES = [
  'offline', 'running', 'failing', 'overflowed', 'compacting',
  'handing_off', 'draining', 'paused', 'stopped', 'crashed',
  'restarting', 'dead', 'zombie',
]
const KTC_STATES = ['idle', 'prompting', 'routing', 'executing', 'compacting', 'finalizing', 'exhausted']
const KDP_STATES = ['undecided', 'guard_ok', 'gate_rejected', 'tool_policy_selected']
const KCL_STATES = ['idle', 'selecting', 'trying', 'done', 'exhausted']
const KMC_STATES = ['accumulating', 'compacting', 'done']

describe('buildCompositeFsmSpec', () => {
  const defaultParams = {
    phase: 'running',
    turnPhase: 'idle',
    decisionStage: 'undecided',
    cascadeState: 'idle',
    compactionStage: 'accumulating',
  }

  it('creates parent nodes for all 5 sub-FSM clusters', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const parentIds = spec.nodes.filter(n => !n.parent).map(n => n.id)
    expect(parentIds).toEqual(['KSM', 'KTC', 'KDP', 'KCL', 'KMC'])
  })

  it('creates the KSM cluster with all 13 keeper-phase states', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const ids = spec.nodes.filter(n => n.parent === 'KSM').map(n => n.id.split(':')[1])
    expect(ids).toEqual(KSM_STATES)
  })

  it('creates the KTC cluster with all 7 turn-phase states', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const ids = spec.nodes.filter(n => n.parent === 'KTC').map(n => n.id.split(':')[1])
    expect(ids).toEqual(KTC_STATES)
  })

  it('creates the KDP cluster with all 4 decision-stage states', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const ids = spec.nodes.filter(n => n.parent === 'KDP').map(n => n.id.split(':')[1])
    expect(ids).toEqual(KDP_STATES)
  })

  it('creates the KCL cluster with all 5 cascade states', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const ids = spec.nodes.filter(n => n.parent === 'KCL').map(n => n.id.split(':')[1])
    expect(ids).toEqual(KCL_STATES)
  })

  it('creates the KMC cluster with all 3 compaction stages', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const ids = spec.nodes.filter(n => n.parent === 'KMC').map(n => n.id.split(':')[1])
    expect(ids).toEqual(KMC_STATES)
  })

  it('total node count = 5 parents + 32 children = 37', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const childCount = KSM_STATES.length + KTC_STATES.length + KDP_STATES.length
      + KCL_STATES.length + KMC_STATES.length
    expect(childCount).toBe(32)
    expect(spec.nodes).toHaveLength(5 + childCount)
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
    for (const phase of ['failing', 'stopped', 'crashed', 'dead', 'zombie']) {
      const spec = buildCompositeFsmSpec({ ...defaultParams, phase })
      expect(spec.nodes.find(n => n.id === `KSM:${phase}`)!.type).toBe('err')
    }
  })

  it('marks the active KSM child as warn for buffer-class phases', () => {
    for (const phase of ['overflowed', 'compacting', 'handing_off', 'draining', 'paused', 'restarting']) {
      const spec = buildCompositeFsmSpec({ ...defaultParams, phase })
      expect(spec.nodes.find(n => n.id === `KSM:${phase}`)!.type).toBe('warn')
    }
  })

  it('marks inactive KSM children as dim', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    expect(spec.nodes.find(n => n.id === 'KSM:dead')!.type).toBe('dim')
  })

  it('marks a gate_rejected decision as err', () => {
    const spec = buildCompositeFsmSpec({ ...defaultParams, decisionStage: 'gate_rejected' })
    expect(spec.nodes.find(n => n.id === 'KDP:gate_rejected')!.type).toBe('err')
  })

  it('marks an exhausted cascade as err', () => {
    const spec = buildCompositeFsmSpec({ ...defaultParams, cascadeState: 'exhausted' })
    expect(spec.nodes.find(n => n.id === 'KCL:exhausted')!.type).toBe('err')
  })

  it('marks the active KMC child with a warn tone', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    expect(spec.nodes.find(n => n.id === 'KMC:accumulating')!.type).toBe('warn')
  })

  it('marks inactive KMC children as dim', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    expect(spec.nodes.find(n => n.id === 'KMC:compacting')!.type).toBe('dim')
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

// ================================================================
// buildCompactionSpec
// ================================================================

describe('buildCompactionSpec', () => {
  it('returns 3 nodes for the KMC states', () => {
    const spec = buildCompactionSpec('accumulating')
    expect(spec.nodes.map(n => n.id)).toEqual(['accumulating', 'compacting', 'done'])
  })

  it('returns 3 edges', () => {
    const spec = buildCompactionSpec('accumulating')
    expect(spec.edges).toHaveLength(3)
  })

  it('sets activeNodeId to the active stage', () => {
    expect(buildCompactionSpec('compacting').activeNodeId).toBe('compacting')
  })

  it('uses breadthfirst layout and LR direction', () => {
    const spec = buildCompactionSpec('accumulating')
    expect(spec.layout).toBe('breadthfirst')
    expect(spec.direction).toBe('LR')
  })

  it('marks the compacting active stage as warn', () => {
    const spec = buildCompactionSpec('compacting')
    expect(spec.nodes.find(n => n.id === 'compacting')!.type).toBe('warn')
  })

  it('marks the accumulating active stage as active when the phase is benign', () => {
    expect(buildCompactionSpec('accumulating').nodes.find(n => n.id === 'accumulating')!.type).toBe('active')
  })

  it('marks the done active stage as active', () => {
    expect(buildCompactionSpec('done').nodes.find(n => n.id === 'done')!.type).toBe('active')
  })

  it('marks the active stage as err when currentPhase is overflowed', () => {
    const spec = buildCompactionSpec('accumulating', 'overflowed')
    expect(spec.nodes.find(n => n.id === 'accumulating')!.type).toBe('err')
  })

  it('marks the active stage as err when currentPhase is failing', () => {
    const spec = buildCompactionSpec('accumulating', 'failing')
    expect(spec.nodes.find(n => n.id === 'accumulating')!.type).toBe('err')
  })

  it('lets the compacting stage take precedence as warn even with a failing phase', () => {
    const spec = buildCompactionSpec('compacting', 'failing')
    expect(spec.nodes.find(n => n.id === 'compacting')!.type).toBe('warn')
  })

  it('marks inactive states as dim', () => {
    const spec = buildCompactionSpec('accumulating')
    expect(spec.nodes.find(n => n.id === 'compacting')!.type).toBe('dim')
  })

  it('treats a null currentPhase as benign', () => {
    expect(buildCompactionSpec('accumulating', null).nodes.find(n => n.id === 'accumulating')!.type).toBe('active')
  })

  it('treats an undefined currentPhase as benign', () => {
    expect(buildCompactionSpec('accumulating').nodes.find(n => n.id === 'accumulating')!.type).toBe('active')
  })

  it('has a ratio_gate edge from accumulating to compacting', () => {
    const spec = buildCompactionSpec('accumulating')
    const edge = spec.edges.find(e => e.source === 'accumulating' && e.target === 'compacting')
    expect(edge?.label).toBe('ratio_gate')
  })

  it('has a recovery edge from compacting to done', () => {
    const spec = buildCompactionSpec('accumulating')
    const edge = spec.edges.find(e => e.source === 'compacting' && e.target === 'done')
    expect(edge?.type).toBe('recovery')
  })

  it('has an error edge from compacting back to accumulating', () => {
    const spec = buildCompactionSpec('accumulating')
    const edge = spec.edges.find(e => e.source === 'compacting' && e.target === 'accumulating')
    expect(edge?.type).toBe('error')
  })
})

// ================================================================
// buildTurnFsmSpec / normalizeTurnFsmState / turnFsmTlaSymbol
// ================================================================

describe('buildTurnFsmSpec', () => {
  it('exposes the 8 UI turn-FSM states (7 backend turn_phase ctors + awaiting_tool_result)', () => {
    expect(TURN_FSM_STATES).toEqual([
      'idle', 'prompting', 'routing', 'executing',
      'awaiting_tool_result', 'compacting', 'finalizing', 'exhausted',
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
    for (const s of ['idle', 'prompting', 'routing', 'executing', 'compacting', 'finalizing', 'exhausted']) {
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
})
