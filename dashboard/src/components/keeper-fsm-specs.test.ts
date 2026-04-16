import { describe, it, expect } from 'vitest'
import {
  buildPhaseSpec,
  buildDecisionPipelineSpec,
  buildCascadeSpec,
  buildCompositeFsmSpec,
  buildCompactionSpec,
} from './keeper-fsm-specs'

// ================================================================
// buildPhaseSpec
// ================================================================

describe('buildPhaseSpec', () => {
  it('returns 12 nodes for all KSM phases', () => {
    const spec = buildPhaseSpec(null)
    expect(spec.nodes).toHaveLength(12)
  })

  it('returns expected node ids', () => {
    const spec = buildPhaseSpec(null)
    const ids = spec.nodes.map(n => n.id)
    expect(ids).toContain('Offline')
    expect(ids).toContain('Running')
    expect(ids).toContain('Failing')
    expect(ids).toContain('Crashed')
    expect(ids).toContain('Dead')
    expect(ids).toContain('Paused')
  })

  it('returns phase edges (30+)', () => {
    const spec = buildPhaseSpec(null)
    expect(spec.edges.length).toBeGreaterThan(20)
  })

  it('sets activeNodeId to null when activePhase is null', () => {
    const spec = buildPhaseSpec(null)
    expect(spec.activeNodeId).toBeNull()
  })

  it('sets activeNodeId when activePhase is provided', () => {
    const spec = buildPhaseSpec('Running')
    expect(spec.activeNodeId).toBe('Running')
  })

  it('marks Running as active type', () => {
    const spec = buildPhaseSpec('Running')
    const running = spec.nodes.find(n => n.id === 'Running')
    expect(running!.type).toBe('active')
  })

  it('marks terminal phases (Stopped/Dead/Crashed) as terminal when inactive', () => {
    const spec = buildPhaseSpec('Running')
    const stopped = spec.nodes.find(n => n.id === 'Stopped')
    const dead = spec.nodes.find(n => n.id === 'Dead')
    const crashed = spec.nodes.find(n => n.id === 'Crashed')
    expect(stopped!.type).toBe('terminal')
    expect(dead!.type).toBe('terminal')
    expect(crashed!.type).toBe('terminal')
  })

  it('marks active Crashed as err type', () => {
    const spec = buildPhaseSpec('Crashed')
    const crashed = spec.nodes.find(n => n.id === 'Crashed')
    expect(crashed!.type).toBe('err')
  })

  it('marks buffer phases as warn when active', () => {
    const spec = buildPhaseSpec('Failing')
    const failing = spec.nodes.find(n => n.id === 'Failing')
    expect(failing!.type).toBe('warn')
  })

  it('marks buffer phases as buffer when inactive', () => {
    const spec = buildPhaseSpec('Running')
    const failing = spec.nodes.find(n => n.id === 'Failing')
    const overflowed = spec.nodes.find(n => n.id === 'Overflowed')
    expect(failing!.type).toBe('buffer')
    expect(overflowed!.type).toBe('buffer')
  })

  it('marks inactive non-buffer non-terminal as state', () => {
    const spec = buildPhaseSpec('Crashed')
    const offline = spec.nodes.find(n => n.id === 'Offline')
    expect(offline!.type).toBe('state')
  })

  it('has boot edge from Offline to Running', () => {
    const spec = buildPhaseSpec(null)
    const bootEdge = spec.edges.find(e => e.source === 'Offline' && e.target === 'Running')
    expect(bootEdge).toBeTruthy()
    expect(bootEdge!.label).toBe('boot')
  })

  it('has error edges with error type', () => {
    const spec = buildPhaseSpec(null)
    const errorEdges = spec.edges.filter(e => e.type === 'error')
    expect(errorEdges.length).toBeGreaterThan(5)
  })

  it('has recovery edges with recovery type', () => {
    const spec = buildPhaseSpec(null)
    const recoveryEdges = spec.edges.filter(e => e.type === 'recovery')
    expect(recoveryEdges.length).toBeGreaterThan(3)
  })

  it('does not set layout or direction', () => {
    const spec = buildPhaseSpec(null)
    expect(spec.layout).toBeUndefined()
    expect(spec.direction).toBeUndefined()
  })

  it('marks active Stopped as terminal (err)', () => {
    const spec = buildPhaseSpec('Stopped')
    const stopped = spec.nodes.find(n => n.id === 'Stopped')
    expect(stopped!.type).toBe('err')
  })

  it('marks active Dead as terminal (err)', () => {
    const spec = buildPhaseSpec('Dead')
    const dead = spec.nodes.find(n => n.id === 'Dead')
    expect(dead!.type).toBe('err')
  })
})

