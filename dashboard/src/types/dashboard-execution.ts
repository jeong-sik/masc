import type { Agent, BoardPost, StopCause, ExecutionSignalTruth, EvidenceSourceCore, KeeperTrustSummary } from './core'
import type { BoardMonitoring, PendingConfirmSummary } from './gate'

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

export type KeeperRuntimeSource = 'env' | 'toml' | 'default'

export interface KeeperRuntimeField<T> {
  value: T
  source: KeeperRuntimeSource
}

export interface KeeperRuntimeResolved {
  stream_idle_timeout_sec: KeeperRuntimeField<number | null>
  body_timeout_override_sec: KeeperRuntimeField<number | null>
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
  keeper_runtime: KeeperRuntimeResolved | null
  fleet_safety: DashboardFleetSafetyHealth | null
  fd_accountant: DashboardFdAccountant | null
  disk_observation: DashboardDiskObservation | null
}

export interface DashboardFdAccountant {
  fd_open: number | null
  fd_limit: number | null
  per_kind: DashboardFdActiveOperations[]
  resource_errors: DashboardFdResourceError[]
}

export interface DashboardFdActiveOperations {
  kind: string
  active_operations: number
}

export interface DashboardFdResourceError {
  kind: string
  error: string
  count: number
}

export interface DashboardDiskObservation {
  mode: string | null
  masc_root: string | null
  storage_space_exhaustion_observations_total: number | null
  last_storage_space_exhaustion_ts: number | null
  filesystem: DashboardDiskFilesystemObservation | null
}

export interface DashboardDiskFilesystemObservation {
  path: string | null
  filesystem: string | null
  mounted_on: string | null
  total_bytes: number | null
  used_bytes: number | null
  available_bytes: number | null
  capacity_percent: number | null
  available_percent: number | null
  error: string | null
}

export interface DashboardFleetSafetyHealth {
  keeper_fibers: number | null
  paused_keepers: number | null
  paused_keepers_health: DashboardPausedKeepersHealth | null
  keeper_fleet_no_fibers: boolean | null
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
  paused_elapsed_sec: number | null
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
  runtime_trust?: KeeperTrustSummary | null
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
  recent_input_preview?: string | null
  recent_output_preview?: string | null
  recent_tool_names?: string[]
  latest_tool_names?: string[]
  latest_tool_call_count?: number | null
  tool_audit_source?: string | null
  tool_audit_at?: string | null
  last_proactive_preview?: string | null
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

export interface DashboardPlanningResponse {
  generated_at?: string
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
  }
  data_quality?: {
    board_contract_ok?: boolean
    gate_feed_ok?: boolean
    last_sync_at?: string
  }
}
