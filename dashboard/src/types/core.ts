// MASC Dashboard — Core entity types (Agent, Task, Message, Board, Keeper)

// --- Core entities ---

export interface Agent {
  name: string
  agent_type?: string
  status?: 'active' | 'busy' | 'listening' | 'idle' | 'inactive' | 'offline'
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
  synthetic?: boolean
}

export interface Task {
  id: string
  title: string
  goal_id?: string | null
  status?: 'todo' | 'in_progress' | 'claimed' | 'awaiting_verification' | 'done' | 'cancelled'
  priority?: number
  assignee?: string
  assignee_kind?: string | null
  description?: string
  created_at?: string
  updated_at?: string
  completed_at?: string
  contract?: TaskContract | null
  handoff_context?: TaskHandoffContext | null
  gate?: TaskGateSnapshot | null
  execution_links?: TaskExecutionLinks | null
}

interface TaskExecutionLinks {
  operation_id?: string | null
  session_id?: string | null
  autoresearch_loop_id?: string | null
}

interface TaskContract {
  strict?: boolean
  completion_contract?: string[]
  required_evidence?: string[]
  inspect_gate_evidence?: string[]
  verify_gate_evidence?: string[]
  links?: TaskExecutionLinks | null
}

interface TaskHandoffContext {
  summary: string
  reason?: string | null
  next_step?: string | null
  failure_mode?: string | null
  evidence_refs?: string[]
  updated_at?: string | null
  updated_by?: string | null
}

interface TaskGateCheck {
  evidence: string
  outcome: 'satisfied' | 'missing' | 'failed' | 'unsupported'
  detail: string
}

export interface TaskGateEvaluation {
  status: 'ready' | 'blocked' | 'inconclusive'
  checks?: TaskGateCheck[]
  reasons?: string[]
}

interface TaskGateSnapshot {
  strict?: boolean
  completion_contract?: string[]
  unmet_completion_contract?: string[]
  done?: TaskGateEvaluation
  inspect_to_implement?: TaskGateEvaluation | null
  verify_to_review?: TaskGateEvaluation | null
}

export interface Message {
  id?: string
  seq?: number
  from?: string
  content: string
  timestamp?: string
  type?: string
}

// --- Board ---

type BoardPostMeta = Record<string, unknown> & {
  source?: string | null
  state_block?: string | null
  classification_reason?: string | null
  judgment?: unknown
}

export interface BoardPost {
  id: string
  author: string
  post_kind?: 'direct' | 'automation' | 'system'
  classification_reason?: string | null
  title: string
  body: string
  content: string
  meta?: BoardPostMeta | null
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
  parent_id?: string | null
  author: string
  content: string
  created_at: string
}

// --- Keeper Metrics ---

export interface InferenceTelemetry {
  system_fingerprint: string | null
  timings: {
    prompt_n: number | null
    prompt_ms: number | null
    prompt_per_second: number | null
    predicted_n: number | null
    predicted_ms: number | null
    predicted_per_second: number | null
    cache_n: number | null
  } | null
  reasoning_tokens: number | null
  peak_memory_gb: number | null
  request_latency_ms: number
}

export interface PromptSegmentTelemetry {
  bytes: number
  estimated_tokens: number
  fingerprint: string | null
}

export interface PromptTelemetry {
  fingerprint: string | null
  estimated_total_tokens: number | null
  estimated_cacheable_tokens: number | null
  segments: Record<string, PromptSegmentTelemetry>
}

export interface CtxCompositionTelemetry {
  actual_input_tokens: number | null
  display_total_tokens: number
  estimated_known_tokens: number
  segments: Record<string, PromptSegmentTelemetry>
}

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
  prompt_fingerprint: string | null
  prompt_metrics: PromptTelemetry | null
  ctx_composition: CtxCompositionTelemetry | null
  input_tokens: number | null
  output_tokens: number | null
  total_tokens: number | null
  wall_tokens_per_second: number | null
  inference_telemetry: InferenceTelemetry | null
  fallback_applied: boolean
  fallback_hops: number
  fallback_from: string | null
  fallback_to: string | null
  fallback_reason: string | null
}

