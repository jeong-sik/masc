// OAS (Open Agent SDK) event types for dashboard runtime monitoring.
// Keep this slice as a discriminated union so each event kind has a stable
// contract instead of one wide product type with many unrelated optionals.

interface OasAgentEventBase {
  agent_name: string
  event_type?: string
  correlation_id?: string
  run_id?: string
  event_key?: string
  timestamp: number
}

interface OasAgentSelectedEvent extends OasAgentEventBase {
  type: 'selected'
  actor_kind: 'agent'
  trigger?: string
  thompson_score?: number
  final_score?: number
}

interface OasAgentDecisionEvent extends OasAgentEventBase {
  type: 'decision'
  actor_kind: 'agent'
  action?: string
  trigger_reason?: string
}

interface OasAgentActionExecutedEvent extends OasAgentEventBase {
  type: 'action_executed'
  actor_kind: 'agent'
  action?: string
  success?: boolean
}

export interface OasKeeperLifecycleEvent extends OasAgentEventBase {
  type: 'keeper_lifecycle'
  actor_kind: 'keeper'
  keeper_name?: string
  event?: string
  phase?: string
  detail?: string
}

interface OasTrustUpdatedEvent extends OasAgentEventBase {
  type: 'trust_updated'
  actor_kind: 'agent'
  secondary_agent?: string
  trust_score?: number
}

interface OasReputationChangedEvent extends OasAgentEventBase {
  type: 'reputation_changed'
  actor_kind: 'agent'
  old_score?: number
  new_score?: number
  trend?: string
}

export type OasAgentEvent =
  | OasAgentSelectedEvent
  | OasAgentDecisionEvent
  | OasAgentActionExecutedEvent
  | OasKeeperLifecycleEvent
  | OasTrustUpdatedEvent
  | OasReputationChangedEvent

export interface OasKeeperSnapshot {
  keeper_name: string
  generation: number
  context_ratio: number
  message_count: number
  timestamp: number
}

export interface OasHealthSummary {
  agentEventsCount: number
  keeperSnapshotsCount: number
  lastKeeperTick: number | null
  totalEvents: number
  totalLlmCalls: number
  totalErrors: number
  lastLlmCallTs: number | null
  lastErrorTs: number | null
}
