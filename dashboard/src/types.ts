// MASC Dashboard — Shared type definitions
// Extracted from the existing vanilla JS dashboard globals

// --- Core entities ---

export interface Agent {
  name: string
  status: 'active' | 'busy' | 'listening' | 'idle' | 'inactive' | 'offline'
  current_task: string | null
  context_ratio?: number
  last_seen?: string
  emoji?: string
  koreanName?: string
  model?: string
  traits?: string[]
  interests?: string[]
  activityLevel?: number
  preferredHours?: number[]
  peakHour?: number
  primaryValue?: string
  personalityHint?: string
}

export interface Task {
  id: string
  title: string
  status: 'todo' | 'in_progress' | 'claimed' | 'done' | 'cancelled'
  priority?: number
  assignee?: string
  description?: string
  created_at?: string
  updated_at?: string
}

export interface Message {
  id?: string
  seq?: number
  from: string
  content: string
  timestamp: string
  type?: string
}

// --- Board ---

export interface BoardPost {
  id: string
  author: string
  title: string
  content: string
  tags: string[]
  votes: number
  vote_balance?: number
  comment_count: number
  created_at: string
  updated_at: string
  flair?: string
  hearth_count?: number
}

export interface BoardComment {
  id: string
  post_id: string
  author: string
  content: string
  created_at: string
}

export interface BoardHearth {
  post_id: string
  agent: string
  created_at: string
}

export interface BoardFlair {
  name: string
  emoji: string
  color: string
}

// --- Keeper Metrics ---

export interface KeeperMetricPoint {
  ts: number
  context_ratio: number
  context_tokens: number
  context_max: number
  latency_ms: number
  generation: number
  channel: string
  is_handoff: boolean
  is_compaction: boolean
  compaction_saved_tokens: number
  compaction_trigger: string | null
  model_used: string
  cost_usd: number
  handoff_to_model: string | null
  handoff_new_generation: number | null
}

export type KeeperLifecycleState =
  | 'active'
  | 'compacting'
  | 'preparing'
  | 'handoff-imminent'
  | 'idle'
  | 'offline'

// --- Keeper SSE Events ---

export interface KeeperHeartbeatEvent {
  type: 'keeper_heartbeat'
  name: string
  generation: number
  context_ratio: number
  ts_unix: number
}

export interface KeeperHandoffEvent {
  type: 'keeper_handoff'
  name: string
  from_generation: number
  to_generation: number
  from_model: string
  to_model: string
  ts_unix: number
}

export interface KeeperCompactionEvent {
  type: 'keeper_compaction'
  name: string
  generation: number
  before_tokens: number
  after_tokens: number
  saved_tokens: number
  trigger: string
  ts_unix: number
}

export interface KeeperGuardrailEvent {
  type: 'keeper_guardrail'
  name: string
  generation: number
  reason: string
  ts_unix: number
}

// --- Keeper Autonomy ---

export type AutonomyLevel = 'L1_Reactive' | 'L2_Suggestive' | 'L3_Guided' | 'L4_Autonomous' | 'L5_Independent'

export interface Goal {
  id: string
  horizon: 'short' | 'mid' | 'long'
  title: string
  metric?: string | null
  target_value?: string | null
  due_date?: string | null
  priority: number
  status: string
  parent_goal_id?: string | null
  last_review_note?: string | null
  last_review_at?: string | null
  created_at: string
  updated_at: string
}

export interface KeeperAutonomyInfo {
  autonomy_level: AutonomyLevel
  active_goal_ids: string[]
  last_autonomous_action_at?: string | null
  autonomous_action_count: number
}

// --- Keeper / Lodge ---

export type KeeperHealthState = 'healthy' | 'idle' | 'stale' | 'degraded' | 'offline'

export type KeeperQuietReason =
  | 'quiet_hours'
  | 'min_gap'
  | 'no_recent_activity'
  | 'disabled'
  | 'startup'
  | 'llm_error'
  | 'graphql_error'
  | 'never_started'
  | 'unknown'

export type KeeperNextActionPath =
  | 'direct_message'
  | 'manual_lodge_poke'
  | 'probe'
  | 'recover'

export type KeeperReplyStatus =
  | 'never'
  | 'awaiting_reply'
  | 'delivered'
  | 'fresh'
  | 'stale'
  | 'error'
  | 'unknown'

