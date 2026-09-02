// MASC Dashboard — Tool metrics / runtime probe / tools inventory / prompts.
// Extracted from dashboard.ts (domain split). Public symbols re-exported
// from dashboard.ts so existing consumers (`from './api/dashboard'`) are unchanged.

import { get, post, type AbortableRequestOptions } from './core'
import { ensureDevToken } from './dev-token'
import type { TelemetryFreshnessMetadata } from './dashboard-shared'
import type { DashboardConfigResolution, DashboardRuntimeResolution } from '../types'
import type { DashboardRuntimeProbeResponse } from './schemas/runtime-probe'

// The activation ledger's wire schema — keeper_skill_activation_ledger.ml
// writes exactly this tag, and every reader below pins it before trusting
// the rows.
const SKILL_ACTIVATIONS_SCHEMA = 'masc.skill-activations/v5'

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
        // The Keeper store answered and holds no Keeper under this name.
        // Distinct from owner_unknown, which is a read that did not answer.
        | 'owner_absent'
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
  // Ranked by the server: cancelled and ack are terminal, finished outranks
  // started, and a stimulus row alone is the producer's record, not a
  // reaction. The two terminals together are a contradiction the server
  // names rather than resolves.
  projection_status:
    | 'conflicting_terminal_evidence'
    | 'matched_terminal_cancelled'
    | 'matched_consumed_ack'
    | 'matched_turn_finished'
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
  turn_finished_seen?: boolean
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
  retained: number
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
  keeper_background?: DashboardKeeperBackground
  effective_keeper_surface?: DashboardEffectiveKeeperSurface | null
  skill_activations?: DashboardSkillActivationProjection | null
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
    eager_body_bytes: number
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
      skill_eager_body_bytes: number
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
  | {
      status: 'warming'
      keeper_name: string
    }

export type DashboardSkillInstructionOrigin =
  | { kind: 'task_instruction'; task_ids: string[] }
  | { kind: 'session_instruction' }

export type DashboardSkillCompositionOrigin =
  | { kind: 'task_composition'; task_ids: string[] }
  | { kind: 'session_composition' }

export type DashboardSkillActivationInvocation =
  | {
      kind: 'instruction'
      origin: DashboardSkillInstructionOrigin
      served_content:
        | { kind: 'skill_body'; bytes: number; sha256: string }
        | {
            kind: 'skill_resource'
            relative_path: string
            bytes: number
            sha256: string
          }
    }
  | {
      kind: 'composition'
      origin: DashboardSkillCompositionOrigin
      tool_name: string
    }

export type DashboardSkillActionIdentity =
  | { kind: 'call_id'; call_id: string }
  | { kind: 'provider_step'; conversation_id: string; step_index: number }

export interface DashboardSkillActivation {
  identity: DashboardSkillReference['identity']
  content_revision: string
  snapshot_revision: string
  turn_ref: string
  runtime_id: string
  skill_tool_use_id: string
  agent_core_turn: number
  invocation: DashboardSkillActivationInvocation
  delivery: {
    boundary:
      | { kind: 'model_response'; agent_core_turn: number }
      | { kind: 'official_client_result_handoff'; agent_core_turn: number }
    runtime_id: string
    delivered_at: string
    content_bytes: number
    content_sha256: string
  } | null
  actions: Array<{
    identity: DashboardSkillActionIdentity
    tool_name: string
    runtime_id: string
    agent_core_turn: number
    observed_at: string
  }>
  activated_at: string
}

export type DashboardSkillTransitionRejection =
  | {
      kind: 'delivery_order'
      skill_tool_use_id: string
      activation_turn_ref: string
      observed_turn_ref: string
      activation_agent_core_turn: number
      observed_agent_core_turn: number
      observed_at: string
    }
  | {
      kind: 'delivery_conflict'
      skill_tool_use_id: string
      activation_turn_ref: string
      observed_turn_ref: string
      observed_agent_core_turn: number
      observed_at: string
    }
  | {
      kind: 'action_before_delivery'
      skill_tool_use_id: string
      activation_turn_ref: string
      observed_turn_ref: string
      action_identity: DashboardSkillActionIdentity
      tool_name: string
      observed_agent_core_turn: number
      observed_at: string
    }

export interface DashboardSkillActivationSummary {
  instruction_invocations: number
  skill_bodies_served: number
  skill_resources_served: number
  instruction_provider_deliveries: number
  instruction_official_client_handoffs: number
  instruction_actions_observed: number
  composition_invocations: number
  composition_provider_deliveries: number
  composition_official_client_handoffs: number
  composition_actions_observed: number
  invalid_transitions: number
}

