// Keeper FSM graph spec builders — one per FSM layer.
// Each returns an FsmGraphSpec consumed by CytoscapeFsm.

import type { FsmGraphSpec, FsmNode, FsmEdge } from './common/cytoscape-fsm'

// ================================================================
// Phase State Machine (keeper lifecycle)
// ================================================================

const PHASE_NODES: Array<{ id: string; label: string }> = [
  { id: 'Offline', label: 'Offline' },
  { id: 'Running', label: 'Running' },
  { id: 'Failing', label: 'Failing' },
  { id: 'Compacting', label: 'Compacting' },
  { id: 'HandingOff', label: 'HandingOff' },
  { id: 'Draining', label: 'Draining' },
  { id: 'Paused', label: 'Paused' },
  { id: 'Restarting', label: 'Restarting' },
  { id: 'Stopped', label: 'Stopped' },
  { id: 'Crashed', label: 'Crashed' },
  { id: 'Dead', label: 'Dead' },
]

const BUFFER_PHASES = new Set(['Failing', 'Compacting', 'HandingOff', 'Draining', 'Restarting'])
const TERMINAL_PHASES = new Set(['Stopped', 'Dead', 'Crashed'])

const PHASE_EDGES: FsmEdge[] = [
  { source: 'Offline', target: 'Running', label: 'boot' },
  { source: 'Running', target: 'Failing', label: 'error threshold', type: 'error' },
  { source: 'Failing', target: 'Running', label: 'recovery', type: 'recovery' },
  { source: 'Running', target: 'Compacting', label: 'compact trigger' },
  { source: 'Compacting', target: 'Running', label: 'compact done', type: 'recovery' },
  { source: 'Running', target: 'HandingOff', label: 'handoff start' },
  { source: 'HandingOff', target: 'Stopped', label: 'handoff complete' },
  { source: 'Running', target: 'Draining', label: 'drain start' },
  { source: 'Draining', target: 'Stopped', label: 'drain complete' },
  { source: 'Running', target: 'Paused', label: 'pause' },
  { source: 'Paused', target: 'Running', label: 'resume', type: 'recovery' },
  { source: 'Running', target: 'Restarting', label: 'restart' },
  { source: 'Restarting', target: 'Running', label: 'boot', type: 'recovery' },
  { source: 'Failing', target: 'Crashed', label: 'max retries', type: 'error' },
  { source: 'Crashed', target: 'Dead', label: 'no recovery', type: 'error' },
  { source: 'Running', target: 'Stopped', label: 'shutdown' },
]

function phaseNodeType(id: string, activePhase: string | null): FsmNode['type'] {
  if (activePhase && id === activePhase) {
    if (TERMINAL_PHASES.has(id)) return 'err'
    if (BUFFER_PHASES.has(id)) return 'warn'
    return 'active'
  }
  if (TERMINAL_PHASES.has(id)) return 'terminal'
  if (BUFFER_PHASES.has(id)) return 'buffer'
  return 'state'
}

export function buildPhaseSpec(activePhase: string | null): FsmGraphSpec {
  return {
    nodes: PHASE_NODES.map(n => ({
      id: n.id,
      label: n.label,
      type: phaseNodeType(n.id, activePhase),
    })),
    edges: PHASE_EDGES,
    activeNodeId: activePhase,
  }
}

// ================================================================
// Decision Pipeline (Guard → Thompson → ToolPolicy)
// ================================================================

interface DecisionPipelineParams {
  phase: string | null
  thompsonAlpha: number
  thompsonBeta: number
  toolCount: number
  recoveryFloorCount: number
}

export function buildDecisionPipelineSpec(params: DecisionPipelineParams): FsmGraphSpec {
  const { phase, thompsonAlpha, thompsonBeta, toolCount, recoveryFloorCount } = params
  const score = thompsonAlpha + thompsonBeta > 0
    ? thompsonAlpha / (thompsonAlpha + thompsonBeta)
    : 0.5

  const isRunning = phase === 'Running'
  const isFailing = phase === 'Failing'

  const nodes: FsmNode[] = [
    { id: 'NormalOps', label: `NormalOps\n\u03b8=${score.toFixed(2)}`, type: isRunning ? 'active' : 'state' },
    { id: 'GuardFires', label: 'Guard Fires', type: isRunning ? 'warn' : 'dim' },
    { id: 'ThompsonPenalty', label: `Thompson\n\u03b1=${thompsonAlpha.toFixed(1)} \u03b2=${thompsonBeta.toFixed(1)}`, type: isRunning ? 'buffer' : 'dim' },
    { id: 'ToolRestricted', label: `Tool Restricted\n${recoveryFloorCount} tools`, type: isFailing ? 'active' : 'dim' },
    { id: 'TurnAttempt', label: 'Turn Attempt', type: isFailing ? 'warn' : 'dim' },
    { id: 'RecoveryReady', label: `Recovery Ready\n${toolCount} tools`, type: isFailing ? 'ok' : 'dim' },
  ]

  const edges: FsmEdge[] = [
    { source: 'NormalOps', target: 'GuardFires', label: 'guardrail_stop', type: 'error' },
    { source: 'GuardFires', target: 'ThompsonPenalty', label: '\u03b2 += 0.5' },
    { source: 'ThompsonPenalty', target: 'NormalOps', label: 'cap 1/cycle', type: 'recovery' },
    { source: 'ToolRestricted', target: 'TurnAttempt', label: `floor ${recoveryFloorCount}` },
    { source: 'TurnAttempt', target: 'TurnAttempt', label: 'turn fails', type: 'error' },
    { source: 'TurnAttempt', target: 'RecoveryReady', label: 'turn ok', type: 'recovery' },
    { source: 'NormalOps', target: 'ToolRestricted', label: 'consecutive fails', type: 'error' },
    { source: 'RecoveryReady', target: 'NormalOps', label: 'heartbeat_ok', type: 'recovery' },
  ]

  return { nodes, edges, activeNodeId: isRunning ? 'NormalOps' : isFailing ? 'ToolRestricted' : null }
}

