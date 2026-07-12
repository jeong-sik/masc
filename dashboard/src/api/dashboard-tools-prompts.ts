// MASC Dashboard — Tool metrics / runtime probe / tools inventory / prompts.
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, post, type AbortableRequestOptions } from './core'
import { ensureDevToken } from './dev-token'
import type { TelemetryFreshnessMetadata } from './dashboard-shared'
import type { DashboardConfigResolution, DashboardRuntimeResolution } from '../types'
import { isKeeperChatReceiptId } from '../lib/keeper-chat-receipt'

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

export type DashboardKeeperWaitingSource =
  | 'event_queue_pending'
  | 'event_queue_inflight'
  | 'chat_queue_pending'
  | 'chat_queue_inflight'
  | 'hitl_pending'
  | 'external_attention'
  | 'fusion_running'
  | 'background_task'
  | 'schedule_waiting'
  | 'turn_admission_waiting'
  | 'turn_admission_shutdown'
  | 'operator_pending_confirm'
  | 'read_error'

export const DASHBOARD_KEEPER_WAITING_SOURCE_VALUES = [
  'event_queue_pending',
  'event_queue_inflight',
  'chat_queue_pending',
  'chat_queue_inflight',
  'hitl_pending',
  'external_attention',
  'fusion_running',
  'background_task',
  'schedule_waiting',
  'turn_admission_waiting',
  'turn_admission_shutdown',
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

export type DashboardKeeperWaitingMetadataStatus = 'registered' | 'queue_only'
export type DashboardKeeperWaitingVisibility = 'operator' | 'redacted'

export type DashboardKeeperWaitingWakeProducer =
  | 'board_dispatch'
  | 'keeper_chat_queue_store'
  | 'keeper_supervisor'
  | 'keeper_no_progress_recovery'
  | 'fusion_sink'
  | 'bg_task_completion'
  | 'connector_attention_hook'
  | 'hitl_resolution_hook'
  | 'external_attention_store'
  | 'schedule_store'
  | 'schedule_runner'
  | 'keeper_turn_admission'
  | 'operator_pending_confirm_store'
  | 'goal_verification_store'
  | 'keeper_turn_failure_route'
  | 'keeper_goal_assignment'
  | 'keeper_goal_stagnation'
  | 'read_model_reader'

export const DASHBOARD_KEEPER_WAITING_STATE_VALUES = [
  'idle',
  'busy',
  'waiting',
  'deferred',
] as const satisfies ReadonlyArray<DashboardKeeperWaitingState>

const DASHBOARD_KEEPER_WAITING_STATE_SET: ReadonlySet<string> =
  new Set(DASHBOARD_KEEPER_WAITING_STATE_VALUES)

/** Exact parser for the backend's closed per-Keeper state vocabulary. */
export function parseDashboardKeeperWaitingState(
  value: unknown,
): DashboardKeeperWaitingState | null {
  return typeof value === 'string' && DASHBOARD_KEEPER_WAITING_STATE_SET.has(value)
    ? value as DashboardKeeperWaitingState
    : null
}

const DASHBOARD_KEEPER_WAITING_METADATA_STATUS_VALUES = [
  'registered',
  'queue_only',
] as const satisfies ReadonlyArray<DashboardKeeperWaitingMetadataStatus>

const DASHBOARD_KEEPER_WAITING_METADATA_STATUS_SET: ReadonlySet<string> =
  new Set(DASHBOARD_KEEPER_WAITING_METADATA_STATUS_VALUES)

const DASHBOARD_KEEPER_WAITING_VISIBILITY_VALUES = [
  'operator',
  'redacted',
] as const satisfies ReadonlyArray<DashboardKeeperWaitingVisibility>

const DASHBOARD_KEEPER_WAITING_VISIBILITY_SET: ReadonlySet<string> =
  new Set(DASHBOARD_KEEPER_WAITING_VISIBILITY_VALUES)

const DASHBOARD_KEEPER_WAITING_WAKE_PRODUCER_VALUES = [
  'board_dispatch',
  'keeper_chat_queue_store',
  'keeper_supervisor',
  'keeper_no_progress_recovery',
  'fusion_sink',
  'bg_task_completion',
  'connector_attention_hook',
  'hitl_resolution_hook',
  'external_attention_store',
  'schedule_store',
  'schedule_runner',
  'keeper_turn_admission',
  'operator_pending_confirm_store',
  'goal_verification_store',
  'keeper_turn_failure_route',
  'keeper_goal_assignment',
  'keeper_goal_stagnation',
  'read_model_reader',
] as const satisfies ReadonlyArray<DashboardKeeperWaitingWakeProducer>

const DASHBOARD_KEEPER_WAITING_WAKE_PRODUCER_SET: ReadonlySet<string> =
  new Set(DASHBOARD_KEEPER_WAITING_WAKE_PRODUCER_VALUES)

export type DashboardKeeperChatQueueSource =
  | { kind: 'dashboard' }
  | { kind: 'discord'; channel_id: string | null; user_id: string | null }
  | {
      kind: 'slack'
      channel_id: string | null
      user_id: string | null
      team_id: string | null
      thread_ts: string | null
    }

export interface DashboardKeeperChatQueueActiveReceipt {
  receipt_id: string
  queue_index: number
  message_source: DashboardKeeperChatQueueSource
  content_length: number
  user_block_count: number
  attachment_count: number
  submitted_at: number
  submitted_at_iso: string
  state: 'pending' | 'inflight'
  lease_id: string | null
  started_at: number | null
  started_at_iso: string | null
}

export type DashboardKeeperChatQueueLoadErrorKind =
  | 'invalid_path'
  | 'read_failed'
  | 'parse_failed'
  | 'migration_failed'
  | 'recovery_failed'

export interface DashboardKeeperChatQueueLoadError {
  kind: DashboardKeeperChatQueueLoadErrorKind
  path: string | null
  message: string | null
}

export type DashboardKeeperChatQueueFailureKind =
  | 'turn_failed'
  | 'timed_out'
  | 'no_visible_reply'
  | 'transcript_persist_failed'
  | 'connector_unavailable'
  | 'delivery_failed'
  | 'cancelled'
  | 'internal_error'

export interface DashboardKeeperChatQueueFailedReceipt {
  receipt_id: string
  state: 'failed'
  failure_kind: DashboardKeeperChatQueueFailureKind
  completed_at: number
  completed_at_iso: string
  outcome_ref: string | null
}

export interface DashboardKeeperChatQueue {
  schema: 'keeper_chat_queue.dashboard.v1'
  revision: number
  pending_count: number
  inflight_count: number
  active_receipts: DashboardKeeperChatQueueActiveReceipt[]
  read_errors: DashboardKeeperChatQueueLoadError[]
  next_action: string | null
  recent_failed_receipt_count: number
  recent_failed_receipt_limit: number
  recent_failed_receipts_truncated: boolean
  recent_failed_receipts: DashboardKeeperChatQueueFailedReceipt[]
}

export interface DashboardKeeperWaitingRow {
  keeper_name: string | null
  source: DashboardKeeperWaitingSource
  waiting_on: string
  wake_producer: DashboardKeeperWaitingWakeProducer
  since: number | null
  since_iso: string | null
  due_at: number | null
  due_at_iso: string | null
  next_action: string
  detail: unknown
}

export interface DashboardKeeperWaitingKeeper {
  keeper_name: string
  metadata_status: DashboardKeeperWaitingMetadataStatus
  state: DashboardKeeperWaitingState
  waiting_on: DashboardKeeperWaitingRow[]
  waiting_count: number
  waiting_count_truncated: boolean
  truncated_sources: Partial<Record<DashboardKeeperWaitingSource, boolean>>
  sources: Partial<Record<DashboardKeeperWaitingSource, number>>
  since: number | null
  since_iso: string | null
  due_at: number | null
  due_at_iso: string | null
  next_action: string | null
  chat_queue: DashboardKeeperChatQueue
}

export interface DashboardKeeperWaitingInventory {
  schema: 'masc.dashboard.keeper_waiting_inventory.v2'
  source: 'server_keeper_waiting_inventory'
  visibility: DashboardKeeperWaitingVisibility
  generated_at: string
  supported_states: DashboardKeeperWaitingState[]
  keeper_count_known: boolean
  keeper_count: number
  waiting_keeper_count: number
  row_count: number
  row_count_truncated: boolean
  external_attention_row_limit: number
  external_attention_truncated_keeper_count: number
  global_row_count: number
  global_pending_confirm_count_known: boolean
  global_pending_confirm_count: number
  source_counts: Partial<Record<DashboardKeeperWaitingSource, number>>
  keepers: DashboardKeeperWaitingKeeper[]
  global_waiting_on: DashboardKeeperWaitingRow[]
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

type DashboardJsonRecord = Record<string, unknown>

function dashboardProjectionError(path: string, expected: string): never {
  throw new Error(`Invalid dashboard tools projection at ${path}: expected ${expected}`)
}

function requireDashboardRecord(value: unknown, path: string): DashboardJsonRecord {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return dashboardProjectionError(path, 'object')
  }
  return value as DashboardJsonRecord
}

function requireDashboardArray(value: unknown, path: string): unknown[] {
  if (!Array.isArray(value)) return dashboardProjectionError(path, 'array')
  return value
}

function requireDashboardString(value: unknown, path: string): string {
  if (typeof value !== 'string' || value.trim() === '') {
    return dashboardProjectionError(path, 'non-empty string')
  }
  return value
}

function requireDashboardText(value: unknown, path: string): string {
  if (typeof value !== 'string') return dashboardProjectionError(path, 'string')
  return value
}

function requireDashboardNullableString(value: unknown, path: string): string | null {
  if (value === null) return null
  return requireDashboardString(value, path)
}

function requireDashboardNullableText(value: unknown, path: string): string | null {
  if (value === null) return null
  return requireDashboardText(value, path)
}

function requireDashboardFiniteNumber(value: unknown, path: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return dashboardProjectionError(path, 'finite number')
  }
  return value
}

