export type CommandPlaneUnitKind = 'company' | 'platoon' | 'squad' | 'agent'

export interface CommandPlanePolicyEnvelope {
  policy_class?: string
  approval_class?: string
  tool_allowlist?: string[]
  model_allowlist?: string[]
  requires_human_for?: string[]
  escalation_timeout_sec?: number
  kill_switch?: boolean
  frozen?: boolean
}

export interface CommandPlaneBudgetEnvelope {
  headcount_cap?: number
  active_operation_cap?: number
  max_cost_usd?: number
  max_tokens?: number
}

export interface CommandPlaneUnitRecord {
  unit_id: string
  label: string
  kind: CommandPlaneUnitKind
  parent_unit_id?: string | null
  leader_id?: string | null
  roster: string[]
  capability_profile: string[]
  source?: string
  created_at?: string
  updated_at?: string
  policy?: CommandPlanePolicyEnvelope
  budget?: CommandPlaneBudgetEnvelope
}

export interface CommandPlaneTreeNode {
  unit: CommandPlaneUnitRecord
  leader_status?: string
  roster_total?: number
  roster_live?: number
  active_operation_count?: number
  health?: 'ok' | 'warn' | 'bad' | string
  reasons?: string[]
  children: CommandPlaneTreeNode[]
}

export interface CommandPlaneTopologySummary {
  total_units?: number
  company_count?: number
  platoon_count?: number
  squad_count?: number
  leaf_agent_unit_count?: number
  live_agent_count?: number
  managed_unit_count?: number
  active_operation_count?: number
}

export interface CommandPlaneTopologyResponse {
  version?: string
  generated_at?: string
  source?: string
  summary?: CommandPlaneTopologySummary
  units: CommandPlaneTreeNode[]
}

export type CommandPlaneOperationStatus =
  | 'planned'
  | 'active'
  | 'paused'
  | 'completed'
  | 'cancelled'
  | 'failed'
  | string

export interface CommandPlaneChainRecord {
  kind: string
  chain_id?: string | null
  goal?: string | null
  run_id?: string | null
  status: string
  viewer_path?: string | null
  last_sync_at?: string | null
}

export interface CommandPlaneOperationRecord {
  operation_id: string
  objective: string
  assigned_unit_id: string
  policy_class?: string
  budget_class?: string
  detachment_session_id?: string | null
  trace_id: string
  checkpoint_ref?: string | null
  active_goal_ids?: string[]
  note?: string | null
  created_by?: string
  source?: string
  status: CommandPlaneOperationStatus
  chain?: CommandPlaneChainRecord | null
  created_at?: string
  updated_at?: string
}

export interface CommandPlaneOperationCard {
  operation: CommandPlaneOperationRecord
  assigned_unit_label?: string
}

export interface CommandPlaneMicroarchSignal {
  tone?: 'ok' | 'warn' | 'bad' | string
  pending_ops?: number
  blocked_ops?: number
  in_flight_ops?: number
  pipeline_stalls?: number
  bus_traffic?: number
  l1_hit_rate?: number
  invalidation_count?: number
  current_pending?: number
  current_in_flight?: number
  cdb_wakeups?: number
  total_stolen?: number
  avg_best_score?: number
  avg_candidate_count?: number
  best_first_operations?: number
  active_sessions?: number
  commit_rate?: number
  total_speculations?: number
}

