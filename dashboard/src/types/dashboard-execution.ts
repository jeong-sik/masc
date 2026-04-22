import type { Agent, BoardPost } from './core'
import type { OperatorAttentionItem, OperatorRecommendedAction } from './dashboard-mission'
import type { BoardMonitoring, GovernanceMonitoring, GovernanceDecisionItem, GovernanceTimelineEvent, GovernanceJudgeSummary, GovernanceJudgment, KeeperApprovalQueueItem, KeeperApprovalRule, PendingConfirmation, PendingConfirmSummary } from './governance'

// --- Dashboard projection responses ---

export interface DashboardShellMetaCognitionBelief {
  id: string
  claim: string
  status: string
  confidence?: number | null
  support_agent_count?: number | null
  challenge_agent_count?: number | null
}

export interface DashboardShellMetaCognitionTension {
  id: string
  topic: string
  kind?: string | null
  severity?: string | null
  recurrence_count?: number | null
  needs_operator?: boolean
}

export interface DashboardShellMetaCognitionDesire {
  id: string
  desired_state: string
  type?: string | null
  actionability?: string | null
  strength?: number | null
}

export interface DashboardShellMetaCognitionSummary {
  stagnation_score: number
  belief_count: number
  contested_belief_count: number
  dominant_belief?: DashboardShellMetaCognitionBelief | null
  top_tension?: DashboardShellMetaCognitionTension | null
  top_desire?: DashboardShellMetaCognitionDesire | null
}

export interface DashboardShellAuthSummary {
  enabled: boolean
  require_token: boolean
  default_role?: string | null
  token_present: boolean
  requested_agent?: string | null
  effective_agent?: string | null
  effective_role?: string | null
  can_keeper_msg: boolean
  keeper_msg_error?: string | null
}

export interface DashboardConfigResolutionItem {
  path: string
  exists: boolean
  source: string
}

export interface DashboardConfigResolution {
  status: 'ready' | 'warn' | 'invalid_env' | 'missing'
  warnings: string[]
  config_root: DashboardConfigResolutionItem
  cascade_authoring: DashboardConfigResolutionItem
  cascade: DashboardConfigResolutionItem
  prompts: DashboardConfigResolutionItem
  keepers: DashboardConfigResolutionItem
  personas: DashboardConfigResolutionItem
}

export interface DashboardRuntimeDiagnostic {
  ts: string
  kind: string
  signal?: string
  message: string
}

export type KeeperRuntimeSource = 'env' | 'toml' | 'default' | 'derived'

export interface KeeperRuntimeField<T> {
  value: T
  source: KeeperRuntimeSource
}

export interface KeeperRuntimeResolved {
  bootstrap_max_active_keepers: KeeperRuntimeField<number>
  reactive_max_turns_per_call: KeeperRuntimeField<number>
  autonomous_max_turns_per_call: KeeperRuntimeField<number>
  reactive_max_idle_turns: KeeperRuntimeField<number>
  autonomous_max_idle_turns: KeeperRuntimeField<number>
  turn_timeout_sec: KeeperRuntimeField<number>
  admission_wait_timeout_sec: KeeperRuntimeField<number>
  oas_timeout_override_sec: KeeperRuntimeField<number | null>
  oas_timeout_per_1k: KeeperRuntimeField<number>
  oas_timeout_per_turn: KeeperRuntimeField<number>
}

export interface DashboardRuntimeResolution {
  status: 'ready' | 'warn' | string
  warnings: string[]
  base_path: DashboardConfigResolutionItem
  workspace_path: DashboardConfigResolutionItem
  resolved_base_path: DashboardConfigResolutionItem
  data_root: DashboardConfigResolutionItem
  prompt_markdown_dir: DashboardConfigResolutionItem
  workspace_git_commit: string | null
  resolved_base_git_commit: string | null
  source_mismatch: boolean
  diagnostics: DashboardRuntimeDiagnostic[]
  build: ServerBuildIdentity
  keeper_runtime: KeeperRuntimeResolved | null
}