function requireDashboardNullableFiniteNumber(value: unknown, path: string): number | null {
  if (value === null) return null
  return requireDashboardFiniteNumber(value, path)
}

function requireDashboardNonnegativeInteger(value: unknown, path: string): number {
  if (
    typeof value !== 'number'
    || !Number.isSafeInteger(value)
    || value < 0
  ) {
    return dashboardProjectionError(path, 'non-negative safe integer')
  }
  return value
}

function requireDashboardBoolean(value: unknown, path: string): boolean {
  if (typeof value !== 'boolean') return dashboardProjectionError(path, 'boolean')
  return value
}

function requireDashboardOwnField(
  record: DashboardJsonRecord,
  field: string,
  path: string,
): unknown {
  if (!Object.prototype.hasOwnProperty.call(record, field)) {
    return dashboardProjectionError(`${path}.${field}`, 'present field')
  }
  return record[field]
}

function requireDashboardIsoTimestamp(value: unknown, path: string): string {
  const timestamp = requireDashboardString(value, path)
  if (!Number.isFinite(Date.parse(timestamp))) {
    return dashboardProjectionError(path, 'ISO timestamp')
  }
  return timestamp
}

function parseDashboardTimestampPair(
  record: DashboardJsonRecord,
  numberField: string,
  isoField: string,
  path: string,
): { value: number | null; iso: string | null } {
  const value = requireDashboardNullableFiniteNumber(
    requireDashboardOwnField(record, numberField, path),
    `${path}.${numberField}`,
  )
  const isoValue = requireDashboardOwnField(record, isoField, path)
  const iso = isoValue === null
    ? null
    : requireDashboardIsoTimestamp(isoValue, `${path}.${isoField}`)
  if ((value === null) !== (iso === null)) {
    return dashboardProjectionError(
      path,
      `${numberField}/${isoField} to be both null or both populated`,
    )
  }
  return { value, iso }
}

