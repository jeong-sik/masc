import type {
  CtxCompositionTelemetry,
  Keeper,
  KeeperLifecycleState,
  KeeperMetricPoint,
  KeeperPhase,
  KeeperProfileConfigErrorKind,
  KeeperTrustLatestEvent,
  KeeperTrustTerminalReason,
  PipelineStage,
  PromptTelemetry,
  ProviderHealth,
} from './types'
import { isRecord, asString, asNumber, asBoolean, asStringArray, toIsoTimestamp } from './components/common/normalize'
import { isKeeperOffline } from './lib/keeper-predicates'
import { keeperDisplayStatus } from './lib/keeper-runtime-display'
import { asKeeperRuntimeBlockerClass } from './lib/runtime-blocker-class'
import {
  asKeeperPauseState,
  asKeeperRuntimeBlockerState,
} from './lib/keeper-runtime-state'
import { normalizeStopCause } from './lib/stop-cause'
import { contextThresholds } from './config/context-thresholds'
import { normalizeKeeperDiagnostic } from './keeper-state'
import type { RuntimeRef } from './types'

/** Normalize a raw runtime_ref JSON object into a typed RuntimeRef. */
function normalizeRuntimeRef(raw: unknown): RuntimeRef | null {
  if (!isRecord(raw)) return null
  const group = asString(raw.group)
  if (!group) return null
  const item = asString(raw.item) ?? null
  return { group, item }
}

function normalizeKeeperLiveActivitySource(raw: unknown): Keeper['last_activity_source'] {
  const source = asString(raw)?.trim()
  switch (source) {
    case 'keeper_meta':
    case 'tool_call':
    case 'approval_pending':
      return source
    default:
      return null
  }
}

function normalizeKeeperProfileConfigError(raw: unknown): Keeper['config_error'] {
  if (!isRecord(raw)) return null
  const reportedKind = asString(raw.kind)
  if (!reportedKind) return null
  const kind: KeeperProfileConfigErrorKind =
    reportedKind === 'read_error'
    || reportedKind === 'parse_error'
    || reportedKind === 'profile_error'
    || reportedKind === 'invalid_name'
      ? reportedKind
      : 'unknown'
  const keeper = asString(raw.keeper)
  const keeperPath = asString(raw.keeper_path)
  const failingPath = asString(raw.failing_path)
  const detail = asString(raw.detail)
  if (!keeper || !keeperPath || !failingPath || !detail) return null
  if (
    raw.terminal_reason !== 'config_invalid'
    || raw.blocking !== true
    || raw.operator_action_required !== true
    || raw.next_action !== 'fix_keeper_toml_config'
  ) return null
  return {
    keeper,
    keeper_path: keeperPath,
    failing_path: failingPath,
    kind,
    reported_kind: kind === 'unknown' ? reportedKind : null,
    detail,
    terminal_reason: 'config_invalid',
    blocking: true,
    operator_action_required: true,
    next_action: 'fix_keeper_toml_config',
  }
}

function normalizeKeeperLiveActivity(raw: unknown): Keeper['live_activity'] {
  if (!isRecord(raw)) return null
  return {
    source: normalizeKeeperLiveActivitySource(raw.source),
    at: toIsoTimestamp(raw.at) ?? asString(raw.at) ?? null,
    age_s: asNumber(raw.age_s) ?? null,
    tool: asString(raw.tool) ?? null,
    turn: asNumber(raw.turn) ?? null,
    keeper_turn_id: asNumber(raw.keeper_turn_id) ?? null,
  }
}

function normalizeKeeperCurrentGate(raw: unknown): Keeper['current_gate'] {
  if (!isRecord(raw)) return null
  const kind = asString(raw.kind) ?? null
  if (!kind) return null
  return {
    kind,
    source: asString(raw.source) ?? null,
    id: asString(raw.id) ?? null,
    tool: asString(raw.tool) ?? null,
    turn_id: asNumber(raw.turn_id) ?? null,
    at: toIsoTimestamp(raw.at) ?? asString(raw.at) ?? null,
    age_s: asNumber(raw.age_s) ?? null,
    disposition: asString(raw.disposition) ?? null,
    disposition_reason: asString(raw.disposition_reason) ?? null,
  }
}

function normalizeKeeperTrustSeverity(raw: unknown): KeeperTrustLatestEvent['severity'] | null {
  const severity = asString(raw)?.trim().toLowerCase()
  switch (severity) {
    case 'ok':
    case 'warn':
    case 'bad':
      return severity
    default:
      return null
  }
}

function normalizeKeeperSandboxProfile(raw: unknown): Keeper['sandbox_profile'] {
  const profile = asString(raw)?.trim().toLowerCase()
  switch (profile) {
    case 'local':
    case 'docker':
      return profile
    default:
      return null
  }
}