export interface DashboardSkillScopedSummary {
  scope: {
    snapshot_revision: string
    turn_ref: string
    invocation_runtime_id: string
    reference: DashboardSkillReference
  }
  summary: DashboardSkillActivationSummary
  provider_delivery_runtime_counts: Array<{ runtime_id: string; count: number }>
  official_client_handoff_runtime_counts: Array<{ runtime_id: string; count: number }>
  action_runtime_counts: Array<{ runtime_id: string; count: number }>
}

export type DashboardSkillActivationProjection =
  | {
      status: 'available'
      keeper_name: string
      summary: DashboardSkillActivationSummary
      scoped_summaries: DashboardSkillScopedSummary[]
      ledger: {
        schema: typeof SKILL_ACTIVATIONS_SCHEMA
        workspace_key: string
        session_id: string
        revision: string
        activations: DashboardSkillActivation[]
        transition_rejections: DashboardSkillTransitionRejection[]
      }
    }
  | { status: 'no_session'; keeper_name: string }
  | { status: 'unavailable'; keeper_name: string; reason: string; detail: string }

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

/** `dashboard_surface` block of /health (masc.dashboard_surface.v1): the
 *  server's own verdict on whether the bundle it serves — the very UI the
 *  reader is looking at — is current, stale, or missing its build stamp. */
export interface DashboardSurfaceHealth {
  status?: string
  next_action?: string
  build_stamp_at?: string
  binary_built_at?: string
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
  DashboardRuntimeProviderProbeStatus,
  DashboardRuntimeProbeStatus,
  DashboardRuntimeProbeRefreshState,
  DashboardRuntimeProviderProbe,
  DashboardRuntimeProviderProbeSummary,
  DashboardRuntimeProbePayload,
  DashboardRuntimeProbeResponse,
} from './schemas/runtime-probe'

export function fetchToolMetrics(): Promise<ToolMetricsResponse> {
  return get('/api/v1/tool-metrics')
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

export interface DashboardToolsRequestOptions extends AbortableRequestOptions {
  keeperName?: string
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function exactSkillActivationObject(
  value: unknown,
  label: string,
  fields: readonly string[],
): Record<string, unknown> {
  if (!isRecord(value)) throw new Error(`skill_activations ${label} is not an object`)
  const allowed = new Set(fields)
  const unexpected = Object.keys(value).find(field => !allowed.has(field))
  if (unexpected !== undefined) {
    throw new Error(`skill_activations ${label} has unexpected field ${unexpected}`)
  }
  return value
}

function skillActivationString(value: unknown, label: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`skill_activations ${label} must be a nonempty string`)
  }
  return value
}

function skillActivationSha256(value: unknown, label: string): string {
  const sha256 = skillActivationString(value, label)
  if (!/^[0-9a-f]{64}$/i.test(sha256)) {
    throw new Error(`skill_activations ${label} must be a 64-character sha256`)
  }
  return sha256
}

function skillActivationNonnegativeInteger(value: unknown, label: string): number {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
    throw new Error(`skill_activations ${label} must be a nonnegative integer`)
  }
  return value
}

function decodeSkillActivationSummary(
  value: unknown,
  label: string,
): DashboardSkillActivationSummary {
  const fields = [
    'instruction_invocations',
    'skill_bodies_served',
    'skill_resources_served',
    'instruction_provider_deliveries',
    'instruction_official_client_handoffs',
    'instruction_actions_observed',
    'composition_invocations',
    'composition_provider_deliveries',
    'composition_official_client_handoffs',
    'composition_actions_observed',
    'invalid_transitions',
  ] as const
  const record = exactSkillActivationObject(value, label, fields)
  return {
    instruction_invocations: skillActivationNonnegativeInteger(record.instruction_invocations, `${label}.instruction_invocations`),
    skill_bodies_served: skillActivationNonnegativeInteger(record.skill_bodies_served, `${label}.skill_bodies_served`),
    skill_resources_served: skillActivationNonnegativeInteger(record.skill_resources_served, `${label}.skill_resources_served`),
    instruction_provider_deliveries: skillActivationNonnegativeInteger(record.instruction_provider_deliveries, `${label}.instruction_provider_deliveries`),
    instruction_official_client_handoffs: skillActivationNonnegativeInteger(record.instruction_official_client_handoffs, `${label}.instruction_official_client_handoffs`),
    instruction_actions_observed: skillActivationNonnegativeInteger(record.instruction_actions_observed, `${label}.instruction_actions_observed`),
    composition_invocations: skillActivationNonnegativeInteger(record.composition_invocations, `${label}.composition_invocations`),
    composition_provider_deliveries: skillActivationNonnegativeInteger(record.composition_provider_deliveries, `${label}.composition_provider_deliveries`),
    composition_official_client_handoffs: skillActivationNonnegativeInteger(record.composition_official_client_handoffs, `${label}.composition_official_client_handoffs`),
    composition_actions_observed: skillActivationNonnegativeInteger(record.composition_actions_observed, `${label}.composition_actions_observed`),
    invalid_transitions: skillActivationNonnegativeInteger(record.invalid_transitions, `${label}.invalid_transitions`),
  }
}