function parseDashboardWaitingSourceCountRecord(
  value: unknown,
  path: string,
): Partial<Record<DashboardKeeperWaitingSource, number>> {
  const record = requireDashboardRecord(value, path)
  const parsed: Partial<Record<DashboardKeeperWaitingSource, number>> = {}
  for (const [rawSource, rawCount] of Object.entries(record)) {
    const source = parseDashboardKeeperWaitingSource(rawSource)
    if (!source) return dashboardProjectionError(`${path}.${rawSource}`, 'known waiting source')
    const count = requireDashboardNonnegativeInteger(rawCount, `${path}.${rawSource}`)
    if (count === 0) {
      return dashboardProjectionError(`${path}.${rawSource}`, 'positive source count')
    }
    parsed[source] = count
  }
  return parsed
}

function parseDashboardWaitingTruncationRecord(
  value: unknown,
  path: string,
): Partial<Record<DashboardKeeperWaitingSource, boolean>> {
  const record = requireDashboardRecord(value, path)
  const parsed: Partial<Record<DashboardKeeperWaitingSource, boolean>> = {}
  for (const [rawSource, rawTruncated] of Object.entries(record)) {
    const source = parseDashboardKeeperWaitingSource(rawSource)
    if (!source) return dashboardProjectionError(`${path}.${rawSource}`, 'known waiting source')
    const truncated = requireDashboardBoolean(rawTruncated, `${path}.${rawSource}`)
    if (!truncated) {
      return dashboardProjectionError(`${path}.${rawSource}`, 'true truncation marker')
    }
    parsed[source] = true
  }
  return parsed
}

function waitingSourceCounts(
  rows: ReadonlyArray<DashboardKeeperWaitingRow>,
): Partial<Record<DashboardKeeperWaitingSource, number>> {
  const counts: Partial<Record<DashboardKeeperWaitingSource, number>> = {}
  for (const row of rows) counts[row.source] = (counts[row.source] ?? 0) + 1
  return counts
}

function waitingSourceCountRecordsEqual(
  left: Partial<Record<DashboardKeeperWaitingSource, number>>,
  right: Partial<Record<DashboardKeeperWaitingSource, number>>,
): boolean {
  return DASHBOARD_KEEPER_WAITING_SOURCE_VALUES.every(
    source => (left[source] ?? 0) === (right[source] ?? 0),
  )
}

const DASHBOARD_KEEPER_CHAT_QUEUE_LOAD_ERROR_KIND_VALUES = [
  'invalid_path',
  'read_failed',
  'parse_failed',
  'migration_failed',
  'recovery_failed',
] as const satisfies ReadonlyArray<DashboardKeeperChatQueueLoadErrorKind>

const DASHBOARD_KEEPER_CHAT_QUEUE_LOAD_ERROR_KIND_SET: ReadonlySet<string> =
  new Set(DASHBOARD_KEEPER_CHAT_QUEUE_LOAD_ERROR_KIND_VALUES)

const DASHBOARD_KEEPER_CHAT_QUEUE_FAILURE_KIND_VALUES = [
  'turn_failed',
  'timed_out',
  'no_visible_reply',
  'transcript_persist_failed',
  'connector_unavailable',
  'delivery_failed',
  'cancelled',
  'internal_error',
] as const satisfies ReadonlyArray<DashboardKeeperChatQueueFailureKind>

