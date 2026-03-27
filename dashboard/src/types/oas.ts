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
  secondary_agent?: string
  action?: string
  trigger?: string
  trigger_reason?: string
  event?: string
  detail?: string
  thompson_score?: number
  final_score?: number
  success?: boolean
  trust_score?: number
  old_score?: number
  new_score?: number
  trend?: string
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
  agent_events_count: number
  keeper_snapshots_count: number
  last_keeper_tick: number | null
  total_events: number
}