/** Maps lowercase backend phase strings (`keeper_state_machine.ml:phase_to_string`)
 *  to PascalCase `KeeperPhase` values. The two unions must stay 1:1 — this is
 *  enforced at compile time by `_BACKEND_PHASE_COVERAGE_CHECK` below.
 *
 *  SSOT contract:
 *    backend variant added → lowercase entry added AND KeeperPhase union extended.
 *    KeeperPhase union extended → coverage check fails if lowercase entry missing.
 *  Drift in either direction surfaces as a typecheck failure, not a silent
 *  string-as-truth fallback.
 */
const BACKEND_PHASE_LOWERCASE_MAP = {
  offline: 'Offline',
  running: 'Running',
  failing: 'Failing',
  overflowed: 'Overflowed',
  compacting: 'Compacting',
  handing_off: 'HandingOff',
  draining: 'Draining',
  paused: 'Paused',
  stopped: 'Stopped',
  crashed: 'Crashed',
  restarting: 'Restarting',
  dead: 'Dead',
} as const satisfies Record<string, KeeperPhase>

/** Forward-compat PascalCase passthrough — accepts already-typed values from
 *  test fixtures or future backend emit paths. Constrained to `KeeperPhase`
 *  keys so a typo would fail typecheck. */
const BACKEND_PHASE_PASCAL_PASSTHROUGH = {
  Offline: 'Offline',
  Running: 'Running',
  Failing: 'Failing',
  Overflowed: 'Overflowed',
  Compacting: 'Compacting',
  HandingOff: 'HandingOff',
  Draining: 'Draining',
  Paused: 'Paused',
  Stopped: 'Stopped',
  Crashed: 'Crashed',
  Restarting: 'Restarting',
  Dead: 'Dead',
} as const satisfies Record<KeeperPhase, KeeperPhase>

// Compile-time coverage check: every KeeperPhase variant must appear as a
// *value* in the lowercase map. If KeeperPhase adds a new arm but the
// lowercase entry is forgotten, this line fails to typecheck.
//
//   type _Missing = Exclude<KeeperPhase, typeof MAP[keyof typeof MAP]>
//
// resolves to `never` only when the map is exhaustive over KeeperPhase.
type _LowercaseMapValueUnion = typeof BACKEND_PHASE_LOWERCASE_MAP[keyof typeof BACKEND_PHASE_LOWERCASE_MAP]
type _MissingLowercaseCoverage = Exclude<KeeperPhase, _LowercaseMapValueUnion>
// If the lowercase map drifts away from `KeeperPhase`, `_MissingLowercaseCoverage`
// resolves to the un-mapped variant string and the `true` literal fails to assign.
const _BACKEND_PHASE_COVERAGE_CHECK: [_MissingLowercaseCoverage] extends [never] ? true : _MissingLowercaseCoverage = true
void _BACKEND_PHASE_COVERAGE_CHECK

export function toKeeperPhase(raw: string | null | undefined): KeeperPhase | null {
  if (!raw) return null
  const trimmed = raw.trim()
  if (!trimmed) return null
  if (trimmed in BACKEND_PHASE_LOWERCASE_MAP) {
    return BACKEND_PHASE_LOWERCASE_MAP[trimmed as keyof typeof BACKEND_PHASE_LOWERCASE_MAP]
  }
  if (trimmed in BACKEND_PHASE_PASCAL_PASSTHROUGH) {
    return BACKEND_PHASE_PASCAL_PASSTHROUGH[trimmed as keyof typeof BACKEND_PHASE_PASCAL_PASSTHROUGH]
  }
  return null
}

// Closed runtime mirror of the `PipelineStage` type (types/core.ts:709).
// `keeper-store-normalize.ts:569` previously cast `asString(row.pipeline_stage)`
// directly with `as PipelineStage`, which trusted whatever the backend
// emitted. `toPipelineStage` enforces the boundary at the normalizer
// edge so an unrecognized string returns `null` instead of polluting
// the typed value. Mirrors `toKeeperPhase` (line 94) and
// `toKeeperLifecycleState` (iter65, sibling cleanup PR).
const PIPELINE_STAGES: ReadonlySet<PipelineStage> = new Set<PipelineStage>([
  'idle', 'compacting', 'handoff', 'offline',
  'failing', 'overflowed', 'draining', 'paused',
  'crashed', 'restarting', 'unknown',
])

export function toPipelineStage(raw: string | null | undefined): PipelineStage | null {
  if (!raw) return null
  const trimmed = raw.trim()
  if (!trimmed) return null
  return PIPELINE_STAGES.has(trimmed as PipelineStage)
    ? (trimmed as PipelineStage)
    : null
}

