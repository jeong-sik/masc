import { describe, it, expect } from 'vitest'
import {
  buildCompositeFsmSpec,
  buildCompactionSpec,
  buildTurnFsmSpec,
  normalizeTurnFsmState,
  turnFsmTlaSymbol,
  TURN_FSM_STATES,
} from './keeper-fsm-specs'

describe('buildCompositeFsmSpec', () => {
  const defaultParams = {
    phase: 'Running',
    turnPhase: 'idle',
    decisionStage: 'undecided',
    cascadeState: 'idle',
    compactionStage: 'accumulating',
  }

  it('creates nodes for all 5 clusters with parents', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const parents = spec.nodes.filter(n => !n.parent)
    const parentIds = parents.map(n => n.id)
    expect(parentIds).toEqual(['KSM', 'KTC', 'KDP', 'KCL', 'KMC'])
  })

  it('creates KSM cluster with 7 child states', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const ksmChildren = spec.nodes.filter(n => n.parent === 'KSM')
    expect(ksmChildren).toHaveLength(7)
    const ids = ksmChildren.map(n => n.id.split(':')[1])
    expect(ids).toContain('Running')
    expect(ids).toContain('Stable')
  })

  it('creates KTC cluster with 5 child states', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const ktcChildren = spec.nodes.filter(n => n.parent === 'KTC')
    expect(ktcChildren).toHaveLength(5)
  })

  it('creates KDP cluster with 4 child states', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const kdpChildren = spec.nodes.filter(n => n.parent === 'KDP')
    expect(kdpChildren).toHaveLength(4)
  })

  it('creates KCL cluster with 5 child states', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const kclChildren = spec.nodes.filter(n => n.parent === 'KCL')
    expect(kclChildren).toHaveLength(5)
  })

  it('creates KMC cluster with 3 child states', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const kmcChildren = spec.nodes.filter(n => n.parent === 'KMC')
    expect(kmcChildren).toHaveLength(3)
  })

  it('total node count = 5 parents + 24 children = 29', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    expect(spec.nodes).toHaveLength(29)
  })

  it('returns empty edges by design', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    expect(spec.edges).toEqual([])
  })

  it('uses breadthfirst layout', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    expect(spec.layout).toBe('breadthfirst')
  })

  it('uses LR direction', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    expect(spec.direction).toBe('LR')
  })

  it('marks active phase child as active type when Running', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const runningChild = spec.nodes.find(n => n.id === 'KSM:Running')
    expect(runningChild!.type).toBe('active')
  })

  it('marks active phase child as err type when Failing', () => {
    const spec = buildCompositeFsmSpec({ ...defaultParams, phase: 'Failing' })
    const failingChild = spec.nodes.find(n => n.id === 'KSM:Failing')
    expect(failingChild!.type).toBe('err')
  })

  it('marks buffer phases as warn type', () => {
    const spec = buildCompositeFsmSpec({ ...defaultParams, phase: 'Compacting' })
    const compactingChild = spec.nodes.find(n => n.id === 'KSM:Compacting')
    expect(compactingChild!.type).toBe('warn')
  })

  it('marks inactive children as dim', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const stableChild = spec.nodes.find(n => n.id === 'KSM:Stable')
    expect(stableChild!.type).toBe('dim')
  })

  it('marks gate_rejected decision as err type', () => {
    const spec = buildCompositeFsmSpec({ ...defaultParams, decisionStage: 'gate_rejected' })
    const rejected = spec.nodes.find(n => n.id === 'KDP:gate_rejected')
    expect(rejected!.type).toBe('err')
  })

  it('marks exhausted cascade as err type', () => {
    const spec = buildCompositeFsmSpec({ ...defaultParams, cascadeState: 'exhausted' })
    const exhausted = spec.nodes.find(n => n.id === 'KCL:exhausted')
    expect(exhausted!.type).toBe('err')
  })

  it('marks KMC active child with warn tone', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const accumulating = spec.nodes.find(n => n.id === 'KMC:accumulating')
    expect(accumulating!.type).toBe('warn')
  })

  it('marks KMC inactive children as dim', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const compacting = spec.nodes.find(n => n.id === 'KMC:compacting')
    expect(compacting!.type).toBe('dim')
  })

  it('does not set activeNodeId', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    expect(spec.activeNodeId).toBeUndefined()
  })

  it('uses correct node id format cluster:state', () => {
    const spec = buildCompositeFsmSpec(defaultParams)
    const ksmChildren = spec.nodes.filter(n => n.parent === 'KSM')
    for (const child of ksmChildren) {
      expect(child.id).toMatch(/^KSM:/)
    }
  })
})

// ================================================================
// buildCompactionSpec
// ================================================================

