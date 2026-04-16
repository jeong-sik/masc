import type {
  CtxCompositionTelemetry,
  Keeper,
  KeeperLifecycleState,
  KeeperMetricPoint,
  KeeperPhase,
  PipelineStage,
  PromptTelemetry,
} from './types'
import { isRecord, asString, asNumber, asBoolean, asStringArray, toIsoTimestamp } from './components/common/normalize'
import { isOfflineStatus } from './lib/status-utils'
import { keeperDisplayStatus } from './lib/keeper-runtime-display'
import { CONTEXT_RATIO_CRITICAL, CONTEXT_RATIO_WARN, CONTEXT_RATIO_COMPACTING } from './config/constants'

/** Maps lowercase backend phase strings to PascalCase KeeperPhase values.
 *  Backend (keeper_state_machine.ml) emits lowercase: "offline", "running", "handing_off", etc.
 *  Frontend KeeperPhase type uses PascalCase: "Offline", "Running", "HandingOff", etc.
 */
const BACKEND_PHASE_MAP: Record<string, KeeperPhase> = {
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
  // Also accept PascalCase for forward-compat / test fixtures
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
}

export function toKeeperPhase(raw: string | null | undefined): KeeperPhase | null {
  if (!raw) return null
  return BACKEND_PHASE_MAP[raw] ?? null
}

function normalizeKeeperAgentStatus(value: unknown): Keeper['status'] {
  const raw = typeof value === 'string' ? value.toLowerCase() : ''
  if (
    raw === 'active'
    || raw === 'busy'
    || raw === 'listening'
    || raw === 'idle'
    || raw === 'inactive'
    || raw === 'offline'
    || raw === 'unbooted'
    || raw === 'stopped'
  ) {
    return raw
  }
  if (raw === 'in_progress' || raw === 'claimed') return 'busy'
  if (raw === 'dead' || raw === 'left') return 'offline'
  return 'offline'
}

