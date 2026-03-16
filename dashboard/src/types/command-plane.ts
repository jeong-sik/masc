export type CommandPlaneUnitKind = 'company' | 'platoon' | 'squad' | 'agent'

export interface CommandPlanePolicyEnvelope {
  policy_class?: string
  approval_class?: string
  tool_allowlist?: string[]
  model_allowlist?: string[]
  requires_human_for?: string[]
  autonomy_level?: string
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
  autonomy_level?: string
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

export interface CommandPlaneSwarmFlag {
  code: string
  severity: string
  summary: string
}

export interface CommandPlaneSwarmLane {
  lane_id: string
  label: string
  kind: 'managed' | 'projected' | 'supervised' | string
  present: boolean
  phase: string
  motion_state: 'moving' | 'waiting' | 'stalled' | 'terminal' | string
  source_of_truth: string
  last_movement_at?: string | null
  movement_reason: string
  current_step: string
  blockers: string[]
  counts: {
    operations?: number
    detachments?: number
    workers?: number
    approvals?: number
    alerts?: number
  }
  hard_flags: CommandPlaneSwarmFlag[]
}

export interface CommandPlaneSwarmTimelineEvent {
  event_id: string
  lane_id: string
  kind: string
  timestamp: string
  title: string
  detail: string
  tone: string
  source: string
}

export interface CommandPlaneSwarmGap {
  code: string
  severity: string
  summary: string
  why_it_matters?: string
  next_tool?: string
  next_step?: string
  lane_ids: string[]
  count: number
}

export interface CommandPlaneSwarmRecommendation {
  tool: string
  label: string
  reason: string
  lane_id?: string | null
}

export interface CommandPlaneSwarmStatus {
  generated_at?: string
  narrative?: {
    state?: string
    started?: string
    active_work?: string
    completion?: string
    lane_id?: string | null
  }
  overview: {
    active_lanes?: number
    moving_lanes?: number
    stalled_lanes?: number
    projected_lanes?: number
    last_movement_at?: string | null
  }
  lanes: CommandPlaneSwarmLane[]
  timeline: CommandPlaneSwarmTimelineEvent[]
  gaps: {
    count?: number
    items: CommandPlaneSwarmGap[]
  }
  recommended_next_action?: CommandPlaneSwarmRecommendation
}

export interface CommandPlaneSwarmProof {
  status: 'present' | 'fallback' | 'missing' | string
  source: 'artifact' | 'slot_samples' | 'none' | string
  reason_code?: string | null
  status_summary?: string | null
  run_id?: string | null
  captured_at?: string | null
  pass?: boolean
  peak_hot_slots?: number
  ctx_per_slot?: number
  workers: {
    expected?: number
    joined?: number
    current_task_bound?: number
    fresh_heartbeats?: number
    done?: number
    final?: number
  }
  expected_artifact_dir?: string | null
  artifact_ref?: string | null
  missing_reason?: string | null
}

export interface CommandPlaneSnapshot {
  version?: string
  generated_at?: string
  topology: CommandPlaneTopologyResponse
  operations: CommandPlaneOperationsResponse
  detachments: CommandPlaneDetachmentsResponse
  alerts: CommandPlaneAlertsResponse
  decisions: CommandPlaneDecisionsResponse
  capacity: CommandPlaneCapacityResponse
  traces: CommandPlaneTracesResponse
  swarm_status?: CommandPlaneSwarmStatus
}

export interface CommandPlaneSummarySnapshot {
  version?: string
  generated_at?: string
  topology: {
    version?: string
    generated_at?: string
    source?: string
    summary?: CommandPlaneTopologySummary
  }
  operations: {
    version?: string
    generated_at?: string
    summary?: CommandPlaneOperationsResponse['summary']
    microarch?: CommandPlaneMicroarchSummary
  }
  detachments: {
    version?: string
    generated_at?: string
    summary?: CommandPlaneDetachmentsResponse['summary']
  }
  alerts: {
    version?: string
    generated_at?: string
    summary?: CommandPlaneAlertsResponse['summary']
  }
  decisions: {
    version?: string
    generated_at?: string
    summary?: CommandPlaneDecisionsResponse['summary']
  }
  swarm_status?: CommandPlaneSwarmStatus
  swarm_proof?: CommandPlaneSwarmProof
}

export interface ChainRuntimeStatus {
  chain_id?: string | null
  started_at?: number | null
  progress?: number | null
  elapsed_sec?: number | null
}

export interface ChainHistoryEventSummary {
  event: string
  chain_id?: string | null
  timestamp?: string | null
  duration_ms?: number | null
  message?: string | null
  tokens?: number | null
}

export interface CommandPlaneChainOverlay {
  operation: CommandPlaneOperationRecord
  runtime?: ChainRuntimeStatus | null
  history?: ChainHistoryEventSummary | null
  mermaid?: string | null
  preview_run?: CommandPlaneChainRun | null
}

export interface CommandPlaneChainConnection {
  status: 'connected' | 'degraded' | 'disconnected' | string
  base_url?: string | null
  message?: string | null
}

export interface CommandPlaneChainSummary {
  version?: string
  generated_at?: string
  connection: CommandPlaneChainConnection
  summary?: {
    linked_operations?: number
    active_chains?: number
    running_operations?: number
    recent_failures?: number
    last_history_event_at?: string | null
  }
  operations: CommandPlaneChainOverlay[]
  recent_history: ChainHistoryEventSummary[]
}

export interface CommandPlaneChainRunNode {
  id: string
  type?: string
  status?: string
  duration_ms?: number | null
  error?: string | null
}

export interface CommandPlaneChainRun {
  run_id?: string | null
  chain_id: string
  duration_ms?: number | null
  success?: boolean | null
  mermaid?: string
  nodes: CommandPlaneChainRunNode[]
}

export interface CommandPlaneChainRunResponse {
  run?: CommandPlaneChainRun | null
}

export interface CommandPlaneHelpDocLink {
  title: string
  path: string
}

export interface CommandPlaneHelpConcept {
  id: string
  title: string
  summary: string
}

export interface CommandPlaneHelpStep {
  id: string
  title: string
  tool: string
  summary: string
  success_signals: string[]
  pitfalls: string[]
}

export interface CommandPlaneHelpPath {
  id: string
  title: string
  summary: string
  when_to_use: string
  steps: CommandPlaneHelpStep[]
}

export interface CommandPlaneHelpToolGroup {
  id: string
  title: string
  description: string
  tools: string[]
}

export interface CommandPlaneHelpPitfall {
  id: string
  title: string
  symptom: string
  why: string
  fix_tool: string
  fix_summary: string
}

export interface CommandPlaneHelpExample {
  id: string
  title: string
  path_id: string
  transport: string
  request: unknown
  response: unknown
  notes: string[]
}

export interface CommandPlaneHelpResponse {
  version?: string
  generated_at?: string
  docs: CommandPlaneHelpDocLink[]
  concepts: CommandPlaneHelpConcept[]
  golden_paths: CommandPlaneHelpPath[]
  tool_groups: CommandPlaneHelpToolGroup[]
  pitfalls: CommandPlaneHelpPitfall[]
  examples: CommandPlaneHelpExample[]
}

export interface CommandPlaneSwarmChecklistItem {
  id: string
  title: string
  status: 'pass' | 'fail' | 'warn'
  detail: string
  next_tool: string
}

export interface CommandPlaneSwarmBlocker {
  code: string
  severity: 'bad' | 'warn' | 'ok'
  title: string
  detail: string
  next_tool: string
}

export interface CommandPlaneSwarmMessage {
  seq: number
  from: string
  content: string
  timestamp: string
}

export interface CommandPlaneSwarmWorker {
  name: string
  role: string
  lane: string
  joined: boolean
  live_presence: boolean
  completed: boolean
  status: string
  current_task: string | null
  bound_task_id: string | null
  bound_task_title: string | null
  bound_task_status: string | null
  current_task_matches_run: boolean
  squad_member: boolean
  detachment_member: boolean
  last_seen: string | null
  heartbeat_age_sec: number | null
  heartbeat_fresh: boolean
  claim_marker_seen: boolean
  done_marker_seen: boolean
  final_marker_seen: boolean
  claim_marker: string
  done_marker: string
  final_marker: string
  last_message: {
    seq: number
    content: string
    timestamp: string
  } | null
}

export interface CommandPlaneSwarmProviderSample {
  timestamp: string
  active_slots: number
  active_slot_ids: number[]
}

export interface CommandPlaneSwarmProvider {
  slot_url?: string | null
  provider_base_url?: string | null
  provider_reachable?: boolean | null
  provider_status_code?: number | null
  provider_model_id?: string | null
  actual_model_id?: string | null
  expected_slots?: number
  actual_slots?: number
  expected_ctx?: number
  actual_ctx?: number
  configured_capacity?: number
  slot_reachable?: boolean | null
  slot_status_code?: number | null
  runtime_blocker?: string | null
  detail?: string | null
  checked_at?: string | null
  total_slots?: number
  ctx_per_slot?: number
  active_slots_now?: number
  peak_active_slots?: number
  sample_count?: number
  last_sample_at?: string | null
  timeline: CommandPlaneSwarmProviderSample[]
}

export interface CommandPlaneRunResolutionHistoryEntry {
  status: 'continued' | 'rerun' | 'abandoned'
  decided_by: string
  decided_at: string
  reason: string
  operation_id?: string | null
  detachment_id?: string | null
  note?: string | null
}

export interface CommandPlaneRunResolutionState {
  run_id: string
  status: 'continued' | 'rerun' | 'abandoned'
  decided_by: string
  decided_at: string
  reason: string
  operation_id?: string | null
  detachment_id?: string | null
  note?: string | null
  history: CommandPlaneRunResolutionHistoryEntry[]
}

export interface CommandPlaneRunResolutionRecommendation {
  run_id: string
  recommended_kind: 'continue' | 'rerun' | 'abandon'
  continue_available: boolean
  rerun_available: boolean
  abandon_available: boolean
  reason: string
  evidence?: {
    operation_id?: string | null
    detachment_id?: string | null
    joined_workers?: number
    current_task_bound?: number
    fresh_heartbeats?: number
    trace_events?: number
    message_events?: number
    runtime_blocker?: string | null
  }
  provenance?: string
  decision_engine?: string
  authoritative?: boolean
}

export interface CommandPlaneSwarmResponse {
  version?: string
  generated_at?: string
  run_id?: string
  room_id?: string
  operation_id?: string | null
  run_resolution?: CommandPlaneRunResolutionState | null
  resolution_recommendation?: CommandPlaneRunResolutionRecommendation | null
  recommended_next_tool?: string
  summary?: {
    expected_workers?: number
    joined_workers?: number
    live_workers?: number
    squad_roster_size?: number
    detachment_roster_size?: number
    current_task_bound?: number
    fresh_heartbeats?: number
    claim_markers_seen?: number
    done_markers_seen?: number
    final_markers_seen?: number
    completed_workers?: number
    peak_hot_slots?: number
    hot_window_ok?: boolean
    pass_hot_concurrency?: boolean
    pass_end_to_end?: boolean
    pending_decisions?: number
    pass?: boolean
  }
  provider?: CommandPlaneSwarmProvider
  operation?: CommandPlaneOperationRecord | null
  squad?: CommandPlaneUnitRecord | null
  detachment?: CommandPlaneDetachmentRecord | null
  workers: CommandPlaneSwarmWorker[]
  checklist: CommandPlaneSwarmChecklistItem[]
  blockers: CommandPlaneSwarmBlocker[]
  recent_messages: CommandPlaneSwarmMessage[]
  recent_trace_events: CommandPlaneTraceEvent[]
  truth_notes: string[]
}

export interface CommandPlaneOrchestraFact {
  label: string
  value: string
}

export interface CommandPlaneOrchestraNode {
  id: string
  kind: 'room' | 'session' | 'operation' | 'detachment' | 'lane' | 'worker' | 'keeper' | string
  label: string
  subtitle?: string | null
  status?: string | null
  tone: 'ok' | 'warn' | 'bad' | string
  pulse?: string | null
  provenance: 'truth' | 'derived' | 'fallback' | string
  visual_class?: string
  glyph?: string
  parent_id?: string | null
  lane_id?: string | null
  link_tab?: 'command' | 'intervene' | string | null
  link_surface?: CommandPlaneSurface | string | null
  link_params?: Record<string, string>
  facts: CommandPlaneOrchestraFact[]
}

export interface CommandPlaneOrchestraEdge {
  id: string
  source: string
  target: string
  kind: string
  label?: string | null
  tone: 'ok' | 'warn' | 'bad' | string
  provenance: 'truth' | 'derived' | 'fallback' | string
  animated?: boolean
}

export interface CommandPlaneOrchestraSignal {
  id: string
  kind: string
  label: string
  detail?: string | null
  tone: 'ok' | 'warn' | 'bad' | string
  provenance: 'truth' | 'derived' | 'fallback' | string
  source_id?: string | null
  target_id?: string | null
  suggested_surface?: CommandPlaneSurface | string | null
  suggested_params?: Record<string, string>
}

export interface CommandPlaneOrchestraFocus {
  target_kind: 'node' | 'signal' | string
  target_id: string
  label: string
  reason: string
  suggested_surface?: CommandPlaneSurface | string | null
  suggested_params?: Record<string, string>
}

export interface CommandPlaneOrchestraResponse {
  version?: string
  generated_at?: string
  room: {
    room_id?: string
    project?: string
    cluster?: string
    paused?: boolean
    pause_reason?: string | null
    agent_count?: number
    task_count?: number
    message_count?: number
  }
  summary?: {
    session_count?: number
    operation_count?: number
    detachment_count?: number
    lane_count?: number
    worker_count?: number
    keeper_count?: number
    signal_count?: number
    alert_count?: number
  }
  nodes: CommandPlaneOrchestraNode[]
  edges: CommandPlaneOrchestraEdge[]
  signals: CommandPlaneOrchestraSignal[]
  focus?: CommandPlaneOrchestraFocus | null
  swarm_status?: CommandPlaneSwarmStatus
  swarm_proof?: CommandPlaneSwarmProof
  truth_notes?: string[]
}

export type CommandPlaneSurface =
  | 'warroom'
  | 'summary'
  | 'orchestra'
  | 'swarm'
  | 'operations'
  | 'topology'
  | 'alerts'
  | 'trace'
  | 'chains'
  | 'control'