function decodeSkillReference(value: unknown, label: string): DashboardSkillReference {
  const record = exactSkillActivationObject(value, label, ['identity', 'content_revision'])
  const identity = exactSkillActivationObject(
    record.identity,
    `${label}.identity`,
    ['source_id', 'package_id', 'name'],
  )
  return {
    identity: {
      source_id: skillActivationString(identity.source_id, `${label}.identity.source_id`),
      package_id: skillActivationString(identity.package_id, `${label}.identity.package_id`),
      name: skillActivationString(identity.name, `${label}.identity.name`),
    },
    content_revision: skillActivationSha256(record.content_revision, `${label}.content_revision`),
  }
}

function decodeTaskIds(value: unknown, label: string): string[] {
  if (!Array.isArray(value) || value.length === 0) {
    throw new Error(`skill_activations ${label} must be a nonempty array`)
  }
  const taskIds = value.map((taskId, index) => skillActivationString(taskId, `${label}[${index}]`))
  if (new Set(taskIds).size !== taskIds.length) {
    throw new Error(`skill_activations ${label} must not contain duplicates`)
  }
  return taskIds
}

function decodeInstructionOrigin(value: unknown, label: string): DashboardSkillInstructionOrigin {
  const base = exactSkillActivationObject(value, label, ['kind', 'task_ids'])
  if (base.kind === 'task_instruction') {
    return {
      kind: 'task_instruction',
      task_ids: decodeTaskIds(base.task_ids, `${label}.task_ids`),
    }
  }
  if (base.kind === 'session_instruction') {
    exactSkillActivationObject(value, label, ['kind'])
    return { kind: 'session_instruction' }
  }
  throw new Error(`skill_activations ${label}.kind is unsupported`)
}

function decodeCompositionOrigin(value: unknown, label: string): DashboardSkillCompositionOrigin {
  const base = exactSkillActivationObject(value, label, ['kind', 'task_ids'])
  if (base.kind === 'task_composition') {
    return {
      kind: 'task_composition',
      task_ids: decodeTaskIds(base.task_ids, `${label}.task_ids`),
    }
  }
  if (base.kind === 'session_composition') {
    exactSkillActivationObject(value, label, ['kind'])
    return { kind: 'session_composition' }
  }
  throw new Error(`skill_activations ${label}.kind is unsupported`)
}

function decodeSkillActivationInvocation(
  value: unknown,
  label: string,
): DashboardSkillActivationInvocation {
  const record = exactSkillActivationObject(
    value,
    label,
    ['kind', 'origin', 'served_content', 'tool_name'],
  )
  if (record.kind === 'instruction') {
    exactSkillActivationObject(value, label, ['kind', 'origin', 'served_content'])
    const served = exactSkillActivationObject(
      record.served_content,
      `${label}.served_content`,
      ['kind', 'relative_path', 'bytes', 'sha256'],
    )
    const bytes = skillActivationNonnegativeInteger(served.bytes, `${label}.served_content.bytes`)
    const sha256 = skillActivationSha256(served.sha256, `${label}.served_content.sha256`)
    const origin = decodeInstructionOrigin(record.origin, `${label}.origin`)
    if (served.kind === 'skill_body') {
      exactSkillActivationObject(record.served_content, `${label}.served_content`, ['kind', 'bytes', 'sha256'])
      return { kind: 'instruction', origin, served_content: { kind: 'skill_body', bytes, sha256 } }
    }
    if (served.kind === 'skill_resource') {
      exactSkillActivationObject(
        record.served_content,
        `${label}.served_content`,
        ['kind', 'relative_path', 'bytes', 'sha256'],
      )
      return {
        kind: 'instruction',
        origin,
        served_content: {
          kind: 'skill_resource',
          relative_path: skillActivationString(served.relative_path, `${label}.served_content.relative_path`),
          bytes,
          sha256,
        },
      }
    }
    throw new Error(`skill_activations ${label}.served_content.kind is unsupported`)
  }
  if (record.kind === 'composition') {
    exactSkillActivationObject(value, label, ['kind', 'origin', 'tool_name'])
    return {
      kind: 'composition',
      origin: decodeCompositionOrigin(record.origin, `${label}.origin`),
      tool_name: skillActivationString(record.tool_name, `${label}.tool_name`),
    }
  }
  throw new Error(`skill_activations ${label}.kind is unsupported`)
}