function normalizeKeeperAgentStatus(value: unknown): Keeper['status'] {
  const raw = typeof value === 'string' ? value.trim().toLowerCase() : ''
  if (
    raw === 'active'
    || raw === 'busy'
    || raw === 'listening'
    || raw === 'idle'
    || raw === 'inactive'
    || raw === 'offline'
    || raw === 'paused'
    || raw === 'unbooted'
    || raw === 'stopped'
  ) {
    return raw
  }
  if (raw === 'in_progress' || raw === 'claimed') return 'busy'
  if (raw === 'dead' || raw === 'left') return 'offline'
  return 'offline'
}

// Closed set of display strings that `keeperDisplayStatus` may emit
// when an offline keeper is rendered. Kept as a `const` set so adding
// a new value at the `KeeperLifecycleState` union type forces a
// parallel update here.
const KEEPER_LIFECYCLE_STATES: ReadonlySet<KeeperLifecycleState> = new Set<KeeperLifecycleState>([
  'active', 'compacting', 'preparing', 'handoff-imminent',
  'idle', 'offline', 'unbooted', 'stopped',
  'paused', 'crashed', 'dead', 'unknown',
])

// Typed parse: replaces the `as KeeperLifecycleState` cast that
// previously trusted whatever `keeperDisplayStatus` returned. Returns
// `null` on unrecognized input; callers decide the fallback. Mirrors
// `toKeeperPhase` (line 94 of this file) in shape.
export function toKeeperLifecycleState(raw: string | null | undefined): KeeperLifecycleState | null {
  if (!raw) return null
  const trimmed = raw.trim()
  if (!trimmed) return null
  return KEEPER_LIFECYCLE_STATES.has(trimmed as KeeperLifecycleState)
    ? (trimmed as KeeperLifecycleState)
    : null
}

export function deriveLifecycleState(keeper: Keeper): KeeperLifecycleState {
  // RFC-0139 PR-2: strict-superset migration off `isOfflineStatus`
  // (status-only). `isKeeperOffline` adds the terminal-FSM-phase axis
  // (Offline/Stopped/Dead/Crashed) so a keeper crashed mid-tick
  // is caught even when its wire-format status hasn't transitioned yet.
  if (isKeeperOffline(keeper)) {
    // Keep offline-detail labels on a typed display axis. Unknown future
    // wire values fall back to idle instead of silently expanding UI state.
    return toKeeperLifecycleState(keeperDisplayStatus(keeper)) ?? 'idle'
  }

  const series = keeper.metrics_series
  if (!series || series.length === 0) {
    return 'idle'
  }
  const latest = series[series.length - 1]
  if (!latest) return 'idle'
  if (latest.is_handoff) return 'handoff-imminent'
  if (latest.is_compaction) return 'compacting'
  const ratio = latest.context_ratio
  const thresholds = contextThresholds.value
  if (ratio > thresholds.critical) return 'handoff-imminent'
  if (ratio > thresholds.warn) return 'preparing'
  if (ratio > thresholds.compacting) return 'compacting'
  return 'active'
}

export function keeperFreshnessTs(keeper: Keeper, heartbeats: Map<string, number>): number | null {
  const mapped = heartbeats.get(keeper.name)
  if (mapped != null) return mapped

  const direct = keeper.last_heartbeat ? Date.parse(keeper.last_heartbeat) : Number.NaN
  if (!Number.isNaN(direct)) return direct

  const ageSeconds = [
    keeper.last_turn_ago_s,
    keeper.last_proactive_ago_s,
    keeper.last_handoff_ago_s,
    keeper.last_compaction_ago_s,
  ].find(value => typeof value === 'number' && Number.isFinite(value) && value >= 0)

  return typeof ageSeconds === 'number'
    ? Date.now() - (ageSeconds * 1000)
    : null
}

function normalizeKeeperTrustLatestEvent(raw: unknown): KeeperTrustLatestEvent | null {
  if (!isRecord(raw)) return null
  const kind = asString(raw.kind)
  const ts = asString(raw.ts)
  const title = asString(raw.title)
  const summary = asString(raw.summary)
  const severity = normalizeKeeperTrustSeverity(raw.severity)
  if (!kind || !ts || !title || !summary || !severity) return null
  return {
    kind,
    ts,
    ts_unix: asNumber(raw.ts_unix) ?? null,
    keeper_turn_id: asNumber(raw.keeper_turn_id) ?? null,
    task_id: asString(raw.task_id) ?? null,
    goal_ids: asStringArray(raw.goal_ids),
    title,
    summary,
    severity,
    next_human_action: asString(raw.next_human_action) ?? null,
    trace_id: asString(raw.trace_id) ?? null,
  }
}

export function normalizeKeeperTrustTerminalReason(raw: unknown): KeeperTrustTerminalReason | null {
  if (!isRecord(raw)) return null
  const code = asString(raw.code)
  if (!code) return null
  return {
    code,
    source: asString(raw.source) ?? null,
    severity: normalizeKeeperTrustSeverity(raw.severity),
    summary: asString(raw.summary) ?? null,
    next_action: asString(raw.next_action) ?? null,
  }
}

