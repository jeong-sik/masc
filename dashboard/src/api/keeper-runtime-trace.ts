// MASC Dashboard — Keeper runtime trace evidence (split from keeper.ts)

import { isRecord } from '../components/common/normalize'
import { fetchWithTimeout, jsonHeaders, DEFAULT_GET_TIMEOUT_MS } from './core'

// --- Runtime trace evidence ---

export interface KeeperRuntimeTraceTurnIdentity {
  requested_keeper_turn_id: number | null
  manifest_keeper_turn_ids: number[]
  receipt_turn_counts: number[]
  max_oas_turn_count: number | null
  provider_lane_resolved_count: number
  provider_attempt_started_count: number
  provider_attempt_finished_count: number
  checkpoint_saved_count: number
  event_bus_correlated_count: number
  memory_injected_count: number
  memory_flushed_count: number
  receipt_appended_count: number
  turn_finished_count: number
}

export interface KeeperRuntimeTraceEventBusSummary {
  event_bus_correlated_count: number
  correlation_ids: string[]
  run_ids: string[]
  context_compact_started_count: number
  context_compacted_count: number
  last_compaction: unknown | null
}

export interface KeeperRuntimeTraceMemorySummary {
  memory_injected_count: number
  memory_injected_present_count: number
  memory_flushed_count: number
  memory_flush_success_count: number
  memory_flush_error_count: number
  episodes_flushed: number
  procedures_flushed: number
}

export interface KeeperRuntimeTraceProviderAttempt {
  ts: string
  event: string
  runtime_id: string | null
  status: string
  error: string | null
  exception_kind: string | null
}

export interface KeeperRuntimeTraceProviderAttemptsSummary {
  started_count: number
  finished_count: number
  terminal_status: string | null
  terminal_error: string | null
  terminal_exception_kind: string | null
  attempts: KeeperRuntimeTraceProviderAttempt[]
}

export interface KeeperRuntimeManifestEventCount {
  event: string
  count: number
}

export const KEEPER_RUNTIME_MANIFEST_SCAN_DIAGNOSTICS_SCHEMA =
  'keeper.runtime_manifest_scan_diagnostics.v1' as const

const KEEPER_RUNTIME_MANIFEST_SCAN_DIAGNOSTIC_KINDS = [
  'retired_event',
  'unsupported_event',
  'invalid_manifest_row',
  'invalid_json_row',
] as const

export type KeeperRuntimeManifestScanDiagnosticKind =
  typeof KEEPER_RUNTIME_MANIFEST_SCAN_DIAGNOSTIC_KINDS[number]

export interface KeeperRuntimeManifestScanDiagnostic {
  kind: KeeperRuntimeManifestScanDiagnosticKind
  event: string | null
  detail: string | null
}

export type KeeperRuntimeManifestScanDiagnostics =
  | {
      state: 'available'
      schema: typeof KEEPER_RUNTIME_MANIFEST_SCAN_DIAGNOSTICS_SCHEMA
      retired_event_count: number
      retired_event_counts: KeeperRuntimeManifestEventCount[]
      unsupported_event_count: number
      unsupported_event_counts: KeeperRuntimeManifestEventCount[]
      unsupported_event_unattributed_count: number
      invalid_manifest_row_count: number
      invalid_json_row_count: number
      samples: KeeperRuntimeManifestScanDiagnostic[]
    }
  | {
      state: 'unavailable'
      schema: string | null
      error: string
    }

export interface KeeperRuntimeLensTurnClock {
  trace_id: string
  keeper_turn_id: number | null
  max_oas_turn_count: number | null
  terminal_event_present: boolean
  terminal_event: string | null
  manifest_total_rows: number
}

export interface KeeperRuntimeLensLifecycleAxis {
  turn_started_count: number
  phase_gate_decided_count: number
  pre_dispatch_blocked_count: number
  receipt_appended_count: number
  turn_finished_count: number
  terminal_status: string
}

export interface KeeperRuntimeLensProviderLaneAxis {
  resolved: boolean
  status: string | null
  resolved_lane: string | null
}

export interface KeeperRuntimeLensProviderAttemptAxis {
  started_count: number
  finished_count: number
  terminal_status: string | null
}

export interface KeeperRuntimeLensPayloadRoleAxis {
  counts: Record<string, number>
}

export interface KeeperRuntimeLensSourceClockAxis {
  counts: Record<string, number>
}