// ================================================================
// buildDecisionPipelineSpec
// ================================================================

describe('buildDecisionPipelineSpec', () => {
  const defaultParams = {
    phase: 'Running' as string | null,
    thompsonAlpha: 2.0,
    thompsonBeta: 1.0,
    toolCount: 5,
    recoveryFloorCount: 2,
  }

  it('returns 6 nodes', () => {
    const spec = buildDecisionPipelineSpec(defaultParams)
    expect(spec.nodes).toHaveLength(6)
  })

  it('returns expected node ids', () => {
    const spec = buildDecisionPipelineSpec(defaultParams)
    const ids = spec.nodes.map(n => n.id)
    expect(ids).toEqual(['NormalOps', 'GuardFires', 'ThompsonPenalty', 'ToolRestricted', 'TurnAttempt', 'RecoveryReady'])
  })

  it('returns 8 edges', () => {
    const spec = buildDecisionPipelineSpec(defaultParams)
    expect(spec.edges).toHaveLength(8)
  })

  it('computes theta score in NormalOps label', () => {
    const spec = buildDecisionPipelineSpec({ ...defaultParams, thompsonAlpha: 3, thompsonBeta: 1 })
    const normalOps = spec.nodes.find(n => n.id === 'NormalOps')
    expect(normalOps!.label).toContain('0.75')
  })

  it('defaults theta to 0.5 when alpha+beta is zero', () => {
    const spec = buildDecisionPipelineSpec({ ...defaultParams, thompsonAlpha: 0, thompsonBeta: 0 })
    const normalOps = spec.nodes.find(n => n.id === 'NormalOps')
    expect(normalOps!.label).toContain('0.50')
  })

  it('shows alpha and beta in ThompsonPenalty label', () => {
    const spec = buildDecisionPipelineSpec({ ...defaultParams, thompsonAlpha: 1.5, thompsonBeta: 2.5 })
    const tp = spec.nodes.find(n => n.id === 'ThompsonPenalty')
    expect(tp!.label).toContain('1.5')
    expect(tp!.label).toContain('2.5')
  })

  it('shows tool count in RecoveryReady label', () => {
    const spec = buildDecisionPipelineSpec({ ...defaultParams, toolCount: 10 })
    const rr = spec.nodes.find(n => n.id === 'RecoveryReady')
    expect(rr!.label).toContain('10')
  })

  it('shows recovery floor count in ToolRestricted label', () => {
    const spec = buildDecisionPipelineSpec({ ...defaultParams, recoveryFloorCount: 3 })
    const tr = spec.nodes.find(n => n.id === 'ToolRestricted')
    expect(tr!.label).toContain('3')
  })

  it('sets activeNodeId to NormalOps when Running', () => {
    const spec = buildDecisionPipelineSpec({ ...defaultParams, phase: 'Running' })
    expect(spec.activeNodeId).toBe('NormalOps')
  })

  it('sets activeNodeId to ToolRestricted when Failing', () => {
    const spec = buildDecisionPipelineSpec({ ...defaultParams, phase: 'Failing' })
    expect(spec.activeNodeId).toBe('ToolRestricted')
  })

  it('sets activeNodeId to null when phase is Stable', () => {
    const spec = buildDecisionPipelineSpec({ ...defaultParams, phase: 'Stable' })
    expect(spec.activeNodeId).toBeNull()
  })

  it('marks NormalOps as active when Running', () => {
    const spec = buildDecisionPipelineSpec({ ...defaultParams, phase: 'Running' })
    const normalOps = spec.nodes.find(n => n.id === 'NormalOps')
    expect(normalOps!.type).toBe('active')
  })

  it('marks GuardFires as warn when Running', () => {
    const spec = buildDecisionPipelineSpec({ ...defaultParams, phase: 'Running' })
    const gf = spec.nodes.find(n => n.id === 'GuardFires')
    expect(gf!.type).toBe('warn')
  })

  it('marks nodes as dim when neither Running nor Failing', () => {
    const spec = buildDecisionPipelineSpec({ ...defaultParams, phase: 'Stable' })
    const gf = spec.nodes.find(n => n.id === 'GuardFires')
    expect(gf!.type).toBe('dim')
  })

  it('marks ToolRestricted as active when Failing', () => {
    const spec = buildDecisionPipelineSpec({ ...defaultParams, phase: 'Failing' })
    const tr = spec.nodes.find(n => n.id === 'ToolRestricted')
    expect(tr!.type).toBe('active')
  })

  it('marks RecoveryReady as ok when Failing', () => {
    const spec = buildDecisionPipelineSpec({ ...defaultParams, phase: 'Failing' })
    const rr = spec.nodes.find(n => n.id === 'RecoveryReady')
    expect(rr!.type).toBe('ok')
  })

  it('has self-loop on TurnAttempt for turn fails', () => {
    const spec = buildDecisionPipelineSpec(defaultParams)
    const selfLoop = spec.edges.find(e => e.source === 'TurnAttempt' && e.target === 'TurnAttempt')
    expect(selfLoop).toBeTruthy()
    expect(selfLoop!.label).toBe('turn fails')
    expect(selfLoop!.type).toBe('error')
  })
})