// ================================================================
// Cascade FSM (Provider Failover)
// ================================================================

interface CascadeParams {
  models: string[]
  lastProviderResult: string | null
}

export function buildCascadeSpec(params: CascadeParams): FsmGraphSpec {
  const { models, lastProviderResult } = params
  const nodes: FsmNode[] = [
    { id: 'Select', label: 'Select\nProvider', type: 'state' },
  ]

  const edges: FsmEdge[] = []

  models.forEach((model, i) => {
    const id = `P${i}`
    const isLastSuccess = model === lastProviderResult
    nodes.push({
      id,
      label: model,
      type: isLastSuccess ? 'ok' : 'state',
    })

    if (i === 0) {
      edges.push({ source: 'Select', target: id, label: 'try', type: 'cascade' })
    } else {
      edges.push({ source: `P${i - 1}`, target: id, label: 'cascade', type: 'cascade' })
    }

    edges.push({ source: id, target: 'Accept', label: 'Call_ok', type: 'recovery' })

    if (i < models.length - 1) {
      edges.push({ source: id, target: `P${i + 1}`, label: '429/timeout', type: 'error' })
    } else {
      edges.push({ source: id, target: 'AcceptExhaust', label: 'exhaustion', type: 'error' })
      edges.push({ source: id, target: 'Exhausted', label: 'non-cascadeable', type: 'error' })
    }
  })

  nodes.push(
    { id: 'Accept', label: 'Accept', type: 'ok' },
    { id: 'AcceptExhaust', label: 'Accept\n(exhaustion)', type: 'warn' },
    { id: 'Exhausted', label: 'Exhausted', type: 'err' },
  )

  const activeId = lastProviderResult
    ? models.indexOf(lastProviderResult) >= 0
      ? `P${models.indexOf(lastProviderResult)}`
      : null
    : null

  return { nodes, edges, activeNodeId: activeId }
}

// ================================================================
// Composite Lifecycle (RFC-0003 KeeperCompositeLifecycle.tla)
// ================================================================
//
// Compound graph: five parent clusters (one per sub-FSM) each containing
// their possible states. The current state is rendered [active] and the
// rest [dim], so the viewer reads "where is this keeper in each layer
// simultaneously". No cross-cluster edges — causal ordering between
// sub-FSMs is captured by the invariants panel, not the graph edges.

export interface CompositeFsmParams {
  phase: string            // KSM — Running | Failing | Overflowed | Compacting | HandingOff | Draining | Stable
  turnPhase: string        // KTC — idle | prompting | executing | compacting | finalizing
  decisionStage: string    // KDP — undecided | guard_ok | gate_rejected | tool_policy_selected
  cascadeState: string     // KCL — idle | selecting | trying | done | exhausted
  compactionStage: string  // KMC — accumulating | compacting | done
}

const KSM_STATES = [
  'Running', 'Failing', 'Overflowed', 'Compacting', 'HandingOff', 'Draining', 'Stable',
]
const KTC_STATES = ['idle', 'prompting', 'executing', 'compacting', 'finalizing']
const KDP_STATES = ['undecided', 'guard_ok', 'gate_rejected', 'tool_policy_selected']
const KCL_STATES = ['idle', 'selecting', 'trying', 'done', 'exhausted']
const KMC_STATES = ['accumulating', 'compacting', 'done']

function nodeType(stateId: string, activeId: string, tone: 'active' | 'warn' | 'err'): FsmNode['type'] {
  return stateId === activeId ? tone : 'dim'
}

function clusterNodes(
  clusterId: string,
  clusterLabel: string,
  states: readonly string[],
  active: string,
  tone: 'active' | 'warn' | 'err',
): FsmNode[] {
  const parent: FsmNode = {
    id: clusterId,
    label: clusterLabel,
    type: 'state',
  }
  const children: FsmNode[] = states.map(s => ({
    id: `${clusterId}:${s}`,
    label: s,
    type: nodeType(s, active, tone),
    parent: clusterId,
  }))
  return [parent, ...children]
}

export function buildCompositeFsmSpec(params: CompositeFsmParams): FsmGraphSpec {
  const nodes: FsmNode[] = [
    ...clusterNodes('KSM', 'KSM · keeper lifecycle', KSM_STATES, params.phase, 'active'),
    ...clusterNodes('KTC', 'KTC · turn cycle', KTC_STATES, params.turnPhase, 'active'),
    ...clusterNodes('KDP', 'KDP · decision pipeline', KDP_STATES, params.decisionStage,
      params.decisionStage === 'gate_rejected' ? 'err' : 'active'),
    ...clusterNodes('KCL', 'KCL · cascade state', KCL_STATES, params.cascadeState,
      params.cascadeState === 'exhausted' ? 'err' : 'active'),
    ...clusterNodes('KMC', 'KMC · memory compaction', KMC_STATES, params.compactionStage, 'warn'),
  ]

  // Edges left empty by design: the compound visual encodes "what sub-FSMs
  // are simultaneously active". Cross-cluster causality lives in the TLA+
  // spec (see KeeperCompositeLifecycle.tla join actions) and the invariants
  // panel — drawing inter-cluster arrows here would overstate the coupling.
  const edges: FsmEdge[] = []

  return {
    nodes,
    edges,
    layout: 'breadthfirst',
    direction: 'LR',
  }
}