describe('buildCompactionSpec', () => {
  it('returns 3 nodes for KMC states', () => {
    const spec = buildCompactionSpec('accumulating')
    expect(spec.nodes).toHaveLength(3)
    const ids = spec.nodes.map(n => n.id)
    expect(ids).toEqual(['accumulating', 'compacting', 'done'])
  })

  it('returns 3 edges', () => {
    const spec = buildCompactionSpec('accumulating')
    expect(spec.edges).toHaveLength(3)
  })

  it('sets activeNodeId to activeStage', () => {
    const spec = buildCompactionSpec('compacting')
    expect(spec.activeNodeId).toBe('compacting')
  })

  it('uses breadthfirst layout', () => {
    const spec = buildCompactionSpec('accumulating')
    expect(spec.layout).toBe('breadthfirst')
  })

  it('uses LR direction', () => {
    const spec = buildCompactionSpec('accumulating')
    expect(spec.direction).toBe('LR')
  })

  it('marks compacting active stage as warn', () => {
    const spec = buildCompactionSpec('compacting')
    const compacting = spec.nodes.find(n => n.id === 'compacting')
    expect(compacting!.type).toBe('warn')
  })

  it('marks accumulating active stage as active with no problematic phase', () => {
    const spec = buildCompactionSpec('accumulating')
    const accumulating = spec.nodes.find(n => n.id === 'accumulating')
    expect(accumulating!.type).toBe('active')
  })

  it('marks done active stage as active', () => {
    const spec = buildCompactionSpec('done')
    const done = spec.nodes.find(n => n.id === 'done')
    expect(done!.type).toBe('active')
  })

  it('marks as err when currentPhase is Overflowed', () => {
    const spec = buildCompactionSpec('accumulating', 'Overflowed')
    const accumulating = spec.nodes.find(n => n.id === 'accumulating')
    expect(accumulating!.type).toBe('err')
  })

  it('marks as err when currentPhase is Failing', () => {
    const spec = buildCompactionSpec('accumulating', 'Failing')
    const accumulating = spec.nodes.find(n => n.id === 'accumulating')
    expect(accumulating!.type).toBe('err')
  })

  it('compacting stage takes precedence as warn even with Failing phase', () => {
    const spec = buildCompactionSpec('compacting', 'Failing')
    const compacting = spec.nodes.find(n => n.id === 'compacting')
    expect(compacting!.type).toBe('warn')
  })

  it('marks inactive states as dim', () => {
    const spec = buildCompactionSpec('accumulating')
    const compacting = spec.nodes.find(n => n.id === 'compacting')
    expect(compacting!.type).toBe('dim')
  })

  it('handles null currentPhase', () => {
    const spec = buildCompactionSpec('accumulating', null)
    const accumulating = spec.nodes.find(n => n.id === 'accumulating')
    expect(accumulating!.type).toBe('active')
  })

  it('handles undefined currentPhase', () => {
    const spec = buildCompactionSpec('accumulating')
    const accumulating = spec.nodes.find(n => n.id === 'accumulating')
    expect(accumulating!.type).toBe('active')
  })

  it('has ratio_gate edge from accumulating to compacting', () => {
    const spec = buildCompactionSpec('accumulating')
    const edge = spec.edges.find(e => e.source === 'accumulating' && e.target === 'compacting')
    expect(edge).toBeTruthy()
    expect(edge!.label).toBe('ratio_gate')
  })

  it('has completion edge from compacting to done', () => {
    const spec = buildCompactionSpec('accumulating')
    const edge = spec.edges.find(e => e.source === 'compacting' && e.target === 'done')
    expect(edge).toBeTruthy()
    expect(edge!.type).toBe('recovery')
  })

  it('has failure edge from compacting back to accumulating', () => {
    const spec = buildCompactionSpec('accumulating')
    const edge = spec.edges.find(e => e.source === 'compacting' && e.target === 'accumulating')
    expect(edge).toBeTruthy()
    expect(edge!.type).toBe('error')
  })
})

// ================================================================
// buildTurnFsmSpec
// ================================================================

describe('buildTurnFsmSpec', () => {
  it('creates one node per keeper_turn_fsm state', () => {
    const spec = buildTurnFsmSpec('streaming')
    expect(spec.nodes.map(n => n.id)).toEqual([...TURN_FSM_STATES])
  })

  it('marks the projected current state active', () => {
    const spec = buildTurnFsmSpec('streaming')
    const streaming = spec.nodes.find(n => n.id === 'streaming')
    expect(streaming!.type).toBe('active')
    expect(spec.activeNodeId).toBe('streaming')
  })

  it('maps legacy prompting to phase_gating', () => {
    expect(normalizeTurnFsmState('prompting')).toBe('phase_gating')
    const spec = buildTurnFsmSpec('prompting')
    expect(spec.activeNodeId).toBe('phase_gating')
  })

  it('maps legacy executing to streaming', () => {
    expect(normalizeTurnFsmState('executing')).toBe('streaming')
  })

  it('maps legacy finalizing and compacting to completing', () => {
    expect(normalizeTurnFsmState('finalizing')).toBe('completing')
    expect(normalizeTurnFsmState('compacting')).toBe('completing')
  })

  it('maps the TLA awaiting_tool symbol to the UI awaiting_tool_result state', () => {
    expect(normalizeTurnFsmState('awaiting_tool')).toBe('awaiting_tool_result')
    expect(turnFsmTlaSymbol('awaiting_tool_result')).toBe('awaiting_tool')
  })

  it('keeps failed and cancelled terminal states visible', () => {
    const failedSpec = buildTurnFsmSpec('failed')
    const failed = failedSpec.nodes.find(n => n.id === 'failed')
    const cancelled = failedSpec.nodes.find(n => n.id === 'cancelled')
    expect(failed!.type).toBe('err')
    expect(cancelled!.type).toBe('warn')
  })

  it('returns no active node for unknown turn phases', () => {
    const spec = buildTurnFsmSpec('mystery')
    expect(spec.activeNodeId).toBeNull()
  })

  it('includes the provider/tool/receipt terminal edges', () => {
    const spec = buildTurnFsmSpec('streaming')
    expect(spec.edges).toContainEqual({
      source: 'streaming',
      target: 'awaiting_tool_result',
      label: 'StreamYieldsTool',
      type: 'cascade',
    })
    expect(spec.edges).toContainEqual({
      source: 'completing',
      target: 'failed',
      label: 'ReceiptLost',
      type: 'error',
    })
  })
})
