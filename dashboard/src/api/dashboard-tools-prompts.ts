// MASC Dashboard — Tool metrics / runtime probe / tools inventory / prompts.
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, getWithResponse, post, type AbortableRequestOptions } from './core'
import { isObserverInstance, OBSERVER_INSTANCE_HEADER, ObserverScopeError } from '../lib/observer-protocol'
import { ensureDevToken } from './dev-token'
import type { TelemetryFreshnessMetadata } from './dashboard-shared'
import type { DashboardConfigResolution, DashboardRuntimeResolution } from '../types'
import type { DashboardRuntimeProbeResponse } from './schemas/runtime-probe'
import type {
  ScheduleQueueProjectionStatus,
  ScheduleReactionProjectionStatus,
} from './schedule-projection-status'
import type { PromptAuthoringIssue } from './schemas/prompt-authoring'
import {
  parseToolMetricsSeriesResponse,
  seriesAnswerMismatch,
  toolMetricsSeriesQuery,
  type ToolMetricsSeriesRequest,
  type ToolMetricsSeriesResponse,
} from './schemas/tool-metrics-series'

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

export interface ToolMetricsResponse {
  metrics_source?: {
    kind: 'tool_metrics'
    scope: 'retained_snapshot_and_current_process'
    persistence: 'sqlite'
  }
  catalog_usage?: {
    visible_total: number
    visible_called: number
    visible_without_observed_call: number
    hidden_called: number
    outside_catalog_called: number
  }
  non_public_call_log?: TelemetryFreshnessMetadata
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
  /** Absent on historical wake rows that predate dispatch-attempt identity. */
  attempt_id?: string
  /** Durable settlement decision; absent for an unsettled or historical wake. */
  settlement_kind?: string
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
        | 'owner_not_current'
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

export type ScheduledTurnDisposition =
  | 'completed'
  | 'checkpointed'
  | 'input_required'
  | 'cancelled'
  | 'skipped'
  | 'failed'
  | 'rested'

export interface DashboardScheduledAutomationKeeperReactionEvidence {
  // Ranked by the server: cancelled and ack are terminal, finished outranks
  // started, and a stimulus row alone is the producer's record, not a
  // reaction. The two terminals together are a contradiction the server
  // names rather than resolves.
  projection_status: ScheduleReactionProjectionStatus
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
  /** How the turn the wake started ended (Keeper_reaction_ledger.Turn_disposition); null until it finishes. */
  turn_finished_disposition?: ScheduledTurnDisposition | null
  event_queue_ack_seen?: boolean
  event_queue_cancelled_seen?: boolean
  matched_record_count?: number
  quarantined_record_count?: number
  stimulus_recorded_at?: number | null
  stimulus_recorded_at_iso?: string | null
  turn_started_recorded_at?: number | null
  turn_started_recorded_at_iso?: string | null
  turn_finished_recorded_at?: number | null
  turn_finished_recorded_at_iso?: string | null
  event_queue_ack_recorded_at?: number | null
  event_queue_ack_recorded_at_iso?: string | null
  event_queue_cancelled_recorded_at?: number | null
  event_queue_cancelled_recorded_at_iso?: string | null
  latest_recorded_at?: number | null
  latest_recorded_at_iso?: string | null
  reason?: string
}

export interface DashboardScheduledAutomationKeeperQueueEvidence {
  resolved_owner?: string
  transfer_target?: string
  transition_id?: string
  terminal_outcome?: 'completed' | 'cancelled'
  terminal_reason?: string | null
  projection_status: ScheduleQueueProjectionStatus
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
  /** Bare keeper name of a keeper_wake payload (no `keeper:` display prefix);
   *  null/absent for every other payload kind. */
  payload_keeper_name?: string | null
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

/** Retained wake outcomes across the schedules the page selects. `counts`
 *  describes definitions; these describe attempts, every retained one and not
 *  only the newest of the rows on the page. `retention_per_schedule` is the
 *  store's ceiling: the numbers are a window, not a history. */
export interface DashboardScheduledAutomationWakeCounts {
  /** Terminal attempts the store keeps (succeeded + failed); the ceiling applies to these. */
  retained: number
  /** Attempts mid-dispatch right now; not part of `retained`. */
  running: number
  succeeded: number
  failed: number
  /** Live definitions whose newest attempt did not land. */
  active_with_failed_newest_wake: number
  retention_per_schedule: number
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
  /** Null when the ledger read failed or the server predates the field. */
  wake_counts?: DashboardScheduledAutomationWakeCounts | null
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
  | 'fusion_running'
  | 'schedule_waiting'
  | 'owner_shutdown'
  | 'operator_pending_confirm'
  | 'runtime_quota_spent'
  | 'read_error'
  | 'observation_unavailable'

export const DASHBOARD_KEEPER_WAITING_SOURCE_VALUES = [
  'event_queue_pending',
  'chat_operation_queued',
  'chat_operation_running',
  'hitl_pending',
  'fusion_running',
  'schedule_waiting',
  'owner_shutdown',
  'operator_pending_confirm',
  'runtime_quota_spent',
  'read_error',
  'observation_unavailable',
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
  /** The sources that put the Keeper in `state`, as the server listed them:
   *  the deferring ones for `deferred`, all of them for `waiting`, none for
   *  `idle` and `busy`. */
  state_sources: string[]
  waiting_on: DashboardKeeperWaitingRow[]
  waiting_count: number
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
    keepers: inventory.keepers.map(keeper => {
      const stateSources: unknown = keeper.state_sources
      if (!Array.isArray(stateSources) || !stateSources.every(source => typeof source === 'string')) {
        throw new Error(
          `Keeper waiting inventory row for ${JSON.stringify(keeper.keeper_name)} has no state_sources list`,
        )
      }
      return {
        ...keeper,
        waiting_on: keeper.waiting_on.map(normalizeKeeperWaitingRow),
      }
    }),
    ...(inventory.global_waiting_on
      ? { global_waiting_on: inventory.global_waiting_on.map(normalizeKeeperWaitingRow) }
      : {}),
  }
}

export interface DashboardToolsWarmingProjection {
  status: 'warming'
}

export interface DashboardToolsResponse {
  generated_at?: string
  status?: string
  is_warming?: boolean
  stale_reason?: string | null
  config_resolution?: DashboardConfigResolution | DashboardToolsWarmingProjection
  runtime_resolution?: DashboardRuntimeResolution | DashboardToolsWarmingProjection
  tool_inventory: DashboardToolInventoryResponse
  tool_usage: ToolMetricsResponse
  keeper_waiting_inventory?: DashboardKeeperWaitingInventory
  effective_keeper_surface?: DashboardEffectiveKeeperSurface | null
}

export interface DashboardSkillReference {
  identity: {
    source_id: string
    package_id: string
    name: string
  }
  content_revision: string
}

export type DashboardToolDelivery =
  | { status: 'delivered' }
  | { status: 'suppressed'; reason: 'runtime_tools_unsupported' }

export type DashboardSkillLoadReason =
  | { kind: 'catalog_default' }
  | { kind: 'keeper_profile' }
  | { kind: 'task'; task_id: string }

export interface DashboardEffectiveSkillProfile {
  reference: DashboardSkillReference
  kind: string
  execution: string
  context: {
    body_bytes: number
    discovery_bytes: number
    tool_schema_bytes: number | null
  }
  load_reasons: DashboardSkillLoadReason[]
}

export type DashboardEffectiveKeeperSurface =
  | {
      status: 'available'
      keeper_name: string
      runtime_id: string
      official_client_kind: string
      tool_delivery: DashboardToolDelivery
      native_posture: string | null
      skill_selection:
        | { mode: 'all' }
        | { mode: 'names'; names: string[] }
      unavailable_skill_names: Array<{
        name: string
        reason: 'not_in_turn_skill_catalog'
      }>
      current_task_id: string | null
      skill_snapshot_revision: string
      skill_resource_read_max_bytes: number | null
      instruction_skills: DashboardSkillReference[]
      composition_skills: DashboardSkillReference[]
      skill_profiles: DashboardEffectiveSkillProfile[]
      tool_surface_bytes: number
      skill_tool_surface_bytes: number
      skill_discovery_bytes: number
      skill_body_bytes: number
      skills_left_out: string[]
      count: number
      tools: Array<{ name: string; origin: { kind: string } }>
      tool_surface_sha256: string | null
    }
  | {
      status: 'unavailable'
      keeper_name: string
      reason: string
      detail: string
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

export type DashboardKeeperQueueResidence =
  | { status: 'empty'; oldest_age_seconds: null; reason: null }
  | { status: 'observed'; oldest_admitted_at_unix: number; oldest_age_seconds: number; reason: null }
  | { status: 'unknown'; oldest_age_seconds: null;
      reason: 'first_admission_not_recorded' | 'queue_observation_incomplete' | 'clock_observation_invalid' }

export interface DashboardKeeperQueueWorkLiveness {
  schema?: string
  status: string
  state: 'idle' | 'backlogged' | 'blocked' | 'unknown'
  runnable_backlog_count: number
  runnable_oldest_source_age_seconds: number | null
  queue_residence: DashboardKeeperQueueResidence | null
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

/** `dashboard_surface` block of /health (masc.dashboard_surface.v1): the
 *  server's own verdict on whether the bundle it serves — the very UI the
 *  reader is looking at — is current, stale, or missing its build stamp. */
export interface DashboardSurfaceHealth {
  status?: string
  next_action?: string
  build_stamp_at?: string
  dashboard_source_commit?: string
  binary_source_commit?: string
  source_provenance?: string
}

export interface DashboardFullHealthResponse {
  health_detail?: string
  overall_status?: string | null
  operator_action_required?: boolean | null
  operator_action_reasons?: string[]
  full_health_snapshot?: DashboardFullHealthSnapshot | null
  schedule_runner?: DashboardScheduleRunnerStatus | null
  keeper_event_queue?: DashboardKeeperEventQueueHealth | null
  dashboard_surface?: DashboardSurfaceHealth | null
  build?: import('../types/dashboard-execution').ServerBuildIdentity | null
}

// --- Runtime provider reachability probe ---

export type {
  DashboardRuntimeProviderProbe,
  DashboardRuntimeProbePayload,
  DashboardRuntimeProbeResponse,
} from './schemas/runtime-probe'

export type { ToolMetricsSeriesRequest }

export async function fetchToolMetricsSeries(
  request: ToolMetricsSeriesRequest,
  opts?: AbortableRequestOptions,
): Promise<ToolMetricsSeriesResponse> {
  const raw = await get<unknown>(`/api/v1/tool-metrics/series?${toolMetricsSeriesQuery(request)}`, {
    signal: opts?.signal,
  })
  const response = parseToolMetricsSeriesResponse(raw)
  const mismatch = seriesAnswerMismatch(request, response)
  if (mismatch !== null) throw new Error(mismatch)
  return response
}

export async function fetchDashboardRuntimeProbe(
  force = false,
  opts?: AbortableRequestOptions,
): Promise<DashboardRuntimeProbeResponse> {
  const query = force ? '?force=1' : ''
  await ensureDevToken()
  const raw = await get<unknown>(`/api/v1/dashboard/runtime-probe${query}`, { signal: opts?.signal })
  const { parseDashboardRuntimeProbeResponse } = await import('./schemas/runtime-probe')
  return parseDashboardRuntimeProbeResponse(raw)
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

function normalizeKeeperQueueResidence(raw: unknown): DashboardKeeperQueueResidence | null {
  const record = asRecord(raw)
  if (!record) return null
  if (record.status === 'observed') {
    if (record.reason !== null || typeof record.oldest_admitted_at_unix !== 'number'
      || !Number.isFinite(record.oldest_admitted_at_unix)
      || typeof record.oldest_age_seconds !== 'number' || !Number.isFinite(record.oldest_age_seconds)
      || record.oldest_age_seconds < 0) return null
    return { status: 'observed', oldest_admitted_at_unix: record.oldest_admitted_at_unix,
      oldest_age_seconds: record.oldest_age_seconds, reason: null }
  }
  if (record.status === 'empty' && record.oldest_age_seconds === null && record.reason === null) {
    return { status: 'empty', oldest_age_seconds: null, reason: null }
  }
  if (record.status !== 'unknown' || record.oldest_age_seconds !== null) return null
  if (record.reason !== 'first_admission_not_recorded' && record.reason !== 'queue_observation_incomplete'
    && record.reason !== 'clock_observation_invalid') return null
  return { status: 'unknown', oldest_age_seconds: null, reason: record.reason }
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
          runnable_oldest_source_age_seconds:
            typeof work.runnable_oldest_source_age_seconds === 'number' ? work.runnable_oldest_source_age_seconds : null,
          queue_residence: normalizeKeeperQueueResidence(work.queue_residence),
          operator_action_required: work.operator_action_required === true,
        }
      : null,
  }
}

export interface DashboardToolsRequestOptions extends AbortableRequestOptions {
  keeperName?: string
}

export async function fetchDashboardTools(opts?: DashboardToolsRequestOptions): Promise<DashboardToolsResponse> {
  await ensureDevToken()
  const keeperQuery = opts?.keeperName
    ? `?keeper=${encodeURIComponent(opts.keeperName)}`
    : ''
  const raw = await get<DashboardToolsResponse>(`/api/v1/dashboard/tools${keeperQuery}`, { signal: opts?.signal })
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
  observerInstance: string,
  opts?: AbortableRequestOptions,
): Promise<DashboardKeeperWaitingInventory> {
  if (!isObserverInstance(observerInstance)) throw new Error('observer generation is unavailable')
  await ensureDevToken()
  const { data } = await getWithResponse<DashboardKeeperWaitingInventory>(
    `/api/v1/keepers/${encodeURIComponent(keeperName)}/waiting-inventory`,
    {
      signal: opts?.signal,
      extraHeaders: { [OBSERVER_INSTANCE_HEADER]: observerInstance },
      consumeWithinTimeout: true,
      beforeResponseBody: response => {
        if (response.ok && response.headers.get(OBSERVER_INSTANCE_HEADER) !== observerInstance) {
          throw new ObserverScopeError()
        }
      },
    },
  )
  return normalizeKeeperWaitingInventory(data)
}

// --- Prompts (override management) ---

export type PromptSource = 'override' | 'file' | 'missing'

export interface DashboardPromptItem {
  key: string
  authoring_issues: readonly PromptAuthoringIssue[]
  category: string
  description: string
  current: string
  effective: string
  file_value: string | null
  override_value: string | null
  file_path: string | null
  /** Where the effective text came from. The server resolves this once, from
   *  the override and the file, and sends the answer. It also sends the two
   *  booleans that resolution consumed; modelling them here gave the panel a
   *  second way to spell the same decision, and it used both. */
  source: PromptSource
  char_count: number
  required_file: boolean
  template_variables: string[]
}

export interface DashboardRuntimePromptAsset {
  path: string
  file_path: string
  value: string
  file_exists: boolean
  char_count: number
}

interface DashboardPromptsResponse {
  prompts: DashboardPromptItem[]
  runtime_assets?: DashboardRuntimePromptAsset[]
}

interface PromptMutationResponse {
  curator_refresh?: { status: 'queued' | 'no_owner' } | { status: 'unavailable'; detail: string } | null
  ok: boolean
  message?: string
  key?: string
  source?: PromptSource
  effective?: string
  error?: string
}

export async function fetchDashboardPrompts(): Promise<DashboardPromptsResponse> {
  const response = await get<DashboardPromptsResponse>('/api/v1/prompts')
  const { parsePromptAuthoringIssues } = await import('./schemas/prompt-authoring')
  return {
    ...response,
    prompts: response.prompts.map(prompt => ({
      ...prompt,
      authoring_issues: parsePromptAuthoringIssues(prompt.authoring_issues),
    })),
  }
}

export function savePromptOverride(key: string, value: string): Promise<PromptMutationResponse> {
  return post('/api/v1/prompts', { action: 'set', key, value })
}

export function clearPromptOverride(key: string): Promise<PromptMutationResponse> {
  return post('/api/v1/prompts', { action: 'clear', key })
}
