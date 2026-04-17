// Keeper FSM graph spec builders — one per FSM layer.
// Each returns an FsmGraphSpec consumed by CytoscapeFsm.

import type { FsmGraphSpec, FsmNode, FsmEdge } from './common/cytoscape-fsm'


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
  const ksmTone: 'active' | 'warn' | 'err' =
    params.phase === 'Failing'
      ? 'err'
      : params.phase === 'Overflowed'
        || params.phase === 'Compacting'
        || params.phase === 'HandingOff'
        || params.phase === 'Draining'
        ? 'warn'
        : 'active'
  const nodes: FsmNode[] = [
    ...clusterNodes('KSM', 'KSM · keeper lifecycle', KSM_STATES, params.phase, ksmTone),
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

export function buildCompactionSpec(
  activeStage: string,
  currentPhase?: string | null,
): FsmGraphSpec {
  const normalizedPhase = currentPhase ?? null
  const tone: 'active' | 'warn' | 'err' =
    activeStage === 'compacting'
      ? 'warn'
      : normalizedPhase === 'Overflowed' || normalizedPhase === 'Failing'
        ? 'err'
        : 'active'

  return {
    nodes: KMC_STATES.map(state => ({
      id: state,
      label: state,
      type: nodeType(state, activeStage, tone),
    })),
    edges: [
      { source: 'accumulating', target: 'compacting', label: 'ratio_gate', type: 'cascade' },
      { source: 'compacting', target: 'done', label: 'Compaction_completed', type: 'recovery' },
      { source: 'compacting', target: 'accumulating', label: 'Compaction_failed', type: 'error' },
    ],
    activeNodeId: activeStage,
    layout: 'breadthfirst',
    direction: 'LR',
  }
}
