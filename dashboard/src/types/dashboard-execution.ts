import type { Agent, BoardPost, StopCause, ExecutionSignalTruth, EvidenceSourceCore } from './core'
import type { BoardMonitoring, GovernanceMonitoring, GovernanceDecisionItem, GovernanceTimelineEvent, GovernanceJudgeSummary, GovernanceJudgment, KeeperApprovalQueueItem, KeeperApprovalRule, KeeperResolvedApprovalItem, PendingConfirmation, PendingConfirmSummary } from './governance'

// --- Dashboard projection responses ---

/**
 * Typed auth error code emitted server-side. SSOT mapping lives in
 * `lib/types/masc_error.ml:dashboard_auth_error_code`; carried both in the
 * dashboard shell summary and the HTTP 401/403 error body
 * (`lib/server/server_auth.ml:auth_error_json`).
 */
export type DashboardAuthErrorCode =
  | 'missing_token'
  | 'invalid_token'
  | 'token_expired'
  | 'actor_mismatch'
  | 'insufficient_role'
  | 'same_origin_blocked'
  | 'unknown'

export interface DashboardShellAuthSummary {
  enabled: boolean
  require_token: boolean
  default_role?: string | null
  token_present: boolean
  token_valid: boolean
  token_agent?: string | null
  requested_agent?: string | null
  effective_agent?: string | null
  effective_role?: string | null
  auth_error_code?: DashboardAuthErrorCode | null
  auth_error_detail?: string | null
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
  runtime_authoring: DashboardConfigResolutionItem
  runtime: DashboardConfigResolutionItem
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

export interface DashboardShellIrTrust {
  safe: string
  audited: string
  privileged: string
}

export interface DashboardShellIrApproval {
  schema: string
  enabled: boolean
  env_key: string
  raw_overlay: string | null
  trust: DashboardShellIrTrust | null
  source: string | null
  reason: string | null
}

export type KeeperRuntimeSource = 'env' | 'toml' | 'default' | 'derived'

export interface KeeperRuntimeField<T> {
  value: T
  source: KeeperRuntimeSource
}

export interface KeeperRuntimeResolved {
  bootstrap_max_active_keepers: KeeperRuntimeField<number>
  reactive_max_idle_turns: KeeperRuntimeField<number>
  autonomous_max_idle_turns: KeeperRuntimeField<number>
  turn_timeout_sec: KeeperRuntimeField<number>
  admission_wait_timeout_sec: KeeperRuntimeField<number>
  oas_timeout_override_sec: KeeperRuntimeField<number | null>
  oas_timeout_per_1k: KeeperRuntimeField<number>
  oas_timeout_per_turn: KeeperRuntimeField<number>
}

export interface DashboardRuntimeResolution {
  generated_at?: string | null
  status: 'ready' | 'warn' | string
  warnings: string[]
  base_path: DashboardConfigResolutionItem
  workspace_path: DashboardConfigResolutionItem
  resolved_base_path: DashboardConfigResolutionItem
  data_root: DashboardConfigResolutionItem
  prompt_markdown_dir: DashboardConfigResolutionItem
  server_repo_path?: DashboardConfigResolutionItem | null
  server_repo_git_commit?: string | null
  workspace_git_commit: string | null
  resolved_base_git_commit: string | null
  source_mismatch: boolean
  server_workspace_mismatch: boolean
  diagnostics: DashboardRuntimeDiagnostic[]
  build: ServerBuildIdentity
  shell_ir_approval?: DashboardShellIrApproval | null
  keeper_runtime: KeeperRuntimeResolved | null
  fleet_safety: DashboardFleetSafetyHealth | null
  fd_accountant: DashboardFdAccountant | null
  cdal: DashboardCdalHealth | null
}

export interface DashboardFdAccountant {
  fd_open: number | null
  fd_limit: number | null
  pressure_active: boolean | null
}

export interface DashboardFleetSafetyHealth {
  keeper_fibers: number | null
  paused_keepers: number | null
  paused_keepers_health: DashboardPausedKeepersHealth | null
  keeper_fleet_no_fibers: boolean | null
  keeper_fd_pressure: DashboardFleetPressureHealth | null
  keeper_fleet_safety: DashboardFleetPressureHealth | null
  keeper_reaction_ledger: DashboardKeeperReactionLedgerHealth | null
}

export interface DashboardBlockerClassObject {
  name: string
  reason?: unknown
}

export type DashboardBlockerClass = string | DashboardBlockerClassObject

export interface DashboardBlockerInfo {
  klass: DashboardBlockerClass | null
  detail: string | null
}

export interface DashboardPausedKeeperDetail {
  name: string
  autoboot_enabled: boolean | null
  pause_kind: string | null
  auto_resume_after_sec: number | null
  persisted_auto_resume_after_sec: number | null
  auto_resume_source: string | null
  paused_elapsed_sec: number | null
  auto_resume_remaining_sec: number | null
  last_blocker: DashboardBlockerInfo | null
  missing_pause_root_cause: boolean | null
}

export interface DashboardPausedKeeperReadError {
  keeper: string
  error: string
}

export interface DashboardPausedKeepersHealth {
  count: number | null
  names: string[]
  running_count: number | null
  running_names: string[]
  durable_count: number | null
  durable_names: string[]
  autoboot_enabled_count: number | null
  autoboot_enabled_names: string[]
  details: DashboardPausedKeeperDetail[]
  read_error_count: number | null
  read_errors: DashboardPausedKeeperReadError[]
}

export interface DashboardCdalProofCompleteness {
  scan_limit: number | null
  run_dir_entries_seen: number | null
  scan_truncated: boolean | null
  run_dirs_scanned: number | null
  completed_run_dirs: number | null
  incomplete_run_dirs: number | null
  stale_incomplete_run_dirs: number | null
  terminal_incomplete_run_dirs: number | null
  missing_manifest_run_dirs: number | null
  missing_contract_run_dirs: number | null
  stale_incomplete_grace_seconds: number | null
  sample_stale_incomplete_run_ids: string[]
  sample_terminal_incomplete_run_ids: string[]
}

export interface DashboardCdalProofStoreHealth {
  root: string | null
  proofs_dir: string | null
  exists: boolean | null
  latest_activity_at: string | null
  latest_activity_unix: number | null
  age_seconds: number | null
  status: string | null
  completeness: DashboardCdalProofCompleteness | null
}

export interface DashboardCdalTaskScopeHealth {
  status: string | null
  recent_limit: number | null
  recent_rows: number | null
  task_id_rows: number | null
  missing_task_scope_rows: number | null
  legacy_unscoped_rows: number | null
  current_writer_missing_task_scope_rows: number | null
  missing_task_scope: boolean | null
  partial_task_scope: boolean | null
  current_writer_missing_task_scope: boolean | null
}

export interface DashboardCdalHealth {
  writer_status: string | null
  operator_action_required: boolean | null
  proof_store_path_drift: boolean | null
  proof_store: DashboardCdalProofStoreHealth | null
  task_scope: DashboardCdalTaskScopeHealth | null
}

export interface DashboardKeeperReactionLedgerPendingKeeper {
  keeper_name: string
  pending_stimulus_count: number
  pending_stimulus_ids: string[]
}

export interface DashboardKeeperReactionLedgerHealth {
  status: string | null
  operator_action_required: boolean | null
  keeper_count: number | null
  row_count: number | null
  stimulus_count: number | null
  reaction_count: number | null
  turn_started_count: number | null
  cursor_ack_count: number | null
  execution_receipt_count: number | null
  terminal_reason_count: number | null
  operator_escalation_count: number | null
  unknown_reaction_count: number | null
  cursor_swept_stimulus_count: number | null
  legacy_cursor_swept_stimulus_count: number | null
  pending_stimulus_count: number | null
  read_error_count: number | null
  pending_by_keeper: DashboardKeeperReactionLedgerPendingKeeper[]
}

export interface DashboardFleetPressureHealth {
  status: string | null
  reason: string | null
  blocker?: string | null
  admission_blocked: boolean | null
  admission_blocked_keepers: number | null
  blocked_keepers: number | null
  blocked_count: number | null
  bootable_keeper_count?: number | null
  running_keeper_fiber_count?: number | null
  healthy_running_keeper_fiber_count?: number | null
  failing_keeper_fiber_count?: number | null
  executable_keeper_fiber_count?: number | null
  minimum_running_fibers?: number | null
  no_running_fibers?: boolean | null
  no_executable_keeper_fibers?: boolean | null
  low_running_fiber_margin?: boolean | null
  reaction_capacity_below_target?: boolean | null
  reaction_capacity_shortfall_count?: number | null
  executable_reaction_capacity_below_target?: boolean | null
  executable_reaction_capacity_shortfall_count?: number | null
  paused_keeper_count?: number | null
  autoboot_enabled_keeper_count?: number | null
  paused_autoboot_enabled_keeper_count?: number | null
  effective_reaction_capacity_count?: number | null
  executable_reaction_capacity_count?: number | null
  target_reaction_capacity_count?: number | null
  operator_action_required?: boolean | null
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
  auth?: DashboardShellAuthSummary | null
  config_resolution?: DashboardConfigResolution | null
  runtime_resolution?: DashboardRuntimeResolution | null
}

export interface DashboardBootstrapSliceError {
  error: string
  slice?: string
}

export type DashboardBootstrapSlice<T> = T | DashboardBootstrapSliceError

export interface DashboardBootstrapResponse {
  served_at?: string
  milestone?: number
  shell?: DashboardBootstrapSlice<DashboardShellResponse>
  execution?: DashboardBootstrapSlice<DashboardExecutionResponse>
  planning?: DashboardBootstrapSlice<DashboardPlanningResponse>
  namespace_truth?: DashboardBootstrapSlice<DashboardNamespaceTruthResponse>
  goals?: DashboardBootstrapSlice<DashboardGoalsTreeResponse>
  goal_loop_status?: DashboardBootstrapSlice<Record<string, unknown>>
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

export interface DashboardNamespaceTruthRetention {
  scope?: string
  workspace_root?: string
  workspace_path?: string
  shell_input?: string
  execution_input?: string
  command_input?: string
  cache_policy?: string
}

export interface DashboardRuntimeCountAuthority {
  source?: string
  authority?: string
  configured_authority?: string
  fallback_policy?: string
  shell_arbitration_allowed?: boolean
  live_total_runtimes?: number
  live_keepers?: number
  configured_keepers?: number
  configured_minus_live_keepers?: number
  count_roles?: Record<string, string>
}

export interface DashboardNamespaceTruthResponse {
  generated_at?: string
  generated_at_iso?: string
  dashboard_surface?: string
  dashboard_aliases?: string[]
  source?: string
  retention?: DashboardNamespaceTruthRetention
  root: {
    status?: ServerStatus | null
    counts?: DashboardShellResponse['counts']
    configured_keepers?: number
    runtime_count_authority?: DashboardRuntimeCountAuthority
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
  operator?: {
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
type DashboardExecutionQueueKind = 'session' | 'operation' | 'keeper'

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
  attention_reason?: string | null
  next_human_action?: string | null
  terminal_reason_code?: string | null
  stop_cause?: StopCause | null
  runtime_trust?: GoalKeeperTrustSummary | null
  top_handoff?: DashboardExecutionHandoff | null
  intervene_handoff?: DashboardExecutionHandoff | null
  command_handoff?: DashboardExecutionHandoff | null
}

export interface DashboardExecutionSessionBrief {
  session_id: string
  goal: string
  namespace?: string | null
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
  keeper_name?: string | null
  keeper_id?: string | null
  status?: Agent['status'] | string
  tone?: DashboardExecutionTone
  state: DashboardExecutionWorkerState
  note: string
  focus: string
  last_signal_at?: string | null
  last_signal_age_sec?: number | null
  signal_truth?: ExecutionSignalTruth
  evidence_source?: EvidenceSourceCore
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
  keeper_id?: string | null
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
  latest_tool_names?: string[]
  latest_tool_call_count?: number | null
  tool_audit_source?: string | null
  tool_audit_at?: string | null
  last_proactive_preview?: string | null
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

// RFC-0319 operator approval mode. Closed union mirrors the backend
// `approval_mode_to_string` (manual | auto_low_risk); any other wire value is
// normalized to 'manual' (fail-closed) at the api-normalize boundary.
export type ApprovalMode = 'manual' | 'auto_low_risk'

export interface HitlApprovalModeStatus {
  mode: ApprovalMode
  // Bands the backend will auto-approve in auto_low_risk mode (SSOT: ['low']).
  // critical/high/medium are structurally excluded by the separation-of-duties
  // floor in Operator_approval.decide_approval_mode, not by this list.
  auto_eligible_bands: string[]
  // True when the backend could not read the persisted mode and fell back to
  // manual — surfaced so the operator knows the toggle reflects a fallback.
  fail_closed: boolean
  read_error?: string
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
  recent_resolved?: KeeperResolvedApprovalItem[]
  approval_rules?: KeeperApprovalRule[]
  hitl?: {
    enabled: boolean
    disabled_by_env: boolean
    env_name: string
    default_enabled: boolean
    approval_mode?: HitlApprovalModeStatus
  }
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
  workspace_fsm?: DashboardWorkspaceFsmSnapshot | null
}

export interface DashboardWorkspaceFsmRefs {
  goal_id?: string | null
  task_ids?: string[]
  post_ids?: string[]
  agent_name?: string | null
}

export interface DashboardWorkspaceFsmEvidence {
  source?: string
  kind?: string
  id?: string | null
  label?: string
  detail?: string
  timestamp?: number | null
  refs?: DashboardWorkspaceFsmRefs
}

export interface DashboardWorkspaceFsmViolation {
  axis?: string
  code?: string
  severity?: 'info' | 'warn' | 'error' | string
  message?: string
  refs?: DashboardWorkspaceFsmRefs
  evidence?: DashboardWorkspaceFsmEvidence[]
}

export interface DashboardWorkspaceFsmProduct {
  refs?: DashboardWorkspaceFsmRefs
  goal?: string | null
  task?: string
  board?: string
  reward?: string
  evidence?: DashboardWorkspaceFsmEvidence[]
  violations?: DashboardWorkspaceFsmViolation[]
}

export interface DashboardWorkspaceFsmSummary {
  products?: number
  violations?: number
  evidence?: number
  severity_counts?: {
    info?: number
    warn?: number
    error?: number
  }
}

export interface DashboardWorkspaceFsmSnapshot {
  schema_version?: number
  mode?: string
  summary?: DashboardWorkspaceFsmSummary
  products?: DashboardWorkspaceFsmProduct[]
  evidence?: DashboardWorkspaceFsmEvidence[]
  violations?: DashboardWorkspaceFsmViolation[]
  projection_error?: string | null
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

export interface GoalTaskSummary {
  total: number
  done: number
  open: number
  terminal: number
  awaiting_verification: number
  cancelled: number
  unassigned: number
  completion_pct: number | null
  by_status: Record<string, number>
  by_linkage_source: Record<string, number>
}

export interface GoalCompletionSummary {
  state: string
  pct: number | null
  pct_source: string
  attainment_state: string
  attainment_basis: string
  /** Mirror of {@link GoalAttainmentProjection.metric_evaluation} (task-1743). */
  metric_evaluation: 'unevaluated' | 'absent'
  task_total: number
  task_done: number
  task_open: number
  is_complete: boolean
  is_terminal: boolean
  ready_to_request_completion: boolean
  gate: 'none' | 'verification' | 'approval' | string
  requires_verifier: boolean
  requires_completion_approval: boolean
  active_verification_request: boolean
  blocking_source: GoalTreeNode['blocking_source']
  blocking_reason: string
}

export interface GoalVerificationVote {
  principal: {
    id: string
    display_name?: string | null
  }
  decision: 'approve' | 'reject' | string
  note?: string | null
  evidence_refs?: string[]
  submitted_at: string
}

export interface GoalVerificationRequest {
  id: string
  goal_id: string
  target_phase: string
  requested_by: {
    id: string
    display_name?: string | null
  }
  policy_snapshot: {
    principals: Array<{ id: string; display_name?: string | null }>
    eligible_principals: Array<{ id: string; display_name?: string | null }>
    required_verdicts: number
  }
  votes: GoalVerificationVote[]
  status: string
  created_at: string
  resolved_at?: string | null
}

export interface GoalVerificationSummary {
  effective_policy?: GoalVerificationRequest['policy_snapshot'] | null
  open_request?: GoalVerificationRequest | null
  latest_request?: GoalVerificationRequest | null
  approve_count: number
  reject_count: number
  remaining_possible: number
}

export interface GoalFsmProjection {
  state: string
  source: 'goal.phase' | string
  next_actions: string[]
  activity_observation: 'runtime' | 'approval' | 'task' | 'child' | 'goal_metadata' | string
  stagnation_status: 'recent' | 'stalled' | 'unobserved' | string
}

export interface GoalKeeperTrustLatestEvent {
  kind: string
  ts: string
  ts_unix?: number | null
  keeper_turn_id?: number | null
  task_id?: string | null
  goal_ids?: string[]
  title: string
  summary: string
  severity: 'ok' | 'warn' | 'bad' | string
  next_human_action?: string | null
  // OTel/Jaeger trace id of the causal event (keeper_runtime_trust_timeline.ml),
  // for deep-linking the latest event to its distributed trace.
  trace_id?: string | null
}

export interface GoalKeeperTrustApprovalState {
  state?: string | null
  summary?: string | null
  pending_count?: number | null
  pending_first?: {
    id?: string | null
    tool_name?: string | null
    task_id?: string | null
    blocker_class?: string | null
  } | null
  // ISO8601 timestamp of the last approval-audit event
  // (keeper_runtime_trust_snapshot.ml) — when the approval state last changed,
  // not derivable from `state` alone.
  latest_event_at?: string | null
}

export interface GoalKeeperTrustExecutionSummary {
  provider_attempt_count?: number | null
  provider_fallback_applied?: boolean | null
  provider_selected_model?: string | null
  runtime_outcome?: string | null
  sandbox_summary?: string | null
  sandbox_root?: string | null
  mutation_guard_summary?: string | null
  latest_receipt_at?: string | null
}

export interface GoalKeeperTrustTerminalReason {
  code?: string | null
  source?: string | null
  severity?: 'ok' | 'warn' | 'bad' | string | null
  summary?: string | null
  next_action?: string | null
}

export interface GoalKeeperTrustSummary {
  disposition?: string | null
  disposition_reason?: string | null
  operator_disposition?: string | null
  operator_disposition_reason?: string | null
  needs_attention?: boolean | null
  attention_reason?: string | null
  next_human_action?: string | null
  approval_state?: GoalKeeperTrustApprovalState | null
  execution_summary?: GoalKeeperTrustExecutionSummary | null
  latest_terminal_reason?: GoalKeeperTrustTerminalReason | null
  latest_next_action?: string | null
  latest_causal_event?: GoalKeeperTrustLatestEvent | null
}

export interface GoalTreeStatusProjection {
  status: string
  status_color: string
  phase: string
  phase_color: string
  goal_fsm: GoalFsmProjection
  health: 'done' | 'paused' | 'blocked' | 'at_risk' | 'on_track' | string
  health_color: string
  badges: string[]
  status_reason: string
  priority: number
}

export interface GoalTreeMetricProjection {
  metric: string | null
  target_value: string | null
  require_completion_approval: boolean
  due_date: string | null
  parent_goal_id: string | null
  convergence: number
  convergence_pct: number
  attainment: GoalAttainmentProjection
}

export interface GoalTreeTaskProjection {
  tasks: GoalTreeTask[]
  task_count: number
  task_done_count: number
  task_summary?: GoalTaskSummary
  completion_summary?: GoalCompletionSummary
}

export interface GoalTreeVerificationProjection {
  verification_summary: GoalVerificationSummary
  effective_verifier_policy?: GoalVerificationRequest['policy_snapshot'] | null
  active_verification_request?: GoalVerificationRequest | null
  pending_verification_count: number
}

export interface GoalTreeActivityProjection {
  timeline_events: unknown[]
  last_activity_at: string
  stagnation_seconds: number
  activity_observation: GoalFsmProjection['activity_observation']
  stagnation_status: GoalFsmProjection['stagnation_status']
  linked_keeper_names: string[]
  pending_approval_count: number
  infra_risk_count: number
}

export interface GoalTreeLinkageProjection {
  linkage_source: 'explicit' | 'title_tag' | 'mixed' | 'none' | string
  linkage_warning_count: number
  blocking_source: 'goal_phase' | 'child_goal' | 'approval' | 'keeper_runtime' | 'task_fsm' | 'goal_linkage' | 'stalled' | 'none' | string
  blocking_reason: string
  latest_keeper_ref?: string | null
  latest_turn_ref?: number | null
  stalled_since?: string | null
}

export interface GoalTreeTimestamps {
  created_at: string
  updated_at: string
}

export interface GoalTreeNode extends
  GoalTreeStatusProjection,
  GoalTreeMetricProjection,
  GoalTreeTaskProjection,
  GoalTreeVerificationProjection,
  GoalTreeActivityProjection,
  GoalTreeLinkageProjection,
  GoalTreeTimestamps {
  id: string
  title: string
  children: GoalTreeNode[]
  child_count: number
}

export interface GoalAttainmentProjection {
  state: 'attained' | 'in_progress' | 'not_started' | 'unmeasured' | string
  basis: 'goal_phase' | 'linked_tasks' | 'metric_target_percent' | 'metric_target_count' | 'unmeasured' | string
  metric: string | null
  /**
   * Whether the declared metric was actually evaluated (task-1743).
   * 'unevaluated': a metric is declared but no evaluator produced a value —
   * attainment_pct is task-derived, not a metric measurement.
   * 'absent': no metric is declared. Distinguishes an unmeasured metric from
   * a genuine measured zero.
   */
  metric_evaluation: 'unevaluated' | 'absent'
  target_value: string | null
  target_parse_status: 'absent' | 'parseable' | 'unparseable' | 'invalid_target' | 'unsupported_metric' | 'no_linked_tasks' | string
  unit: 'percent' | 'count' | 'unknown' | string
  observed_value: number | null
  target_numeric: number | null
  attainment_pct: number | null
  task_done_count: number
  task_count: number
  note: string
}

export interface GoalTreeSummary {
  total_goals: number
  active_goals: number
  on_track_goals: number
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
  network_mode: string
  runtime_id: string
  runtime_outcome: string | null
  latest_execution_outcome: string | null
  latest_execution_at: string | null
  latest_receipt: Record<string, unknown> | null
  runtime_trust: GoalKeeperTrustSummary | null
  latest_causal_event: GoalKeeperTrustLatestEvent | null
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
  workspace_root?: string
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
