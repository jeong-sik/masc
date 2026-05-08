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

interface CompositeFsmParams {
  phase: string            // KSM — Running | Failing | Overflowed | Compacting | HandingOff | Draining | Stable
  turnPhase: string        // KTC — idle | prompting | routing | executing | compacting | finalizing | exhausted
  decisionStage: string    // KDP — undecided | guard_ok | gate_rejected | tool_policy_selected
  cascadeState: string     // KCL — idle | selecting | trying | done | exhausted
  compactionStage: string  // KMC — accumulating | compacting | done
}

const KSM_STATES = [
  'Running', 'Failing', 'Overflowed', 'Compacting', 'HandingOff', 'Draining', 'Stable',
]
const KTC_STATES = ['idle', 'prompting', 'routing', 'executing', 'compacting', 'finalizing', 'exhausted']
const KDP_STATES = ['undecided', 'guard_ok', 'gate_rejected', 'tool_policy_selected']
const KCL_STATES = ['idle', 'selecting', 'trying', 'done', 'exhausted']
const KMC_STATES = ['accumulating', 'compacting', 'done']

export const TURN_FSM_STATES = [
  'idle',
  'phase_gating',
  'cascade_routing',
  'awaiting_provider',
  'streaming',
  'awaiting_tool_result',
  'completing',
  'done',
  'failed',
  'cancelled',
] as const

export type KeeperTurnFsmState = (typeof TURN_FSM_STATES)[number]

const TURN_FSM_TLA_SYMBOLS: Record<KeeperTurnFsmState, string> = {
  idle: 'idle',
  phase_gating: 'phase_gating',
  cascade_routing: 'cascade_routing',
  awaiting_provider: 'awaiting_provider',
  streaming: 'streaming',
  awaiting_tool_result: 'awaiting_tool',
  completing: 'completing',
  done: 'done',
  failed: 'failed',
  cancelled: 'cancelled',
}

const LEGACY_TURN_PHASE_MAP: Record<string, KeeperTurnFsmState> = {
  idle: 'idle',
  prompting: 'phase_gating',
  routing: 'cascade_routing',
  executing: 'streaming',
  compacting: 'completing',
  finalizing: 'completing',
  exhausted: 'completing',
  awaiting_tool: 'awaiting_tool_result',
}

const TURN_FSM_EDGES: FsmEdge[] = [
  { source: 'idle', target: 'phase_gating', label: 'StartTurn' },
  { source: 'phase_gating', target: 'done', label: 'PhaseGateSkip', type: 'recovery' },
  { source: 'phase_gating', target: 'cascade_routing', label: 'PhaseGateOk' },
  { source: 'cascade_routing', target: 'awaiting_provider', label: 'CascadeRouted', type: 'cascade' },
  { source: 'cascade_routing', target: 'failed', label: 'CascadeUnavailable', type: 'error' },
  { source: 'awaiting_provider', target: 'streaming', label: 'ProviderResponded' },
  { source: 'awaiting_provider', target: 'cancelled', label: 'ProviderTimeout', type: 'error' },
  { source: 'streaming', target: 'awaiting_tool_result', label: 'StreamYieldsTool', type: 'cascade' },
  { source: 'awaiting_tool_result', target: 'streaming', label: 'ToolReturned', type: 'recovery' },
  { source: 'streaming', target: 'completing', label: 'StreamComplete' },
  { source: 'completing', target: 'done', label: 'ContractOk', type: 'recovery' },
  { source: 'completing', target: 'failed', label: 'ContractViolation', type: 'error' },
  { source: 'completing', target: 'failed', label: 'ReceiptLost', type: 'error' },
  { source: 'phase_gating', target: 'cancelled', label: 'HonorStopSignal', type: 'error' },
  { source: 'cascade_routing', target: 'cancelled', label: 'HonorStopSignal', type: 'error' },
  { source: 'streaming', target: 'cancelled', label: 'HonorStopSignal', type: 'error' },
  { source: 'awaiting_tool_result', target: 'cancelled', label: 'HonorStopSignal', type: 'error' },
  { source: 'completing', target: 'cancelled', label: 'HonorStopSignal', type: 'error' },
]

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

export function normalizeTurnFsmState(turnPhase: string | null | undefined): KeeperTurnFsmState | null {
  if (!turnPhase) return null
  const normalized = turnPhase.trim().toLowerCase()
  if (!normalized) return null
  if ((TURN_FSM_STATES as readonly string[]).includes(normalized)) {
    return normalized as KeeperTurnFsmState
  }
  return LEGACY_TURN_PHASE_MAP[normalized] ?? null
}

export function turnFsmTlaSymbol(state: KeeperTurnFsmState): string {
  return TURN_FSM_TLA_SYMBOLS[state]
}

function turnNodeType(state: KeeperTurnFsmState, activeState: KeeperTurnFsmState | null): FsmNode['type'] {
  if (state === activeState) {
    if (state === 'failed') return 'err'
    if (state === 'cancelled') return 'warn'
    if (state === 'done') return 'ok'
    return 'active'
  }

  switch (state) {
    case 'done':
      return 'ok'
    case 'failed':
      return 'err'
    case 'cancelled':
      return 'warn'
    default:
      return 'state'
  }
}

export function buildTurnFsmSpec(turnPhase: string | null | undefined): FsmGraphSpec {
  const activeState = normalizeTurnFsmState(turnPhase)
  return {
    nodes: TURN_FSM_STATES.map(state => ({
      id: state,
      label: state,
      type: turnNodeType(state, activeState),
    })),
    edges: TURN_FSM_EDGES,
    activeNodeId: activeState,
    layout: 'breadthfirst',
    direction: 'LR',
  }
}