function decodeSkillActionIdentity(
  value: unknown,
  label: string,
): DashboardSkillActionIdentity {
  if (!isRecord(value)) throw new Error(`skill_activations ${label} is not an object`)
  if (value.kind === 'call_id') {
    const record = exactSkillActivationObject(value, label, ['kind', 'call_id'])
    return {
      kind: 'call_id',
      call_id: skillActivationString(record.call_id, `${label}.call_id`),
    }
  }
  if (value.kind === 'provider_step') {
    const record = exactSkillActivationObject(
      value,
      label,
      ['kind', 'conversation_id', 'step_index'],
    )
    return {
      kind: 'provider_step',
      conversation_id: skillActivationString(
        record.conversation_id,
        `${label}.conversation_id`,
      ),
      step_index: skillActivationNonnegativeInteger(
        record.step_index,
        `${label}.step_index`,
      ),
    }
  }
  throw new Error(`skill_activations ${label}.kind is unsupported`)
}

function decodeSkillActivation(value: unknown, label: string): DashboardSkillActivation {
  const record = exactSkillActivationObject(value, label, [
    'identity',
    'content_revision',
    'snapshot_revision',
    'turn_ref',
    'runtime_id',
    'skill_tool_use_id',
    'agent_core_turn',
    'invocation',
    'delivery',
    'actions',
    'activated_at',
  ])
  const reference = decodeSkillReference(
    { identity: record.identity, content_revision: record.content_revision },
    label,
  )
  let delivery: DashboardSkillActivation['delivery'] = null
  if (record.delivery !== null) {
    const delivered = exactSkillActivationObject(record.delivery, `${label}.delivery`, [
      'boundary',
      'runtime_id',
      'delivered_at',
      'content_bytes',
      'content_sha256',
    ])
    const boundary = exactSkillActivationObject(
      delivered.boundary,
      `${label}.delivery.boundary`,
      ['kind', 'agent_core_turn'],
    )
    if (boundary.kind !== 'model_response' && boundary.kind !== 'official_client_result_handoff') {
      throw new Error(`skill_activations ${label}.delivery.boundary.kind is unsupported`)
    }
    delivery = {
      boundary: {
        kind: boundary.kind,
        agent_core_turn: skillActivationNonnegativeInteger(
          boundary.agent_core_turn,
          `${label}.delivery.boundary.agent_core_turn`,
        ),
      },
      runtime_id: skillActivationString(delivered.runtime_id, `${label}.delivery.runtime_id`),
      delivered_at: skillActivationString(delivered.delivered_at, `${label}.delivery.delivered_at`),
      content_bytes: skillActivationNonnegativeInteger(delivered.content_bytes, `${label}.delivery.content_bytes`),
      content_sha256: skillActivationSha256(delivered.content_sha256, `${label}.delivery.content_sha256`),
    }
  }
  if (!Array.isArray(record.actions)) throw new Error(`skill_activations ${label}.actions must be an array`)
  const actions = record.actions.map((action, index) => {
    const actionLabel = `${label}.actions[${index}]`
    const decoded = exactSkillActivationObject(action, actionLabel, [
      'identity',
      'tool_name',
      'runtime_id',
      'agent_core_turn',
      'observed_at',
    ])
    return {
      identity: decodeSkillActionIdentity(decoded.identity, `${actionLabel}.identity`),
      tool_name: skillActivationString(decoded.tool_name, `${actionLabel}.tool_name`),
      runtime_id: skillActivationString(decoded.runtime_id, `${actionLabel}.runtime_id`),
      agent_core_turn: skillActivationNonnegativeInteger(decoded.agent_core_turn, `${actionLabel}.agent_core_turn`),
      observed_at: skillActivationString(decoded.observed_at, `${actionLabel}.observed_at`),
    }
  })
  return {
    ...reference,
    snapshot_revision: skillActivationSha256(record.snapshot_revision, `${label}.snapshot_revision`),
    turn_ref: skillActivationString(record.turn_ref, `${label}.turn_ref`),
    runtime_id: skillActivationString(record.runtime_id, `${label}.runtime_id`),
    skill_tool_use_id: skillActivationString(record.skill_tool_use_id, `${label}.skill_tool_use_id`),
    agent_core_turn: skillActivationNonnegativeInteger(record.agent_core_turn, `${label}.agent_core_turn`),
    invocation: decodeSkillActivationInvocation(record.invocation, `${label}.invocation`),
    delivery,
    actions,
    activated_at: skillActivationString(record.activated_at, `${label}.activated_at`),
  }
}

