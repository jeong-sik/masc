import { isRecord, asString, asNumber, asBoolean, asStringArray, extractArray } from './components/common/normalize'
import {
  normalizeOperatorActionDescriptor,
  normalizePendingConfirmation,
  normalizePendingConfirmEnvelope,
  normalizePendingConfirmSummary,
} from './pending-confirm'
import {
  normalizeKeeperContextMetricsUnavailable,
  normalizeKeeperLastTurnUsage,
  normalizeKeeperTrust,
} from './keeper-store-normalize'
import {
  normalizeAttentionItem,
  normalizeRecommendedAction,
} from './store-normalizers'
import type {
  InferenceInflightSnapshot,
  Message,
  OperatorActionDescriptor,
  OperatorAttentionItem,
  OperatorDigest,
  OperatorGuidanceSummary,
  OperatorJudgment,
  OperatorKeeperSnapshot,
  OperatorReviewDecision,
  OperatorRecommendedAction,
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

function normalizeInferenceInflight(raw: unknown): InferenceInflightSnapshot | null {
  if (!isRecord(raw) || raw.boundary_owner !== 'oas_runtime') return null
  const active = asNumber(raw.active)
  if (active === undefined || !Number.isSafeInteger(active) || active < 0) return null
  return { boundary_owner: 'oas_runtime', active }
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

function normalizeKeeper(raw: unknown): OperatorKeeperSnapshot | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  if (!name) return null
  const hasModelLabel = Boolean(asString(raw.model) ?? asString(raw.active_model) ?? asString(raw.primary_model))
  // Context fields are accepted only from the TurnRecord projection (the
  // measurement SSOT); a retired or unknown source drops entirely — absence
  // is explained by the typed context_metrics_unavailable channel.
  const contextSource = asString(raw.context_source) ?? null
  const contextMeasured = contextSource === 'turn_record'
  return {
    name,
    runtime_class: 'keeper' as const,
    phase: asString(raw.phase) ?? null,
    pipeline_stage: asString(raw.pipeline_stage) ?? null,
    paused: asBoolean(raw.paused) ?? null,
    registered: asBoolean(raw.registered),
    agent_name: asString(raw.agent_name),
    status: asString(raw.status),
    context_ratio: contextMeasured ? asNumber(raw.context_ratio) ?? null : null,
    context_tokens: contextMeasured ? asNumber(raw.context_tokens) ?? null : null,
    context_max: contextMeasured ? asNumber(raw.context_max) ?? null : null,
    context_source: contextMeasured ? contextSource : null,
    context_metrics_unavailable: normalizeKeeperContextMetricsUnavailable(raw.context_metrics_unavailable),
    last_turn_usage: normalizeKeeperLastTurnUsage(raw.last_turn_usage),
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
  return {
    root: normalizeNamespace(root.root),
    keepers: extractArray(root.keepers, ['items', 'keepers'])
      .map(normalizeKeeper)
      .filter((item): item is OperatorKeeperSnapshot => item !== null),
    inference_inflight: normalizeInferenceInflight(root.inference_inflight),
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
