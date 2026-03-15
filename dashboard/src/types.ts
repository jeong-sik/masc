// MASC Dashboard — Shared type definitions
// Extracted from the existing vanilla JS dashboard globals

// --- Core entities ---

export interface Agent {
  name: string
  agent_type?: string
  status: 'active' | 'busy' | 'listening' | 'idle' | 'inactive' | 'offline'
  current_task: string | null
  context_ratio?: number
  joined_at?: string
  last_seen?: string
  capabilities?: string[]
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
  post_kind?: 'human' | 'automation' | 'system'
  title: string
  body: string
  content: string
  meta?: {
    source?: string | null
    state_block?: string | null
  } | null
  tags: string[]
  votes: number
  vote_balance?: number
  comment_count: number
  created_at: string
  updated_at: string
  flair?: string
  hearth?: string | null
  visibility?: string
  expires_at?: string | null
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

export type KeeperContinuityState =
  | 'desired_offline'
  | 'recovering'
  | 'healthy'
  | 'offline'

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
  continuity_state?: KeeperContinuityState | null
  continuity_summary?: string | null
}

export type KeeperConversationRole = 'user' | 'assistant' | 'system' | 'tool' | 'other'

export type KeeperConversationDelivery =
  | 'history'
  | 'sending'
  | 'streaming'
  | 'delivered'
  | 'timeout'
  | 'error'

export interface KeeperConversationUsage {
  inputTokens?: number | null
  outputTokens?: number | null
  totalTokens?: number | null
}

export interface KeeperConversationDetails {
  traceId?: string | null
  generation?: number | null
  modelUsed?: string | null
  latencyMs?: number | null
  costUsd?: number | null
  usage?: KeeperConversationUsage | null
  skillPrimary?: string | null
  skillReason?: string | null
  stateBlock?: string | null
  rawPayload?: unknown
}

export type KeeperConversationStreamState =
  | 'opening'
  | 'streaming'
  | 'finalizing'
  | null