export interface KeeperDiagnostic {
  health_state: KeeperHealthState
  quiet_reason?: KeeperQuietReason | null
  next_action_path: KeeperNextActionPath
  last_reply_status: KeeperReplyStatus
  last_reply_at?: string | null
  last_reply_preview?: string | null
  last_error?: string | null
  next_eligible_at_s?: number | null
  recoverable?: boolean
  summary?: string
  keepalive_running?: boolean
}

export type KeeperConversationRole = 'user' | 'assistant' | 'system' | 'tool' | 'other'

export type KeeperConversationDelivery =
  | 'history'
  | 'sending'
  | 'delivered'
  | 'timeout'
  | 'error'

export interface KeeperConversationEntry {
  id: string
  role: KeeperConversationRole
  label: string
  text: string
  timestamp?: string | null
  delivery: KeeperConversationDelivery
  error?: string | null
}

export interface KeeperStatusDetail {
  name: string
  diagnostic?: KeeperDiagnostic | null
  history: KeeperConversationEntry[]
  rawText: string
  rawStatus?: unknown
  loadedAt: string
}

export interface Keeper {
  name: string
  emoji?: string
  koreanName?: string
  agent_name?: string
  trace_id?: string
  model?: string
  primary_model?: string
  active_model?: string
  next_model_hint?: string | null
  status: string
  presence_keepalive?: boolean
  presence_keepalive_sec?: number
  keepalive_running?: boolean
  proactive_enabled?: boolean
  proactive_idle_sec?: number
  proactive_cooldown_sec?: number
  // Autonomy fields (Phase 2)
  autonomy_level?: AutonomyLevel
  active_goal_ids?: string[]
  last_autonomous_action_at?: string | null
  autonomous_action_count?: number
  created_at?: string
  updated_at?: string
  last_heartbeat?: string
  keeper_age_s?: number
  last_turn_ago_s?: number
  last_handoff_ago_s?: number
  last_compaction_ago_s?: number
  last_proactive_ago_s?: number
  last_proactive_reason?: string | null
  last_drift_reason?: string | null
  drift_count_total?: number
  generation?: number
  turn_count?: number
  context_ratio?: number
  context_tokens?: number
  context_max?: number
  context_source?: string
  context?: {
    source?: string
    context_ratio?: number
    context_tokens?: number
    context_max?: number
    message_count?: number
    has_checkpoint?: boolean
  }
  traits?: string[]
  interests?: string[]
  primaryValue?: string
  activityLevel?: number
  will?: string | null
  needs?: string | null
  desires?: string | null
  memory_recent_note?: string | null
  conversation_tail_count?: number
  k2k_count?: number
  k2k_mentions?: Array<{ keeper: string; count: number }>
  handoff_count_total?: number
  compaction_count?: number
  last_compaction_saved_tokens?: number
  diagnostic?: KeeperDiagnostic | null
  skill_primary?: string | null
  skill_secondary?: string[]
  skill_reason?: string | null
  metrics_window?: {
    fallback_rate?: number
    model_fallback_rate?: number
    proactive_fallback_rate?: number
    proactive_preview_similarity_avg?: number
    memory_pass_rate?: number
    memory_avg_score?: number
    handoff_count?: number
    compaction_events?: number
    compaction_saved_tokens?: number
    tool_call_count?: number
    [key: string]: unknown
  }
  agent?: {
    name?: string
    exists?: boolean
    error?: string
    status?: string
    current_task?: string | null
    last_seen?: string
    last_seen_ago_s?: number
    is_zombie?: boolean
    [key: string]: unknown
  }
  // Metrics time-series (from backend metrics_series)
  metrics_series?: KeeperMetricPoint[]
  // TRPG-specific keeper fields
  trpg_stats?: TrpgCharacterStats
  inventory?: string[]
  relationships?: Record<string, string>
}

// --- TRPG ---

export interface TrpgCharacterStats {
  hp: number
  max_hp: number
  mp: number
  max_mp: number
  level: number
  xp: number
  strength: number
  dexterity: number
  constitution: number
  intelligence: number
  wisdom: number
  charisma: number
}

export interface TrpgActor {
  id: string
  name: string
  role: 'dm' | 'player' | 'npc'
  keeper?: string
  archetype?: string
  persona?: string
  portrait?: string
  background?: string
  traits?: string[]
  skills?: string[]
  stats?: TrpgCharacterStats
  stats_raw?: Record<string, number>
  status: string
}

export interface TrpgRound {
  round_number: number
  phase: string
  events: TrpgEvent[]
  timestamp: string
}