const DASHBOARD_KEEPER_CHAT_QUEUE_FAILURE_KIND_SET: ReadonlySet<string> =
  new Set(DASHBOARD_KEEPER_CHAT_QUEUE_FAILURE_KIND_VALUES)

function parseDashboardKeeperChatQueueSource(
  value: unknown,
  path: string,
  visibility: DashboardKeeperWaitingVisibility,
): DashboardKeeperChatQueueSource {
  const source = requireDashboardRecord(value, path)
  const kind = requireDashboardString(source.kind, `${path}.kind`)
  switch (kind) {
    case 'dashboard':
      return { kind }
    case 'discord':
      if (visibility === 'redacted') {
        if (source.channel_id !== undefined || source.user_id !== undefined) {
          return dashboardProjectionError(path, 'redacted Discord source without route coordinates')
        }
        return { kind, channel_id: null, user_id: null }
      }
      return {
        kind,
        channel_id: requireDashboardString(source.channel_id, `${path}.channel_id`),
        user_id: requireDashboardString(source.user_id, `${path}.user_id`),
      }
    case 'slack':
      if (visibility === 'redacted') {
        if (
          source.channel_id !== undefined
          || source.user_id !== undefined
          || source.team_id !== undefined
          || source.thread_ts !== undefined
        ) {
          return dashboardProjectionError(path, 'redacted Slack source without route coordinates')
        }
        return {
          kind,
          channel_id: null,
          user_id: null,
          team_id: null,
          thread_ts: null,
        }
      }
      return {
        kind,
        channel_id: requireDashboardString(source.channel_id, `${path}.channel_id`),
        user_id: requireDashboardString(source.user_id, `${path}.user_id`),
        team_id: requireDashboardNullableText(source.team_id, `${path}.team_id`),
        thread_ts: requireDashboardNullableText(source.thread_ts, `${path}.thread_ts`),
      }
    default:
      return dashboardProjectionError(`${path}.kind`, 'dashboard | discord | slack')
  }
}

function parseDashboardKeeperChatQueueActiveReceipt(
  value: unknown,
  path: string,
  visibility: DashboardKeeperWaitingVisibility,
): DashboardKeeperChatQueueActiveReceipt {
  const receipt = requireDashboardRecord(value, path)
  const receiptId = requireDashboardString(receipt.receipt_id, `${path}.receipt_id`)
  if (!isKeeperChatReceiptId(receiptId)) {
    return dashboardProjectionError(`${path}.receipt_id`, 'durable Keeper chat receipt id')
  }
  const state = receipt.state
  if (state !== 'pending' && state !== 'inflight') {
    return dashboardProjectionError(`${path}.state`, 'pending | inflight')
  }
  const source = parseDashboardKeeperChatQueueSource(
    receipt.message_source,
    `${path}.message_source`,
    visibility,
  )
  const leaseId = requireDashboardNullableString(receipt.lease_id, `${path}.lease_id`)
  const startedAt = receipt.started_at === null
    ? null
    : requireDashboardFiniteNumber(receipt.started_at, `${path}.started_at`)
  const startedAtIso = receipt.started_at_iso === null
    ? null
    : requireDashboardIsoTimestamp(receipt.started_at_iso, `${path}.started_at_iso`)
  if (
    (state === 'pending' && (leaseId !== null || startedAt !== null || startedAtIso !== null))
    || (state === 'inflight' && (leaseId === null || startedAt === null || startedAtIso === null))
  ) {
    return dashboardProjectionError(
      path,
      state === 'pending'
        ? 'pending receipt without lease timestamps'
        : 'inflight receipt with lease timestamps',
    )
  }
  return {
    receipt_id: receiptId,
    queue_index: requireDashboardNonnegativeInteger(receipt.queue_index, `${path}.queue_index`),
    message_source: source,
    content_length: requireDashboardNonnegativeInteger(receipt.content_length, `${path}.content_length`),
    user_block_count: requireDashboardNonnegativeInteger(receipt.user_block_count, `${path}.user_block_count`),
    attachment_count: requireDashboardNonnegativeInteger(receipt.attachment_count, `${path}.attachment_count`),
    submitted_at: requireDashboardFiniteNumber(receipt.submitted_at, `${path}.submitted_at`),
    submitted_at_iso: requireDashboardIsoTimestamp(receipt.submitted_at_iso, `${path}.submitted_at_iso`),
    state,
    lease_id: leaseId,
    started_at: startedAt,
    started_at_iso: startedAtIso,
  }
}

function parseDashboardKeeperChatQueueLoadError(
  value: unknown,
  path: string,
  visibility: DashboardKeeperWaitingVisibility,
): DashboardKeeperChatQueueLoadError {
  const error = requireDashboardRecord(value, path)
  const kind = requireDashboardString(error.kind, `${path}.kind`)
  if (!DASHBOARD_KEEPER_CHAT_QUEUE_LOAD_ERROR_KIND_SET.has(kind)) {
    return dashboardProjectionError(`${path}.kind`, 'known queue load error kind')
  }
  if (visibility === 'redacted') {
    if (error.path !== undefined || error.message !== undefined) {
      return dashboardProjectionError(path, 'redacted queue error without path or message')
    }
    return { kind: kind as DashboardKeeperChatQueueLoadErrorKind, path: null, message: null }
  }
  return {
    kind: kind as DashboardKeeperChatQueueLoadErrorKind,
    path: requireDashboardNullableText(error.path, `${path}.path`),
    message: requireDashboardString(error.message, `${path}.message`),
  }
}