// ================================================================
// buildCascadeSpec
// ================================================================

describe('buildCascadeSpec', () => {
  it('creates Select node plus terminal nodes when models is empty', () => {
    const spec = buildCascadeSpec({ models: [], lastProviderResult: null })
    expect(spec.nodes).toHaveLength(4)
    const ids = spec.nodes.map(n => n.id)
    expect(ids).toContain('Select')
    expect(ids).toContain('Accept')
    expect(ids).toContain('AcceptExhaust')
    expect(ids).toContain('Exhausted')
  })

  it('creates no model edges when models is empty', () => {
    const spec = buildCascadeSpec({ models: [], lastProviderResult: null })
    expect(spec.edges).toHaveLength(0)
  })

  it('creates nodes for each model plus infrastructure nodes', () => {
    const spec = buildCascadeSpec({ models: ['gpt-4', 'claude', 'gemini'], lastProviderResult: null })
    expect(spec.nodes).toHaveLength(7)
  })

  it('names model nodes P0, P1, P2', () => {
    const spec = buildCascadeSpec({ models: ['gpt-4', 'claude'], lastProviderResult: null })
    const ids = spec.nodes.map(n => n.id)
    expect(ids).toContain('P0')
    expect(ids).toContain('P1')
  })

  it('uses model name as label for model nodes', () => {
    const spec = buildCascadeSpec({ models: ['gpt-4', 'claude'], lastProviderResult: null })
    const p0 = spec.nodes.find(n => n.id === 'P0')
    expect(p0!.label).toBe('gpt-4')
  })

  it('connects Select to first model', () => {
    const spec = buildCascadeSpec({ models: ['gpt-4'], lastProviderResult: null })
    const edge = spec.edges.find(e => e.source === 'Select' && e.target === 'P0')
    expect(edge).toBeTruthy()
    expect(edge!.type).toBe('cascade')
  })

  it('cascades between consecutive models', () => {
    const spec = buildCascadeSpec({ models: ['a', 'b', 'c'], lastProviderResult: null })
    const cascadeEdge = spec.edges.find(e => e.source === 'P0' && e.target === 'P1' && e.label === 'cascade')
    expect(cascadeEdge).toBeTruthy()
  })

  it('each model has Call_ok edge to Accept', () => {
    const spec = buildCascadeSpec({ models: ['a', 'b'], lastProviderResult: null })
    const callOkEdges = spec.edges.filter(e => e.label === 'Call_ok' && e.target === 'Accept')
    expect(callOkEdges).toHaveLength(2)
  })

  it('last model has exhaustion edges', () => {
    const spec = buildCascadeSpec({ models: ['a', 'b'], lastProviderResult: null })
    const exhaustEdges = spec.edges.filter(e => e.source === 'P1' && (e.target === 'AcceptExhaust' || e.target === 'Exhausted'))
    expect(exhaustEdges).toHaveLength(2)
  })

  it('non-last models have 429/timeout edge to next model', () => {
    const spec = buildCascadeSpec({ models: ['a', 'b', 'c'], lastProviderResult: null })
    const timeout0 = spec.edges.find(e => e.source === 'P0' && e.target === 'P1' && e.label === '429/timeout')
    expect(timeout0).toBeTruthy()
    expect(timeout0!.type).toBe('error')
  })

  it('sets activeNodeId based on lastProviderResult', () => {
    const spec = buildCascadeSpec({ models: ['gpt-4', 'claude'], lastProviderResult: 'claude' })
    expect(spec.activeNodeId).toBe('P1')
  })

  it('sets activeNodeId to null when lastProviderResult is null', () => {
    const spec = buildCascadeSpec({ models: ['gpt-4'], lastProviderResult: null })
    expect(spec.activeNodeId).toBeNull()
  })

  it('sets activeNodeId to null when lastProviderResult not in models', () => {
    const spec = buildCascadeSpec({ models: ['gpt-4'], lastProviderResult: 'unknown-model' })
    expect(spec.activeNodeId).toBeNull()
  })

  it('marks matching model as ok type', () => {
    const spec = buildCascadeSpec({ models: ['gpt-4', 'claude'], lastProviderResult: 'gpt-4' })
    const p0 = spec.nodes.find(n => n.id === 'P0')
    expect(p0!.type).toBe('ok')
  })

  it('marks non-matching model as state type', () => {
    const spec = buildCascadeSpec({ models: ['gpt-4', 'claude'], lastProviderResult: 'gpt-4' })
    const p1 = spec.nodes.find(n => n.id === 'P1')
    expect(p1!.type).toBe('state')
  })

  it('handles single model correctly', () => {
    const spec = buildCascadeSpec({ models: ['only-one'], lastProviderResult: null })
    expect(spec.nodes).toHaveLength(5)
    // Select→P0(try), P0→Accept(Call_ok), P0→AcceptExhaust(exhaustion), P0→Exhausted(non-cascadeable) = 4
    expect(spec.edges).toHaveLength(4)
  })

  it('edge count grows linearly with model count', () => {
    const spec1 = buildCascadeSpec({ models: ['a'], lastProviderResult: null })
    const spec2 = buildCascadeSpec({ models: ['a', 'b'], lastProviderResult: null })
    const spec3 = buildCascadeSpec({ models: ['a', 'b', 'c'], lastProviderResult: null })
    // Each model adds ~3 edges, last model adds 4
    expect(spec2.edges.length).toBeGreaterThan(spec1.edges.length)
    expect(spec3.edges.length).toBeGreaterThan(spec2.edges.length)
  })
})

// ================================================================
// buildCompositeFsmSpec
// ================================================================

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
