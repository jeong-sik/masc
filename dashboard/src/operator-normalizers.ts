import { isRecord, asString, asNumber, asBoolean, asStringArray, extractArray } from './components/common/normalize'
import {
  normalizeOperatorActionDescriptor,
  normalizePendingConfirmation,
  normalizePendingConfirmEnvelope,
  normalizePendingConfirmSummary,
} from './pending-confirm'
import { normalizeKeeperTrust } from './keeper-store-normalize'
import {
  normalizeAttentionItem,
  normalizeRecommendedAction,
} from './store-normalizers'
import type {
  AdmissionQueueSnapshot,
  Message,
  OperatorActionDescriptor,
  OperatorAttentionItem,
  OperatorDigest,
  OperatorGuidanceSummary,
  OperatorJudgment,
  OperatorKeeperSnapshot,
  OperatorReviewDecision,
  OperatorRecommendedAction,
  OperatorJudgeRuntime,
  OperatorSessionSnapshot,
  OperatorSnapshot,
  OperatorNamespaceSnapshot,
  PendingConfirmation,
} from './types'
import { SYSTEM_ACTOR_NAME } from './types/core'

function normalizeMessage(raw: unknown): Message | null {
  if (!isRecord(raw)) return null
  return {
    id: asString(raw.id),
    seq: asNumber(raw.seq),
    from: asString(raw.from) ?? asString(raw.from_agent) ?? SYSTEM_ACTOR_NAME,
    content: asString(raw.content) ?? '',
    timestamp: asString(raw.timestamp) ?? new Date().toISOString(),
    type: asString(raw.type),
  }
}

function normalizeNamespace(raw: unknown): OperatorNamespaceSnapshot {
  if (!isRecord(raw)) return {}
  return {
    project: asString(raw.project),
    cluster: asString(raw.cluster),
    paused: asBoolean(raw.paused),
    pause_reason: asString(raw.pause_reason) ?? null,
    paused_by: asString(raw.paused_by) ?? null,
    paused_at: asString(raw.paused_at) ?? null,
  }
}

function normalizeStringRecord(raw: unknown): Record<string, string> | undefined {
  if (!isRecord(raw)) return undefined
  const entries = Object.entries(raw)
    .map(([key, value]) => {
      const text = asString(value)
      return text ? [key, text] : null
    })
    .filter((entry): entry is [string, string] => entry !== null)
  return entries.length > 0 ? Object.fromEntries(entries) : undefined
}

function normalizeOperatorJudgeRuntime(raw: unknown): OperatorJudgeRuntime | null {
  if (!isRecord(raw)) return null
  return {
    enabled: asBoolean(raw.enabled),
    judge_online: asBoolean(raw.judge_online),
    refreshing: asBoolean(raw.refreshing),
    generated_at: asString(raw.generated_at) ?? null,
    expires_at: asString(raw.expires_at) ?? null,
    model_used: null,
    keeper_name: asString(raw.keeper_name) ?? null,
    last_error: asString(raw.last_error) ?? null,
  }
}

interface AdmissionQueueNormalization {
  value: AdmissionQueueSnapshot | null
  error: string | null
}

function normalizeAdmissionQueue(raw: unknown): AdmissionQueueNormalization {
  if (raw === undefined || raw === null) return { value: null, error: null }
  if (!isRecord(raw)) return { value: null, error: 'Admission projection has an invalid shape.' }
  const throttleOwner = asString(raw.throttle_owner)
  const maxConcurrent = asNumber(raw.max_concurrent)
  const active = asNumber(raw.active)
  const available = asNumber(raw.available)
  const queueDepth = asNumber(raw.queue_depth)
  if (!throttleOwner?.trim()) {
    return { value: null, error: 'Admission projection is missing throttle ownership.' }
  }
  if (
    maxConcurrent === undefined
    || active === undefined
    || available === undefined
    || queueDepth === undefined
    || !Number.isSafeInteger(maxConcurrent)
    || maxConcurrent < 1
    || !Number.isSafeInteger(active)
    || active < 0
    || !Number.isSafeInteger(available)
    || available < 0
    || !Number.isSafeInteger(queueDepth)
    || queueDepth < 0
  ) return { value: null, error: 'Admission projection contains invalid counters.' }
  if (active > maxConcurrent || available > maxConcurrent || active + available !== maxConcurrent) {
    return { value: null, error: 'Admission projection counters are inconsistent.' }
  }
  return {
    value: {
      throttle_owner: throttleOwner.trim(),
      max_concurrent: maxConcurrent,
      active,
      available,
      queue_depth: queueDepth,
    },
    error: null,
  }
}