export interface KeeperTrustLatestEvent {
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
}

export interface KeeperTrustApprovalState {
  state?: string | null
  summary?: string | null
  pending_count?: number | null
}

export interface KeeperTrustExecutionSummary {
  tool_contract_result?: string | null
  sandbox_summary?: string | null
  mutation_guard_summary?: string | null
  latest_receipt_at?: string | null
}

export interface KeeperTrustSummary {
  disposition?: string | null
  disposition_reason?: string | null
  needs_attention?: boolean | null
  attention_reason?: string | null
  next_human_action?: string | null
  approval_state?: KeeperTrustApprovalState | null
  execution_summary?: KeeperTrustExecutionSummary | null
  latest_causal_event?: KeeperTrustLatestEvent | null
}

export type KeeperLifecycleState =
  | 'active'
  | 'compacting'
  | 'preparing'
  | 'handoff-imminent'
  | 'idle'
  | 'offline'
  | 'unbooted'
  | 'stopped'

export interface Goal {
  id: string
  horizon: 'short' | 'mid' | 'long'
  title: string
  metric?: string | null
  target_value?: string | null
  due_date?: string | null
  priority: number
  status: string
  phase: string
  verifier_policy?: GoalVerifierPolicy | null
  require_completion_approval?: boolean
  active_verification_request_id?: string | null
  parent_goal_id?: string | null
  last_review_note?: string | null
  last_review_at?: string | null
  created_at: string
  updated_at: string
}

export interface GoalVerifierPrincipal {
  kind: 'operator' | 'keeper' | string
  id: string
  display_name?: string | null
}

export interface GoalVerifierPolicy {
  inherit_mode: 'extend' | 'replace' | string
  principals: GoalVerifierPrincipal[]
  required_verdicts?: number | null
}

// --- Keeper ---

type KeeperHealthState = 'healthy' | 'idle' | 'stale' | 'degraded' | 'offline'

type KeeperQuietReason =
  | 'quiet_hours'
  | 'min_gap'
  | 'no_recent_activity'
  | 'disabled'
  | 'startup'
  | 'model_error'
  | 'graphql_error'
  | 'never_started'
  | 'unknown'

type KeeperNextActionPath =
  | 'direct_message'
  | 'manual_social_sweep'
  | 'probe'
  | 'recover'

type KeeperReplyStatus =
  | 'never'
  | 'awaiting_reply'
  | 'delivered'
  | 'fresh'
  | 'stale'
  | 'error'
  | 'unknown'

type KeeperContinuityState =
  | 'not_running'
  | 'recovering'
  | 'healthy'
  | 'disabled'
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

export type KeeperConversationSource =
  | 'direct_user'
  | 'direct_assistant'
  | 'world_state_prompt'
  | 'internal_assistant'
  | 'tool_result'
  | 'system'
  | 'unknown'

export type KeeperConversationDelivery =
  | 'history'
  | 'sending'
  | 'streaming'
  | 'delivered'
  | 'timeout'
  | 'error'

interface KeeperConversationUsage {
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
  replyText?: string | null
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
  source: KeeperConversationSource
  label: string
  text: string
  rawText?: string | null
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

export type PipelineStage =
  | 'idle'
  | 'thinking'
  | 'tool_use'
  | 'compacting'
  | 'handoff'
  | 'scheduled_autonomous'
  | 'offline'
  | 'failing'
  | 'draining'
  | 'paused'
  | 'crashed'
  | 'restarting'

// Aggregated metrics computed by the backend over a sliding window.
// Fields mirror dashboard_http_keeper_detail.ml summary output.
interface MetricsWindowTopItem {
  tool?: string
  kind?: string
  model?: string
  reason?: string
  trigger?: string
  count?: number
  [key: string]: unknown
}

export interface MetricsWindow {
  // -- Sample metadata --
  sample_points?: number
  window_sample_points?: number
  turn_points?: number
  window_turn_points?: number
  heartbeat_points?: number
  window_heartbeat_points?: number
  proactive_points?: number
  window_proactive_points?: number
  window_interactions?: number
  window_turns?: number
  window_series_max_lines?: number
  window_series_max_bytes?: number
  primary_model?: string