export interface KeeperConversationEntry {
  id: string
  role: KeeperConversationRole
  label: string
  text: string
  timestamp?: string | null
  delivery: KeeperConversationDelivery
  streamState?: KeeperConversationStreamState
  details?: KeeperConversationDetails | null
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
  runtime_class?: 'resident_keeper' | 'persistent_agent'
  desired?: boolean
  resident_registered?: boolean
  reconcile_status?: string | null
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
  last_proactive_preview?: string | null
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
  recent_input_preview?: string | null
  recent_output_preview?: string | null
  recent_tool_names?: string[]
  allowed_tool_names?: string[]
  latest_tool_names?: string[]
  latest_tool_call_count?: number | null
  tool_audit_source?: string | null
  tool_audit_at?: string | null
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
    agent_type?: string
    status?: string
    current_task?: string | null
    joined_at?: string
    last_seen?: string
    last_seen_ago_s?: number
    capabilities?: string[]
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

// --- Governance ---

export interface GovernanceContextRef {
  board_post_id?: string | null
  task_id?: string | null
  operation_id?: string | null
  team_session_id?: string | null
}

export interface GovernanceResolvedAction {
  action_kind?: string
  resolved_tool?: string | null
  target_type?: string | null
  target_id?: string | null
  reason?: string
  payload_preview?: unknown
}

export interface GovernanceExecutedRoute {
  action_type?: string
  delegated_tool?: string | null
  confirmation_state?: string
  created_at?: string | null
}

export interface GovernanceGuardrailState {
  requires_human_gate?: boolean
  pending_confirm?: PendingConfirmation | null
  pending_confirm_token?: string | null
  ready_to_execute?: boolean
}

export interface PendingConfirmEnvelope {
  items: PendingConfirmation[]
  summary: PendingConfirmSummary
}

export interface GovernanceJudgment {
  judgment_id?: string
  target_kind?: string
  target_id?: string
  status?: string
  summary?: string
  confidence?: number | null
  generated_at?: string | null
  expires_at?: string | null
  model_used?: string | null
  keeper_name?: string | null
  evidence_refs?: string[]
  recommended_action?: GovernanceResolvedAction | null
  guardrail_state?: GovernanceGuardrailState | null
  executed_route?: GovernanceExecutedRoute | null
}

export interface GovernanceDecisionItem {
  kind: 'case' | string
  id: string
  topic: string
  status: string
  origin?: string | null
  subject_type?: string | null
  risk_class?: 'low' | 'high' | string | null
  provenance?: string | null
  auto_execution_state?: string | null
  petition_count?: number
  brief_count?: number
  last_activity_at?: string | null
  truth_summary?: string
  judgment_summary?: string | null
  confidence?: number | null
  related_agents: string[]
  context?: GovernanceContextRef
  linked_board_post_id?: string | null
  linked_task_id?: string | null
  linked_operation_id?: string | null
  linked_session_id?: string | null
  recommended_action?: GovernanceResolvedAction | null
  executed_route?: GovernanceExecutedRoute | null
  guardrail_state?: GovernanceGuardrailState | null
  evidence_refs: string[]
}

export interface GovernancePetition {
  id: string
  case_id: string
  title: string
  origin?: string | null
  subject_type?: string | null
  risk_class?: 'low' | 'high' | string | null
  source_refs: string[]
  created_by?: string | null
  created_at?: string | null
}

export interface GovernanceCaseBrief {
  id: string
  author: string
  stance: 'support' | 'oppose' | 'neutral' | string
  summary: string
  evidence_refs: string[]
  created_at?: string | null
}

export interface GovernanceExecutionOrder {
  id: string
  case_id: string
  status: 'queued_auto' | 'needs_human_gate' | 'auto_executed' | 'done' | 'denied' | 'blocked' | string
  risk_class?: 'low' | 'high' | string | null
  action_request?: GovernanceResolvedAction | null
  created_at?: string | null
  updated_at?: string | null
  execution_ref?: string | null
  result_summary?: string | null
  actor?: string | null
}

export interface GovernanceCaseBundle {
  case: {
    id: string
    petition_ids: string[]
    title: string
    origin?: string | null
    subject_type?: string | null
    risk_class?: 'low' | 'high' | string | null
    status: string
    created_at?: string | null
    updated_at?: string | null
    source_refs: string[]
    briefs: GovernanceCaseBrief[]
  }
  petitions: GovernancePetition[]
  ruling?: GovernanceJudgment | null
  execution_order?: GovernanceExecutionOrder | null
}

export interface GovernanceTimelineEvent {
  kind: string
  item_kind?: string
  item_id?: string
  topic?: string
  created_at?: string | null
  summary?: string
  actor?: string | null
  index?: number
  decision?: string | null
}

export interface GovernanceJudgeSummary {
  judge_online?: boolean
  refreshing?: boolean
  generated_at?: string | null
  expires_at?: string | null
  model_used?: string | null
  keeper_name?: string | null
  last_error?: string | null
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

export interface GovernanceMonitoring {
  alert_level?: 'ok' | 'warn' | 'bad' | string
  cases_open?: number
  pending_ruling?: number
  ready_auto_execute?: number
  needs_human_gate?: number
  executed?: number
  blocked?: number
  oldest_open_case_age_s?: number | null
  last_activity_age_s?: number | null
  slo_target_case_age_s?: number
  slo_breached?: boolean
  judge_online?: boolean
  warn_age_s?: number
  bad_age_s?: number
}

export interface SocialRuntimeStatus {
  enabled: boolean
  strategy?: string
  queue_depth?: number
  processed_events?: number
  active_keepers?: number
  last_event_at?: string | null
  last_social_action_at?: string | null
  last_pass_reason?: string | null
  last_system_skip_reason?: string | null
  total_checks?: number
  total_acted?: number
  total_passed?: number
  total_skipped?: number
  total_failed?: number
  last_result?: {
    checked?: number
    acted?: number
    passed?: number
    skipped?: number
    failed?: number
    last_tick_at?: string | null
    last_pass_reason?: string | null
    last_system_skip_reason?: string | null
    activity_report?: string | null
    checkins?: LodgeCheckinResult[]
  } | null
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
  skipped_reason?: string | null
  last_pass_reason?: string | null
  last_system_skip_reason?: string | null
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
  last_pass_reason?: string | null
  last_system_skip_reason?: string | null
  last_tick_result?: LodgeTickResult | null
  active_self_heartbeats?: string[]
}

export interface GardenerRuntimeStatus {
  enabled: boolean
  alive: boolean
  status?: string
  tick_in_progress?: boolean
  tick_count?: number
  check_interval_sec?: number
  last_tick_started_at?: string | null
  last_tick_completed_at?: string | null
  next_tick_due_at?: string | null
  last_health_check_at?: string | null
  last_intervention?: string
  last_decision_source?: string
  last_action?: string
  last_target?: string | null
  last_reason?: string | null
  last_error?: string | null
  circuit_open?: boolean
  circuit_open_until?: string | null
  can_spawn?: boolean
  can_retire?: boolean
  last_spawn_attempt_at?: string | null
  last_retirement_attempt_at?: string | null
  spawns_today?: number
  retirements_today?: number
  health_summary?: {
    total_agents?: number
    active_agents?: number
    idle_agents?: number
    todo_count?: number
    high_priority_todo?: number
    orphan_count?: number
    homeostatic_score?: number
    needs_workers?: boolean
  }
}

export interface GuardianRuntimeStatus {
  enabled: boolean
  mode?: string
  masc_enabled?: boolean
  masc_loops_running?: boolean
  runtime_owner?: string | null
  zombie_loop_running?: boolean
  gc_loop_running?: boolean
  lodge_enabled?: boolean
  lodge_loop_started?: boolean
  lodge_running?: boolean
  last_zombie_cleanup?: string | null
  last_gc?: string | null
  last_lodge?: string | null
  last_zombie_result?: string | null
  last_gc_result?: string | null
  last_lodge_result?: {
    ok?: boolean
    message?: string
  } | null
}

export interface SentinelRuntimeStatus {
  enabled: boolean
  started: boolean
  agent_name?: string | null
  llm_enabled?: boolean
  uptime_s?: number
  embedded_guardian_loops_running?: boolean
  guardian_runtime_owner?: string | null
  consumers?: string[]
}

// --- Dashboard projection responses ---

export interface DashboardShellResponse {
  generated_at?: string
  status: ServerStatus
  counts?: {
    agents?: number
    tasks?: number
    keepers?: number
  }
}

export interface DashboardRoomTruthAttentionSummary {
  count: number
  bad_count: number
  warn_count: number
  provenance?: string | null
  top_item?: OperatorAttentionItem | null
}

export interface DashboardRoomTruthRecommendationSummary {
  count: number
  provenance?: string | null
  top_action?: OperatorRecommendedAction | null
}

export interface DashboardRoomTruthFocus {
  label: string
  reason: string
  source: string
  provenance: string
  target_kind?: string | null
  target_id?: string | null
  suggested_tab?: 'command' | 'intervene' | string | null
  suggested_surface?: CommandPlaneSurface | string | null
  suggested_params?: Record<string, string>
}

export interface DashboardRoomTruthResponse {
  generated_at?: string
  room: {
    status?: ServerStatus | null
    counts?: DashboardShellResponse['counts']
    provenance?: string | null
  }
  execution?: {
    summary?: DashboardExecutionSummary | null
    top_queue?: DashboardExecutionQueueItem | null
    provenance?: string | null
  }
  command?: {
    active_operations?: number
    active_detachments?: number
    pending_approvals?: number
    bad_alerts?: number
    warn_alerts?: number
    moving_lanes?: number
    active_lanes?: number
    provenance?: string | null
  }
  operator?: {
    health?: string | null
    attention_summary?: DashboardRoomTruthAttentionSummary | null
    recommendation_summary?: DashboardRoomTruthRecommendationSummary | null
    pending_confirm_summary?: PendingConfirmSummary | null
    provenance?: string | null
  }
  focus?: DashboardRoomTruthFocus | null
}

export interface ServerBuildIdentity {
  release_version: string
  commit?: string | null
  started_at: string
  uptime_seconds: number
}

export type DashboardExecutionTone = 'ok' | 'warn' | 'bad'
export type DashboardExecutionWorkerState = 'working' | 'watching' | 'quiet' | 'offline'
export type DashboardExecutionContinuityState = 'healthy' | 'warning' | 'critical'
export type DashboardExecutionQueueKind = 'session' | 'operation'

export interface DashboardExecutionSummary {
  active_sessions?: number
  blocked_sessions?: number
  active_operations?: number
  blocked_operations?: number
  runtime_pressure?: number
  worker_alerts?: number
  continuity_alerts?: number
  priority_items?: number
  todo_tasks?: number
  claimed_tasks?: number
  running_tasks?: number
  done_tasks?: number
  cancelled_tasks?: number
  keepers?: number
}

export interface DashboardExecutionHandoff {
  surface: 'intervene' | 'command'
  label: string
  target_type: string
  target_id: string
  focus_kind: string
  operation_id?: string | null
  command_surface?: string | null
}

export interface DashboardExecutionQueueItem {
  id: string
  kind: DashboardExecutionQueueKind
  severity: DashboardExecutionTone
  status?: string
  summary: string
  target_type: string
  target_id: string
  linked_session_id?: string | null
  linked_operation_id?: string | null
  last_seen_at?: string | null
  top_handoff?: DashboardExecutionHandoff | null
  intervene_handoff?: DashboardExecutionHandoff | null
  command_handoff?: DashboardExecutionHandoff | null
}

export interface DashboardExecutionSessionBrief {
  session_id: string
  goal: string
  room?: string | null
  status?: string
  health?: string
  member_names: string[]
  linked_operation_id?: string | null
  linked_detachment_id?: string | null
  runtime_blocker?: string | null
  worker_gap_summary?: string | null
  last_activity_at?: string | null
  last_activity_summary?: string | null
  communication_summary?: string | null
  active_count?: number
  seen_count?: number
  planned_count?: number
  required_count?: number
  counts_basis?: string | null
  top_handoff?: DashboardExecutionHandoff | null
  intervene_handoff?: DashboardExecutionHandoff | null
  command_handoff?: DashboardExecutionHandoff | null
}

export interface DashboardExecutionOperationBrief {
  operation_id: string
  objective: string
  status?: string
  stage?: string | null
  assigned_unit_id?: string | null
  assigned_unit_label?: string | null
  linked_session_id?: string | null
  linked_detachment_id?: string | null
  blocker_summary?: string | null
  search_status?: string | null
  next_tool?: string | null
  updated_at?: string | null
  top_handoff?: DashboardExecutionHandoff | null
  command_handoff?: DashboardExecutionHandoff | null
}

export interface DashboardExecutionWorkerSupportBrief {
  name: string
  agent_name?: string
  status?: Agent['status'] | string
  tone: DashboardExecutionTone
  state: DashboardExecutionWorkerState
  note: string
  focus: string
  last_signal_at?: string | null
  last_signal_age_sec?: number | null
  signal_truth?: 'live' | 'stale' | 'absent'
  evidence_source?: 'message' | 'presence' | 'none'
  active_task_count?: number
  related_session_id?: string | null
  related_operation_id?: string | null
  emoji?: string
  korean_name?: string | null
  model?: string | null
  recent_output_preview?: string | null
  recent_event?: string | null
}

export interface DashboardExecutionLodgeTick {
  checked?: number
  acted?: number
  passed?: number
  skipped?: number
  failed?: number
  last_tick_at?: string | null
  last_skip_reason?: string | null
  last_pass_reason?: string | null
  last_system_skip_reason?: string | null
  strategy?: string | null
  queue_depth?: number | null
  activity_report?: string | null
}

export interface DashboardExecutionLodgeCheckin {
  agent_name: string
  trigger?: string | null
  outcome: 'acted' | 'passed' | 'skipped' | 'failed' | string
  summary?: string | null
  reason?: string | null
  allowed_tool_names: string[]
  used_tool_names: string[]
  used_tool_call_count?: number | null
  action_kind?: 'post' | 'comment' | 'vote' | 'none' | string
  tool_audit_source?: string | null
  tool_audit_at?: string | null
  checked_at?: string | null
  decision_reason?: string | null
  worker_name?: string | null
  failure_reason?: string | null
}

export interface DashboardExecutionContinuityBrief {
  name: string
  agent_name?: string | null
  status?: string
  tone: DashboardExecutionTone
  state: DashboardExecutionContinuityState
  note: string
  focus: string
  last_signal_at?: string | null
  last_autonomous_action_at?: string | null
  generation?: number
  turn_count?: number
  context_ratio?: number | null
  continuity?: string | null
  lifecycle?: string | null
  related_session_id?: string | null
  model?: string | null
  emoji?: string
  korean_name?: string | null
  skill_reason?: string | null
  recent_input_preview?: string | null
  recent_output_preview?: string | null
  recent_tool_names?: string[]
  allowed_tool_names?: string[]
  latest_tool_names?: string[]
  latest_tool_call_count?: number | null
  tool_audit_source?: string | null
  tool_audit_at?: string | null
  last_proactive_preview?: string | null
  continuity_summary?: string | null
  skill_route_summary?: string | null
}

export interface DashboardExecutionResponse {
  generated_at?: string
  status?: ServerStatus
  summary?: DashboardExecutionSummary
  social_tick?: DashboardExecutionLodgeTick | null
  social_checkins?: unknown[]
  lodge_tick?: DashboardExecutionLodgeTick | null
  lodge_checkins?: unknown[]
  execution_queue?: unknown[]
  session_briefs?: unknown[]
  operation_briefs?: unknown[]
  worker_support_briefs?: unknown[]
  priority_queue?: unknown[]
  worker_briefs?: unknown[]
  continuity_briefs?: unknown[]
  offline_worker_briefs?: unknown[]
  agents?: unknown[]
  tasks?: unknown[]
  messages?: unknown[]
  keepers?: unknown[]
}

export interface DashboardMemoryResponse {
  generated_at?: string
  summary?: {
    visible_posts?: number
    sort_by?: string
    exclude_system?: boolean
  }
  posts?: BoardPost[]
  count?: number
  limit?: number
  offset?: number
  sort_by?: string
}

export interface DashboardGovernanceResponse {
  generated_at?: string
  summary?: {
    cases_open?: number
    pending_ruling?: number
    ready_auto_execute?: number
    needs_human_gate?: number
    executed?: number
    blocked?: number
    ready_to_execute?: number
    oldest_open_case_age_s?: number | null
    last_activity_age_s?: number | null
    judge_online?: boolean
    judge_last_seen_at?: string | null
  }
  items?: GovernanceDecisionItem[]
  activity?: GovernanceTimelineEvent[]
  judge?: GovernanceJudgeSummary
  pending_actions?: PendingConfirmation[]
}

export interface DashboardPlanningResponse {
  generated_at?: string
  goals?: unknown[]
  rollup?: Record<string, unknown>
  mdal?: {
    loops?: unknown[]
    error?: string
  }
  task_backlog?: {
    todo?: number
    claimed?: number
    in_progress?: number
    done?: number
    cancelled?: number
  }
}

export interface DashboardMissionSummary {
  room_health?: string
  cluster?: string
  project?: string
  current_room?: string | null
  paused?: boolean
  tempo_interval_s?: number
  active_agents?: number
  keeper_pressure?: number
  active_operations?: number
  pending_approvals?: number
  incident_count?: number
  recommended_action_count?: number
  top_attention?: OperatorAttentionItem | null
  top_action?: OperatorRecommendedAction | null
}

export interface DashboardMissionCommandFocus {
  health?: string
  active_operations?: number
  pending_approvals?: number
  swarm_overview?: CommandPlaneSwarmStatus['overview']
  top_attention?: OperatorAttentionItem | null
  top_action?: OperatorRecommendedAction | null
  session_cards: OperatorSessionCard[]
}

export interface DashboardMissionTargets {
  sessions: OperatorSessionSnapshot[]
  keepers: OperatorKeeperSnapshot[]
  pending_confirms: PendingConfirmation[]
  available_actions: OperatorActionDescriptor[]
}

export interface DashboardMissionAttentionQueueItem {
  id: string
  kind: string
  severity: string
  summary: string
  target_type: string
  target_id?: string | null
  top_action?: OperatorRecommendedAction | null
  related_session_ids: string[]
  related_agent_names: string[]
  evidence_preview: string[]
  last_seen_at?: string | null
}

export interface DashboardMissionSessionBrief {
  session_id: string
  goal: string
  room?: string | null
  status?: string
  health?: string
  member_names: string[]
  started_at?: string | null
  elapsed_sec?: number | null
  operation_id?: string | null
  blocker_summary?: string | null
  last_event_at?: string | null
  last_event_summary?: string | null
  communication_summary?: string | null
  active_count?: number
  seen_count?: number
  planned_count?: number
  required_count?: number
  counts_basis?: string | null
  related_attention_count: number
  top_attention?: OperatorAttentionItem | null
  top_recommendation?: OperatorRecommendedAction | null
}

export interface DashboardMissionParticipantPreview {
  agent_name: string
  display_name?: string | null
  is_live?: boolean
  status?: string
  current_work?: string | null
  recent_input_preview?: string | null
  recent_output_preview?: string | null
  recent_tool_names: string[]
  last_activity_at?: string | null
}

export interface DashboardMissionOperationBadge {
  operation_id: string
  status?: string
  stage?: string | null
  detachment_status?: string | null
  objective?: string | null
  updated_at?: string | null
}

export interface DashboardMissionKeeperRef {
  name: string
  agent_name?: string | null
  status?: string
  generation?: number
  context_ratio?: number | null
  last_turn_ago_s?: number | null
  current_work?: string | null
}

export interface DashboardMissionSessionCard extends DashboardMissionSessionBrief {
  member_previews: DashboardMissionParticipantPreview[]
  operation_badges: DashboardMissionOperationBadge[]
  keeper_refs: DashboardMissionKeeperRef[]
}

export interface DashboardMissionAgentBrief {
  agent_name: string
  display_name?: string | null
  is_live?: boolean
  archived_reason?: string | null
  status?: string
  where?: string | null
  with_whom: string[]
  current_work?: string | null
  related_session_id?: string | null
  related_attention_count: number
  last_activity_at?: string | null
  last_activity_age_sec?: number | null
  signal_truth?: 'live' | 'stale' | 'archived' | 'unknown'
  evidence_source?: 'message' | 'presence' | 'session' | 'none'
  recent_output_preview?: string | null
  recent_input_preview?: string | null
  recent_event?: string | null
  recent_tool_names: string[]
  allowed_tool_names?: string[]
  latest_tool_names?: string[]
  latest_tool_call_count?: number | null
  tool_audit_source?: string | null
  tool_audit_at?: string | null
}

export interface DashboardMissionKeeperBrief {
  name: string
  agent_name?: string | null
  status?: string
  generation?: number
  context_ratio?: number | null
  last_turn_ago_s?: number | null
  current_work?: string | null
  last_autonomous_action_at?: string | null
  allowed_tool_names?: string[]
  latest_tool_names?: string[]
  latest_tool_call_count?: number | null
  tool_audit_source?: string | null
  tool_audit_at?: string | null
}

export interface DashboardMissionInternalSignal {
  id: string
  signal_type: 'attention' | 'action'
  severity: string
  summary: string
  target_type: string
  target_id?: string | null
  attention?: OperatorAttentionItem | null
  action?: OperatorRecommendedAction | null
}

export interface DashboardMissionResponse {
  generated_at?: string
  summary: DashboardMissionSummary
  incidents: OperatorAttentionItem[]
  recommended_actions: OperatorRecommendedAction[]
  command_focus: DashboardMissionCommandFocus
  operator_targets: DashboardMissionTargets
  attention_queue: DashboardMissionAttentionQueueItem[]
  sessions: DashboardMissionSessionCard[]
  session_briefs: DashboardMissionSessionBrief[]
  agent_briefs: DashboardMissionAgentBrief[]
  keeper_briefs: DashboardMissionKeeperBrief[]
  internal_signals: DashboardMissionInternalSignal[]
}

export interface DashboardMissionTimelineItem {
  id: string
  timestamp?: string | null
  event_type?: string
  actor?: string | null
  summary: string
}

export interface DashboardMissionSessionDetailResponse {
  generated_at?: string
  session_id: string
  session?: DashboardMissionSessionCard | null
  timeline: DashboardMissionTimelineItem[]
  participants: DashboardMissionParticipantPreview[]
  operations: DashboardMissionOperationBadge[]
  keepers: DashboardMissionKeeperRef[]
  error?: string | null
}

export interface DashboardMissionBriefingSection {
  id: string
  label: string
  status: 'ok' | 'healthy' | 'aligned' | 'watch' | 'risk' | 'unclear'
  summary: string
  evidence: string[]
  signal_class?: 'operational_risk' | 'metadata_gap' | 'mixed'
  evidence_quality?: 'strong' | 'partial' | 'missing'
}

export interface DashboardMissionBriefingMetadataGap {
  kind: string
  summary: string
  scope_type: 'session' | 'keeper' | 'agent'
  scope_id?: string | null
  severity: 'info' | 'watch'
}

export interface DashboardMissionBriefingResponse {
  generated_at?: string
  cached?: boolean
  stale?: boolean
  refreshing?: boolean
  status?: 'ok' | 'pending' | 'unavailable' | 'error'
  summary?: string | null
  model?: string | null
  ttl_sec?: number
  criteria: string[]
  basis?: {
    current_room?: string | null
    crew_count?: number
    agent_count?: number
    keeper_count?: number
  }
  metadata_gap_count?: number
  metadata_gaps: DashboardMissionBriefingMetadataGap[]
  sections: DashboardMissionBriefingSection[]
  error?: string | null
  last_error?: string | null
}

export type DashboardProofVerdict = 'proven' | 'partial' | 'insufficient' | string

export interface DashboardProofSummary {
  headline?: string
  detail?: string
  session_id?: string
  goal?: string
  verdict?: DashboardProofVerdict
  live_verdict?: DashboardProofVerdict
  historical_verdict?: DashboardProofVerdict | null
  verdict_basis?: 'live' | 'live_and_historical' | 'historical_only' | string
  actors_count?: number
  planned_actor_count?: number
  mentioned_actor_count?: number
  unanswered_actor_count?: number
  interaction_count?: number
  evidence_count?: number
  cp_trace_count?: number
}

export interface DashboardProofSelection {
  mode?: 'explicit' | 'latest_auto_selected' | 'requested_not_found' | 'none' | string
  reason?: string
  requested_session_id?: string | null
  requested_operation_id?: string | null
  selected_session_id?: string | null
  selected_goal?: string | null
  selected_created_by?: string | null
  selected_operation_id?: string | null
  available_session_count?: number
}

export interface DashboardProofTimelineItem {
  id: string
  seq?: number
  source?: string
  session_id?: string | null
  operation_id?: string | null
  event_type?: string
  timestamp?: string
  actor?: string | null
  summary?: string
  detail?: Record<string, unknown>
}

export interface DashboardProofActorContribution {
  actor: string
  role?: string | null
  activity_state?: 'acted' | 'mentioned_only' | 'planned_only' | string
  activity_detail?: string | null
  observed_event_count?: number
  turn_count?: number
  spawn_count?: number
  tool_evidence_count?: number
  interaction_count?: number
  mention_count?: number
  recent_input_preview?: string | null
  recent_output_preview?: string | null
  recent_event_summary?: string | null
  requested_by?: string | null
  recent_request_preview?: string | null
  recent_request_at?: string | null
  recent_tool_names?: string[]
  last_active_at?: string | null
}

export interface DashboardProofToolEvidence {
  actor?: string | null
  event_type?: string | null
  tool_names?: string[]
  summary?: string | null
  timestamp?: string | null
}

export interface DashboardProofArtifactRef {
  kind: string
  path: string
  exists: boolean
}

export interface DashboardProofBackingEvidence {
  operation_id?: string
  detachment_id?: string
  traces?: Record<string, unknown>
  detachments?: Record<string, unknown>
  summary?: Record<string, unknown>
  swarm_proof?: Record<string, unknown> | null
}

export interface DashboardProofResponse {
  schema_version?: string
  generated_at?: string
  room?: Record<string, unknown>
  selection?: DashboardProofSelection
  session_id?: string | null
  operation_id?: string | null
  proof_verdict?: DashboardProofVerdict
  summary?: DashboardProofSummary
  timeline?: DashboardProofTimelineItem[]
  actor_contributions?: DashboardProofActorContribution[]
  goal_binding?: Record<string, unknown>
  tool_evidence?: DashboardProofToolEvidence[]
  cp_backing_evidence?: DashboardProofBackingEvidence | null
  artifacts?: DashboardProofArtifactRef[]
  raw_proof?: Record<string, unknown> | null
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

export interface OperatorLinkedAutoresearch {
  loop_id?: string | null
  session_id?: string | null
  status?: string | null
  current_cycle?: number
  best_score?: number | null
  last_decision?: string | null
  target_file?: string | null
  workdir?: string | null
  source_workdir?: string | null
  program_note?: string | null
  operation_id?: string | null
  queued_hypothesis?: string | null
  warnings?: string[]
  error?: string | null
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
  linked_autoresearch?: OperatorLinkedAutoresearch | null
  session?: Record<string, unknown>
  recent_events?: Record<string, unknown>[]
}

export interface OperatorKeeperSnapshot {
  name: string
  runtime_class?: 'resident_keeper' | 'persistent_agent'
  desired?: boolean
  resident_registered?: boolean
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

export interface PendingConfirmSummary {
  actor_filter?: string | null
  filter_active: boolean
  visible_count: number
  total_count: number
  hidden_count: number
  hidden_actors: string[]
  confirm_required_actions: OperatorActionDescriptor[]
}

export interface OperatorAttentionItem {
  kind: string
  severity: string
  summary: string
  target_type: string
  target_id?: string | null
  actor?: string | null
  evidence?: unknown
}

export interface OperatorRecommendedAction {
  action_type: string
  target_type: string
  target_id?: string | null
  severity: string
  reason: string
  confirm_required?: boolean
  suggested_payload?: unknown
  preview?: unknown
}

export interface OperatorWorkerCard {
  actor?: string | null
  spawn_agent?: string | null
  spawn_role?: string | null
  spawn_model?: string | null
  worker_class?: string | null
  parent_actor?: string | null
  capsule_mode?: string | null
  runtime_pool?: string | null
  lane_id?: string | null
  controller_level?: string | null
  control_domain?: string | null
  supervisor_actor?: string | null
  model_tier?: string | null
  task_profile?: string | null
  risk_level?: string | null
  routing_confidence?: number | null
  routing_reason?: string | null
  status: string
  turn_count: number
  empty_note_turn_count: number
  has_turn: boolean
  last_turn_ts_iso?: string | null
}

export interface OperatorSessionCard {
  session_id: string
  goal?: string
  status?: string
  health?: string
  scale_profile?: string
  control_profile?: string
  planned_worker_count?: number
  active_agent_count?: number
  last_turn_age_sec?: number | null
  attention_count?: number
  recommended_action_count?: number
  top_attention?: OperatorAttentionItem | null
  top_recommendation?: OperatorRecommendedAction | null
}

export interface OperatorResidentJudgeRuntime {
  enabled?: boolean
  judge_online?: boolean
  refreshing?: boolean
  generated_at?: string | null
  expires_at?: string | null
  model_used?: string | null
  keeper_name?: string | null
  last_error?: string | null
}

export interface OperatorGuidanceSummary {
  summary?: string | null
  confidence?: number | null
  provenance?: string | null
  authoritative?: boolean
  surface?: string | null
  fresh_until?: string | null
  keeper_name?: string | null
  fallback_used?: boolean
  disagreement_with_truth?: boolean
}

export interface OperatorJudgment {
  judgment_id?: string
  surface?: string | null
  target_type?: string | null
  target_id?: string | null
  status?: string | null
  summary?: string | null
  confidence?: number | null
  generated_at?: string | null
  fresh_until?: string | null
  keeper_name?: string | null
  model_name?: string | null
  runtime_name?: string | null
  evidence_refs: string[]
  recommended_action?: OperatorRecommendedAction | null
  supersedes: string[]
  fallback_used?: boolean
  disagreement_with_truth?: boolean
  provenance?: string | null
}

export interface OperatorDigest {
  trace_id?: string
  target_type: 'room' | 'team_session' | string
  target_id?: string | null
  health?: string
  judgment_owner?: string | null
  authoritative_judgment_available?: boolean
  resident_judge_runtime?: OperatorResidentJudgeRuntime | null
  judgment?: OperatorJudgment | null
  active_guidance_layer?: string | null
  active_summary?: OperatorGuidanceSummary | null
  active_recommended_actions?: OperatorRecommendedAction[]
  active_recommendation_source?: string | null
  active_recommendation_summary?: OperatorGuidanceSummary | null
  fallback_recommended_actions?: OperatorRecommendedAction[]
  recommendation_summary?: OperatorGuidanceSummary | null
  swarm_status?: CommandPlaneSwarmStatus
  attention_items: OperatorAttentionItem[]
  recommended_actions: OperatorRecommendedAction[]
  session_cards: OperatorSessionCard[]
  worker_cards: OperatorWorkerCard[]
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
  resident_judge_runtime?: OperatorResidentJudgeRuntime | null
  persistent_agents?: OperatorKeeperSnapshot[]
  command_plane?: CommandPlaneSnapshot
  swarm_status?: CommandPlaneSwarmStatus
  recent_messages: Message[]
  pending_confirms: PendingConfirmation[]
  pending_confirm_envelope?: PendingConfirmEnvelope | null
  pending_confirm_summary?: PendingConfirmSummary
  available_actions: OperatorActionDescriptor[]
}

export type OperatorActionType =
  | 'broadcast'
  | 'room_pause'
  | 'room_resume'
  | 'social_sweep'
  | 'lodge_tick'
  | 'task_inject'
  | 'team_note'
  | 'team_broadcast'
  | 'team_task_inject'
  | 'team_worker_spawn_batch'
  | 'team_stop'
  | 'keeper_message'
  | 'keeper_probe'
  | 'keeper_recover'
  | 'swarm_run_continue'
  | 'swarm_run_rerun'
  | 'swarm_run_abandon'

export type OperatorTargetType = 'room' | 'team_session' | 'keeper' | 'swarm_run'

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

export interface ServerStatus {
  room?: string
  room_base_path?: string
  cluster?: string
  project?: string
  paused?: boolean
  version?: string
  generated_at?: string
  build?: ServerBuildIdentity
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
    governance?: GovernanceMonitoring
  }
  lodge?: LodgeRuntimeStatus
  social_runtime?: SocialRuntimeStatus
  gardener?: GardenerRuntimeStatus
  guardian?: GuardianRuntimeStatus
  sentinel?: SentinelRuntimeStatus
  data_quality?: {
    board_contract_ok?: boolean
    governance_feed_ok?: boolean
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

export type DashboardSemanticSurfaceId = TabId | 'side_rail'

export interface DashboardSemanticMetric {
  id: string
  label: string
  what_it_measures: string
  why_it_exists: string
  source_path: string
  update_trigger: string
  agent_behavior_effect: string
  ecosystem_effect: string
  interpretation: string
  bad_smell: string
  next_action: string
}

export interface DashboardSemanticPanel {
  id: string
  title: string
  purpose: string
  problem_solved: string
  when_active: string
  agent_role: string
  ecosystem_function: string
  related_tools: string[]
  metrics: DashboardSemanticMetric[]
}

export interface DashboardSemanticSurface {
  id: DashboardSemanticSurfaceId | string
  label: string
  purpose: string
  problem_solved: string
  when_active: string
  agent_role: string
  ecosystem_function: string
  panels: DashboardSemanticPanel[]
}

export interface DashboardSemanticsResponse {
  schema_version?: string
  generated_at?: string
  surfaces: DashboardSemanticSurface[]
}

export type TabId =
  | 'mission'
  | 'proof'
  | 'execution'
  | 'tools'
  | 'live'
  | 'memory'
  | 'governance'
  | 'planning'
  | 'intervene'
  | 'command'
  | 'lab'
  | 'social'

export const VALID_TABS: TabId[] = [
  'mission',
  'proof',
  'execution',
  'tools',
  'live',
  'memory',
  'governance',
  'planning',
  'intervene',
  'command',
  'lab',
  'social',
]

// --- Social Graph types ---

export interface SocialGraphNode {
  id: string
  label: string
  type: string
  weight: number
  kind: string
  status: string
}

export interface SocialGraphEdge {
  source: string
  target: string
  type: string
  weight: number
  kind: string
  active: boolean
}

export interface SocialGraphTimelineEvent {
  kind: string
  actor: Record<string, unknown>
  summary: string
  subject: { id: string; type: string } | null
  ts: number
  ts_iso: string
  seq: number
  room_id: string
  tags: string[]
  payload: Record<string, unknown>
}

export interface SocialGraphStats {
  [key: string]: number
}

export interface SocialGraphResponse {
  nodes: SocialGraphNode[]
  edges: SocialGraphEdge[]
  stats: SocialGraphStats
  timeline: SocialGraphTimelineEvent[]
  generated_at: string
  window: { start: number; end: number; limit: number; room_id: string }
}