function normalizeGuidanceSummary(raw: unknown): OperatorGuidanceSummary | null {
  if (!isRecord(raw)) return null
  return {
    summary: asString(raw.summary) ?? null,
    confidence: asNumber(raw.confidence) ?? null,
    provenance: asString(raw.provenance) ?? null,
    authoritative: asBoolean(raw.authoritative),
    surface: asString(raw.surface) ?? null,
    fresh_until: asString(raw.fresh_until) ?? null,
    keeper_name: asString(raw.keeper_name) ?? null,
    fallback_used: asBoolean(raw.fallback_used),
    disagreement_with_truth: asBoolean(raw.disagreement_with_truth),
  }
}

function normalizeOperatorReviewDecisionValue(raw: unknown): OperatorReviewDecision['decision'] | null {
  const decision = asString(raw)?.trim().toLowerCase()
  return decision === 'resolved' || decision === 'deferred' ? decision : null
}

function normalizeOperatorDigestTargetType(raw: unknown): OperatorDigest['target_type'] {
  const targetType = asString(raw)?.trim().toLowerCase()
  switch (targetType) {
    case 'root':
    case 'namespace':
    case 'workspace':
    case 'keeper':
      return targetType
    default:
      return 'root'
  }
}

function normalizeReviewDecision(raw: unknown): OperatorReviewDecision | null {
  if (!isRecord(raw)) return null
  const itemId = asString(raw.item_id)
  const fingerprint = asString(raw.fingerprint)
  const decision = normalizeOperatorReviewDecisionValue(raw.decision)
  const actor = asString(raw.actor)
  const reason = asString(raw.reason)
  const at = asString(raw.at)
  const targetType = asString(raw.target_type)
  if (!itemId || !fingerprint || !decision || !actor || !reason || !at || !targetType) return null
  return {
    item_id: itemId,
    fingerprint,
    decision,
    actor,
    reason,
    at,
    target_type: targetType,
    target_id: asString(raw.target_id) ?? null,
    recommended_action_type: asString(raw.recommended_action_type) ?? null,
  }
}

function normalizeOperatorJudgment(raw: unknown): OperatorJudgment | null {
  if (!isRecord(raw)) return null
  return {
    judgment_id: asString(raw.judgment_id) ?? undefined,
    surface: asString(raw.surface) ?? null,
    target_type: asString(raw.target_type) ?? null,
    target_id: asString(raw.target_id) ?? null,
    status: asString(raw.status) ?? null,
    summary: asString(raw.summary) ?? null,
    confidence: asNumber(raw.confidence) ?? null,
    generated_at: asString(raw.generated_at) ?? null,
    fresh_until: asString(raw.fresh_until) ?? null,
    keeper_name: asString(raw.keeper_name) ?? null,
    model_name: null,
    runtime_name: asString(raw.runtime_name) ? 'runtime' : null,
    evidence_refs: asStringArray(raw.evidence_refs),
    recommended_action: normalizeRecommendedAction(raw.recommended_action),
    supersedes: asStringArray(raw.supersedes),
    fallback_used: asBoolean(raw.fallback_used),
    disagreement_with_truth: asBoolean(raw.disagreement_with_truth),
    provenance: asString(raw.provenance) ?? null,
  }
}

