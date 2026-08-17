// Agent Core (embedded execution) event types for dashboard runtime monitoring.
// Keep this slice as a discriminated union so each event kind has a stable
// contract instead of one wide product type with many unrelated optionals.

import type { KeeperPhase } from './core'

interface AgentCoreAgentEventBase {
  agent_name: string
  event_id?: string
  event_type?: string
  correlation_id?: string
  run_id?: string
  event_key?: string
  timestamp: number
}

// `phase` is the keeper FSM phase at emit time. Backend emits the
// lowercase wire form via `Keeper_state_machine.phase_to_string`
// (lib/runtime/runtime_events.ml:170–179); the factory in
// `agent-core-runtime-store.ts` normalizes it to the canonical PascalCase
// `KeeperPhase` so consumers don't carry around two casing forms.
// `null` means either the lifecycle event genuinely had no phase
// (e.g. a `Custom_event` with `phase = None`) or the wire value
// didn't match any known variant — both cases collapse to the same
// "no typed phase" state.
export interface AgentCoreKeeperLifecycleEvent extends AgentCoreAgentEventBase {
  type: 'keeper_lifecycle'
  actor_kind: 'keeper'
  keeper_name?: string
  event?: string
  phase?: KeeperPhase | null
  detail?: string
}

export type AgentCoreAgentEvent = AgentCoreKeeperLifecycleEvent

export interface AgentCoreHealthSummary {
  agentEventsCount: number
  totalEvents: number
  replayLoadedEvents: number
  replayTotalMatchingEvents: number
  replayTruncated: boolean
  replayCapped: boolean
  hasMore: boolean
  totalLlmCalls: number
  totalErrors: number
  lastLlmCallTs: number | null
  lastErrorTs: number | null
  evidenceRefsCount: number
  artifactRefsCount: number
  rawTraceRefsCount: number
  reportRefsCount: number
  proofRefsCount: number
  telemetryRefsCount: number
  runtimeEvidenceRefsCount: number
  lastEvidenceTs: number | null
}
