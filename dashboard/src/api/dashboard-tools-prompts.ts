// MASC Dashboard — Tool metrics / runtime probe / tools inventory / prompts.
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, post, type AbortableRequestOptions } from './core'
import { ensureDevToken } from './dev-token'
import type { TelemetryFreshnessMetadata } from './dashboard-shared'
import type { DashboardConfigResolution, DashboardRuntimeResolution } from '../types'

// --- Tool metrics (P4 Phase 4.5) ---

export interface DashboardToolInventoryItem {
  name: string
  description: string
  category: string
  category_description?: string | null
  enabled_in_current_mode: boolean
  direct_call_allowed: boolean
  required_permission?: string | null
  doc_refs: string[]
  prompt_hints: string[]
  surfaces: string[]
  visibility: string
  lifecycle: string
  implementationStatus: string
  tier: string
  canonicalName?: string | null
  replacement?: string | null
  reason?: string | null
}

interface SurfaceSummaryEntry {
  count: number
  tools: string[]
}

interface DashboardToolInventoryResponse {
  count: number
  tools: DashboardToolInventoryItem[]
  surface_summary?: Record<string, SurfaceSummaryEntry>
}

export interface ToolMetricsTopEntry {
  name: string
  call_count: number
}

export interface ToolMetricsResponse extends TelemetryFreshnessMetadata {
  total_calls: number
  distinct_tools_called: number
  top_20: ToolMetricsTopEntry[]
  never_called_count: number
  tool_distribution?: { total: number; public: number; visible: number; hidden: number } | null
  dispatch_v2_enabled: boolean
  registered_count: number
}

export interface DashboardScheduledAutomationFsm {
  state: string
  active_count: number
  terminal_count: number
  next_due_at?: string | null
}

export interface DashboardScheduledAutomationExecution {
  execution_id: string
  schedule_id: string
  started_at?: number
  started_at_iso?: string | null
  finished_at?: number | null
  finished_at_iso?: string | null
  due_at?: number
  payload_digest?: string
  status: string
  detail?: unknown | null
  error?: string | null
}

export interface DashboardScheduledAutomationDispatchReceipt {
  projection_status: 'recognized' | 'unrecognized_detail'
  kind?: string
  queue?: string
  stimulus?: string
  stimulus_id?: string | null
  reaction_ledger_status?: string | null
  reaction_ledger_error?: string | null
  keeper_name?: string
  schedule_id?: string
  urgency?: string
  post_id?: string
  author?: string
  hearth?: string | null
  reason?: string
}

export interface DashboardScheduledAutomationKeeperReactionEvidence {
  projection_status:
    | 'matched_consumed_ack'
    | 'matched_turn_started'
    | 'matched_stimulus'
    | 'not_found'
    | 'missing_stimulus_id'
    | 'unrecognized_receipt'
  source?: string
  keeper_name?: string
  schedule_id?: string
  post_id?: string
  stimulus?: string
  stimulus_id?: string
  stimulus_kind?: string
  reaction_kind?: string
  stimulus_seen?: boolean
  turn_started_seen?: boolean
  event_queue_ack_seen?: boolean
  matched_record_count?: number
  stimulus_recorded_at?: number | null
  stimulus_recorded_at_iso?: string | null
  turn_started_recorded_at?: number | null
  turn_started_recorded_at_iso?: string | null
  event_queue_ack_recorded_at?: number | null
  event_queue_ack_recorded_at_iso?: string | null
  latest_recorded_at?: number | null
  latest_recorded_at_iso?: string | null
  reason?: string
}

export interface DashboardScheduledAutomationKeeperQueueEvidence {
  projection_status: 'matched_pending' | 'matched_inflight' | 'not_found' | 'read_error' | 'unrecognized_receipt'
  source?: string
  queue?: string
  stimulus?: string
  keeper_name?: string
  schedule_id?: string
  post_id?: string
  pending_count?: number
  inflight_count?: number
  matched_bucket?: string
  matched_post_id?: string
  matched_schedule_id?: string | null
  matched_payload_kind?: string
  matched_arrived_at?: number
  matched_arrived_at_iso?: string
  matched_age_seconds?: number
  read_errors?: Array<{ kind?: string; path?: string | null; message?: string }>
  reason?: string
}

export interface DashboardScheduledAutomationKeeperToolStatus {
  name: string
  registered_schema?: boolean
  dispatch_registered?: boolean
  direct_call_allowed?: boolean
  visibility?: string
  surfaces?: string[]
  surface_count?: number
  effect_domain?: string | null
  read_only?: boolean | null
  requires_actor_binding?: boolean | null
}

