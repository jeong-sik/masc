// OAS (Open Agent SDK) Event types for dashboard monitoring

export interface OasAgentEvent {
  type:
    | 'selected'
    | 'decision'
    | 'action_executed'
    | 'keeper_lifecycle'
    | 'trust_updated'
    | 'reputation_changed'
  agent_name: string
  actor_kind?: 'agent' | 'keeper'
  keeper_name?: string
  secondary_agent?: string
  action?: string
  trigger?: string
  trigger_reason?: string
  event?: string
  event_type?: string
  detail?: string
  thompson_score?: number
  final_score?: number
  success?: boolean
  trust_score?: number
  old_score?: number
  new_score?: number
  trend?: string
  correlation_id?: string
  run_id?: string
  event_key?: string
  timestamp: number
}

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