export function normalizeOperatorDigest(raw: unknown): OperatorDigest {
  const root = isRecord(raw) ? raw : {}
  return {
    trace_id: asString(root.trace_id),
    target_type: normalizeOperatorDigestTargetType(root.target_type),
    target_id: asString(root.target_id) ?? null,
    health: asString(root.health),
    judgment_owner: asString(root.judgment_owner) ?? null,
    authoritative_judgment_available: asBoolean(root.authoritative_judgment_available),
    operator_judge_runtime: normalizeOperatorJudgeRuntime(root.operator_judge_runtime),
    judgment: normalizeOperatorJudgment(root.judgment),
    active_guidance_layer: asString(root.active_guidance_layer) ?? null,
    active_summary: normalizeGuidanceSummary(root.active_summary),
    active_recommended_actions: extractArray(root.active_recommended_actions)
      .map(normalizeRecommendedAction)
      .filter((item): item is OperatorRecommendedAction => item !== null),
    active_recommendation_source: asString(root.active_recommendation_source) ?? null,
    active_recommendation_summary: normalizeGuidanceSummary(root.active_recommendation_summary),
    fallback_recommended_actions: extractArray(root.fallback_recommended_actions)
      .map(normalizeRecommendedAction)
      .filter((item): item is OperatorRecommendedAction => item !== null),
    recommendation_summary: normalizeGuidanceSummary(root.recommendation_summary),
    root: normalizeNamespace(root.root),
    attention_items: extractArray(root.attention_items)
      .map(normalizeAttentionItem)
      .filter((item): item is OperatorAttentionItem => item !== null),
    recommended_actions: extractArray(root.recommended_actions)
      .map(normalizeRecommendedAction)
      .filter((item): item is OperatorRecommendedAction => item !== null),
    recent_reviews: extractArray(root.recent_reviews)
      .map(normalizeReviewDecision)
      .filter((item): item is OperatorReviewDecision => item !== null),
  }
}

function normalizeSession(raw: unknown): OperatorSessionSnapshot | null {
  if (!isRecord(raw)) return null
  const statusBlock = isRecord(raw.status) ? raw.status : undefined
  const summary = isRecord(raw.summary) ? raw.summary : isRecord(statusBlock?.summary) ? statusBlock.summary : undefined
  const session = isRecord(raw.session) ? raw.session : isRecord(statusBlock?.session) ? statusBlock.session : undefined
  const sessionId =
    asString(raw.session_id)
    ?? asString(summary?.session_id)
    ?? asString(session?.session_id)
  if (!sessionId) return null

  const reportPaths = normalizeStringRecord(raw.report_paths)
    ?? normalizeStringRecord(statusBlock?.report_paths)
  const recentEvents = extractArray(raw.recent_events, ['events'])
    .filter(isRecord)

  return {
    session_id: sessionId,
    status: asString(raw.status) ?? asString(summary?.status) ?? asString(session?.status),
    progress_pct: asNumber(raw.progress_pct) ?? asNumber(summary?.progress_pct),
    elapsed_sec: asNumber(raw.elapsed_sec) ?? asNumber(summary?.elapsed_sec),
    remaining_sec: asNumber(raw.remaining_sec) ?? asNumber(summary?.remaining_sec),
    done_delta_total: asNumber(raw.done_delta_total) ?? asNumber(summary?.done_delta_total),
    summary,
    team_health: isRecord(raw.team_health) ? raw.team_health : isRecord(statusBlock?.team_health) ? statusBlock.team_health : undefined,
    communication_metrics: isRecord(raw.communication_metrics) ? raw.communication_metrics : isRecord(statusBlock?.communication_metrics) ? statusBlock.communication_metrics : undefined,
    orchestration_state: isRecord(raw.orchestration_state) ? raw.orchestration_state : isRecord(statusBlock?.orchestration_state) ? statusBlock.orchestration_state : undefined,
    runtime_metrics: isRecord(raw.runtime_metrics) ? raw.runtime_metrics : isRecord(statusBlock?.runtime_metrics) ? statusBlock.runtime_metrics : undefined,
    report_paths: reportPaths,
    session,
    recent_events: recentEvents,
  }
}