function parseDashboardKeeperChatQueueFailedReceipt(
  value: unknown,
  path: string,
): DashboardKeeperChatQueueFailedReceipt {
  const receipt = requireDashboardRecord(value, path)
  const receiptId = requireDashboardString(receipt.receipt_id, `${path}.receipt_id`)
  if (!isKeeperChatReceiptId(receiptId)) {
    return dashboardProjectionError(`${path}.receipt_id`, 'durable Keeper chat receipt id')
  }
  if (receipt.state !== 'failed') {
    return dashboardProjectionError(`${path}.state`, 'failed')
  }
  const failureKind = requireDashboardString(receipt.failure_kind, `${path}.failure_kind`)
  if (!DASHBOARD_KEEPER_CHAT_QUEUE_FAILURE_KIND_SET.has(failureKind)) {
    return dashboardProjectionError(`${path}.failure_kind`, 'known queue failure kind')
  }
  return {
    receipt_id: receiptId,
    state: 'failed',
    failure_kind: failureKind as DashboardKeeperChatQueueFailureKind,
    completed_at: requireDashboardFiniteNumber(receipt.completed_at, `${path}.completed_at`),
    completed_at_iso: requireDashboardIsoTimestamp(receipt.completed_at_iso, `${path}.completed_at_iso`),
    outcome_ref: requireDashboardNullableText(receipt.outcome_ref, `${path}.outcome_ref`),
  }
}

/** Parse the entire typed queue projection. Its state-bearing fields are closed
 * vocabularies: projection drift is an error, never an empty-queue fallback. */
export function parseDashboardKeeperChatQueue(
  value: unknown,
  path = 'keeper_waiting_inventory.keepers[].chat_queue',
  visibility: DashboardKeeperWaitingVisibility = 'operator',
): DashboardKeeperChatQueue {
  const queue = requireDashboardRecord(value, path)
  if (queue.schema !== 'keeper_chat_queue.dashboard.v1') {
    return dashboardProjectionError(`${path}.schema`, 'keeper_chat_queue.dashboard.v1')
  }
  const pendingCount = requireDashboardNonnegativeInteger(
    queue.pending_count,
    `${path}.pending_count`,
  )
  const inflightCount = requireDashboardNonnegativeInteger(
    queue.inflight_count,
    `${path}.inflight_count`,
  )
  const activeReceipts = requireDashboardArray(queue.active_receipts, `${path}.active_receipts`)
    .map((receipt, index) => parseDashboardKeeperChatQueueActiveReceipt(
      receipt,
      `${path}.active_receipts[${index}]`,
      visibility,
    ))
  const activeReceiptIds = new Set<string>()
  let sawPending = false
  activeReceipts.forEach((receipt, index) => {
    if (receipt.queue_index !== index) {
      return dashboardProjectionError(
        `${path}.active_receipts[${index}].queue_index`,
        `contiguous queue index ${index}`,
      )
    }
    if (activeReceiptIds.has(receipt.receipt_id)) {
      return dashboardProjectionError(
        `${path}.active_receipts[${index}].receipt_id`,
        'unique active receipt id',
      )
    }
    activeReceiptIds.add(receipt.receipt_id)
    if (receipt.state === 'pending') sawPending = true
    else if (sawPending) {
      return dashboardProjectionError(
        `${path}.active_receipts[${index}].state`,
        'inflight receipts before pending receipts',
      )
    }
  })
  const parsedPendingCount = activeReceipts.filter(receipt => receipt.state === 'pending').length
  const parsedInflightCount = activeReceipts.length - parsedPendingCount
  if (parsedPendingCount !== pendingCount || parsedInflightCount !== inflightCount) {
    return dashboardProjectionError(
      `${path}.active_receipts`,
      `${pendingCount} pending and ${inflightCount} inflight receipts`,
    )
  }
  const recentFailedReceiptCount = requireDashboardNonnegativeInteger(
    queue.recent_failed_receipt_count,
    `${path}.recent_failed_receipt_count`,
  )
  const recentFailedReceiptLimit = requireDashboardNonnegativeInteger(
    queue.recent_failed_receipt_limit,
    `${path}.recent_failed_receipt_limit`,
  )
  const recentFailedReceiptsTruncated = requireDashboardBoolean(
    queue.recent_failed_receipts_truncated,
    `${path}.recent_failed_receipts_truncated`,
  )
  const recentFailedReceipts = requireDashboardArray(
    queue.recent_failed_receipts,
    `${path}.recent_failed_receipts`,
  ).map((receipt, index) => parseDashboardKeeperChatQueueFailedReceipt(
    receipt,
    `${path}.recent_failed_receipts[${index}]`,
  ))
  const recentFailedReceiptIds = new Set<string>()
  recentFailedReceipts.forEach((receipt, index) => {
    if (recentFailedReceiptIds.has(receipt.receipt_id)) {
      return dashboardProjectionError(
        `${path}.recent_failed_receipts[${index}].receipt_id`,
        'unique recent failed receipt id',
      )
    }
    recentFailedReceiptIds.add(receipt.receipt_id)
  })
  const expectedVisibleFailedCount = Math.min(
    recentFailedReceiptCount,
    recentFailedReceiptLimit,
  )
  if (
    recentFailedReceipts.length !== expectedVisibleFailedCount
    || recentFailedReceiptsTruncated !== (recentFailedReceiptCount > recentFailedReceiptLimit)
  ) {
    return dashboardProjectionError(
      `${path}.recent_failed_receipts`,
      `bounded list of ${expectedVisibleFailedCount} receipts with matching truncation flag`,
    )
  }
  const nextAction = requireDashboardNullableString(queue.next_action, `${path}.next_action`)
  return {
    schema: 'keeper_chat_queue.dashboard.v1',
    revision: requireDashboardNonnegativeInteger(queue.revision, `${path}.revision`),
    pending_count: pendingCount,
    inflight_count: inflightCount,
    active_receipts: activeReceipts,
    read_errors: requireDashboardArray(queue.read_errors, `${path}.read_errors`)
      .map((error, index) => parseDashboardKeeperChatQueueLoadError(
        error,
        `${path}.read_errors[${index}]`,
        visibility,
      )),
    next_action: nextAction,
    recent_failed_receipt_count: recentFailedReceiptCount,
    recent_failed_receipt_limit: recentFailedReceiptLimit,
    recent_failed_receipts_truncated: recentFailedReceiptsTruncated,
    recent_failed_receipts: recentFailedReceipts,
  }
}