export function deriveLifecycleState(keeper: Keeper): KeeperLifecycleState {
  const status = keeper.status?.toLowerCase() ?? ''
  if (isOfflineStatus(status)) return keeperDisplayStatus(keeper) as KeeperLifecycleState

  const series = keeper.metrics_series
  if (!series || series.length === 0) {
    return 'idle'
  }
  const latest = series[series.length - 1]
  if (!latest) return 'idle'
  if (latest.is_handoff) return 'handoff-imminent'
  if (latest.is_compaction) return 'compacting'
  const ratio = latest.context_ratio
  if (ratio > CONTEXT_RATIO_CRITICAL) return 'handoff-imminent'
  if (ratio > CONTEXT_RATIO_WARN) return 'preparing'
  if (ratio > CONTEXT_RATIO_COMPACTING) return 'compacting'
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

function normalizeTurnBudget(raw: unknown): Keeper['turn_budget'] {
  if (!isRecord(raw)) return null
  const readSlot = (v: unknown) => {
    if (!isRecord(v)) return null
    const value = asNumber(v.value)
    if (value == null) return null
    let source: 'override' | 'env' | 'override_invalid' = 'env'
    if (v.source === 'override') source = 'override'
    else if (v.source === 'override_invalid') source = 'override_invalid'
    const envDefault = asNumber(v.env_default) ?? value
    const envVar = asString(v.env_var) ?? ''
    const rawOverride = asNumber(v.raw_override)
    return {
      value,
      source,
      env_default: envDefault,
      env_var: envVar,
      raw_override: rawOverride ?? null,
    }
  }
  const reactive = readSlot(raw.reactive)
  const scheduled = readSlot(raw.scheduled_autonomous)
  if (!reactive || !scheduled) return null
  return {
    reactive,
    scheduled_autonomous: scheduled,
    manifest_path: asString(raw.manifest_path) ?? null,
    clamp_min: asNumber(raw.clamp_min) ?? 1,
    clamp_max: asNumber(raw.clamp_max) ?? 50,
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
      const handoffToModel =
        handoffObj
          ? (typeof handoffObj.to_model === 'string' ? handoffObj.to_model : null)
          : (typeof item.handoff_to_model === 'string' ? item.handoff_to_model : null)
      const rawPrompt = isRecord(item.prompt) ? item.prompt : null
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
        request_latency_ms: asNumber(rawTel.request_latency_ms) ?? 0,
      } : null
      const cascadeObj = isRecord(item.cascade) ? item.cascade : null
      const fallbackEvents = cascadeObj && Array.isArray(cascadeObj.fallback_events) ? cascadeObj.fallback_events : []
      const firstFallback = fallbackEvents.length > 0 && isRecord(fallbackEvents[0]) ? fallbackEvents[0] : null
      return {
        ts,
        context_ratio: contextRatio,
        context_tokens: asNumber(item.context_tokens) ?? 0,
        context_max: asNumber(item.context_max) ?? 0,
        latency_ms: asNumber(item.latency_ms) ?? 0,
        generation: asNumber(item.generation) ?? 0,
        channel: typeof item.channel === 'string' ? item.channel : 'turn',
        is_handoff: handoffPerformed,
        is_compaction: item.compacted === true,
        compaction_saved_tokens: asNumber(item.compaction_saved_tokens) ?? 0,
        compaction_trigger: typeof item.compaction_trigger === 'string' ? item.compaction_trigger : null,
        model_used: typeof item.model_used === 'string' ? item.model_used : '',
        cost_usd: asNumber(item.cost_usd) ?? Number.NaN,
        handoff_to_model: handoffToModel,
        handoff_new_generation: handoffNewGeneration,
        prompt_fingerprint: promptFingerprint,
        prompt_metrics,
        ctx_composition,
        inference_telemetry,
        fallback_applied: cascadeObj ? cascadeObj.fallback_applied === true : false,
        fallback_hops: cascadeObj ? (asNumber(cascadeObj.fallback_hops) ?? 0) : 0,
        fallback_from: firstFallback && typeof firstFallback.from_model_id === 'string' ? firstFallback.from_model_id : null,
        fallback_to: firstFallback && typeof firstFallback.to_model_id === 'string' ? firstFallback.to_model_id : null,
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

    // Booleans (e.g. proactive_preview_similarity_warn)
    if (typeof value === 'boolean') {
      normalized[key] = value
      continue
    }

    // Strings (e.g. primary_model, proactive_preview_similarity_method)
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
      const model = asString(row.model) ?? asString(row.active_model) ?? asString(row.primary_model)
      const skillSecondary = asStringArray(row.skill_secondary)
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

      return {
        name,
        runtime_class: 'keeper' as const,
        pipeline_stage: (asString(row.pipeline_stage) ?? 'idle') as PipelineStage,
        phase: toKeeperPhase(asString(row.phase)),
        paused: asBoolean(row.paused),
        registered:
          typeof row.registered === 'boolean' ? row.registered : undefined,
        reconcile_status: asString(row.reconcile_status) ?? null,
        emoji: asString(row.emoji),
        koreanName: asString(row.koreanName) ?? asString(row.korean_name),
        agent_name: asString(row.agent_name),
        trace_id: asString(row.trace_id),
        model,
        primary_model: asString(row.primary_model),
        active_model: asString(row.active_model),
        last_model_used: asString(row.last_model_used),
        next_model_hint: asString(row.next_model_hint) ?? null,
        status: normalizeKeeperAgentStatus(statusRaw),
        presence_keepalive:
          typeof row.presence_keepalive === 'boolean' ? row.presence_keepalive : undefined,
        presence_keepalive_sec: asNumber(row.presence_keepalive_sec),
        keepalive_running:
          typeof row.keepalive_running === 'boolean' ? row.keepalive_running : undefined,
        proactive_enabled:
          typeof row.proactive_enabled === 'boolean' ? row.proactive_enabled : undefined,
        proactive_idle_sec: asNumber(row.proactive_idle_sec),
        proactive_cooldown_sec: asNumber(row.proactive_cooldown_sec),
        runtime_blocker_class:
          (asString(row.runtime_blocker_class) as Keeper['runtime_blocker_class']) ?? null,
        runtime_blocker_summary: asString(row.runtime_blocker_summary) ?? null,
        runtime_blocker_continue_gate:
          typeof row.runtime_blocker_continue_gate === 'boolean'
            ? row.runtime_blocker_continue_gate
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
        last_proactive_preview: asString(row.last_proactive_preview) ?? null,
        social_model: asString(row.social_model) ?? null,
        configured_social_model: asString(row.configured_social_model) ?? null,
        social_model_recognized: asBoolean(row.social_model_recognized) ?? null,
        social_model_fallback: asString(row.social_model_fallback) ?? null,
        last_speech_act: asString(row.last_speech_act) ?? null,
        last_blocker: asString(row.last_blocker) ?? null,
        last_need: asString(row.last_need) ?? null,
        context_ratio: contextRatio,
        context_tokens: asNumber(row.context_tokens) ?? asNumber(contextRaw?.context_tokens),
        context_max: asNumber(row.context_max) ?? asNumber(contextRaw?.context_max),
        context_source: asString(row.context_source) ?? asString(contextRaw?.source),
        context: normalizedContext,
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
        turn_budget: normalizeTurnBudget(row.turn_budget),
        conversation_tail_count: asNumber(row.conversation_tail_count),
        k2k_count: asNumber(row.k2k_count),
        handoff_count_total: asNumber(row.handoff_count_total) ?? asNumber(row.trace_history_count),
        compaction_count: asNumber(row.compaction_count),
        last_compaction_saved_tokens: asNumber(row.last_compaction_saved_tokens),
        skill_primary: asString(row.skill_primary) ?? null,
        skill_secondary: skillSecondary,
        skill_reason: asString(row.skill_reason) ?? null,
        metrics_series: metricsSeries.length > 0 ? metricsSeries : undefined,
        metrics_window: metricsWindow,
        agent: normalizedAgent,
      }
    })
    .filter((row): row is Keeper => row !== null)
}
