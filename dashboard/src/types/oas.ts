// OAS (Open Agent SDK) Event types for dashboard monitoring

export interface OasAgentEvent {
  type: 'selected' | 'decision' | 'action_executed'
  agent_name: string
  action?: string
  trigger?: string
  trigger_reason?: string
  thompson_score?: number
  final_score?: number
  success?: boolean
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
  last_gardener_tick: number | null
  total_events: number
}