export function normalizeKeeperTrust(raw: unknown): Keeper['trust'] {
  if (!isRecord(raw)) return null
  const approvalRaw = isRecord(raw.approval_state) ? raw.approval_state : raw.approval
  const executionRaw = isRecord(raw.execution_summary) ? raw.execution_summary : raw.execution
  return {
    disposition: asString(raw.disposition) ?? null,
    disposition_reason: asString(raw.disposition_reason) ?? null,
    operator_disposition: asString(raw.operator_disposition) ?? null,
    operator_disposition_reason: asString(raw.operator_disposition_reason) ?? null,
    needs_attention:
      typeof raw.needs_attention === 'boolean' ? raw.needs_attention : null,
    attention_reason: asString(raw.attention_reason) ?? null,
    next_human_action: asString(raw.next_human_action) ?? null,
    latest_terminal_reason: normalizeKeeperTrustTerminalReason(raw.latest_terminal_reason),
    latest_next_action: asString(raw.latest_next_action) ?? null,
    approval_state: isRecord(approvalRaw)
      ? {
          state: asString(approvalRaw.state) ?? null,
          summary: asString(approvalRaw.summary) ?? null,
          pending_count: asNumber(approvalRaw.pending_count) ?? null,
          pending_first: isRecord(approvalRaw.pending_first)
            ? {
                id: asString(approvalRaw.pending_first.id) ?? null,
                tool_name: asString(approvalRaw.pending_first.tool_name) ?? null,
                task_id: asString(approvalRaw.pending_first.task_id) ?? null,
                blocker_class: asString(approvalRaw.pending_first.blocker_class) ?? null,
              }
            : null,
          latest_event_at: asString(approvalRaw.latest_event_at) ?? null,
        }
      : null,
    execution_summary: isRecord(executionRaw)
      ? {
          provider_attempt_count:
            asNumber(executionRaw.provider_attempt_count) ?? null,
          provider_fallback_applied:
            asBoolean(executionRaw.provider_fallback_applied) ?? null,
          provider_selected_model: asString(executionRaw.provider_selected_model) ?? null,
          runtime_outcome: asString(executionRaw.runtime_outcome) ?? null,
          sandbox_summary: asString(executionRaw.sandbox_summary) ?? null,
          sandbox_root: asString(executionRaw.sandbox_root) ?? null,
          completion_observation_summary:
            asString(executionRaw.completion_observation_summary) ?? null,
          latest_receipt_at: asString(executionRaw.latest_receipt_at) ?? null,
        }
      : null,
    latest_causal_event: normalizeKeeperTrustLatestEvent(raw.latest_causal_event),
  }
}

function normalizePromptSegments(
  raw: Record<string, unknown> | null,
  excludedKeys: Set<string>,
): Record<string, { bytes: number; estimated_tokens: number; fingerprint: string | null }> {
  const segments: Record<string, { bytes: number; estimated_tokens: number; fingerprint: string | null }> = {}
  if (!raw) return segments
  for (const [key, value] of Object.entries(raw)) {
    if (excludedKeys.has(key) || !isRecord(value)) continue
    const bytes = asNumber(value.bytes)
    const estimatedTokens = asNumber(value.estimated_tokens)
    const fingerprint = typeof value.fingerprint === 'string' ? value.fingerprint : null
    if (bytes == null && estimatedTokens == null && fingerprint == null) continue
    segments[key] = {
      bytes: bytes ?? 0,
      estimated_tokens: estimatedTokens ?? 0,
      fingerprint,
    }
  }
  return segments
}