function normalizeKeeper(raw: unknown): OperatorKeeperSnapshot | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  if (!name) return null
  const contextRaw = isRecord(raw.context) ? raw.context : undefined
  const hasModelLabel = Boolean(asString(raw.model) ?? asString(raw.active_model) ?? asString(raw.primary_model))
  return {
    name,
    runtime_class: 'keeper' as const,
    phase: asString(raw.phase) ?? null,
    pipeline_stage: asString(raw.pipeline_stage) ?? null,
    paused: asBoolean(raw.paused) ?? null,
    registered: asBoolean(raw.registered),
    agent_name: asString(raw.agent_name),
    status: asString(raw.status),
    context_ratio: asNumber(raw.context_ratio) ?? asNumber(contextRaw?.context_ratio),
    context_tokens: asNumber(raw.context_tokens) ?? asNumber(contextRaw?.context_tokens),
    context_max: asNumber(raw.context_max) ?? asNumber(contextRaw?.context_max),
    context_source: asString(raw.context_source) ?? asString(contextRaw?.source),
    generation: asNumber(raw.generation),
    active_goal_ids: asStringArray(raw.active_goal_ids),
    last_autonomous_action_at: asString(raw.last_autonomous_action_at) ?? null,
    last_turn_ago_s: asNumber(raw.last_turn_ago_s),
    model: hasModelLabel ? 'runtime' : undefined,
    needs_attention: typeof raw.needs_attention === 'boolean' ? raw.needs_attention : null,
    attention_reason: asString(raw.attention_reason) ?? null,
    next_human_action: asString(raw.next_human_action) ?? null,
    runtime_trust: normalizeKeeperTrust(raw.runtime_trust ?? raw.trust),
  }
}

export function normalizeOperatorSnapshot(raw: unknown): OperatorSnapshot {
  const root = isRecord(raw) ? raw : {}
  const pendingConfirmEnvelope = normalizePendingConfirmEnvelope(root.pending_confirm_envelope)
  const admissionQueue = normalizeAdmissionQueue(root.admission_queue)
  return {
    root: normalizeNamespace(root.root),
    sessions: extractArray(root.sessions, ['items', 'sessions'])
      .map(normalizeSession)
      .filter((item): item is OperatorSessionSnapshot => item !== null),
    keepers: extractArray(root.keepers, ['items', 'keepers'])
      .map(normalizeKeeper)
      .filter((item): item is OperatorKeeperSnapshot => item !== null),
    admission_queue: admissionQueue.value,
    admission_queue_error: admissionQueue.error,
    operator_judge_runtime: normalizeOperatorJudgeRuntime(root.operator_judge_runtime),
    persistent_agents: extractArray(root.persistent_agents, ['items', 'persistent_agents'])
      .map(normalizeKeeper)
      .filter((item): item is OperatorKeeperSnapshot => item !== null),
    recent_messages: extractArray(root.recent_messages, ['messages'])
      .map(normalizeMessage)
      .filter((item): item is Message => item !== null),
    pending_confirms: pendingConfirmEnvelope?.items
      ?? extractArray(root.pending_confirms, ['items', 'confirms'])
        .map(normalizePendingConfirmation)
        .filter((item): item is PendingConfirmation => item !== null),
    pending_confirm_envelope: pendingConfirmEnvelope ?? undefined,
    pending_confirm_summary:
      pendingConfirmEnvelope?.summary
      ?? normalizePendingConfirmSummary(root.pending_confirm_summary)
      ?? undefined,
    available_actions: extractArray(root.available_actions, ['actions'])
      .map(normalizeOperatorActionDescriptor)
      .filter((item): item is OperatorActionDescriptor => item !== null),
  }
}