function parseDashboardKeeperWaitingMetadataStatus(
  value: unknown,
  path: string,
): DashboardKeeperWaitingMetadataStatus {
  const status = requireDashboardString(value, path)
  if (!DASHBOARD_KEEPER_WAITING_METADATA_STATUS_SET.has(status)) {
    return dashboardProjectionError(path, 'registered | queue_only')
  }
  return status as DashboardKeeperWaitingMetadataStatus
}

function parseDashboardKeeperWaitingVisibility(
  value: unknown,
  path: string,
): DashboardKeeperWaitingVisibility {
  const visibility = requireDashboardString(value, path)
  if (!DASHBOARD_KEEPER_WAITING_VISIBILITY_SET.has(visibility)) {
    return dashboardProjectionError(path, 'operator | redacted')
  }
  return visibility as DashboardKeeperWaitingVisibility
}

function parseDashboardKeeperWaitingWakeProducer(
  value: unknown,
  path: string,
): DashboardKeeperWaitingWakeProducer {
  const producer = requireDashboardString(value, path)
  if (!DASHBOARD_KEEPER_WAITING_WAKE_PRODUCER_SET.has(producer)) {
    return dashboardProjectionError(path, 'known waiting wake producer')
  }
  return producer as DashboardKeeperWaitingWakeProducer
}

function parseDashboardKeeperWaitingRow(
  value: unknown,
  path: string,
  expectedKeeperName: string | null,
): DashboardKeeperWaitingRow {
  const row = requireDashboardRecord(value, path)
  const keeperName = requireDashboardNullableString(row.keeper_name, `${path}.keeper_name`)
  if (keeperName !== expectedKeeperName) {
    return dashboardProjectionError(
      `${path}.keeper_name`,
      expectedKeeperName === null ? 'null global owner' : `owner ${expectedKeeperName}`,
    )
  }
  const source = parseDashboardKeeperWaitingSource(row.source)
  if (!source) return dashboardProjectionError(`${path}.source`, 'known waiting source')
  const since = parseDashboardTimestampPair(row, 'since', 'since_iso', path)
  const dueAt = parseDashboardTimestampPair(row, 'due_at', 'due_at_iso', path)
  return {
    keeper_name: keeperName,
    source,
    waiting_on: requireDashboardString(row.waiting_on, `${path}.waiting_on`),
    wake_producer: parseDashboardKeeperWaitingWakeProducer(
      row.wake_producer,
      `${path}.wake_producer`,
    ),
    since: since.value,
    since_iso: since.iso,
    due_at: dueAt.value,
    due_at_iso: dueAt.iso,
    next_action: requireDashboardString(row.next_action, `${path}.next_action`),
    detail: requireDashboardOwnField(row, 'detail', path),
  }
}