export interface TrpgEvent {
  type: string
  actor?: string
  actor_id?: string
  actor_name?: string
  seq?: number
  room_id?: string
  phase?: string
  category?: string
  visibility?: string
  event_id?: string
  content: string
  dice_roll?: DiceRoll
  timestamp: string
}

export interface DiceRoll {
  notation: string
  rolls: number[]
  total: number
  modifier?: number
}

export interface TrpgSession {
  id: string
  room: string
  status: 'active' | 'paused' | 'ended'
  round: number
  actors: TrpgActor[]
  created_at: string
}

export interface TrpgOutcome {
  result: 'victory' | 'defeat' | 'draw'
  reason?: string
  summary?: string
  turn?: number
  phase?: string
}

export interface TrpgJoinGate {
  phase_open: boolean
  min_points: number
  window: string
  last_opened_turn?: number | null
  last_closed_turn?: number | null
}

export interface TrpgContributionEntry {
  actor_id: string
  score: number
  last_reason?: string | null
  reasons?: string[]
}

export interface TrpgState {
  session?: TrpgSession
  current_round?: TrpgRound
  map?: string
  join_gate?: TrpgJoinGate
  contribution_ledger?: TrpgContributionEntry[]
  outcome?: TrpgOutcome
  party: TrpgActor[]
  story_log: TrpgEvent[]
  history: TrpgSession[]
}

// --- MDAL (Metric-Driven Agent Loop) ---

export type MdalEvidenceStatus = 'verified' | 'legacy_unverified'

export interface MdalIterationEvidence {
  worker_engine: 'api_tool_loop'
  worker_model: string
  tool_call_count: number
  tool_names: string[]
  session_id: string
  evidence_status: MdalEvidenceStatus
}

export interface MdalIterationRecord {
  iteration: number
  metric_before: number
  metric_after: number
  delta: number
  changes: string
  failed_attempts: string
  next_suggestion: string
  elapsed_ms: number
  cost_usd: number | null
  evidence?: MdalIterationEvidence | null
}

export interface MdalLoop {
  loop_id: string
  profile: string
  status: 'running' | 'interrupted' | 'completed' | 'stopped' | 'error'
  strict_mode?: boolean
  error_message?: string | null
  stop_reason?: string | null
  current_iteration: number
  max_iterations: number
  baseline_metric: number
  current_metric: number
  target: string
  stagnation_streak: number
  stagnation_limit: number
  elapsed_seconds: number
  updated_at?: string | null
  stopped_at?: string | null
  execution_mode?: 'worker_spawn'
  worker_engine?: 'api_tool_loop' | null
  worker_model?: string | null
  evidence_policy?: 'hard' | 'legacy'
  latest_tool_call_count?: number
  latest_tool_names?: string[]
  session_id?: string | null
  evidence_status?: MdalEvidenceStatus | null
  durability?: 'persistent_backend' | 'memory_only'
  persistence_backend?: 'filesystem' | 'postgres' | 'memory'
  recoverable?: boolean
  history: MdalIterationRecord[]
}

// --- Perpetual Agent ---

export interface PerpetualStatus {
  running: boolean
  goal?: string
  turn?: number
  generation?: number
  context_ratio?: number
  model?: string
  cost_usd?: number
}

// --- Council ---

export interface CouncilDebate {
  id: string
  topic: string
  status: string
  argument_count: number
  created_at?: string
}

export interface CouncilSession {
  id: string
  topic: string
  initiator: string
  votes: number
  quorum: number
  threshold?: number
  state?: string
  created_at?: string
}

export interface CouncilDebateSummary {
  id: string
  topic: string
  status: string
  support_count: number
  oppose_count: number
  neutral_count: number
  total_arguments: number
  created_at?: string
  summary_text?: string
}

export interface BoardMonitoring {
  alert_level?: 'ok' | 'warn' | 'bad' | string
  posts_total?: number
  new_posts_24h?: number
  unanswered_posts?: number
  last_activity_age_s?: number | null
  slo_target_age_s?: number
  slo_breached?: boolean
  warn_age_s?: number
  bad_age_s?: number
}

export interface CouncilMonitoring {
  alert_level?: 'ok' | 'warn' | 'bad' | string
  debates_open?: number
  debates_pending?: number
  sessions_active?: number
  sessions_without_quorum?: number
  oldest_open_debate_age_s?: number | null
  last_activity_age_s?: number | null
  slo_target_quorum_age_s?: number
  slo_breached?: boolean
  warn_age_s?: number
  bad_age_s?: number
}

