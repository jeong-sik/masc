// Keeper FSM graph spec builders — one per FSM layer.
// Each returns an FsmGraphSpec consumed by CytoscapeFsm.

import type { FsmGraphSpec, FsmNode, FsmEdge } from './common/cytoscape-fsm'
import { compositePhaseTone } from '../lib/keeper-operational-state'
import { toKeeperPhase } from '../keeper-store-normalize'


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
  phase: string            // KSM — offline | running | failing | draining | paused | stopped | crashed | restarting
  turnPhase: string        // KTC — idle | prompting | routing | executing | finalizing | exhausted
  decisionStage: string    // KDP — undecided | guard_ok | tool_policy_selected
  runtimeState: string     // KCL — idle | selecting | trying | done | exhausted
}

const KSM_STATES = [
  'offline', 'running', 'failing',
  'draining', 'paused', 'stopped', 'crashed',
  'restarting',
]
const KTC_STATES = ['idle', 'prompting', 'routing', 'executing', 'finalizing', 'exhausted']
const KDP_STATES = ['undecided', 'guard_ok', 'tool_policy_selected']
const KCL_STATES = ['idle', 'selecting', 'trying', 'done', 'exhausted']

export const TURN_FSM_STATES = [
  'idle',
  'prompting',
  'routing',
  'executing',
  // UI-side surface for the TLA `awaiting_tool` symbol — the agent-core turn
  // sits here after invoking a tool until the tool result arrives.
  // `normalizeTurnFsmState` maps the raw `awaiting_tool` backend phase
  // onto this UI state, and `turnFsmTlaSymbol` translates it back.
  'awaiting_tool_result',
  'finalizing',
  'exhausted',
] as const

export type KeeperTurnFsmState = (typeof TURN_FSM_STATES)[number]

const TURN_FSM_TLA_SYMBOLS: Record<KeeperTurnFsmState, string> = {
  idle: 'idle',
  prompting: 'prompting',
  routing: 'routing',
  executing: 'executing',
  awaiting_tool_result: 'awaiting_tool',
  finalizing: 'finalizing',
  exhausted: 'exhausted',
}

// Raw backend turn-phase values that should collapse onto a canonical
// UI state. Currently only the TLA `awaiting_tool` symbol is renamed
// for the dashboard surface; leave additional aliases here when the
// backend introduces new raw phases that map onto an existing UI state.
const TURN_FSM_STATE_ALIASES: Readonly<Record<string, KeeperTurnFsmState>> = {
  awaiting_tool: 'awaiting_tool_result',
}

// 23 canonical turn_phase transitions. Mirrors the GADT enumeration in
// `lib/keeper/keeper_registry_types.ml:259-291 module Turn_phase_transition`
// (RFC-0072 Phase 4b/5). Every constructor on the GADT corresponds to one
// edge here; adding a new constructor in OCaml must be paired with a new
// edge in this list, otherwise the dashboard visualization hides a real
// transition the runtime can take. The previous list omitted the four
// `* -> exhausted` arms from prompting/routing/finalizing,
// surfacing only the `executing -> exhausted` path even though runtime
// exhaustion can be entered from any non-terminal turn phase.
const TURN_FSM_EDGES: FsmEdge[] = [
  // From Idle (1): boot dispatch.
  { source: 'idle', target: 'prompting', label: 'StartTurn' },
  // From Prompting (4): routing / executing / finalizing / exhausted.
  { source: 'prompting', target: 'routing', label: 'RouteOk' },
  { source: 'prompting', target: 'executing', label: 'SkipRouting' },
  { source: 'prompting', target: 'finalizing', label: 'SkipExecution' },
  { source: 'prompting', target: 'exhausted', label: 'Exhausted', type: 'error' },
  // From Routing (3): retry-back / dispatch / exhausted.
  { source: 'routing', target: 'prompting', label: 'Retry' },
  { source: 'routing', target: 'executing', label: 'RuntimeRouted', type: 'runtime' },
  { source: 'routing', target: 'exhausted', label: 'Exhausted', type: 'error' },
  // From Executing (4): retry-back / re-entry / completion / exhausted.
  { source: 'executing', target: 'prompting', label: 'Retry' },
  { source: 'executing', target: 'routing', label: 'Retry' },
  { source: 'executing', target: 'finalizing', label: 'Complete' },
  { source: 'executing', target: 'exhausted', label: 'Exhausted', type: 'error' },
  // From Finalizing (4): degraded retry across phases / exhausted.
  { source: 'finalizing', target: 'prompting', label: 'NextTurn' },
  { source: 'finalizing', target: 'routing', label: 'NextTurnSkip' },
  { source: 'finalizing', target: 'executing', label: 'NextTurnDirect' },
  { source: 'finalizing', target: 'exhausted', label: 'Exhausted', type: 'error' },
  // From Exhausted (3): retry.
  { source: 'exhausted', target: 'prompting', label: 'RetryAfterExhausted' },
  { source: 'exhausted', target: 'routing', label: 'RetryAfterExhausted' },
  { source: 'exhausted', target: 'executing', label: 'RetryAfterExhausted' },
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
  // RFC-0135 PR-11: phase tone derivation moved to SSOT
  // (`compositePhaseTone` in `lib/keeper-operational-state.ts`). Same 6
  // warn-phase literals were copy-pasted between this builder and
  // `fsm-hub-invariant-analysis.ts` (N-of-M anti-pattern). Unknown wire
  // values fall back to 'active' to match the previous fall-through
  // semantics of the inline OR chain.
  const ksmPhase = toKeeperPhase(params.phase)
  const ksmTone: 'active' | 'warn' | 'err' = ksmPhase === null ? 'active' : compositePhaseTone(ksmPhase)
  const nodes: FsmNode[] = [
    ...clusterNodes('KSM', 'KSM · keeper lifecycle', KSM_STATES, params.phase, ksmTone),
    ...clusterNodes('KTC', 'KTC · turn cycle', KTC_STATES, params.turnPhase, 'active'),
    ...clusterNodes('KDP', 'KDP · decision pipeline', KDP_STATES, params.decisionStage, 'active'),
    ...clusterNodes('KCL', 'KCL · runtime state', KCL_STATES, params.runtimeState,
      params.runtimeState === 'exhausted' ? 'err' : 'active'),
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


export function normalizeTurnFsmState(turnPhase: string | null | undefined): KeeperTurnFsmState | null {
  if (!turnPhase) return null
  const normalized = turnPhase.trim().toLowerCase()
  if (!normalized) return null
  const aliased = TURN_FSM_STATE_ALIASES[normalized]
  if (aliased) return aliased
  if ((TURN_FSM_STATES as readonly string[]).includes(normalized)) {
    return normalized as KeeperTurnFsmState
  }
  return null
}

export function turnFsmTlaSymbol(state: KeeperTurnFsmState): string {
  return TURN_FSM_TLA_SYMBOLS[state]
}

function turnNodeType(state: KeeperTurnFsmState, activeState: KeeperTurnFsmState | null): FsmNode['type'] {
  if (state === activeState) {
    if (state === 'exhausted') return 'err'
    return 'active'
  }

  switch (state) {
    case 'exhausted':
      return 'err'
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