function normalizeMetricsSeries(raw: unknown): KeeperMetricPoint[] {
  if (!Array.isArray(raw)) return []
  return raw
    .map((item): KeeperMetricPoint | null => {
      if (!isRecord(item)) return null
      const ts = asNumber(item.ts_unix)
      const contextRatio = asNumber(item.context_ratio)
      if (ts == null || contextRatio == null) return null
      const handoffObj = isRecord(item.handoff) ? item.handoff : null
      const handoffPerformed =
        handoffObj != null
          ? (item.handoff_performed === true || handoffObj.performed === true)
          : item.handoff === true || item.handoff_performed === true
      const handoffNewGeneration =
        handoffObj
          ? (asNumber(handoffObj.new_generation) ?? asNumber(handoffObj.to_generation) ?? null)
          : (asNumber(item.handoff_new_generation) ?? null)
      const handoffToModel = null
      const rawPrompt = isRecord(item.prompt) ? item.prompt : null
      const rawUsage = isRecord(item.usage) ? item.usage : null
      const promptSegments: NonNullable<PromptTelemetry['segments']> =
        normalizePromptSegments(rawPrompt, new Set(['fingerprint', 'estimated_total_tokens', 'estimated_cacheable_tokens']))
      const promptFingerprint =
        (typeof item.prompt_fingerprint === 'string' ? item.prompt_fingerprint : null)
        ?? (rawPrompt && typeof rawPrompt.fingerprint === 'string' ? rawPrompt.fingerprint : null)
      const prompt_metrics =
        promptFingerprint != null || rawPrompt != null || Object.keys(promptSegments).length > 0
          ? {
              fingerprint: promptFingerprint,
              estimated_total_tokens: rawPrompt ? (asNumber(rawPrompt.estimated_total_tokens) ?? null) : null,
              estimated_cacheable_tokens: rawPrompt ? (asNumber(rawPrompt.estimated_cacheable_tokens) ?? null) : null,
              segments: promptSegments,
            }
          : null
      const rawCtxComposition = isRecord(item.ctx_composition) ? item.ctx_composition : null
      const rawCtxSegments =
        rawCtxComposition && isRecord(rawCtxComposition.segments) ? rawCtxComposition.segments : null
      const ctxSegments =
        normalizePromptSegments(rawCtxSegments, new Set())
      const ctx_composition: CtxCompositionTelemetry | null =
        rawCtxComposition != null || Object.keys(ctxSegments).length > 0
          ? {
              actual_input_tokens: rawCtxComposition ? (asNumber(rawCtxComposition.actual_input_tokens) ?? null) : null,
              display_total_tokens: rawCtxComposition ? (asNumber(rawCtxComposition.display_total_tokens) ?? 0) : 0,
              estimated_known_tokens: rawCtxComposition ? (asNumber(rawCtxComposition.estimated_known_tokens) ?? 0) : 0,
              segments: ctxSegments,
            }
          : null
      const rawTel = isRecord(item.inference_telemetry) ? item.inference_telemetry : null
      const rawTimings = rawTel && isRecord(rawTel.timings) ? rawTel.timings : null
      const latencyMs = asNumber(item.latency_ms) ?? null
      const inputTokens = rawUsage ? (asNumber(rawUsage.input_tokens) ?? null) : null
      const outputTokens = rawUsage ? (asNumber(rawUsage.output_tokens) ?? null) : null
      const totalTokens = rawUsage ? (asNumber(rawUsage.total_tokens) ?? null) : null
      const wallTokensPerSecond =
        outputTokens != null && latencyMs != null && latencyMs > 0
          ? outputTokens / (latencyMs / 1000)
          : null
      const inference_telemetry = rawTel ? {
        system_fingerprint: typeof rawTel.system_fingerprint === 'string' ? rawTel.system_fingerprint : null,
        timings: rawTimings ? {
          prompt_n: asNumber(rawTimings.prompt_n) ?? null,
          prompt_ms: asNumber(rawTimings.prompt_ms) ?? null,
          prompt_per_second: asNumber(rawTimings.prompt_per_second) ?? null,
          predicted_n: asNumber(rawTimings.predicted_n) ?? null,
          predicted_ms: asNumber(rawTimings.predicted_ms) ?? null,
          predicted_per_second: asNumber(rawTimings.predicted_per_second) ?? null,
          cache_n: asNumber(rawTimings.cache_n) ?? null,
        } : null,
        reasoning_tokens: asNumber(rawTel.reasoning_tokens) ?? null,
        peak_memory_gb: asNumber(rawTel.peak_memory_gb) ?? null,
        request_latency_ms: asNumber(rawTel.request_latency_ms) ?? null,
        ttfrc_ms: asNumber(rawTel.ttfrc_ms) ?? null,
        prefill_ms: asNumber(rawTel.prefill_ms) ?? null,
      } : null
      const runtimeObj = isRecord(item.runtime) ? item.runtime : null
      const fallbackEvents = runtimeObj && Array.isArray(runtimeObj.fallback_events) ? runtimeObj.fallback_events : []
      const firstFallback = fallbackEvents.length > 0 && isRecord(fallbackEvents[0]) ? fallbackEvents[0] : null
      return {
        ts,
        context_ratio: contextRatio,
        context_tokens: asNumber(item.context_tokens) ?? 0,
        context_max: asNumber(item.context_max) ?? 0,
        latency_ms: latencyMs,
        generation: asNumber(item.generation) ?? 0,
        channel: typeof item.channel === 'string' ? item.channel : 'turn',
        is_handoff: handoffPerformed,
        is_compaction: item.compacted === true,
        compaction_saved_tokens: asNumber(item.compaction_saved_tokens) ?? 0,
        compaction_trigger: typeof item.compaction_trigger === 'string' ? item.compaction_trigger : null,
        model_used: '',
        cost_usd: asNumber(item.cost_usd) ?? Number.NaN,
        handoff_to_model: handoffToModel,
        handoff_new_generation: handoffNewGeneration,
        prompt_fingerprint: promptFingerprint,
        prompt_metrics,
        ctx_composition,
        input_tokens: inputTokens,
        output_tokens: outputTokens,
        total_tokens: totalTokens,
        wall_tokens_per_second: wallTokensPerSecond,
        inference_telemetry,
        runtime_id: runtimeObj ? (asString(runtimeObj.runtime_id) ?? asString(runtimeObj.name) ?? null) : null,
        runtime_outcome: runtimeObj ? (asString(runtimeObj.outcome) ?? null) : null,
        runtime_selected_model: null,
        runtime_attempt_count: runtimeObj ? (asNumber(runtimeObj.attempt_count) ?? null) : null,
        runtime_strategy: runtimeObj && typeof runtimeObj.strategy === 'string' ? runtimeObj.strategy : null,
        fallback_applied: runtimeObj ? runtimeObj.fallback_applied === true : false,
        fallback_hops: runtimeObj ? (asNumber(runtimeObj.fallback_hops) ?? 0) : 0,
        fallback_from: null,
        fallback_to: null,
        fallback_reason: firstFallback && typeof firstFallback.reason === 'string' ? firstFallback.reason : null,
      }
    })
    .filter((item): item is KeeperMetricPoint => item !== null)
}