export interface DashboardScheduledAutomationActor {
  id: string
  kind: string
  display_name?: string | null
}

export interface DashboardScheduledAutomationStandingGrant {
  grant_id: string
  scope: 'standing'
  approved_by: DashboardScheduledAutomationActor
  approved_at: number
  approved_at_iso?: string | null
  payload_digest: string
}

export interface DashboardScheduledAutomationSignal {
  signal_id: string
  kind: string
  event_type?: string
  schedule_id: string
  emitted_at?: number
  emitted_at_iso?: string | null
  due_at?: number
  due_at_iso?: string | null
  risk_class: string
  payload_digest?: string
  payload_kind?: string | null
}

export interface DashboardScheduledAutomationRequest {
  schedule_id: string
  status: string
  effective_status?: string
  execution_readiness?: string
  operator_action?: string | null
  keeper_next_tool?: string | null
  keeper_next_tool_status?: DashboardScheduledAutomationKeeperToolStatus | null
  keeper_next_action?: string | null
  risk_class: string
  approval_required: boolean
  source: string
  requested_by?: DashboardScheduledAutomationActor | null
  scheduled_by?: DashboardScheduledAutomationActor | null
  recurrence?: {
    kind: string
    interval_sec?: number
    hour?: number
    minute?: number
    second?: number
    expression?: string
    timezone?: string
  }
  recurrence_kind?: string
  requested_at?: number
  requested_at_iso?: string
  due_at?: number
  due_at_iso?: string
  next_due_at?: number | null
  next_due_at_iso?: string | null
  expires_at?: number | null
  expires_at_iso?: string | null
  payload_digest?: string
  payload_kind?: string | null
  payload_support?: 'supported' | 'unsupported' | 'unknown'
  payload_target?: string | null
  payload_summary?: string | null
  recurrence_summary?: string | null
  requires_separate_human_grant?: boolean
  approval_policy?: string | null
  active_standing_grant?: DashboardScheduledAutomationStandingGrant | null
  last_execution?: DashboardScheduledAutomationExecution | null
  dispatch_receipt?: DashboardScheduledAutomationDispatchReceipt | null
  keeper_queue_evidence?: DashboardScheduledAutomationKeeperQueueEvidence | null
  keeper_reaction_evidence?: DashboardScheduledAutomationKeeperReactionEvidence | null
}

export interface DashboardScheduledAutomationPayloadSupport {
  supported_kinds?: string[]
  unsupported_request_count?: number
  unsupported_kinds?: Array<{ kind: string; count: number }>
  unknown_request_count?: number
}

export interface DashboardScheduledAutomationLiveSupportedNonTerminalEvidence {
  schema?: string
  source?: string
  projection_status:
    | 'matched_supported_non_terminal'
    | 'no_supported_payload_rows'
    | 'no_supported_non_terminal'
  criteria?: string
  reason?: string
  request_count?: number
  supported_request_count?: number
  supported_non_terminal_count?: number
  supported_live_count?: number
  supported_terminal_or_expired_count?: number
  unsupported_request_count?: number
  unknown_request_count?: number
  terminal_or_expired_count?: number
  matched_schedule_ids?: string[]
  matched_schedule_id_limit?: number
}

export interface DashboardScheduledAutomation {
  schema?: string
  source?: string
  generated_at?: string
  request_count: number
  request_limit: number
  truncated: boolean
  signal_source?: string
  signal_count?: number
  signal_limit?: number
  signals?: DashboardScheduledAutomationSignal[]
  counts: Record<string, number>
  derived_counts?: Record<string, number>
  payload_support?: DashboardScheduledAutomationPayloadSupport
  live_supported_non_terminal_evidence?: DashboardScheduledAutomationLiveSupportedNonTerminalEvidence
  fsm: DashboardScheduledAutomationFsm
  requests: DashboardScheduledAutomationRequest[]
}

export interface DashboardKeeperWaitingRow {
  keeper_name?: string | null
  source: string
  waiting_on: string
  wake_producer?: string | null
  since?: number | null
  since_iso?: string | null
  due_at?: number | null
  due_at_iso?: string | null
  next_action: string
  detail?: unknown
}

export interface DashboardKeeperWaitingKeeper {
  keeper_name: string
  state: 'idle' | 'busy' | 'waiting' | 'deferred' | string
  waiting_on: DashboardKeeperWaitingRow[]
  waiting_count: number
  waiting_count_truncated?: boolean
  truncated_sources?: Record<string, boolean>
  sources?: Record<string, number>
  since?: number | null
  since_iso?: string | null
  due_at?: number | null
  due_at_iso?: string | null
  next_action?: string | null
}

