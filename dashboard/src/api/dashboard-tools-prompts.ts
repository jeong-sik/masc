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
  registered_count: number
}

export interface DashboardScheduledAutomationFsm {
  state: string
  /** null when the server reported no count — it sends null for every count
   *  when the schedule ledger read failed. Never render null as 0. */
  active_count: number | null
  terminal_count: number | null
  next_due_at?: string | null
}

export interface DashboardScheduledAutomationWakeReceipt {
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

type DashboardScheduledAutomationDeferredActivation =
  | {
      activation_status: 'deferred'
      activation_reason:
        | 'lifecycle_denied'
        | 'shutdown_fenced'
        | 'owner_unknown'
        | 'not_running'
      activation_detail: string
    }
  | {
      activation_status: 'deferred'
      activation_reason:
        | 'autoboot_disabled'
        | 'proactive_disabled'
        | 'unregistered'
      activation_detail: null
    }

type DashboardScheduledAutomationOccurrenceActivation =
  | ({
      occurrence_status: 'awaiting_ack'
    } & (
      | {
          activation_status: 'signaled'
          activation_reason: null
          activation_detail: null
        }
      | DashboardScheduledAutomationDeferredActivation
    ))
  | {
      occurrence_status: 'already_acked' | 'already_cancelled'
      activation_status: 'not_required'
      activation_reason: null
      activation_detail: null
    }

export type DashboardScheduledAutomationDispatchReceipt =
  | ({
      projection_status: 'recognized'
      kind: 'masc.keeper_wake.enqueued'
      queue: string
      stimulus: string
      stimulus_id: string | null
      reaction_ledger_status: 'recorded' | 'record_failed' | null
      reaction_ledger_error: string | null
      keeper_name: string
      schedule_id: string
      urgency: string
      post_id: string
      result_delivery_policy?: 'none' | 'reply_to_origin'
    } & DashboardScheduledAutomationOccurrenceActivation)
  | {
      projection_status: 'unrecognized_detail'
      reason: string
    }

export interface DashboardScheduledAutomationKeeperReactionEvidence {
  projection_status:
    | 'matched_consumed_ack'
    | 'matched_turn_started'
    | 'matched_stimulus'
    | 'not_found'
    | 'quarantined'
    | 'read_error'
    | 'missing_stimulus_id'
    | 'invalid_stimulus_id'
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
  quarantined_record_count?: number
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
  projection_status: 'matched_pending' | 'not_found' | 'read_error' | 'unrecognized_receipt'
  source?: string
  queue?: string
  stimulus?: string
  keeper_name?: string
  schedule_id?: string
  post_id?: string
  pending_count?: number
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

export interface DashboardScheduledAutomationActor {
  id: string
  kind: string
  display_name?: string | null
}

export interface DashboardScheduledAutomationSignal {
  occurrence_id: string
  kind: string
  event_type?: string
  schedule_id: string
  emitted_at?: number
  emitted_at_iso?: string | null
  due_at?: number
  due_at_iso?: string | null
  payload_digest?: string
  payload_kind?: string | null
}

export interface DashboardScheduledAutomationRequest {
  schedule_id: string
  status: 'scheduled' | 'due' | 'running' | 'succeeded' | 'failed' | 'cancelled' | 'expired'
  /** Alias that makes clear this FSM tracks schedule dispatch, not result delivery. */
  dispatch_status?: DashboardScheduledAutomationRequest['status']
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
  last_wake?: DashboardScheduledAutomationWakeReceipt | null
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

/** Served by GET /api/v1/dashboard/scheduled-automation. Counts are nullable
 *  because the server reports a schedule-ledger read failure as null counts
 *  plus [schedule_store_read_error], and that distinction has to survive the
 *  decoder. */
export interface DashboardScheduledAutomation {
  schema?: string
  source?: string
  generated_at?: string
  schedule_store_known?: boolean
  schedule_store_read_error?: string | null
  status?: string
  request_count: number | null
  request_limit: number | null
  truncated: boolean
  signal_source?: string
  signal_count?: number
  signal_limit?: number
  signals?: DashboardScheduledAutomationSignal[]
  counts: Record<string, number> | null
  payload_support?: DashboardScheduledAutomationPayloadSupport
  warnings?: string[]
  live_supported_non_terminal_evidence?: DashboardScheduledAutomationLiveSupportedNonTerminalEvidence
  fsm: DashboardScheduledAutomationFsm
  requests: DashboardScheduledAutomationRequest[]
}

export type DashboardKeeperWaitingSource =
  | 'event_queue_pending'
  | 'chat_operation_queued'
  | 'chat_operation_running'
  | 'hitl_pending'
  | 'external_attention'
  | 'fusion_running'
  | 'schedule_waiting'
  | 'owner_shutdown'
  | 'operator_pending_confirm'
  | 'read_error'

export const DASHBOARD_KEEPER_WAITING_SOURCE_VALUES = [
  'event_queue_pending',
  'chat_operation_queued',
  'chat_operation_running',
  'hitl_pending',
  'external_attention',
  'fusion_running',
  'schedule_waiting',
  'owner_shutdown',
  'operator_pending_confirm',
  'read_error',
] as const satisfies ReadonlyArray<DashboardKeeperWaitingSource>

type NoMissingWaitingSource<Missing extends never> = Missing
export type _DashboardKeeperWaitingSourceComplete = NoMissingWaitingSource<
  Exclude<
    DashboardKeeperWaitingSource,
    (typeof DASHBOARD_KEEPER_WAITING_SOURCE_VALUES)[number]
  >
>

const DASHBOARD_KEEPER_WAITING_SOURCE_SET: ReadonlySet<string> =
  new Set(DASHBOARD_KEEPER_WAITING_SOURCE_VALUES)

/** Exact parser for the backend's closed waiting-inventory source vocabulary. */
export function parseDashboardKeeperWaitingSource(
  value: unknown,
): DashboardKeeperWaitingSource | null {
  return typeof value === 'string' && DASHBOARD_KEEPER_WAITING_SOURCE_SET.has(value)
    ? value as DashboardKeeperWaitingSource
    : null
}

export type DashboardKeeperWaitingState = 'idle' | 'busy' | 'waiting' | 'deferred'

export interface DashboardKeeperWaitingRow {
  keeper_name?: string | null
  source: DashboardKeeperWaitingSource
  waiting_on: string
  /** Operator sentence the server derives from the row's typed fields
   *  (`server_keeper_waiting_inventory.ml`); the default reading of a row.
   *  `waiting_on` / `wake_producer` / `next_action` / `detail` are the raw
   *  vocabulary behind the technical disclosure. */
  what: string
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
  state: DashboardKeeperWaitingState
  waiting_on: DashboardKeeperWaitingRow[]
  waiting_count: number
  waiting_count_truncated?: boolean
  truncated_sources?: Record<string, boolean>
  sources?: Record<string, number>
  since?: number | null
  since_iso?: string | null
  due_at?: number | null
  due_at_iso?: string | null
  source_next_actions?: Record<string, string[]>
  current_execution?: {
    turn_phase?: string
    decision?: { stage?: string }
    runtime?: { state?: string }
    latest_tool?: {
      name?: string
      used_at?: number
      used_at_iso?: string
    } | null
    run_state?: {
      kind?: string
      wake_kind?: string
      stimulus_kinds?: string[]
      active_tool_count?: number
    }
    live_turn?: {
      turn_id?: number
      started_at?: number
      last_progress_at?: number
      last_progress_kind?: string | null
      selected_model?: string | null
      active_tool_count?: number
    } | null
  } | null
  /** @deprecated Use source_next_actions; retained while older consumers migrate. */
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

function normalizeKeeperWaitingRow(row: DashboardKeeperWaitingRow): DashboardKeeperWaitingRow {
  const source = parseDashboardKeeperWaitingSource(row.source)
  if (!source) {
    throw new Error(`Unknown keeper waiting inventory source: ${JSON.stringify(row.source)}`)
  }
  return { ...row, source }
}

export function normalizeKeeperWaitingInventory(
  inventory: DashboardKeeperWaitingInventory,
): DashboardKeeperWaitingInventory {
  return {
    ...inventory,
    keepers: inventory.keepers.map(keeper => ({
      ...keeper,
      waiting_on: keeper.waiting_on.map(normalizeKeeperWaitingRow),
    })),
    ...(inventory.global_waiting_on
      ? { global_waiting_on: inventory.global_waiting_on.map(normalizeKeeperWaitingRow) }
      : {}),
  }
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
  keeper_waiting_inventory?: DashboardKeeperWaitingInventory
  keeper_background?: DashboardKeeperBackground
}

export interface DashboardScheduleRunnerCounts {
  due_changed?: number
  emitted?: number
  rescheduled?: number
  dispatch_succeeded?: number
  dispatch_failed?: number
  dispatch_unsupported?: number
  dispatch_start_rejected?: number
  wake_enqueued?: number
  wake_skipped_no_keeper?: number
  wake_skipped_missing_schedule?: number
  wake_skipped_non_keeper_actor?: number
  wake_skipped_unregistered_keeper?: number
  wake_failed?: number
}

export interface DashboardScheduleRunnerStatus {
  schema?: string
  status?: string
  tick_in_flight?: boolean
  tick_count?: number
  success_count?: number
  failure_count?: number
  crash_count?: number
  last_tick_started_at?: number | null
  last_tick_finished_at?: number | null
  last_success_at?: number | null
  last_error_at?: number | null
  last_error?: string | null
  last_duration_sec?: number | null
  last_counts?: DashboardScheduleRunnerCounts | null
  stale_after_sec?: number | null
  last_tick_age_sec?: number | null
  last_success_age_sec?: number | null
  last_error_age_sec?: number | null
}

export interface DashboardKeeperQueueStorageIntegrity {
  schema?: string
  status: string
  counts_complete: boolean
  read_error_count: number
  transition_outbox_count: number
  operator_action_required: boolean
}

export interface DashboardKeeperQueueWorkLiveness {
  schema?: string
  status: string
  state: 'idle' | 'backlogged' | 'blocked' | 'stalled' | 'unknown'
  runnable_backlog_count: number
  runnable_oldest_age_seconds: number | null
  stale_after_seconds: number | null
  operator_action_required: boolean
}

export interface DashboardKeeperEventQueueHealth {
  schema?: string
  status: string
  operator_action_required: boolean
  status_reasons: string[]
  backlog_clean: boolean
  storage_integrity: DashboardKeeperQueueStorageIntegrity | null
  work_liveness: DashboardKeeperQueueWorkLiveness | null
}

export type DashboardFullHealthSnapshotStatus =
  | 'ready'
  | 'warming'
  | 'stale'
  | 'timeout'
  | 'error'

export interface DashboardFullHealthSnapshot {
  status: DashboardFullHealthSnapshotStatus
  stale_reason: string | null
  last_good_available: boolean
  component_timed_out: boolean
}

export interface DashboardFullHealthResponse {
  health_detail?: string
  overall_status?: string | null
  operator_action_required?: boolean | null
  operator_action_reasons?: string[]
  full_health_snapshot?: DashboardFullHealthSnapshot | null
  schedule_runner?: DashboardScheduleRunnerStatus | null
  keeper_event_queue?: DashboardKeeperEventQueueHealth | null
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

export async function fetchDashboardFullHealth(
  opts?: AbortableRequestOptions,
): Promise<DashboardFullHealthResponse> {
  const raw = await get<DashboardFullHealthResponse>('/health?full=1', { signal: opts?.signal })
  return normalizeFullHealthResponse(raw)
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null
}

export function normalizeScheduleRunnerStatus(
  raw: unknown,
): DashboardScheduleRunnerStatus | null {
  const record = asRecord(raw)
  if (!record) return null

  const counts = asRecord(record.last_counts)
  const status: DashboardScheduleRunnerStatus = {
    schema: typeof record.schema === 'string' ? record.schema : undefined,
    status: typeof record.status === 'string' ? record.status : 'unknown',
    tick_in_flight: typeof record.tick_in_flight === 'boolean' ? record.tick_in_flight : false,
    tick_count: typeof record.tick_count === 'number' ? record.tick_count : 0,
    success_count: typeof record.success_count === 'number' ? record.success_count : 0,
    failure_count: typeof record.failure_count === 'number' ? record.failure_count : 0,
    crash_count: typeof record.crash_count === 'number' ? record.crash_count : 0,
    last_tick_started_at:
      typeof record.last_tick_started_at === 'number' ? record.last_tick_started_at : null,
    last_tick_finished_at:
      typeof record.last_tick_finished_at === 'number' ? record.last_tick_finished_at : null,
    last_success_at:
      typeof record.last_success_at === 'number' ? record.last_success_at : null,
    last_error_at:
      typeof record.last_error_at === 'number' ? record.last_error_at : null,
    last_error:
      typeof record.last_error === 'string' ? record.last_error : null,
    last_duration_sec:
      typeof record.last_duration_sec === 'number' ? record.last_duration_sec : null,
    last_counts: counts
      ? {
          due_changed:
            typeof counts.due_changed === 'number' ? counts.due_changed : undefined,
          emitted:
            typeof counts.emitted === 'number' ? counts.emitted : undefined,
          rescheduled:
            typeof counts.rescheduled === 'number' ? counts.rescheduled : undefined,
          dispatch_succeeded:
            typeof counts.dispatch_succeeded === 'number' ? counts.dispatch_succeeded : undefined,
          dispatch_failed:
            typeof counts.dispatch_failed === 'number' ? counts.dispatch_failed : undefined,
          dispatch_unsupported:
            typeof counts.dispatch_unsupported === 'number' ? counts.dispatch_unsupported : undefined,
          dispatch_start_rejected:
            typeof counts.dispatch_start_rejected === 'number' ? counts.dispatch_start_rejected : undefined,
          wake_enqueued:
            typeof counts.wake_enqueued === 'number' ? counts.wake_enqueued : undefined,
          wake_skipped_no_keeper:
            typeof counts.wake_skipped_no_keeper === 'number' ? counts.wake_skipped_no_keeper : undefined,
          wake_skipped_missing_schedule:
            typeof counts.wake_skipped_missing_schedule === 'number'
              ? counts.wake_skipped_missing_schedule
              : undefined,
          wake_skipped_non_keeper_actor:
            typeof counts.wake_skipped_non_keeper_actor === 'number'
              ? counts.wake_skipped_non_keeper_actor
              : undefined,
          wake_skipped_unregistered_keeper:
            typeof counts.wake_skipped_unregistered_keeper === 'number'
              ? counts.wake_skipped_unregistered_keeper
              : undefined,
          wake_failed:
            typeof counts.wake_failed === 'number' ? counts.wake_failed : undefined,
        }
      : null,
    stale_after_sec: typeof record.stale_after_sec === 'number' ? record.stale_after_sec : null,
    last_tick_age_sec:
      typeof record.last_tick_age_sec === 'number' ? record.last_tick_age_sec : null,
    last_success_age_sec:
      typeof record.last_success_age_sec === 'number' ? record.last_success_age_sec : null,
    last_error_age_sec:
      typeof record.last_error_age_sec === 'number' ? record.last_error_age_sec : null,
  }
  return status
}

export function normalizeFullHealthResponse(
  raw: DashboardFullHealthResponse,
): DashboardFullHealthResponse {
  const scheduleRunner = normalizeScheduleRunnerStatus(raw.schedule_runner)
  const keeperEventQueue = normalizeKeeperEventQueueHealth(raw.keeper_event_queue)
  const fullHealthSnapshot = normalizeFullHealthSnapshot(raw.full_health_snapshot)
  return {
    ...raw,
    overall_status: typeof raw.overall_status === 'string' ? raw.overall_status : null,
    operator_action_required:
      typeof raw.operator_action_required === 'boolean' ? raw.operator_action_required : null,
    operator_action_reasons: Array.isArray(raw.operator_action_reasons)
      ? raw.operator_action_reasons.filter((value): value is string => typeof value === 'string')
      : [],
    full_health_snapshot: fullHealthSnapshot,
    ...(scheduleRunner ? { schedule_runner: scheduleRunner } : {}),
    ...(keeperEventQueue ? { keeper_event_queue: keeperEventQueue } : {}),
  }
}

const FULL_HEALTH_SNAPSHOT_STATUSES: ReadonlySet<DashboardFullHealthSnapshotStatus> = new Set([
  'ready',
  'warming',
  'stale',
  'timeout',
  'error',
])

function normalizeFullHealthSnapshot(raw: unknown): DashboardFullHealthSnapshot | null {
  const record = asRecord(raw)
  if (!record) return null
  const status = typeof record.status === 'string' ? record.status : null
  if (!status || !FULL_HEALTH_SNAPSHOT_STATUSES.has(status as DashboardFullHealthSnapshotStatus)) {
    return null
  }
  const staleReason = record.stale_reason
  if (
    !(staleReason === null || typeof staleReason === 'string')
    || typeof record.last_good_available !== 'boolean'
    || typeof record.component_timed_out !== 'boolean'
  ) {
    return null
  }
  return {
    status: status as DashboardFullHealthSnapshotStatus,
    stale_reason: staleReason,
    last_good_available: record.last_good_available,
    component_timed_out: record.component_timed_out,
  }
}

function normalizeKeeperEventQueueHealth(raw: unknown): DashboardKeeperEventQueueHealth | null {
  const record = asRecord(raw)
  if (!record) return null
  const storage = asRecord(record.storage_integrity)
  const work = asRecord(record.work_liveness)
  const workState = work?.state
  const normalizedWorkState: DashboardKeeperQueueWorkLiveness['state'] =
    workState === 'idle'
      || workState === 'backlogged'
      || workState === 'blocked'
      || workState === 'stalled'
      ? workState
      : 'unknown'
  return {
    schema: typeof record.schema === 'string' ? record.schema : undefined,
    status: typeof record.status === 'string' ? record.status : 'unknown',
    operator_action_required: record.operator_action_required === true,
    status_reasons: Array.isArray(record.status_reasons)
      ? record.status_reasons.filter((value): value is string => typeof value === 'string')
      : [],
    backlog_clean: record.backlog_clean === true,
    storage_integrity: storage
      ? {
          schema: typeof storage.schema === 'string' ? storage.schema : undefined,
          status: typeof storage.status === 'string' ? storage.status : 'unknown',
          counts_complete: storage.counts_complete === true,
          read_error_count: typeof storage.read_error_count === 'number' ? storage.read_error_count : 0,
          transition_outbox_count:
            typeof storage.transition_outbox_count === 'number' ? storage.transition_outbox_count : 0,
          operator_action_required: storage.operator_action_required === true,
        }
      : null,
    work_liveness: work
      ? {
          schema: typeof work.schema === 'string' ? work.schema : undefined,
          status: typeof work.status === 'string' ? work.status : 'unknown',
          state: normalizedWorkState,
          runnable_backlog_count:
            typeof work.runnable_backlog_count === 'number' ? work.runnable_backlog_count : 0,
          runnable_oldest_age_seconds:
            typeof work.runnable_oldest_age_seconds === 'number' ? work.runnable_oldest_age_seconds : null,
          stale_after_seconds:
            typeof work.stale_after_seconds === 'number' ? work.stale_after_seconds : null,
          operator_action_required: work.operator_action_required === true,
        }
      : null,
  }
}

export async function fetchDashboardTools(opts?: AbortableRequestOptions): Promise<DashboardToolsResponse> {
  await ensureDevToken()
  const raw = await get<DashboardToolsResponse>('/api/v1/dashboard/tools', { signal: opts?.signal })
  const normalizedTools = raw.tool_inventory?.tools?.map(t => ({
    ...t,
    category: t.category ?? 'uncategorized',
    tier: t.tier ?? '(unknown tier)',
    // Tool-layer decoupling groundwork: surface membership is consumer-owned
    // metadata, not an wake constraint. Totalize here so the field is
    // never absent downstream; consumers keep working with [] and the surface
    // filter simply degrades to zero counts. Mirrors category/tier above.
    surfaces: t.surfaces ?? [],
  }))
  const normalizedWaitingInventory = raw.keeper_waiting_inventory
    ? normalizeKeeperWaitingInventory(raw.keeper_waiting_inventory)
    : undefined
  return {
    ...raw,
    tool_inventory: {
      ...raw.tool_inventory,
      ...(normalizedTools ? { tools: normalizedTools } : {}),
    },
    ...(normalizedWaitingInventory
      ? { keeper_waiting_inventory: normalizedWaitingInventory }
      : {}),
  }
}

export async function fetchKeeperWaitingInventory(
  keeperName: string,
  opts?: AbortableRequestOptions,
): Promise<DashboardKeeperWaitingInventory> {
  await ensureDevToken()
  const raw = await get<DashboardKeeperWaitingInventory>(
    `/api/v1/keepers/${encodeURIComponent(keeperName)}/waiting-inventory`,
    { signal: opts?.signal },
  )
  return normalizeKeeperWaitingInventory(raw)
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