  // -- Handoff / Compaction counts --
  handoff_count?: number
  compaction_events?: number
  compaction_before_tokens?: number
  compaction_saved_tokens?: number
  compaction_saved_ratio?: number
  avg_compaction_saved_tokens?: number

  // -- Fallback rates --
  fallback_count?: number
  fallback_rate?: number
  model_fallback_count?: number
  model_fallback_rate?: number
  model_fallback_numerator?: number
  model_fallback_denominator?: number
  proactive_fallback_count?: number
  proactive_fallback_rate?: number
  proactive_template_fallback_count?: number
  proactive_template_fallback_rate?: number
  proactive_template_fallback_numerator?: number
  proactive_template_fallback_denominator?: number

  // -- Intervention --
  intervention_share?: number
  intervention_per_turn?: number

  // -- Automation counts & rates --
  auto_reflect_count?: number
  auto_plan_count?: number
  auto_compact_count?: number
  auto_handoff_count?: number
  guardrail_stop_count?: number
  auto_reflect_rate?: number
  auto_plan_rate?: number
  auto_compact_rate?: number
  auto_handoff_rate?: number
  guardrail_stop_rate?: number

  // -- Drift --
  drift_applied_count?: number
  drift_applied_rate?: number

  // -- Alignment quality --
  repetition_risk_avg?: number
  goal_alignment_avg?: number
  response_alignment_avg?: number
  goal_drift_avg?: number

  // -- Proactive preview similarity --
  proactive_preview_sample_count?: number
  proactive_preview_pair_count?: number
  proactive_preview_similarity_avg?: number
  proactive_preview_similarity_max?: number
  proactive_preview_similarity_warn?: boolean
  proactive_preview_similarity_method?: string
  proactive_preview_similarity_window?: number

  // -- Tool --
  tool_call_count?: number

  // -- Memory --
  memory_checks?: number
  memory_passed?: number
  memory_failed?: number
  memory_pass_rate?: number
  memory_avg_score?: number
  memory_threshold?: number
  memory_corrections?: number
  memory_correction_success?: number
  memory_notes_added?: number

  // -- Memory compaction --
  memory_compaction_events?: number
  memory_compaction_before_notes?: number
  memory_compaction_dropped_notes?: number
  memory_compaction_invalid_dropped?: number
  memory_compaction_drop_ratio?: number
  memory_compaction_drop_avg?: number

  // -- Memory weather --
  memory_weather_checks?: number
  memory_weather_passed?: number
  memory_weather_pass_rate?: number

  // -- Top-N lists --
  top_work_kinds?: MetricsWindowTopItem[]
  top_models?: MetricsWindowTopItem[]
  top_tools?: MetricsWindowTopItem[]
  top_memory_kinds?: MetricsWindowTopItem[]
  top_drift_reasons?: MetricsWindowTopItem[]
  top_compaction_triggers?: MetricsWindowTopItem[]
  generation_equipment?: MetricsWindowTopItem[]