export interface DashboardShellResponse {
  generated_at?: string
  status: ServerStatus
  counts?: {
    agents?: number
    tasks?: number
    keepers?: number
    total_runtimes?: number
  }
  configured_keepers?: number
  providers?: Record<string, unknown>
  meta_cognition?: DashboardShellMetaCognitionSummary | null
  auth?: DashboardShellAuthSummary | null
  config_resolution?: DashboardConfigResolution | null
  runtime_resolution?: DashboardRuntimeResolution | null
}

export interface DashboardNamespaceTruthAttentionSummary {
  count: number
  bad_count: number
  warn_count: number
  provenance?: string | null
  top_item?: OperatorAttentionItem | null
}

export interface DashboardNamespaceTruthRecommendationSummary {
  count: number
  provenance?: string | null
  top_action?: OperatorRecommendedAction | null
}

export interface DashboardNamespaceTruthMetaCognitionDigest {
  post_id: string
  title: string
  created_at: string
  updated_at?: string | null
  hearth?: string | null
  digest_key?: string | null
  matches_summary?: boolean
  provenance?: string | null
}

interface DashboardNamespaceTruthMetaCognition {
  summary?: DashboardShellMetaCognitionSummary | null
  latest_digest?: DashboardNamespaceTruthMetaCognitionDigest | null
  provenance?: string | null
}

export interface DashboardNamespaceTruthFocus {
  label: string
  reason: string
  source: string
  provenance: string
  target_kind?: string | null
  target_id?: string | null
  suggested_tab?: 'command' | 'intervene' | string | null
  suggested_surface?: string | null
  suggested_params?: Record<string, string>
}

export interface DashboardReadinessPillar {
  key: string
  label: string
  status: 'ok' | 'warn' | 'bad' | string
  score: number
  summary: string
  blocking_reasons: string[]
  metrics?: Record<string, number>
}

export interface DashboardReadinessSummary {
  status: 'ok' | 'warn' | 'bad' | string
  score: number
  decision_required_count: number
  blocking_count: number
  pillars: DashboardReadinessPillar[]
}

export interface DashboardAttentionEvent {
  severity: 'info' | 'warn' | 'bad' | string
  kind: string
  summary: string
  requires_decision: boolean
  keeper_name?: string | null
  target_type?: string | null
  target_id?: string | null
  recommended_action?: string | null
  provenance?: string | null
}

export interface DashboardNamespaceTruthResponse {
  generated_at?: string
  root: {
    status?: ServerStatus | null
    counts?: DashboardShellResponse['counts']
    configured_keepers?: number
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
    provenance?: string | null
  }
  meta_cognition?: DashboardNamespaceTruthMetaCognition | null
  operator?: {
    health?: string | null
    attention_summary?: DashboardNamespaceTruthAttentionSummary | null
    recommendation_summary?: DashboardNamespaceTruthRecommendationSummary | null
    pending_confirm_summary?: PendingConfirmSummary | null
    provenance?: string | null
  }
  readiness?: DashboardReadinessSummary | null
  attention_events?: DashboardAttentionEvent[]
  focus?: DashboardNamespaceTruthFocus | null
}

export interface ServerBuildIdentity {
  release_version: string
  commit?: string | null
  started_at: string
  uptime_seconds: number
}

type DashboardExecutionTone = 'ok' | 'warn' | 'bad'
type DashboardExecutionWorkerState = 'working' | 'watching' | 'quiet' | 'offline'
type DashboardExecutionContinuityState = 'healthy' | 'warning' | 'critical'
type DashboardExecutionQueueKind = 'session' | 'operation'

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
  severity?: DashboardExecutionTone
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
  namespace?: string | null
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

export interface DashboardExecutionWorkerSupportBrief {
  name: string
  agent_name?: string
  status?: Agent['status'] | string
  tone?: DashboardExecutionTone
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

export interface DashboardExecutionContinuityBrief {
  name: string
  agent_name?: string | null
  status?: string
  tone?: DashboardExecutionTone
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
  allowed_tool_count?: number | null
  allowed_tool_preview?: string[]
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
  social_tick?: unknown
  social_checkins?: unknown[]
  execution_queue?: unknown[]
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
    exclude_automation?: boolean
  }
  posts?: BoardPost[]
  count?: number
  limit?: number
  offset?: number
  /** true when more posts exist past this page. Use with offset+limit to request the next page. */
  has_more?: boolean
  /** Total number of matching posts when the server could determine it; null when has_more=true. */
  total?: number | null
  sort_by?: string
}