function parseDashboardKeeperWaitingKeeper(
  value: unknown,
  path: string,
  visibility: DashboardKeeperWaitingVisibility,
): DashboardKeeperWaitingKeeper {
  const keeper = requireDashboardRecord(value, path)
  const keeperName = requireDashboardString(keeper.keeper_name, `${path}.keeper_name`)
  const metadataStatus = parseDashboardKeeperWaitingMetadataStatus(
    keeper.metadata_status,
    `${path}.metadata_status`,
  )
  const state = parseDashboardKeeperWaitingState(keeper.state)
  if (!state) return dashboardProjectionError(`${path}.state`, 'idle | busy | waiting | deferred')
  const waitingOn = requireDashboardArray(keeper.waiting_on, `${path}.waiting_on`)
    .map((row, index) => parseDashboardKeeperWaitingRow(
      row,
      `${path}.waiting_on[${index}]`,
      keeperName,
    ))
  const waitingCount = requireDashboardNonnegativeInteger(
    keeper.waiting_count,
    `${path}.waiting_count`,
  )
  if (waitingCount !== waitingOn.length) {
    return dashboardProjectionError(`${path}.waiting_count`, `${waitingOn.length} visible rows`)
  }
  if (
    (state === 'idle' && waitingCount !== 0)
    || ((state === 'waiting' || state === 'deferred') && waitingCount === 0)
  ) {
    return dashboardProjectionError(`${path}.state`, `state consistent with ${waitingCount} rows`)
  }
  const waitingCountTruncated = requireDashboardBoolean(
    keeper.waiting_count_truncated,
    `${path}.waiting_count_truncated`,
  )
  const truncatedSources = parseDashboardWaitingTruncationRecord(
    keeper.truncated_sources,
    `${path}.truncated_sources`,
  )
  if (waitingCountTruncated !== Object.values(truncatedSources).some(Boolean)) {
    return dashboardProjectionError(
      `${path}.waiting_count_truncated`,
      'flag matching truncated_sources',
    )
  }
  const sources = parseDashboardWaitingSourceCountRecord(keeper.sources, `${path}.sources`)
  if (!waitingSourceCountRecordsEqual(sources, waitingSourceCounts(waitingOn))) {
    return dashboardProjectionError(`${path}.sources`, 'counts matching waiting_on rows')
  }
  const since = parseDashboardTimestampPair(keeper, 'since', 'since_iso', path)
  const dueAt = parseDashboardTimestampPair(keeper, 'due_at', 'due_at_iso', path)
  const nextAction = requireDashboardNullableString(keeper.next_action, `${path}.next_action`)
  if (
    (waitingOn.length === 0 && nextAction !== null)
    || (waitingOn.length > 0 && nextAction !== waitingOn[0]?.next_action)
  ) {
    return dashboardProjectionError(`${path}.next_action`, 'first waiting row action or null')
  }
  return {
    keeper_name: keeperName,
    metadata_status: metadataStatus,
    state,
    waiting_on: waitingOn,
    waiting_count: waitingCount,
    waiting_count_truncated: waitingCountTruncated,
    truncated_sources: truncatedSources,
    sources,
    since: since.value,
    since_iso: since.iso,
    due_at: dueAt.value,
    due_at_iso: dueAt.iso,
    next_action: nextAction,
    chat_queue: parseDashboardKeeperChatQueue(
      keeper.chat_queue,
      `${path}.chat_queue`,
      visibility,
    ),
  }
}