export interface DashboardKeeperWaitingInventory {
  schema?: string
  source?: string
  generated_at?: string
  supported_states?: string[]
  keeper_count_known?: boolean
  keeper_count: number
  waiting_keeper_count: number
  row_count: number
  row_count_truncated?: boolean
  external_attention_row_limit?: number
  external_attention_truncated_keeper_count?: number
  global_row_count?: number
  global_pending_confirm_count_known?: boolean
  global_pending_confirm_count?: number
  source_counts?: Record<string, number>
  keepers: DashboardKeeperWaitingKeeper[]
  global_waiting_on?: DashboardKeeperWaitingRow[]
}

// Keeper autonomous background (server_keeper_background.dashboard_json). Surfaces
// per-keeper recurring tasks with the owning keeper's loop liveness as context.
// Deferred async work (bg-shell / fusion / hitl) is NOT here — it is reused from
// DashboardKeeperWaitingInventory rather than re-projected.
export interface DashboardKeeperBackgroundLoop {
  phase: string
  started_at?: number | null
  started_at_iso?: string | null
  restart_count: number
  last_restart_at?: number | null
  last_restart_at_iso?: string | null
  dead_since?: number | null
  dead_since_iso?: string | null
}

export interface DashboardKeeperRecurringTask {
  id: string
  label: string
  action_kind: string
  interval_sec: number
  enabled: boolean
  run_count: number
  failure_count: number
  max_failures: number
  // null until the task first runs (never epoch 0), and next_run is null while
  // the task is paused or has never run.
  last_run_at?: number | null
  last_run_at_iso?: string | null
  next_run_at?: number | null
  next_run_at_iso?: string | null
}

export interface DashboardKeeperBackgroundKeeper {
  keeper_name: string
  loop: DashboardKeeperBackgroundLoop
  recurring: DashboardKeeperRecurringTask[]
  recurring_count: number
}

export interface DashboardKeeperBackground {
  schema?: string
  source?: string
  generated_at?: string
  keeper_count: number
  recurring_keeper_count: number
  recurring_count: number
  keepers: DashboardKeeperBackgroundKeeper[]
}

export interface DashboardToolsResponse {
  generated_at?: string
  status?: string
  is_warming?: boolean
  stale_reason?: string | null
  config_resolution?: DashboardConfigResolution
  runtime_resolution?: DashboardRuntimeResolution
  tool_inventory: DashboardToolInventoryResponse
  tool_usage: ToolMetricsResponse
  scheduled_automation?: DashboardScheduledAutomation
  keeper_waiting_inventory?: DashboardKeeperWaitingInventory
  keeper_background?: DashboardKeeperBackground
}

// --- Runtime probe (KV-cache / model load probe) ---

interface DashboardRuntimeProbeLoadedModel {
  name?: string | null
  model?: string | null
  size_vram_bytes?: number | null
  context_length?: number | null
  expires_at?: string | null
}

interface DashboardRuntimeProbeRun {
  run_index: number
  http_status?: number | null
  wall_clock_ms?: number | null
  total_duration_ms?: number | null
  load_duration_ms?: number | null
  prompt_eval_count?: number | null
  prompt_eval_duration_ms?: number | null
  prompt_tokens_per_second?: number | null
  eval_count?: number | null
  eval_duration_ms?: number | null
  generation_tokens_per_second?: number | null
  done?: boolean | null
  done_reason?: string | null
  thinking_present?: boolean
  response_preview?: string | null
  response_chars?: number | null
  error?: string | null
}

interface DashboardRuntimeProbeAssessment {
  signal?: string | null
  baseline_run_index?: number | null
  best_repeat_run_index?: number | null
  baseline_prompt_eval_duration_ms?: number | null
  best_repeat_prompt_eval_duration_ms?: number | null
  prompt_eval_duration_reduction_ratio?: number | null
  note?: string | null
  limitation?: string | null
}

export interface DashboardRuntimeProviderProbe {
  runtime_id?: string | null
  provider_id?: string | null
  provider_display_name?: string | null
  model_id?: string | null
  model_api_name?: string | null
  protocol?: string | null
  runtime_kind?: string | null
  transport?: string | null
  auth_kind?: string | null
  credential_required?: boolean | null
  auth_present?: boolean | null
  status?: string | null
  reachable?: boolean | null
  http_status?: number | null
  latency_ms?: number | null
  model_count?: number | null
  content_type?: string | null
  downloaded_bytes?: number | null
  endpoint_url?: string | null
  probe_url?: string | null
  error?: string | null
  checked_at?: string | null
}