function decodeTransitionRejection(value: unknown, label: string): DashboardSkillTransitionRejection {
  const record = exactSkillActivationObject(value, label, [
    'kind',
    'skill_tool_use_id',
    'activation_turn_ref',
    'observed_turn_ref',
    'activation_agent_core_turn',
    'observed_agent_core_turn',
    'observed_at',
    'action_identity',
    'tool_name',
  ])
  const common = {
    skill_tool_use_id: skillActivationString(record.skill_tool_use_id, `${label}.skill_tool_use_id`),
    activation_turn_ref: skillActivationString(record.activation_turn_ref, `${label}.activation_turn_ref`),
    observed_turn_ref: skillActivationString(record.observed_turn_ref, `${label}.observed_turn_ref`),
    observed_agent_core_turn: skillActivationNonnegativeInteger(record.observed_agent_core_turn, `${label}.observed_agent_core_turn`),
    observed_at: skillActivationString(record.observed_at, `${label}.observed_at`),
  }
  if (record.kind === 'delivery_order') {
    exactSkillActivationObject(value, label, [
      'kind',
      'skill_tool_use_id',
      'activation_turn_ref',
      'observed_turn_ref',
      'activation_agent_core_turn',
      'observed_agent_core_turn',
      'observed_at',
    ])
    return {
      kind: 'delivery_order',
      ...common,
      activation_agent_core_turn: skillActivationNonnegativeInteger(
        record.activation_agent_core_turn,
        `${label}.activation_agent_core_turn`,
      ),
    }
  }
  if (record.kind === 'delivery_conflict') {
    exactSkillActivationObject(value, label, [
      'kind',
      'skill_tool_use_id',
      'activation_turn_ref',
      'observed_turn_ref',
      'observed_agent_core_turn',
      'observed_at',
    ])
    return { kind: 'delivery_conflict', ...common }
  }
  if (record.kind === 'action_before_delivery') {
    exactSkillActivationObject(value, label, [
      'kind',
      'skill_tool_use_id',
      'activation_turn_ref',
      'observed_turn_ref',
      'action_identity',
      'tool_name',
      'observed_agent_core_turn',
      'observed_at',
    ])
    return {
      kind: 'action_before_delivery',
      ...common,
      action_identity: decodeSkillActionIdentity(record.action_identity, `${label}.action_identity`),
      tool_name: skillActivationString(record.tool_name, `${label}.tool_name`),
    }
  }
  throw new Error(`skill_activations ${label}.kind is unsupported`)
}

function decodeRuntimeCounts(
  value: unknown,
  label: string,
): Array<{ runtime_id: string; count: number }> {
  if (!Array.isArray(value)) throw new Error(`skill_activations ${label} must be an array`)
  return value.map((entry, index) => {
    const entryLabel = `${label}[${index}]`
    const record = exactSkillActivationObject(entry, entryLabel, ['runtime_id', 'count'])
    const count = skillActivationNonnegativeInteger(record.count, `${entryLabel}.count`)
    if (count === 0) throw new Error(`skill_activations ${entryLabel}.count must be positive`)
    return {
      runtime_id: skillActivationString(record.runtime_id, `${entryLabel}.runtime_id`),
      count,
    }
  })
}