// Top-N list keys that contain arrays of { tool/kind/model/..., count } objects
const TOP_LIST_KEYS = new Set([
  'top_tools', 'top_work_kinds', 'top_models', 'top_memory_kinds',
  'top_drift_reasons', 'top_compaction_triggers', 'generation_equipment',
])

function normalizeMetricsWindow(raw: unknown): Keeper['metrics_window'] | undefined {
  if (!isRecord(raw)) return undefined

  const normalized: Keeper['metrics_window'] = {}
  for (const [key, value] of Object.entries(raw)) {
    // Top-N lists: array of objects with at least one meaningful value
    if (TOP_LIST_KEYS.has(key)) {
      if (!Array.isArray(value)) continue
      const items = value.filter(item => {
        if (!isRecord(item)) return false
        return Object.values(item).some(v =>
          (typeof v === 'string' && v.trim() !== '') || typeof v === 'number',
        )
      })
      if (items.length > 0) normalized[key] = items
      continue
    }

    // Numbers (majority of fields)
    const numberValue = asNumber(value)
    if (numberValue != null) {
      normalized[key] = numberValue
      continue
    }

    // Booleans
    if (typeof value === 'boolean') {
      normalized[key] = value
      continue
    }

    // Strings
    if (typeof value === 'string' && value.trim() !== '') {
      normalized[key] = value
    }
  }

  return Object.keys(normalized).length > 0 ? normalized : undefined
}