export interface DashboardRuntimeProviderProbeSummary {
  runtimes?: number
  probed?: number
  reachable?: number
  failed?: number
  skipped?: number
  default_runtime_id?: string | null
}

export interface DashboardRuntimeProbePayload {
  source?: string
  status?: string | null
  checked_at?: string | null
  summary?: DashboardRuntimeProviderProbeSummary | null
  providers?: DashboardRuntimeProviderProbe[]
  server_url?: string
  ps_endpoint?: string
  generate_endpoint?: string
  configured_default_model?: string | null
  requested_model?: string | null
  effective_model?: string | null
  probe_runs_requested?: number
  probe_runs_completed?: number
  max_tokens?: number
  keep_alive?: string | null
  timeout_sec?: number
  ps_timeout_sec?: number
  prompt_chars?: number
  prompt_preview?: string
  ps_http_status_before?: number | null
  ps_http_status_after?: number | null
  loaded_models_before?: DashboardRuntimeProbeLoadedModel[]
  loaded_models_after?: DashboardRuntimeProbeLoadedModel[]
  model_loaded_before_probe?: boolean
  model_loaded_after_probe?: boolean
  runs?: DashboardRuntimeProbeRun[]
  kv_cache_assessment?: DashboardRuntimeProbeAssessment | null
  observations?: string[]
  errors?: string[]
  limitations?: string[]
  probe_ok?: boolean
}

export interface DashboardRuntimeProbeResponse {
  generated_at?: string
  refreshed_at_unix?: number
  cache_ttl_sec?: number
  cache_age_sec?: number
  cache_hit?: boolean
  // Non-blocking route freshness tag. 'served_stale' / 'warming_up' mean a
  // background refresh was scheduled and the fresh value arrives on the next
  // poll — a force=1 ("Live probe") response is not guaranteed to be fresh.
  refresh_state?: 'fresh' | 'recent' | 'served_stale' | 'warming_up'
  probe?: DashboardRuntimeProbePayload | null
}

export function fetchToolMetrics(): Promise<ToolMetricsResponse> {
  return get('/api/v1/tool-metrics')
}

export async function fetchDashboardRuntimeProbe(
  force = false,
  opts?: AbortableRequestOptions,
): Promise<DashboardRuntimeProbeResponse> {
  const query = force ? '?force=1' : ''
  await ensureDevToken()
  return get(`/api/v1/dashboard/runtime-probe${query}`, { signal: opts?.signal })
}

export async function fetchDashboardTools(opts?: AbortableRequestOptions): Promise<DashboardToolsResponse> {
  const raw = await get<DashboardToolsResponse>('/api/v1/dashboard/tools', { signal: opts?.signal })
  const normalizedTools = raw.tool_inventory?.tools?.map(t => ({
    ...t,
    category: t.category ?? 'uncategorized',
    tier: t.tier ?? '(unknown tier)',
    // Tool-layer decoupling groundwork: surface membership is consumer-owned
    // metadata, not an execution constraint. Totalize here so the field is
    // never absent downstream; consumers keep working with [] and the surface
    // filter simply degrades to zero counts. Mirrors category/tier above.
    surfaces: t.surfaces ?? [],
  }))
  return {
    ...raw,
    tool_inventory: {
      ...raw.tool_inventory,
      ...(normalizedTools ? { tools: normalizedTools } : {}),
    },
  }
}

// --- Prompts (override management) ---

export type PromptSource = 'override' | 'file' | 'default' | 'missing'

export interface DashboardPromptItem {
  key: string
  category: string
  description: string
  current: string
  default: string | null
  effective: string
  file_value: string | null
  override_value: string | null
  file_path: string | null
  file_exists: boolean
  source: PromptSource
  has_override: boolean
  char_count: number
  required_file: boolean
  template_variables: string[]
}

interface DashboardPromptsResponse {
  prompts: DashboardPromptItem[]
}

interface PromptMutationResponse {
  ok: boolean
  message?: string
  key?: string
  source?: PromptSource
  effective?: string
  error?: string
}

export function fetchDashboardPrompts(): Promise<DashboardPromptsResponse> {
  return get('/api/v1/prompts')
}

export function savePromptOverride(key: string, value: string): Promise<PromptMutationResponse> {
  return post('/api/v1/prompts', { action: 'set', key, value })
}

export function clearPromptOverride(key: string): Promise<PromptMutationResponse> {
  return post('/api/v1/prompts', { action: 'clear', key })
}