export function parseDashboardKeeperWaitingInventory(
  value: unknown,
  path = 'keeper_waiting_inventory',
): DashboardKeeperWaitingInventory {
  const inventory = requireDashboardRecord(value, path)
  if (inventory.schema !== 'masc.dashboard.keeper_waiting_inventory.v2') {
    return dashboardProjectionError(
      `${path}.schema`,
      'masc.dashboard.keeper_waiting_inventory.v2',
    )
  }
  if (inventory.source !== 'server_keeper_waiting_inventory') {
    return dashboardProjectionError(`${path}.source`, 'server_keeper_waiting_inventory')
  }
  const visibility = parseDashboardKeeperWaitingVisibility(
    inventory.visibility,
    `${path}.visibility`,
  )
  const supportedStates = requireDashboardArray(
    inventory.supported_states,
    `${path}.supported_states`,
  ).map((state, index) => {
    const parsed = parseDashboardKeeperWaitingState(state)
    if (!parsed) {
      return dashboardProjectionError(
        `${path}.supported_states[${index}]`,
        'known Keeper waiting state',
      )
    }
    return parsed
  })
  if (
    supportedStates.length !== DASHBOARD_KEEPER_WAITING_STATE_VALUES.length
    || new Set(supportedStates).size !== DASHBOARD_KEEPER_WAITING_STATE_VALUES.length
    || !DASHBOARD_KEEPER_WAITING_STATE_VALUES.every(state => supportedStates.includes(state))
  ) {
    return dashboardProjectionError(`${path}.supported_states`, 'complete unique state vocabulary')
  }
  const keepers = requireDashboardArray(inventory.keepers, `${path}.keepers`)
    .map((keeper, index) => parseDashboardKeeperWaitingKeeper(
      keeper,
      `${path}.keepers[${index}]`,
      visibility,
    ))
  if (new Set(keepers.map(keeper => keeper.keeper_name)).size !== keepers.length) {
    return dashboardProjectionError(`${path}.keepers`, 'unique keeper names')
  }
  const globalWaitingOn = requireDashboardArray(
    inventory.global_waiting_on,
    `${path}.global_waiting_on`,
  ).map((row, index) => parseDashboardKeeperWaitingRow(
    row,
    `${path}.global_waiting_on[${index}]`,
    null,
  ))
  const keeperCount = requireDashboardNonnegativeInteger(
    inventory.keeper_count,
    `${path}.keeper_count`,
  )
  if (keeperCount !== keepers.length) {
    return dashboardProjectionError(`${path}.keeper_count`, `${keepers.length} Keeper rows`)
  }
  const waitingKeeperCount = requireDashboardNonnegativeInteger(
    inventory.waiting_keeper_count,
    `${path}.waiting_keeper_count`,
  )
  const parsedWaitingKeeperCount = keepers.filter(keeper => keeper.state !== 'idle').length
  if (waitingKeeperCount !== parsedWaitingKeeperCount) {
    return dashboardProjectionError(
      `${path}.waiting_keeper_count`,
      `${parsedWaitingKeeperCount} non-idle Keepers`,
    )
  }
  const rowCount = requireDashboardNonnegativeInteger(inventory.row_count, `${path}.row_count`)
  const parsedRowCount = keepers.reduce((count, keeper) => count + keeper.waiting_count, 0)
  if (rowCount !== parsedRowCount) {
    return dashboardProjectionError(`${path}.row_count`, `${parsedRowCount} keeper rows`)
  }
  const globalRowCount = requireDashboardNonnegativeInteger(
    inventory.global_row_count,
    `${path}.global_row_count`,
  )
  if (globalRowCount !== globalWaitingOn.length) {
    return dashboardProjectionError(
      `${path}.global_row_count`,
      `${globalWaitingOn.length} global rows`,
    )
  }
  const externalAttentionTruncatedKeeperCount = requireDashboardNonnegativeInteger(
    inventory.external_attention_truncated_keeper_count,
    `${path}.external_attention_truncated_keeper_count`,
  )
  const parsedTruncatedKeeperCount = keepers.filter(
    keeper => keeper.truncated_sources.external_attention === true,
  ).length
  if (externalAttentionTruncatedKeeperCount !== parsedTruncatedKeeperCount) {
    return dashboardProjectionError(
      `${path}.external_attention_truncated_keeper_count`,
      `${parsedTruncatedKeeperCount} truncated Keepers`,
    )
  }
  const rowCountTruncated = requireDashboardBoolean(
    inventory.row_count_truncated,
    `${path}.row_count_truncated`,
  )
  if (rowCountTruncated !== (externalAttentionTruncatedKeeperCount > 0)) {
    return dashboardProjectionError(
      `${path}.row_count_truncated`,
      'flag matching external attention truncation',
    )
  }
  const sourceCounts = parseDashboardWaitingSourceCountRecord(
    inventory.source_counts,
    `${path}.source_counts`,
  )
  const parsedSourceCounts = waitingSourceCounts([
    ...keepers.flatMap(keeper => keeper.waiting_on),
    ...globalWaitingOn,
  ])
  if (!waitingSourceCountRecordsEqual(sourceCounts, parsedSourceCounts)) {
    return dashboardProjectionError(`${path}.source_counts`, 'counts matching all waiting rows')
  }
  return {
    schema: 'masc.dashboard.keeper_waiting_inventory.v2',
    source: 'server_keeper_waiting_inventory',
    visibility,
    generated_at: requireDashboardIsoTimestamp(inventory.generated_at, `${path}.generated_at`),
    supported_states: supportedStates,
    keeper_count_known: requireDashboardBoolean(
      inventory.keeper_count_known,
      `${path}.keeper_count_known`,
    ),
    keeper_count: keeperCount,
    waiting_keeper_count: waitingKeeperCount,
    row_count: rowCount,
    row_count_truncated: rowCountTruncated,
    external_attention_row_limit: requireDashboardNonnegativeInteger(
      inventory.external_attention_row_limit,
      `${path}.external_attention_row_limit`,
    ),
    external_attention_truncated_keeper_count: externalAttentionTruncatedKeeperCount,
    global_row_count: globalRowCount,
    global_pending_confirm_count_known: requireDashboardBoolean(
      inventory.global_pending_confirm_count_known,
      `${path}.global_pending_confirm_count_known`,
    ),
    global_pending_confirm_count: requireDashboardNonnegativeInteger(
      inventory.global_pending_confirm_count,
      `${path}.global_pending_confirm_count`,
    ),
    source_counts: sourceCounts,
    keepers,
    global_waiting_on: globalWaitingOn,
  }
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

export interface FetchDashboardToolsOptions extends AbortableRequestOptions {
  freshKeeperChatQueue?: boolean
}

export async function fetchDashboardTools(
  opts?: FetchDashboardToolsOptions,
): Promise<DashboardToolsResponse> {
  const path = opts?.freshKeeperChatQueue
    ? '/api/v1/dashboard/tools?fresh_keeper_chat_queue=1'
    : '/api/v1/dashboard/tools'
  const raw = await get<DashboardToolsResponse>(path, { signal: opts?.signal })
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
  const normalizedWaitingInventory = raw.keeper_waiting_inventory
    ? parseDashboardKeeperWaitingInventory(raw.keeper_waiting_inventory)
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