export interface DashboardGovernanceResponse {
  generated_at?: string
  note?: string
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
  judgments?: GovernanceJudgment[]
  pending_actions?: PendingConfirmation[]
  approval_queue?: KeeperApprovalQueueItem[]
  approval_rules?: KeeperApprovalRule[]
}

export interface DashboardPlanningResponse {
  generated_at?: string
  goals?: unknown[]
  rollup?: Record<string, unknown>
  task_backlog?: {
    todo?: number
    claimed?: number
    in_progress?: number
    done?: number
    cancelled?: number
  }
}

// --- Goal Tree (hierarchical goal decomposition) ---

export interface GoalTreeTask {
  id: string
  title: string
  status: string
  status_color: string
  priority: number
  assignee: string | null
  goal_id: string | null
  linkage_source: 'explicit' | 'title_tag' | 'mixed' | 'none' | string
  is_terminal: boolean
  created_at: string
  updated_at: string
}

export interface GoalTreeNode {
  id: string
  title: string
  horizon: string
  status: string
  status_color: string
  health: 'done' | 'paused' | 'blocked' | 'at_risk' | 'on_track' | string
  health_color: string
  badges: string[]
  status_reason: string
  priority: number
  metric: string | null
  target_value: string | null
  due_date: string | null
  parent_goal_id: string | null
  convergence: number
  convergence_pct: number
  tasks: GoalTreeTask[]
  task_count: number
  task_done_count: number
  children: GoalTreeNode[]
  child_count: number
  last_activity_at: string
  stagnation_seconds: number
  linked_keeper_names: string[]
  pending_approval_count: number
  infra_risk_count: number
  linkage_source: 'explicit' | 'title_tag' | 'mixed' | 'none' | string
  linkage_warning_count: number
  created_at: string
  updated_at: string
}

export interface GoalTreeSummary {
  total_goals: number
  active_goals: number
  done_goals: number
  paused_goals: number
  at_risk_goals: number
  blocked_goals: number
  total_tasks: number
  done_tasks: number
  pending_approvals: number
  infra_risk_count: number
  overall_convergence: number
  overall_convergence_pct: number
}

export interface DashboardGoalsTreeResponse {
  generated_at?: string
  tree: GoalTreeNode[]
  summary: GoalTreeSummary
}

export interface GoalDetailKeeper {
  name: string
  agent_name: string
  current_task_id: string | null
  active_goal_ids: string[]
  sandbox_profile: string
  execution_scope: string
  network_mode: string
  cascade_name: string
  approval_profile: string | null
  sandbox_effective_kind: string | null
  cascade_outcome: string | null
  latest_execution_outcome: string | null
  latest_execution_at: string | null
  latest_receipt: Record<string, unknown> | null
}

export interface GoalDetailTimelineEvent {
  ts: string
  kind: string
  lane: string
  title: string
  summary: string
  severity: 'ok' | 'warn' | 'bad' | string
}

export interface DashboardGoalDetailResponse {
  generated_at?: string
  goal: GoalTreeNode
  linked_tasks: GoalTreeTask[]
  linked_keepers: GoalDetailKeeper[]
  approvals: Array<Record<string, unknown>>
  execution_receipts: Array<Record<string, unknown>>
  timeline: GoalDetailTimelineEvent[]
}


export interface ServerStatus {
  coordination_root?: string
  workspace_path?: string
  workspace_differs?: boolean
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
    window_hours: number
    tool_calls: number
    failures: number
    failure_rate: number
    since_epoch: number
    distinct_tools?: number
    top_failures?: Array<{ tool: string; calls: number; failures: number }>
    top_active?: Array<{ tool: string; calls: number; failures: number }>
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
  data_quality?: {
    board_contract_ok?: boolean
    governance_feed_ok?: boolean
    last_sync_at?: string
  }
}