  // Catch-all for future fields
  [key: string]: unknown
}

export type KeeperPhase =
  | 'Offline'
  | 'Running'
  | 'Failing'
  | 'Overflowed'
  | 'Compacting'
  | 'HandingOff'
  | 'Draining'
  | 'Paused'
  | 'Stopped'
  | 'Crashed'
  | 'Restarting'
  | 'Dead'

export interface Keeper {
  name: string
  pipeline_stage?: PipelineStage
  phase?: KeeperPhase | null
  runtime_class?: 'keeper'
  paused?: boolean
  registered?: boolean
  reconcile_status?: string | null
  emoji?: string
  koreanName?: string
  agent_name?: string
  trace_id?: string
  model?: string
  primary_model?: string
  active_model?: string
  active_model_label?: string | null
  last_model_used?: string
  last_model_used_label?: string | null
  next_model_hint?: string | null
  cascade_name?: string
  status: string
  presence_keepalive?: boolean
  presence_keepalive_sec?: number
  keepalive_running?: boolean
  diagnostic?: KeeperDiagnostic | null
  registry_state?: string | null
  proactive_enabled?: boolean
  proactive_idle_sec?: number
  proactive_cooldown_sec?: number
  runtime_blocker_class?:
    | 'ambiguous_post_commit_timeout'
    | 'ambiguous_post_commit_failure'
    | 'autonomous_slot_wait_timeout'
    | 'admission_queue_wait_timeout'
    | 'turn_timeout_after_queue_wait'
    | 'turn_timeout'
    | 'completion_contract_violation'
    | 'cascade_exhausted'
    | null
  runtime_blocker_summary?: string | null
  runtime_blocker_continue_gate?: boolean | null
  needs_attention?: boolean | null
  attention_reason?: string | null
  next_human_action?: string | null
  active_goal_ids?: string[]
  goal?: string | null
  short_goal?: string | null
  mid_goal?: string | null
  long_goal?: string | null
  goal_horizons?: {
    short?: string | null
    mid?: string | null
    long?: string | null
  } | null
  sandbox_profile?: 'local' | 'docker' | string | null
  sandbox_target?: string | null
  sandbox_last_error?: string | null
  effective_sandbox_image?: string | null
  blocked_task_count?: number | null
  goal_progress?: {
    active_goal_count?: number
    linked_task_count?: number
    done_task_count?: number
    open_task_count?: number
    blocked_task_count?: number
    convergence?: number | null
  } | null
  approval_policy_effective?: {
    allow_rules?: number
    deny_rules?: number
    persisted_rules?: number
  } | null
  last_autonomous_action_at?: string | null
  autonomous_action_count?: number
  autonomous_turn_count?: number
  autonomous_text_turn_count?: number
  autonomous_tool_turn_count?: number
  board_reactive_turn_count?: number
  mention_reactive_turn_count?: number
  noop_turn_count?: number
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
  social_model?: string | null
  configured_social_model?: string | null
  social_model_recognized?: boolean | null
  social_model_fallback?: string | null
  last_speech_act?: string | null
  last_blocker?: string | null
  last_need?: string | null
  last_drift_reason?: string | null
  drift_count_total?: number
  runtime_warning_ctx_ratio?: number | null
  trust?: KeeperTrustSummary | null
  generation?: number
  turn_count?: number
  total_turns?: number
  total_tokens?: number
  last_latency_ms?: number
  last_activity_ago_s?: number
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
  // Observed audit fallback from the shell summary; not authored tool policy.
  latest_tool_names?: string[]
  latest_tool_call_count?: number | null
  tool_audit_source?: string | null
  tool_audit_at?: string | null
  turn_budget?: {
    reactive: {
      value: number
      source: 'override' | 'env' | 'override_invalid'
      env_default: number
      env_var: string
      raw_override: number | null
    }
    scheduled_autonomous: {
      value: number
      source: 'override' | 'env' | 'override_invalid'
      env_default: number
      env_var: string
      raw_override: number | null
    }
    manifest_path: string | null
    clamp_min: number
    clamp_max: number
  } | null
  conversation_tail_count?: number
  k2k_count?: number
  k2k_mentions?: Array<{ keeper: string; count: number }>
  handoff_count_total?: number
  compaction_count?: number
  last_compaction_saved_tokens?: number
  skill_primary?: string | null
  skill_secondary?: string[]
  skill_reason?: string | null
  metrics_window?: MetricsWindow
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
  inventory?: string[]
  relationships?: Record<string, string>
  supervisor_diagnostics?: KeeperSupervisorDiagnostics
  outcomes?: KeeperOutcomes
  conditions?: KeeperConditions
}

/** Outcomes rollup — aggregated successes / failures / validation
 *  for the last 50-entry transition ring. Backed by
 *  [Dashboard_http_keeper.compute_outcomes_rollup]. See
 *  [specs/keeper-state-machine/KeeperOutcomesConservation.tla] for the
 *  conservation invariant:
 *    successes.substantive_turns + failures.turn_failed + failures.gate_rejected
 *      = observed_turns
 */
export interface KeeperOutcomes {
  window: string
  observed_turns: number
  successes: {
    substantive_turns: number
    compactions_ok: number
    handoffs_ok: number
  }
  failures: {
    turn_failed: number
    gate_rejected: number
    compaction_failed: number
    handoff_failed: number
    crashes: number
    restarts: number
    consecutive_fail_current: number
  }
  validation: {
    oas_verdicts: {
      pass: number
      fail: number
      unknown: number
      top_failure_reasons: string[]
    }
    /** null until CDAL verdict gate (#7531) lands. */
    cdal_gate: null | {
      pass: number
      reject: number
      pending_verification: number
    }
    last_verdict_at: number | null
  }
}

/** 16 observable conditions that drive the keeper FSM (RFC-0002 §4).
 *  Serialized by [Keeper_state_machine.conditions_to_json]. */
export interface KeeperConditions {
  launch_pending: boolean
  fiber_alive: boolean
  heartbeat_healthy: boolean
  turn_healthy: boolean
  context_within_budget: boolean
  context_handoff_needed: boolean
  compaction_active: boolean
  handoff_active: boolean
  operator_paused: boolean
  stop_requested: boolean
  restart_budget_remaining: boolean
  backoff_elapsed: boolean
  guardrail_triggered: boolean
  drain_complete: boolean
  context_overflow: boolean
  compact_retry_exhausted: boolean
}

export interface KeeperSupervisorCrashLogEntry {
  ts?: number
  reason?: string
}

interface KeeperSupervisorDiagnostics {
  restart_count?: number
  max_restarts?: number
  crash_log?: KeeperSupervisorCrashLogEntry[]
  last_failure_reason?: string | null
  dead_since?: number | null
  sp_events?: unknown[]
  health_score?: number
  dead_eta_sec?: number | null
}

// --- Keeper Config (structured read-only view) ---

interface KeeperConfigPrompt {
  goal: string
  short_goal: string
  mid_goal: string
  long_goal: string
  will: string
  needs: string
  desires: string
  instructions: string
  system_prompt_blocks: {
    constitution: {
      key: string
      source: string
      text: string
    }
    world: {
      key: string
      source: string
      text: string
    }
    capabilities: {
      key: string
      source: string
      text: string
    }
  }
  effective_system_prompt: string
}

interface KeeperConfigExecution {
  models: string[]
  active_model: string
  active_model_label?: string | null
  last_model_used_label?: string | null
  verify: boolean
  selected_cascade_name: string
  selected_cascade_canonical: string
}

interface KeeperConfigCompaction {
  profile: string
  ratio_gate: number
  message_gate: number
  token_gate: number
  cooldown_sec: number
}

interface KeeperConfigProactive {
  enabled: boolean
  idle_sec: number
  cooldown_sec: number
}

export type KeeperFeatureStatus = 'wired' | 'source_only' | 'unwired'

interface KeeperConfigDrift {
  status: KeeperFeatureStatus
  enabled: boolean | null
  min_turn_gap: number | null
  count_total: number | null
  last_reason: string | null
}

interface KeeperConfigHandoff {
  auto: boolean
  threshold: number
  cooldown_sec: number
}

interface KeeperConfigRuntime {
  paused: boolean
  registered: boolean
  keepalive_running: boolean
  registry_state?: string | null
  fiber_health: string
  presence_keepalive: boolean
  presence_keepalive_sec: number
  runtime_blocker_class?:
    | 'ambiguous_post_commit_timeout'
    | 'ambiguous_post_commit_failure'
    | 'autonomous_slot_wait_timeout'
    | 'admission_queue_wait_timeout'
    | 'turn_timeout_after_queue_wait'
    | 'turn_timeout'
    | 'completion_contract_violation'
    | 'cascade_exhausted'
    | null
  active_model_label?: string | null
  last_model_used_label?: string | null
  runtime_blocker_summary?: string | null
  runtime_blocker_continue_gate?: boolean | null
}

interface KeeperConfigCoordination {
  mention_targets: string[]
  joined_room_ids: string[]
}

export interface KeeperConfigTools {
  tool_access: unknown
  tool_policy_mode: 'preset' | 'custom' | string
  tool_preset?:
    | 'minimal'
    | 'social'
    | 'messaging'
    | 'dispatch'
    | 'coding'
    | 'research'
    | 'delivery'
    | 'full'
    | null
  tool_also_allow: string[]
  tool_custom_allowlist: string[]
  resolved_allowlist: string[]
  tool_denylist: string[]
  active_masc_tool_count: number
  active_keeper_tool_count: number
  total_active: number
}

interface KeeperConfigSources {
  live_meta_path: string
  default_manifest_path: string | null
  default_source_kind: 'toml' | 'persona' | null
  precedence: string[]
  has_live_override: boolean
  override_fields: string[]
  cascade_catalog_source_kind: 'json' | 'toml' | null
  cascade_catalog_source_path: string | null
  cascade_runtime_json_path: string | null
  cascade_runtime_json_editable: boolean
}

interface KeeperConfigMetrics {
  generation: number
  total_turns: number
  total_input_tokens: number
  total_output_tokens: number
  total_tokens: number
  total_cost_usd: number
  last_model_used: string
  last_input_tokens: number
  last_output_tokens: number
  last_total_tokens: number
  last_latency_ms: number
  last_total_tokens_per_sec: number | null
  last_output_tokens_per_sec: number | null
  compaction_count: number
}

export interface KeeperSandboxEnvironment {
  base_path?: string | null
  project_root?: string | null
  docker_playground_enabled: boolean
  docker_container_name?: string | null
  container_playground_root?: string | null
  docker_image?: string | null
  pids_limit?: number | null
  memory?: string | null
  tmpfs_size?: string | null
  seccomp_profile?: string | null
  require_rootless: boolean
  require_userns: boolean
}

export interface KeeperHookSlot {
  active: boolean
  source: string
  gates?: string[]
  effects?: string[]
  features?: string[]
}

interface KeeperHookIntrospection {
  slots: Record<string, KeeperHookSlot>
  deny_list: string[]
  deny_list_count: number
  destructive_check_tools: string[]
  cost_budget: { max_cost_usd?: number | null; active: boolean }
}

export interface KeeperConfig {
  name: string
  sandbox_profile?: 'local' | 'docker' | string
  network_mode?: 'none' | 'inherit' | string
  shared_memory_scope?: 'disabled' | 'room' | string
  sandbox_last_error?: string | null
  effective_sandbox_image?: string | null
  private_workspace_root?: string | null
  sandbox_environment?: KeeperSandboxEnvironment
  allowed_paths: string[]
  effective_allowed_paths: string[]
  prompt: KeeperConfigPrompt
  execution: KeeperConfigExecution
  compaction: KeeperConfigCompaction
  proactive: KeeperConfigProactive
  drift: KeeperConfigDrift
  handoff: KeeperConfigHandoff
  hooks?: KeeperHookIntrospection
  runtime: KeeperConfigRuntime
  coordination: KeeperConfigCoordination
  tools: KeeperConfigTools
  sources: KeeperConfigSources
  metrics: KeeperConfigMetrics
}