export interface KeeperRuntimeLensClaimScopeAxis {
  present: boolean
  source: string
  status: string
  result: string | null
  mode: string | null
  scoped: boolean | null
  fallback_reason: string | null
  excluded_count: number | null
  claimed_task_id: string | null
}

export interface KeeperRuntimeLensConfigDriftAxis {
  present: boolean
  status: string
  error: string | null
  has_live_override: boolean
  runtime_override: boolean
  override_fields: string[]
  default_runtime_id: string | null
  live_runtime_id: string | null
  active_config_root: string | null
  active_config_root_source: string | null
  default_manifest_path: string | null
}

export interface KeeperRuntimeLensContextAxis {
  context_injected_count: number
  context_compacted_event_count: number
  event_bus_correlated_count: number
  context_compact_started_count: number
  context_compacted_count: number
  checkpoint_loaded_count: number
  checkpoint_saved_count: number
  last_compaction: unknown
}

export interface KeeperRuntimeLensMemoryAxis extends KeeperRuntimeTraceMemorySummary {}

export interface KeeperRuntimeLensAxes {
  lifecycle: KeeperRuntimeLensLifecycleAxis
  provider_lane: KeeperRuntimeLensProviderLaneAxis
  provider_attempt: KeeperRuntimeLensProviderAttemptAxis
  payload_role: KeeperRuntimeLensPayloadRoleAxis
  source_clock: KeeperRuntimeLensSourceClockAxis
  claim_scope: KeeperRuntimeLensClaimScopeAxis
  config_drift: KeeperRuntimeLensConfigDriftAxis
  context: KeeperRuntimeLensContextAxis
  memory: KeeperRuntimeLensMemoryAxis
}

export interface KeeperRuntimeLensLaneEvent {
  event: string
  count: number
}

export interface KeeperRuntimeLensLane {
  lane: string
  label: string
  event_count: number
  terminal_status: string
  completeness: string
  gap_codes: string[]
  gap_badge: string | null
  events: KeeperRuntimeLensLaneEvent[]
}

export interface KeeperRuntimeLensSwimlanes {
  keeper: KeeperRuntimeLensLane
  masc_policy_runtime: KeeperRuntimeLensLane
  oas_agent: KeeperRuntimeLensLane
  provider: KeeperRuntimeLensLane
  tool_runtime: KeeperRuntimeLensLane
  memory_context: KeeperRuntimeLensLane
}

export interface KeeperRuntimeLensGap {
  code: string
  severity: string
  lane: string
  detail: string | null
}

export interface KeeperRuntimeLensClockEdgeLinks {
  receipt_path: string | null
  checkpoint_path: string | null
  tool_call_log_path: string | null
}

export interface KeeperRuntimeLensClockEdge {
  edge_id: string
  lane: string
  event: string
  status: string
  observed_at: string
  source_clock: string
  started_at: string | null
  finished_at: string | null
  trace_id: string
  keeper_turn_id: number | null
  oas_turn_count: number | null
  provider_attempt_id: string | null
  tool_batch_id: string | null
  checkpoint_id: string | null
  compaction_id: string | null
  event_bus_correlation_id: string | null
  event_bus_run_id: string | null
  event_bus_event_count: number | null
  event_bus_payload_kinds: string[]
  parent_event_id: string | null
  caused_by: string | null
  links: KeeperRuntimeLensClockEdgeLinks
}

export interface KeeperRuntimeLensClockGroup {
  group_type: string
  group_id: string
  edge_count: number
  edge_ids: string[]
  lanes: string[]
  events: string[]
  statuses: string[]
  first_observed_at: string | null
  last_observed_at: string | null
  closed: boolean
  terminal_events: string[]
  parent_event_ids: string[]
  caused_by: string[]
  event_bus_event_count: number
  event_bus_payload_kinds: string[]
}

export interface KeeperRuntimeLens {
  turn_clock: KeeperRuntimeLensTurnClock
  axes: KeeperRuntimeLensAxes
  swimlanes: KeeperRuntimeLensSwimlanes
  clock_edges: KeeperRuntimeLensClockEdge[]
  clock_groups: KeeperRuntimeLensClockGroup[]
  gaps: KeeperRuntimeLensGap[]
}

export interface KeeperRuntimeTraceLinkedArtifact {
  kind: string
  path: string
  present: boolean
  file_stat: Record<string, unknown> | null
}