export function normalizeKeepers(raw: unknown): Keeper[] {
  const rows =
    Array.isArray(raw)
      ? raw
      : isRecord(raw) && Array.isArray(raw.keepers)
        ? raw.keepers
        : []

  return rows
    .map((row): Keeper | null => {
      if (!isRecord(row)) return null
      const agentRaw = isRecord(row.agent) ? row.agent : null
      const contextRaw = isRecord(row.context) ? row.context : null
      const metricsWindow = normalizeMetricsWindow(row.metrics_window)

      const name = asString(row.name)
      if (!name) return null

      const contextRatio = asNumber(row.context_ratio) ?? asNumber(contextRaw?.context_ratio)
      const statusRaw = asString(row.status) ?? asString(agentRaw?.status) ?? 'offline'
      const model = undefined
      const metricsSeries = normalizeMetricsSeries(row.metrics_series)

      const normalizedContext =
        contextRaw
          ? {
              source: asString(contextRaw.source),
              context_ratio: asNumber(contextRaw.context_ratio),
              context_tokens: asNumber(contextRaw.context_tokens),
              context_max: asNumber(contextRaw.context_max),
              message_count: asNumber(contextRaw.message_count),
              has_checkpoint: typeof contextRaw.has_checkpoint === 'boolean' ? contextRaw.has_checkpoint : undefined,
            }
          : undefined

      const normalizedAgent =
        agentRaw
          ? {
              name: asString(agentRaw.name),
              exists: typeof agentRaw.exists === 'boolean' ? agentRaw.exists : undefined,
              error: asString(agentRaw.error),
              agent_type: asString(agentRaw.agent_type),
              status: asString(agentRaw.status),
              current_task: asString(agentRaw.current_task) ?? null,
              joined_at: asString(agentRaw.joined_at),
              last_seen: asString(agentRaw.last_seen),
              last_seen_ago_s: asNumber(agentRaw.last_seen_ago_s),
              capabilities: asStringArray(agentRaw.capabilities),
              is_zombie: typeof agentRaw.is_zombie === 'boolean' ? agentRaw.is_zombie : undefined,
            }
          : undefined

      const providerHealth: ProviderHealth | null = null
      const runtimeBlockerClass = asKeeperRuntimeBlockerClass(row.runtime_blocker_class)
      const runtimeBlockerSummary = asString(row.runtime_blocker_summary) ?? null
      const trust = normalizeKeeperTrust(row.runtime_trust ?? row.trust)
      const terminalReason = trust?.latest_terminal_reason ?? null
      const nextHumanAction = asString(row.next_human_action) ?? null
      const stopCause = normalizeStopCause({
        stop_cause: row.stop_cause,
        runtime_blocker_class: runtimeBlockerClass,
        runtime_blocker_summary: runtimeBlockerSummary,
        terminal_reason_code: terminalReason?.code ?? null,
        terminal_reason_summary: terminalReason?.summary ?? null,
        terminal_reason_severity: terminalReason?.severity ?? null,
        terminal_reason_next_action: terminalReason?.next_action ?? null,
        attention_reason: asString(row.attention_reason) ?? trust?.attention_reason ?? null,
        next_action: nextHumanAction ?? trust?.next_human_action ?? trust?.latest_next_action ?? null,
      })

      return {
        name,
        runtime_class: 'keeper' as const,
        // Typed parse replaces an `as PipelineStage` cast that trusted
        // whatever string `row.pipeline_stage` carried (it's `string | null`
        // upstream — see api/dashboard.ts:265). Unrecognized values fall
        // back to `'unknown'` (a valid PipelineStage tag) so consumers
        // can render the keeper as "stage not known yet" rather than
        // routing an arbitrary backend string through a lying type.
        pipeline_stage: toPipelineStage(asString(row.pipeline_stage)) ?? 'unknown',
        pipeline_stage_detail: asString(row.pipeline_stage_detail) ?? null,
        lifecycle_phase:
          toKeeperPhase(asString(row.lifecycle_phase))
          ?? toKeeperPhase(asString(row.phase)),
        phase: toKeeperPhase(asString(row.phase)),
        paused: asBoolean(row.paused),
        registered:
          typeof row.registered === 'boolean' ? row.registered : undefined,
        reconcile_status: asString(row.reconcile_status) ?? null,
        emoji: asString(row.emoji),
        koreanName: asString(row.koreanName) ?? asString(row.korean_name),
        keeper_id: asString(row.keeper_id) ?? null,
        agent_name: asString(row.agent_name),
        trace_id: asString(row.trace_id),
        model,
        primary_model: undefined,
        active_model: undefined,
        active_model_label: null,
        last_model_used: undefined,
        last_model_used_label: null,
        next_model_hint: null,
        runtime_id: asString(row.runtime_id) ?? null,
        runtime_ref: normalizeRuntimeRef(row.runtime_ref),
        runtime_canonical: asString(row.runtime_canonical) ?? asString(row.selected_runtime_canonical) ?? null,
        selected_runtime_canonical: asString(row.selected_runtime_canonical) ?? null,
        status: normalizeKeeperAgentStatus(statusRaw),
        keepalive_running:
          typeof row.keepalive_running === 'boolean' ? row.keepalive_running : undefined,
        proactive_enabled:
          typeof row.proactive_enabled === 'boolean' ? row.proactive_enabled : undefined,
        pause_state: asKeeperPauseState(row.pause_state),
        runtime_blocker_state: asKeeperRuntimeBlockerState(row.runtime_blocker_state),
        runtime_blocker_class: runtimeBlockerClass,
        runtime_blocker_summary: runtimeBlockerSummary,
        stop_cause: stopCause,
        needs_attention:
          typeof row.needs_attention === 'boolean' ? row.needs_attention : null,
        attention_reason: asString(row.attention_reason) ?? null,
        next_human_action: nextHumanAction,
        config_error: normalizeKeeperProfileConfigError(row.config_error),
        trust,
        active_goal_ids: asStringArray(row.active_goal_ids) ?? [],
        goal: asString(row.goal) ?? null,
        sandbox_profile: normalizeKeeperSandboxProfile(row.sandbox_profile),
        sandbox_target: asString(row.sandbox_target) ?? null,
        sandbox_last_error: asString(row.sandbox_last_error) ?? null,
        blocked_task_count: asNumber(row.blocked_task_count) ?? null,
        goal_progress: isRecord(row.goal_progress)
          ? {
              active_goal_count: asNumber(row.goal_progress.active_goal_count) ?? undefined,
              linked_task_count: asNumber(row.goal_progress.linked_task_count) ?? undefined,
              done_task_count: asNumber(row.goal_progress.done_task_count) ?? undefined,
              open_task_count: asNumber(row.goal_progress.open_task_count) ?? undefined,
              blocked_task_count: asNumber(row.goal_progress.blocked_task_count) ?? undefined,
              convergence: asNumber(row.goal_progress.convergence) ?? null,
            }
          : null,
        created_at: toIsoTimestamp(row.created_at) ?? asString(row.created_at),
        updated_at: toIsoTimestamp(row.updated_at) ?? asString(row.updated_at),
        last_heartbeat: asString(row.last_heartbeat) ?? asString(agentRaw?.last_seen),
        last_autonomous_action_at: toIsoTimestamp(row.last_autonomous_action_at) ?? asString(row.last_autonomous_action_at) ?? null,
        generation: asNumber(row.generation),
        turn_count: asNumber(row.turn_count) ?? asNumber(row.total_turns),
        total_turns: asNumber(row.total_turns) ?? asNumber(row.turn_count),
        total_tokens: asNumber(row.total_tokens),
        last_latency_ms: asNumber(row.last_latency_ms),
        autonomous_action_count: asNumber(row.autonomous_action_count),
        autonomous_turn_count: asNumber(row.autonomous_turn_count),
        autonomous_text_turn_count: asNumber(row.autonomous_text_turn_count),
        autonomous_tool_turn_count: asNumber(row.autonomous_tool_turn_count),
        board_reactive_turn_count: asNumber(row.board_reactive_turn_count),
        mention_reactive_turn_count: asNumber(row.mention_reactive_turn_count),
        noop_turn_count: asNumber(row.noop_turn_count),
        keeper_age_s: asNumber(row.keeper_age_s),
        last_turn_ago_s: asNumber(row.last_turn_ago_s),
        last_handoff_ago_s: asNumber(row.last_handoff_ago_s),
        last_compaction_ago_s: asNumber(row.last_compaction_ago_s),
        last_proactive_ago_s: asNumber(row.last_proactive_ago_s),
        last_proactive_reason: asString(row.last_proactive_reason) ?? null,
        last_activity_ago_s: asNumber(row.last_activity_ago_s),
        last_activity_at: toIsoTimestamp(row.last_activity_at) ?? asString(row.last_activity_at) ?? null,
        last_activity_source: normalizeKeeperLiveActivitySource(row.last_activity_source),
        live_activity: normalizeKeeperLiveActivity(row.live_activity),
        current_gate: normalizeKeeperCurrentGate(row.current_gate),
        last_proactive_preview: asString(row.last_proactive_preview) ?? null,
        last_blocker: asString(row.last_blocker) ?? null,
        runtime_warning_ctx_ratio: asNumber(row.runtime_warning_ctx_ratio) ?? null,
        context_ratio: contextRatio,
        context_tokens: asNumber(row.context_tokens) ?? asNumber(contextRaw?.context_tokens),
        context_max: asNumber(row.context_max) ?? asNumber(contextRaw?.context_max),
        context_source: asString(row.context_source) ?? asString(contextRaw?.source),
        context: normalizedContext,
        compaction_profile: asString(row.compaction_profile) ?? null,
        compaction_ratio_gate: asNumber(row.compaction_ratio_gate) ?? null,
        compaction_message_gate: asNumber(row.compaction_message_gate) ?? null,
        compaction_token_gate: asNumber(row.compaction_token_gate) ?? null,
        traits: asStringArray(row.traits),
        interests: asStringArray(row.interests),
        primaryValue: asString(row.primaryValue) ?? asString(row.primary_value),
        activityLevel: asNumber(row.activityLevel) ?? asNumber(row.activity_level),
        memory_recent_note: asString(row.memory_recent_note) ?? null,
        recent_input_preview: asString(row.recent_input_preview) ?? null,
        recent_output_preview: asString(row.recent_output_preview) ?? null,
        recent_tool_names: asStringArray(row.recent_tool_names) ?? [],
        latest_tool_names: asStringArray(row.latest_tool_names) ?? [],
        latest_tool_call_count: asNumber(row.latest_tool_call_count) ?? null,
        tool_audit_source: asString(row.tool_audit_source) ?? null,
        tool_audit_at: toIsoTimestamp(row.tool_audit_at) ?? asString(row.tool_audit_at) ?? null,
        diagnostic: normalizeKeeperDiagnostic(row.diagnostic),
        conversation_tail_count: asNumber(row.conversation_tail_count),
        k2k_count: asNumber(row.k2k_count),
        handoff_count_total: asNumber(row.handoff_count_total) ?? asNumber(row.trace_history_count),
        compaction_count: asNumber(row.compaction_count),
        last_compaction_saved_tokens: asNumber(row.last_compaction_saved_tokens),
        metrics_series: metricsSeries.length > 0 ? metricsSeries : undefined,
        metrics_window: metricsWindow,
        agent: normalizedAgent,
        provider_health: providerHealth,
      }
    })
    .filter((row): row is Keeper => row !== null)
}