export interface CommandPlaneMicroarchSummary {
  pipeline?: {
    total_ops?: number
    completed_ops?: number
    stalled_cycles?: number
    hazards_detected?: number
    forwarding_used?: number
    pipeline_flushes?: number
    ipc?: number
  }
  cache?: {
    total_reads?: number
    total_writes?: number
    l1_hit_rate?: number
    invalidation_count?: number
    writeback_count?: number
    bus_traffic?: number
  }
  ooo?: {
    agent_count?: number
    total_added?: number
    total_issued?: number
    total_completed?: number
    total_stolen?: number
    cdb_wakeups?: number
    stall_cycles?: number
    global_cdb_events?: number
    current_pending?: number
    current_in_flight?: number
  }
  speculative?: {
    total_speculations?: number
    total_commits?: number
    total_aborts?: number
    commit_rate?: number
    total_fast_calls?: number
    total_cost_usd?: number
    active_sessions?: number
  }
  search_fabric?: {
    total_operations?: number
    best_first_operations?: number
    legacy_operations?: number
    blocked_operations?: number
    ready_operations?: number
    research_pipeline_operations?: number
    avg_candidate_count?: number
    avg_best_score?: number
    top_stage?: string | null
  }
  signals?: {
    issue_pressure?: CommandPlaneMicroarchSignal
    cache_contention?: CommandPlaneMicroarchSignal
    scheduler_efficiency?: CommandPlaneMicroarchSignal
    routing_confidence?: CommandPlaneMicroarchSignal
    speculative_posture?: CommandPlaneMicroarchSignal
  }
}

export interface CommandPlaneOperationsResponse {
  version?: string
  generated_at?: string
  summary?: {
    total?: number
    active?: number
    paused?: number
      managed?: number
      projected?: number
    }
  microarch?: CommandPlaneMicroarchSummary
  operations: CommandPlaneOperationCard[]
}

export interface CommandPlaneDetachmentRecord {
  detachment_id: string
  operation_id: string
  assigned_unit_id: string
  leader_id?: string | null
  roster: string[]
  session_id?: string | null
  checkpoint_ref?: string | null
  runtime_kind?: string | null
  runtime_ref?: string | null
  source?: string
  status?: string
  last_event_at?: string | null
  last_progress_at?: string | null
  heartbeat_deadline?: string | null
  created_at?: string
  updated_at?: string
}

export interface CommandPlaneDetachmentCard {
  detachment: CommandPlaneDetachmentRecord
  assigned_unit_label?: string
  operation?: CommandPlaneOperationRecord | null
}

export interface CommandPlaneDetachmentsResponse {
  version?: string
  generated_at?: string
  summary?: {
    total?: number
    active?: number
    projected?: number
  }
  detachments: CommandPlaneDetachmentCard[]
}

export interface CommandPlaneDecisionRecord {
  decision_id: string
  trace_id: string
  requested_action: string
  scope_type: string
  scope_id: string
  operation_id?: string | null
  target_unit_id?: string | null
  requested_by?: string
  status?: string
  reason?: string | null
  source?: string
  detail?: unknown
  created_at?: string
  decided_at?: string | null
  expires_at?: string | null
}

export interface CommandPlaneDecisionsResponse {
  version?: string
  generated_at?: string
  summary?: {
    total?: number
    pending?: number
    approved?: number
    denied?: number
  }
  decisions: CommandPlaneDecisionRecord[]
}

export interface CommandPlaneCapacityRow {
  unit: CommandPlaneUnitRecord
  roster_total?: number
  roster_live?: number
  headcount_cap?: number
  active_operations?: number
  active_operation_cap?: number
  utilization?: number
}

export interface CommandPlaneCapacityResponse {
  version?: string
  generated_at?: string
  capacity: CommandPlaneCapacityRow[]
}

export interface CommandPlaneAlert {
  alert_id: string
  severity?: 'bad' | 'warn' | 'info' | string
  kind?: string
  scope_type?: string
  scope_id?: string
  title?: string
  detail?: string
  timestamp?: string
}

export interface CommandPlaneAlertsResponse {
  version?: string
  generated_at?: string
  summary?: {
    total?: number
    bad?: number
    warn?: number
  }
  alerts: CommandPlaneAlert[]
}

export interface CommandPlaneTraceEvent {
  event_id: string
  trace_id: string
  event_type: string
  operation_id?: string | null
  unit_id?: string | null
  actor?: string | null
  source?: string
  timestamp?: string
  detail?: unknown
}

export interface CommandPlaneTracesResponse {
  version?: string
  generated_at?: string
  events: CommandPlaneTraceEvent[]
}

export type CommandPlaneSurface =
  | 'operations'
  | 'chains'
  | 'control'