export interface KeeperRuntimeTraceLinkedArtifacts {
  receipts: KeeperRuntimeTraceLinkedArtifact[]
  checkpoints: KeeperRuntimeTraceLinkedArtifact[]
  tool_call_logs: KeeperRuntimeTraceLinkedArtifact[]
}

export interface KeeperRuntimeTraceResponse {
  keeper: string
  trace_id: string
  turn_id: number | null
  manifest_path: string
  manifest_path_present: boolean
  manifest_total_rows: number
  manifest_returned_rows: number
  receipt_returned_rows: number
  manifest_scan_diagnostics: KeeperRuntimeManifestScanDiagnostics
  turn_identity: KeeperRuntimeTraceTurnIdentity
  provider_attempts: KeeperRuntimeTraceProviderAttemptsSummary
  event_bus: KeeperRuntimeTraceEventBusSummary
  memory: KeeperRuntimeTraceMemorySummary
  runtime_lens: KeeperRuntimeLens
  linked_artifacts: KeeperRuntimeTraceLinkedArtifacts
  manifest_rows: Record<string, unknown>[]
  receipts: Record<string, unknown>[]
  health: string
  stale_reason: string | null
}

function numberField(raw: Record<string, unknown>, key: string): number {
  const value = raw[key]
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

function nullableNumberField(raw: Record<string, unknown>, key: string): number | null {
  const value = raw[key]
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function nullableBooleanField(raw: Record<string, unknown>, key: string): boolean | null {
  const value = raw[key]
  return typeof value === 'boolean' ? value : null
}

function stringField(raw: Record<string, unknown>, key: string): string {
  const value = raw[key]
  return typeof value === 'string' ? value : ''
}

function nullableStringField(raw: Record<string, unknown>, key: string): string | null {
  const value = raw[key]
  return typeof value === 'string' ? value : null
}

function numberListField(raw: Record<string, unknown>, key: string): number[] {
  const value = raw[key]
  if (!Array.isArray(value)) return []
  return value.filter((item): item is number => typeof item === 'number' && Number.isFinite(item))
}

function stringListField(raw: Record<string, unknown>, key: string): string[] {
  const value = raw[key]
  if (!Array.isArray(value)) return []
  return value.filter((item): item is string => typeof item === 'string')
}

function nonNegativeInteger(raw: unknown): number | null {
  return typeof raw === 'number' && Number.isInteger(raw) && raw >= 0 ? raw : null
}

function parseManifestEventCount(raw: unknown): KeeperRuntimeManifestEventCount | null {
  if (!isRecord(raw) || typeof raw.event !== 'string' || raw.event === '') return null
  const count = nonNegativeInteger(raw.count)
  return count === null ? null : { event: raw.event, count }
}

function isManifestScanDiagnosticKind(
  raw: unknown,
): raw is KeeperRuntimeManifestScanDiagnosticKind {
  return typeof raw === 'string'
    && KEEPER_RUNTIME_MANIFEST_SCAN_DIAGNOSTIC_KINDS.some(kind => kind === raw)
}

function nullableWireString(raw: unknown): string | null | undefined {
  if (raw === undefined || raw === null) return null
  return typeof raw === 'string' ? raw : undefined
}

function allParsed<T>(values: (T | null)[]): values is T[] {
  return values.every(value => value !== null)
}

function parseManifestScanDiagnostic(
  raw: unknown,
): KeeperRuntimeManifestScanDiagnostic | null {
  if (!isRecord(raw) || !isManifestScanDiagnosticKind(raw.kind)) return null
  const event = nullableWireString(raw.event)
  const detail = nullableWireString(raw.detail)
  if (event === undefined || detail === undefined) return null
  return { kind: raw.kind, event, detail }
}

function parseManifestScanDiagnostics(raw: unknown): KeeperRuntimeManifestScanDiagnostics {
  if (!isRecord(raw)) {
    return {
      state: 'unavailable',
      schema: null,
      error: 'runtime did not report manifest scan diagnostics',
    }
  }
  const schema = typeof raw.schema === 'string' ? raw.schema : null
  if (schema !== KEEPER_RUNTIME_MANIFEST_SCAN_DIAGNOSTICS_SCHEMA) {
    return {
      state: 'unavailable',
      schema,
      error: schema === null
        ? 'manifest scan diagnostics schema is missing'
        : `unsupported manifest scan diagnostics schema: ${schema}`,
    }
  }
  if (
    !Array.isArray(raw.retired_event_counts)
    || !Array.isArray(raw.unsupported_event_counts)
    || !Array.isArray(raw.samples)
  ) {
    return { state: 'unavailable', schema, error: 'malformed manifest scan diagnostics payload' }
  }
  const retiredEventCounts = raw.retired_event_counts.map(parseManifestEventCount)
  const unsupportedEventCounts = raw.unsupported_event_counts.map(parseManifestEventCount)
  const samples = raw.samples.map(parseManifestScanDiagnostic)
  const retiredEventCount = nonNegativeInteger(raw.retired_event_count)
  const unsupportedEventCount = nonNegativeInteger(raw.unsupported_event_count)
  const unsupportedEventUnattributedCount = nonNegativeInteger(
    raw.unsupported_event_unattributed_count,
  )
  const invalidManifestRowCount = nonNegativeInteger(raw.invalid_manifest_row_count)
  const invalidJsonRowCount = nonNegativeInteger(raw.invalid_json_row_count)
  if (
    retiredEventCount === null
    || unsupportedEventCount === null
    || unsupportedEventUnattributedCount === null
    || invalidManifestRowCount === null
    || invalidJsonRowCount === null
    || !allParsed(retiredEventCounts)
    || !allParsed(unsupportedEventCounts)
    || !allParsed(samples)
  ) {
    return { state: 'unavailable', schema, error: 'malformed manifest scan diagnostics payload' }
  }
  return {
    state: 'available',
    schema,
    retired_event_count: retiredEventCount,
    retired_event_counts: retiredEventCounts,
    unsupported_event_count: unsupportedEventCount,
    unsupported_event_counts: unsupportedEventCounts,
    unsupported_event_unattributed_count: unsupportedEventUnattributedCount,
    invalid_manifest_row_count: invalidManifestRowCount,
    invalid_json_row_count: invalidJsonRowCount,
    samples,
  }
}

function recordListField(raw: Record<string, unknown>, key: string): Record<string, unknown>[] {
  const value = raw[key]
  if (!Array.isArray(value)) return []
  return value.filter(isRecord)
}

function parseRuntimeTraceLinkedArtifact(raw: unknown): KeeperRuntimeTraceLinkedArtifact {
  const obj = isRecord(raw) ? raw : {}
  return {
    kind: stringField(obj, 'kind'),
    path: stringField(obj, 'path'),
    present: obj.present === true,
    file_stat: isRecord(obj.file_stat) ? obj.file_stat : null,
  }
}

function parseRuntimeTraceLinkedArtifacts(raw: unknown): KeeperRuntimeTraceLinkedArtifacts {
  const obj = isRecord(raw) ? raw : {}
  const parseList = (key: string) => {
    const value = obj[key]
    return Array.isArray(value) ? value.map(parseRuntimeTraceLinkedArtifact) : []
  }
  return {
    receipts: parseList('receipts'),
    checkpoints: parseList('checkpoints'),
    tool_call_logs: parseList('tool_call_logs'),
  }
}

function parseRuntimeTraceTurnIdentity(raw: unknown): KeeperRuntimeTraceTurnIdentity {
  const obj = isRecord(raw) ? raw : {}
  return {
    requested_keeper_turn_id: nullableNumberField(obj, 'requested_keeper_turn_id'),
    manifest_keeper_turn_ids: numberListField(obj, 'manifest_keeper_turn_ids'),
    receipt_turn_counts: numberListField(obj, 'receipt_turn_counts'),
    max_oas_turn_count: nullableNumberField(obj, 'max_oas_turn_count'),
    provider_lane_resolved_count: numberField(obj, 'provider_lane_resolved_count'),
    provider_attempt_started_count: numberField(obj, 'provider_attempt_started_count'),
    provider_attempt_finished_count: numberField(obj, 'provider_attempt_finished_count'),
    checkpoint_saved_count: numberField(obj, 'checkpoint_saved_count'),
    event_bus_correlated_count: numberField(obj, 'event_bus_correlated_count'),
    memory_injected_count: numberField(obj, 'memory_injected_count'),
    memory_flushed_count: numberField(obj, 'memory_flushed_count'),
    receipt_appended_count: numberField(obj, 'receipt_appended_count'),
    turn_finished_count: numberField(obj, 'turn_finished_count'),
  }
}

function parseRuntimeTraceEventBus(raw: unknown): KeeperRuntimeTraceEventBusSummary {
  const obj = isRecord(raw) ? raw : {}
  return {
    event_bus_correlated_count: numberField(obj, 'event_bus_correlated_count'),
    correlation_ids: stringListField(obj, 'correlation_ids'),
    run_ids: stringListField(obj, 'run_ids'),
    context_compact_started_count: numberField(obj, 'context_compact_started_count'),
    context_compacted_count: numberField(obj, 'context_compacted_count'),
    last_compaction: obj.last_compaction ?? null,
  }
}

function parseRuntimeTraceMemory(raw: unknown): KeeperRuntimeTraceMemorySummary {
  const obj = isRecord(raw) ? raw : {}
  return {
    memory_injected_count: numberField(obj, 'memory_injected_count'),
    memory_injected_present_count: numberField(obj, 'memory_injected_present_count'),
    memory_flushed_count: numberField(obj, 'memory_flushed_count'),
    memory_flush_success_count: numberField(obj, 'memory_flush_success_count'),
    memory_flush_error_count: numberField(obj, 'memory_flush_error_count'),
    episodes_flushed: numberField(obj, 'episodes_flushed'),
    procedures_flushed: numberField(obj, 'procedures_flushed'),
  }
}

function parseRuntimeTraceProviderAttempt(raw: unknown): KeeperRuntimeTraceProviderAttempt {
  const obj = isRecord(raw) ? raw : {}
  return {
    ts: stringField(obj, 'ts'),
    event: stringField(obj, 'event'),
    runtime_id: nullableStringField(obj, 'runtime_id'),
    status: stringField(obj, 'status'),
    error: nullableStringField(obj, 'error'),
    exception_kind: nullableStringField(obj, 'exception_kind'),
  }
}

function parseRuntimeTraceProviderAttempts(raw: unknown): KeeperRuntimeTraceProviderAttemptsSummary {
  const obj = isRecord(raw) ? raw : {}
  const attempts = Array.isArray(obj.attempts)
    ? obj.attempts.map(parseRuntimeTraceProviderAttempt)
    : []
  return {
    started_count: numberField(obj, 'started_count'),
    finished_count: numberField(obj, 'finished_count'),
    terminal_status: nullableStringField(obj, 'terminal_status'),
    terminal_error: nullableStringField(obj, 'terminal_error'),
    terminal_exception_kind: nullableStringField(obj, 'terminal_exception_kind'),
    attempts,
  }
}

function parseRuntimeLensTurnClock(raw: unknown, fallbackTraceId: string): KeeperRuntimeLensTurnClock {
  const obj = isRecord(raw) ? raw : {}
  return {
    trace_id: stringField(obj, 'trace_id') || fallbackTraceId,
    keeper_turn_id: nullableNumberField(obj, 'keeper_turn_id'),
    max_oas_turn_count: nullableNumberField(obj, 'max_oas_turn_count'),
    terminal_event_present: obj.terminal_event_present === true,
    terminal_event: nullableStringField(obj, 'terminal_event'),
    manifest_total_rows: numberField(obj, 'manifest_total_rows'),
  }
}

function parseRuntimeLensLifecycleAxis(raw: unknown): KeeperRuntimeLensLifecycleAxis {
  const obj = isRecord(raw) ? raw : {}
  return {
    turn_started_count: numberField(obj, 'turn_started_count'),
    phase_gate_decided_count: numberField(obj, 'phase_gate_decided_count'),
    pre_dispatch_blocked_count: numberField(obj, 'pre_dispatch_blocked_count'),
    receipt_appended_count: numberField(obj, 'receipt_appended_count'),
    turn_finished_count: numberField(obj, 'turn_finished_count'),
    terminal_status: stringField(obj, 'terminal_status') || 'unknown',
  }
}

function parseRuntimeLensProviderLaneAxis(raw: unknown): KeeperRuntimeLensProviderLaneAxis {
  const obj = isRecord(raw) ? raw : {}
  return {
    resolved: obj.resolved === true,
    status: nullableStringField(obj, 'status'),
    resolved_lane: nullableStringField(obj, 'resolved_lane'),
  }
}

function parseRuntimeLensProviderAttemptAxis(raw: unknown): KeeperRuntimeLensProviderAttemptAxis {
  const obj = isRecord(raw) ? raw : {}
  return {
    started_count: numberField(obj, 'started_count'),
    finished_count: numberField(obj, 'finished_count'),
    terminal_status: nullableStringField(obj, 'terminal_status'),
  }
}

function parseRuntimeLensPayloadRoleAxis(raw: unknown): KeeperRuntimeLensPayloadRoleAxis {
  const obj = isRecord(raw) ? raw : {}
  const counts: Record<string, number> = {}
  if (isRecord(obj)) {
    for (const key of Object.keys(obj)) {
      const value = obj[key]
      if (typeof value === 'number') {
        counts[key] = value
      }
    }
  }
  return { counts }
}

function parseRuntimeLensSourceClockAxis(raw: unknown): KeeperRuntimeLensSourceClockAxis {
  const obj = isRecord(raw) ? raw : {}
  const counts: Record<string, number> = {}
  if (isRecord(obj)) {
    for (const key of Object.keys(obj)) {
      const value = obj[key]
      if (typeof value === 'number') {
        counts[key] = value
      }
    }
  }
  return { counts }
}

function parseRuntimeLensClaimScopeAxis(raw: unknown): KeeperRuntimeLensClaimScopeAxis {
  const obj = isRecord(raw) ? raw : {}
  return {
    present: obj.present === true,
    source: stringField(obj, 'source') || '(unknown source)',
    status: stringField(obj, 'status') || 'not_observed',
    result: nullableStringField(obj, 'result'),
    mode: nullableStringField(obj, 'mode'),
    scoped: nullableBooleanField(obj, 'scoped'),
    fallback_reason: nullableStringField(obj, 'fallback_reason'),
    excluded_count: nullableNumberField(obj, 'excluded_count'),
    claimed_task_id: nullableStringField(obj, 'claimed_task_id'),
  }
}

function parseRuntimeLensConfigDriftAxis(raw: unknown): KeeperRuntimeLensConfigDriftAxis {
  const obj = isRecord(raw) ? raw : {}
  return {
    present: obj.present === true,
    status: stringField(obj, 'status') || 'unknown',
    error: nullableStringField(obj, 'error'),
    has_live_override: obj.has_live_override === true,
    runtime_override: obj.runtime_override === true,
    override_fields: stringListField(obj, 'override_fields'),
    default_runtime_id: nullableStringField(obj, 'default_runtime_id'),
    live_runtime_id: nullableStringField(obj, 'live_runtime_id'),
    active_config_root: nullableStringField(obj, 'active_config_root'),
    active_config_root_source: nullableStringField(obj, 'active_config_root_source'),
    default_manifest_path: nullableStringField(obj, 'default_manifest_path'),
  }
}

function parseRuntimeLensContextAxis(raw: unknown): KeeperRuntimeLensContextAxis {
  const obj = isRecord(raw) ? raw : {}
  return {
    context_injected_count: numberField(obj, 'context_injected_count'),
    context_compacted_event_count: numberField(obj, 'context_compacted_event_count'),
    event_bus_correlated_count: numberField(obj, 'event_bus_correlated_count'),
    context_compact_started_count: numberField(obj, 'context_compact_started_count'),
    context_compacted_count: numberField(obj, 'context_compacted_count'),
    checkpoint_loaded_count: numberField(obj, 'checkpoint_loaded_count'),
    checkpoint_saved_count: numberField(obj, 'checkpoint_saved_count'),
    last_compaction: obj.last_compaction ?? null,
  }
}

function parseRuntimeLensAxes(raw: unknown): KeeperRuntimeLensAxes {
  const obj = isRecord(raw) ? raw : {}
  return {
    lifecycle: parseRuntimeLensLifecycleAxis(obj.lifecycle),
    provider_lane: parseRuntimeLensProviderLaneAxis(obj.provider_lane),
    provider_attempt: parseRuntimeLensProviderAttemptAxis(obj.provider_attempt),
    payload_role: parseRuntimeLensPayloadRoleAxis(obj.payload_role),
    source_clock: parseRuntimeLensSourceClockAxis(obj.source_clock),
    claim_scope: parseRuntimeLensClaimScopeAxis(obj.claim_scope),
    config_drift: parseRuntimeLensConfigDriftAxis(obj.config_drift),
    context: parseRuntimeLensContextAxis(obj.context),
    memory: parseRuntimeTraceMemory(obj.memory),
  }
}

function parseRuntimeLensLaneEvent(raw: unknown): KeeperRuntimeLensLaneEvent {
  const obj = isRecord(raw) ? raw : {}
  return {
    event: stringField(obj, 'event'),
    count: numberField(obj, 'count'),
  }
}

function parseRuntimeLensLane(raw: unknown, lane: string, label: string): KeeperRuntimeLensLane {
  const obj = isRecord(raw) ? raw : {}
  const events = Array.isArray(obj.events)
    ? obj.events.map(parseRuntimeLensLaneEvent).filter(event => event.event !== '')
    : []
  return {
    lane: stringField(obj, 'lane') || lane,
    label: stringField(obj, 'label') || label,
    event_count: numberField(obj, 'event_count'),
    terminal_status: stringField(obj, 'terminal_status') || 'unknown',
    completeness: stringField(obj, 'completeness') || 'unknown',
    gap_codes: stringListField(obj, 'gap_codes'),
    gap_badge: nullableStringField(obj, 'gap_badge'),
    events,
  }
}

function parseRuntimeLensSwimlanes(raw: unknown): KeeperRuntimeLensSwimlanes {
  const obj = isRecord(raw) ? raw : {}
  return {
    keeper: parseRuntimeLensLane(obj.keeper, 'keeper', 'Keeper'),
    masc_policy_runtime: parseRuntimeLensLane(obj.masc_policy_runtime, 'masc_policy_runtime', 'MASC Runtime'),
    oas_agent: parseRuntimeLensLane(obj.oas_agent, 'oas_agent', 'OAS'),
    provider: parseRuntimeLensLane(obj.provider, 'provider', 'Provider'),
    tool_runtime: parseRuntimeLensLane(obj.tool_runtime, 'tool_runtime', 'Tool Runtime'),
    memory_context: parseRuntimeLensLane(obj.memory_context, 'memory_context', 'Memory/Context'),
  }
}

function parseRuntimeLensGap(raw: unknown): KeeperRuntimeLensGap {
  const obj = isRecord(raw) ? raw : {}
  return {
    code: stringField(obj, 'code') || 'unknown_gap',
    severity: stringField(obj, 'severity') || '(unknown severity)',
    lane: stringField(obj, 'lane') || 'unknown',
    detail: nullableStringField(obj, 'detail'),
  }
}

function parseRuntimeLensClockEdgeLinks(raw: unknown): KeeperRuntimeLensClockEdgeLinks {
  const obj = isRecord(raw) ? raw : {}
  return {
    receipt_path: nullableStringField(obj, 'receipt_path'),
    checkpoint_path: nullableStringField(obj, 'checkpoint_path'),
    tool_call_log_path: nullableStringField(obj, 'tool_call_log_path'),
  }
}

function parseRuntimeLensClockEdge(raw: unknown): KeeperRuntimeLensClockEdge {
  const obj = isRecord(raw) ? raw : {}
  return {
    edge_id: stringField(obj, 'edge_id') || 'unknown_edge',
    lane: stringField(obj, 'lane') || 'unknown',
    event: stringField(obj, 'event') || 'unknown_event',
    status: stringField(obj, 'status') || 'unknown',
    observed_at: stringField(obj, 'observed_at'),
    source_clock: stringField(obj, 'source_clock') || 'unknown',
    started_at: nullableStringField(obj, 'started_at'),
    finished_at: nullableStringField(obj, 'finished_at'),
    trace_id: stringField(obj, 'trace_id'),
    keeper_turn_id: nullableNumberField(obj, 'keeper_turn_id'),
    oas_turn_count: nullableNumberField(obj, 'oas_turn_count'),
    provider_attempt_id: nullableStringField(obj, 'provider_attempt_id'),
    tool_batch_id: nullableStringField(obj, 'tool_batch_id'),
    checkpoint_id: nullableStringField(obj, 'checkpoint_id'),
    compaction_id: nullableStringField(obj, 'compaction_id'),
    event_bus_correlation_id: nullableStringField(obj, 'event_bus_correlation_id'),
    event_bus_run_id: nullableStringField(obj, 'event_bus_run_id'),
    event_bus_event_count: nullableNumberField(obj, 'event_bus_event_count'),
    event_bus_payload_kinds: stringListField(obj, 'event_bus_payload_kinds'),
    parent_event_id: nullableStringField(obj, 'parent_event_id'),
    caused_by: nullableStringField(obj, 'caused_by'),
    links: parseRuntimeLensClockEdgeLinks(obj.links),
  }
}

function parseRuntimeLensClockGroup(raw: unknown): KeeperRuntimeLensClockGroup {
  const obj = isRecord(raw) ? raw : {}
  return {
    group_type: stringField(obj, 'group_type') || 'unknown',
    group_id: stringField(obj, 'group_id') || 'unknown_group',
    edge_count: numberField(obj, 'edge_count'),
    edge_ids: stringListField(obj, 'edge_ids'),
    lanes: stringListField(obj, 'lanes'),
    events: stringListField(obj, 'events'),
    statuses: stringListField(obj, 'statuses'),
    first_observed_at: nullableStringField(obj, 'first_observed_at'),
    last_observed_at: nullableStringField(obj, 'last_observed_at'),
    closed: nullableBooleanField(obj, 'closed') ?? false,
    terminal_events: stringListField(obj, 'terminal_events'),
    parent_event_ids: stringListField(obj, 'parent_event_ids'),
    caused_by: stringListField(obj, 'caused_by'),
    event_bus_event_count: numberField(obj, 'event_bus_event_count'),
    event_bus_payload_kinds: stringListField(obj, 'event_bus_payload_kinds'),
  }
}

function parseRuntimeLens(raw: unknown, fallbackTraceId: string): KeeperRuntimeLens {
  const obj = isRecord(raw) ? raw : {}
  const gaps = Array.isArray(obj.gaps) ? obj.gaps.map(parseRuntimeLensGap) : []
  const clockEdges = Array.isArray(obj.clock_edges)
    ? obj.clock_edges.map(parseRuntimeLensClockEdge)
    : []
  const clockGroups = Array.isArray(obj.clock_groups)
    ? obj.clock_groups.map(parseRuntimeLensClockGroup)
    : []
  return {
    turn_clock: parseRuntimeLensTurnClock(obj.turn_clock, fallbackTraceId),
    axes: parseRuntimeLensAxes(obj.axes),
    swimlanes: parseRuntimeLensSwimlanes(obj.swimlanes),
    clock_edges: clockEdges,
    clock_groups: clockGroups,
    gaps,
  }
}

export function parseKeeperRuntimeTrace(raw: unknown): KeeperRuntimeTraceResponse {
  if (!isRecord(raw)) throw new Error('runtime trace response is not a record')
  const traceId = stringField(raw, 'trace_id')
  return {
    keeper: stringField(raw, 'keeper'),
    trace_id: traceId,
    turn_id: nullableNumberField(raw, 'turn_id'),
    manifest_path: stringField(raw, 'manifest_path'),
    manifest_path_present: raw.manifest_path_present === true,
    manifest_total_rows: numberField(raw, 'manifest_total_rows'),
    manifest_returned_rows: numberField(raw, 'manifest_returned_rows'),
    receipt_returned_rows: numberField(raw, 'receipt_returned_rows'),
    manifest_scan_diagnostics: parseManifestScanDiagnostics(raw.manifest_scan_diagnostics),
    turn_identity: parseRuntimeTraceTurnIdentity(raw.turn_identity),
    provider_attempts: parseRuntimeTraceProviderAttempts(raw.provider_attempts),
    event_bus: parseRuntimeTraceEventBus(raw.event_bus),
    memory: parseRuntimeTraceMemory(raw.memory),
    runtime_lens: parseRuntimeLens(raw.runtime_lens, traceId),
    linked_artifacts: parseRuntimeTraceLinkedArtifacts(raw.linked_artifacts),
    manifest_rows: recordListField(raw, 'manifest_rows'),
    receipts: recordListField(raw, 'receipts'),
    health: stringField(raw, 'health') || 'unknown',
    stale_reason: nullableStringField(raw, 'stale_reason'),
  }
}

export async function fetchKeeperRuntimeTrace(
  name: string,
  opts?: { traceId?: string; turnId?: number; limit?: number; signal?: AbortSignal },
): Promise<KeeperRuntimeTraceResponse> {
  const params = new URLSearchParams()
  if (opts?.traceId) params.set('trace_id', opts.traceId)
  if (typeof opts?.turnId === 'number') params.set('turn_id', String(opts.turnId))
  if (typeof opts?.limit === 'number') params.set('limit', String(opts.limit))
  const qs = params.toString()
  const resp = await fetchWithTimeout(
    `/api/v1/keepers/${encodeURIComponent(name)}/runtime-trace${qs ? `?${qs}` : ''}`,
    { headers: jsonHeaders(), signal: opts?.signal },
    DEFAULT_GET_TIMEOUT_MS,
  )
  if (!resp.ok) throw new Error(`runtime trace fetch failed: ${resp.status}`)
  return parseKeeperRuntimeTrace(await resp.json())
}