function decodeScopedSummary(value: unknown, label: string): DashboardSkillScopedSummary {
  const record = exactSkillActivationObject(value, label, [
    'scope',
    'summary',
    'provider_delivery_runtime_counts',
    'official_client_handoff_runtime_counts',
    'action_runtime_counts',
  ])
  const scope = exactSkillActivationObject(record.scope, `${label}.scope`, [
    'snapshot_revision',
    'turn_ref',
    'invocation_runtime_id',
    'reference',
  ])
  return {
    scope: {
      snapshot_revision: skillActivationSha256(scope.snapshot_revision, `${label}.scope.snapshot_revision`),
      turn_ref: skillActivationString(scope.turn_ref, `${label}.scope.turn_ref`),
      invocation_runtime_id: skillActivationString(
        scope.invocation_runtime_id,
        `${label}.scope.invocation_runtime_id`,
      ),
      reference: decodeSkillReference(scope.reference, `${label}.scope.reference`),
    },
    summary: decodeSkillActivationSummary(record.summary, `${label}.summary`),
    provider_delivery_runtime_counts: decodeRuntimeCounts(
      record.provider_delivery_runtime_counts,
      `${label}.provider_delivery_runtime_counts`,
    ),
    official_client_handoff_runtime_counts: decodeRuntimeCounts(
      record.official_client_handoff_runtime_counts,
      `${label}.official_client_handoff_runtime_counts`,
    ),
    action_runtime_counts: decodeRuntimeCounts(
      record.action_runtime_counts,
      `${label}.action_runtime_counts`,
    ),
  }
}

export function normalizeSkillActivationProjection(
  value: unknown,
): DashboardSkillActivationProjection | null | undefined {
  if (value === null || value === undefined) return value
  if (!isRecord(value) || typeof value.status !== 'string') {
    throw new Error('skill_activations is not a typed projection')
  }
  if (value.status === 'no_session') {
    const record = exactSkillActivationObject(value, 'no_session', ['status', 'keeper_name'])
    return {
      status: 'no_session',
      keeper_name: skillActivationString(record.keeper_name, 'no_session.keeper_name'),
    }
  }
  if (value.status === 'unavailable') {
    const record = exactSkillActivationObject(
      value,
      'unavailable',
      ['status', 'keeper_name', 'reason', 'detail'],
    )
    return {
      status: 'unavailable',
      keeper_name: skillActivationString(record.keeper_name, 'unavailable.keeper_name'),
      reason: skillActivationString(record.reason, 'unavailable.reason'),
      detail: skillActivationString(record.detail, 'unavailable.detail'),
    }
  }
  if (value.status !== 'available') throw new Error('skill_activations status is unsupported')
  const projection = exactSkillActivationObject(
    value,
    'available',
    ['status', 'keeper_name', 'summary', 'scoped_summaries', 'ledger'],
  )
  const ledger = exactSkillActivationObject(projection.ledger, 'available.ledger', [
    'schema',
    'workspace_key',
    'session_id',
    'revision',
    'activations',
    'transition_rejections',
  ])
  if (ledger.schema !== SKILL_ACTIVATIONS_SCHEMA) {
    throw new Error('skill_activations schema is not v5')
  }
  if (
    !Array.isArray(ledger.activations)
    || !Array.isArray(ledger.transition_rejections)
    || !Array.isArray(projection.scoped_summaries)
  ) {
    throw new Error('skill_activations arrays are missing')
  }
  return {
    status: 'available',
    keeper_name: skillActivationString(projection.keeper_name, 'available.keeper_name'),
    summary: decodeSkillActivationSummary(projection.summary, 'available.summary'),
    scoped_summaries: projection.scoped_summaries.map((scoped, index) =>
      decodeScopedSummary(scoped, `available.scoped_summaries[${index}]`)),
    ledger: {
      schema: SKILL_ACTIVATIONS_SCHEMA,
      workspace_key: skillActivationSha256(ledger.workspace_key, 'available.ledger.workspace_key'),
      session_id: skillActivationString(ledger.session_id, 'available.ledger.session_id'),
      revision: skillActivationSha256(ledger.revision, 'available.ledger.revision'),
      activations: ledger.activations.map((activation, index) =>
        decodeSkillActivation(activation, `available.ledger.activations[${index}]`)),
      transition_rejections: ledger.transition_rejections.map((rejection, index) =>
        decodeTransitionRejection(rejection, `available.ledger.transition_rejections[${index}]`)),
    },
  }
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
  const normalizedSkillActivations = normalizeSkillActivationProjection(raw.skill_activations)
  return {
    ...raw,
    tool_inventory: {
      ...raw.tool_inventory,
      ...(normalizedTools ? { tools: normalizedTools } : {}),
    },
    ...(normalizedWaitingInventory
      ? { keeper_waiting_inventory: normalizedWaitingInventory }
      : {}),
    ...(normalizedSkillActivations !== undefined
      ? { skill_activations: normalizedSkillActivations }
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

export type PromptSource = 'override' | 'file' | 'missing'

export interface DashboardPromptItem {
  key: string
  category: string
  description: string
  current: string
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