export interface LodgeCheckinResult {
  name: string
  trigger?: string
  outcome?: 'acted' | 'passed' | 'skipped' | string
  summary?: string
  reason?: string
}

export interface LodgeTickResult {
  hour?: number
  checked: number
  acted: number
  acted_names: string[]
  activity_report?: string
  quiet_hours_overridden?: boolean
  skipped_reason?: string
  acted_rows?: Array<{ name: string; summary?: string }>
  passed_rows?: Array<{ name: string; reason?: string }>
  skipped_rows?: Array<{ name: string; reason?: string }>
  checkins?: LodgeCheckinResult[]
}

export interface LodgeRuntimeStatus {
  enabled: boolean
  interval_s: number
  quiet_start?: number
  quiet_end?: number
  quiet_active?: boolean
  use_planner?: boolean
  delegate_llm?: boolean
  agent_count?: number
  agents?: string[]
  last_tick_ago_s?: number | null
  last_tick_ago?: string
  total_ticks?: number
  total_checkins?: number
  last_skip_reason?: string | null
  last_tick_result?: LodgeTickResult | null
  active_self_heartbeats?: string[]
}

// --- Dashboard batch response ---

export interface DashboardData {
  agents: { agents: Agent[] }
  tasks: { tasks: Task[] }
  messages: { messages: Message[] }
  status: ServerStatus
  keepers: Keeper[] | { keepers: Keeper[] }
  perpetual: PerpetualStatus
}

export interface OperatorRoomSnapshot {
  room_id?: string
  current_room?: string
  project?: string
  cluster?: string
  paused?: boolean
  pause_reason?: string | null
  paused_by?: string | null
  paused_at?: string | null
}

export interface OperatorSessionSnapshot {
  session_id: string
  command_plane_operation_id?: string
  command_plane_detachment_id?: string
  status?: string
  progress_pct?: number
  elapsed_sec?: number
  remaining_sec?: number
  done_delta_total?: number
  summary?: Record<string, unknown>
  team_health?: Record<string, unknown>
  communication_metrics?: Record<string, unknown>
  orchestration_state?: Record<string, unknown>
  cascade_metrics?: Record<string, unknown>
  report_paths?: Record<string, string>
  session?: Record<string, unknown>
  recent_events?: Record<string, unknown>[]
}

export interface OperatorKeeperSnapshot {
  name: string
  agent_name?: string
  status?: string
  autonomy_level?: string
  context_ratio?: number
  generation?: number
  active_goal_ids?: string[]
  last_autonomous_action_at?: string | null
  last_turn_ago_s?: number
  model?: string
}

export interface PendingConfirmation {
  confirm_token: string
  actor?: string
  action_type?: string
  target_type?: string
  target_id?: string | null
  delegated_tool?: string
  created_at?: string
  preview?: unknown
}

export interface OperatorActionDescriptor {
  action_type: string
  target_type: string
  description?: string
  confirm_required?: boolean
}

export interface KeeperProbeResult {
  status?: unknown
  diagnostic?: KeeperDiagnostic | null
}

export interface KeeperRecoverResult {
  recovered: boolean
  skipped_reason?: string | null
  before?: KeeperDiagnostic | null
  after?: KeeperDiagnostic | null
  down?: unknown
  up?: unknown
}

export interface OperatorSnapshot {
  room: OperatorRoomSnapshot
  sessions: OperatorSessionSnapshot[]
  keepers: OperatorKeeperSnapshot[]
  command_plane?: CommandPlaneSnapshot
  swarm_status?: CommandPlaneSwarmStatus
  recent_messages: Message[]
  pending_confirms: PendingConfirmation[]
  available_actions: OperatorActionDescriptor[]
}

export type OperatorActionType =
  | 'broadcast'
  | 'room_pause'
  | 'room_resume'
  | 'lodge_tick'
  | 'team_turn'
  | 'team_note'
  | 'team_broadcast'
  | 'team_task_inject'
  | 'team_stop'
  | 'keeper_msg'
  | 'keeper_message'
  | 'keeper_probe'
  | 'keeper_recover'
  | 'task_inject'

export type OperatorTargetType = 'room' | 'team_session' | 'keeper'

export interface OperatorActionRequest {
  actor: string
  action_type: OperatorActionType
  target_type: OperatorTargetType
  target_id?: string
  payload: Record<string, unknown>
}

export interface OperatorActionResult {
  status: string
  confirm_required?: boolean
  confirm_token?: string
  preview?: unknown
  delegated_tool?: string
  result?: unknown
  executed_action?: unknown
  delegated_tool_result?: unknown
}

export interface OperatorActionLogEntry {
  id: number
  at: string
  actor: string
  action_type: string
  target_label: string
  outcome: 'preview' | 'executed' | 'confirmed' | 'error'
  message: string
  delegated_tool?: string
}

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
  total_slots?: number
  ctx_per_slot?: number
  active_slots_now?: number
  peak_active_slots?: number
  sample_count?: number
  last_sample_at?: string | null
  timeline: CommandPlaneSwarmProviderSample[]
}

export interface CommandPlaneSwarmResponse {
  version?: string
  generated_at?: string
  run_id?: string
  room_id?: string
  operation_id?: string | null
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

export type CommandPlaneSurface =
  | 'summary'
  | 'swarm'
  | 'operations'
  | 'topology'
  | 'alerts'
  | 'trace'
  | 'chains'
  | 'control'

export interface ServerStatus {
  room?: string
  room_base_path?: string
  cluster?: string
  project?: string
  paused?: boolean
  version?: string
  uptime_seconds?: number
  tempo_interval_s?: number
  tempo?: string
  tool_call_health?: {
    timeouts: number
    p95_duration_ms: number | null
    window_hours: number
  }
  alert_thresholds?: {
    proactive_fallback_warn: number
    proactive_fallback_bad: number
    proactive_similarity_warn: number
    proactive_similarity_bad: number
    toast_cooldown_sec: number
  }
  monitoring?: {
    board?: BoardMonitoring
    council?: CouncilMonitoring
  }
  lodge?: LodgeRuntimeStatus
  data_quality?: {
    board_contract_ok?: boolean
    council_feed_ok?: boolean
    last_sync_at?: string
  }
}

// --- SSE Events ---

export type SSEEventType =
  | 'agent_joined'
  | 'agent_left'
  | 'broadcast'
  | 'task_update'
  | 'board_post'
  | 'masc/board_post'
  | 'board_comment'
  | 'masc/board_comment'
  | 'heartbeat'
  | 'keeper_heartbeat'
  | 'keeper_handoff'
  | 'keeper_compaction'
  | 'keeper_guardrail'
  | 'mdal_started'
  | 'mdal_iteration'
  | 'mdal_completed'
  | 'mdal_stopped'

export interface SSEEvent {
  type: SSEEventType
  agent?: string
  from?: string
  from_agent?: string
  message?: string
  content?: string
  task_id?: string
  status?: string
  post_id?: string
  author?: string
  // Keeper event fields
  name?: string
  generation?: number
  context_ratio?: number
  ts_unix?: number
  from_generation?: number
  to_generation?: number
  from_model?: string
  to_model?: string
  before_tokens?: number
  after_tokens?: number
  saved_tokens?: number
  trigger?: string
  reason?: string
  // MDAL event fields
  loop_id?: string
  profile?: string
  baseline?: number
  target?: string
  final_metric?: number
  iterations?: number
  iteration?: number
  metric_before?: number
  metric_after?: number
  delta?: number
}

// --- Journal ---

export type JournalEventType =
  | 'agent_joined'
  | 'agent_left'
  | 'broadcast'
  | 'task_update'
  | 'board_post'
  | 'board_comment'
  | 'keeper_heartbeat'
  | 'keeper_handoff'
  | 'keeper_compaction'
  | 'keeper_guardrail'
  | 'unknown'

export interface JournalEntry {
  agent: string
  text: string
  timestamp: number
  kind?: 'board' | 'tasks' | 'keepers' | 'system'
  eventType?: JournalEventType
  author?: string
  preview?: string
  postId?: string
}

// --- Sort modes ---

export type BoardSortMode = 'hot' | 'trending' | 'recent' | 'updated' | 'discussed'

// --- Route state ---

export interface RouteState {
  tab: TabId
  params: Record<string, string>
  postId: string | null
}

export type TabId =
  | 'command'
  | 'overview'
  | 'board'
  | 'goals'
  | 'agents'
  | 'ops'
  | 'trpg'

export const VALID_TABS: TabId[] = [
  'command',
  'overview',
  'board',
  'goals',
  'agents',
  'ops',
  'trpg',
]
