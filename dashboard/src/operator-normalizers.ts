import { isRecord, asString, asNumber, asBoolean, asStringArray, extractArray } from './components/common/normalize'
import {
  normalizeOperatorActionDescriptor,
  normalizePendingConfirmation,
  normalizePendingConfirmEnvelope,
  normalizePendingConfirmSummary,
} from './pending-confirm'
import type {
  Message,
  OperatorActionDescriptor,
  OperatorAttentionItem,
  OperatorDigest,
  OperatorGuidanceSummary,
  OperatorJudgment,
  OperatorKeeperSnapshot,
  OperatorLinkedAutoresearch,
  OperatorReviewDecision,
  OperatorRecommendedAction,
  OperatorJudgeRuntime,
  OperatorSessionSnapshot,
  OperatorSnapshot,
  OperatorNamespaceSnapshot,
  PendingConfirmation,
} from './types'

function normalizeMessage(raw: unknown): Message | null {
  if (!isRecord(raw)) return null
  return {
    id: asString(raw.id),
    seq: asNumber(raw.seq),
    from: asString(raw.from) ?? asString(raw.from_agent) ?? 'system',
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

function normalizeAttentionItem(raw: unknown): OperatorAttentionItem | null {
  if (!isRecord(raw)) return null
  const kind = asString(raw.kind)
  const summary = asString(raw.summary)
  const targetType = asString(raw.target_type)
  if (!kind || !summary || !targetType) return null
  return {
    kind,
    severity: asString(raw.severity) ?? 'unknown',
    summary,
    target_type: targetType,
    target_id: asString(raw.target_id) ?? null,
    actor: asString(raw.actor) ?? null,
    evidence: raw.evidence,
  }
}

function normalizeRecommendedAction(raw: unknown): OperatorRecommendedAction | null {
  if (!isRecord(raw)) return null
  const actionType = asString(raw.action_type)
  const targetType = asString(raw.target_type)
  const reason = asString(raw.reason)
  if (!actionType || !targetType || !reason) return null
  return {
    action_type: actionType,
    target_type: targetType,
    target_id: asString(raw.target_id) ?? null,
    severity: asString(raw.severity) ?? 'unknown',
    reason,
    confirm_required: asBoolean(raw.confirm_required),
    suggested_payload: raw.suggested_payload,
    preview: raw.preview,
  }
}

function normalizeOperatorJudgeRuntime(raw: unknown): OperatorJudgeRuntime | null {
  if (!isRecord(raw)) return null
  return {
    enabled: asBoolean(raw.enabled),
    judge_online: asBoolean(raw.judge_online),
    refreshing: asBoolean(raw.refreshing),
    generated_at: asString(raw.generated_at) ?? null,
    expires_at: asString(raw.expires_at) ?? null,
    model_used: asString(raw.model_used) ?? null,
    keeper_name: asString(raw.keeper_name) ?? null,
    last_error: asString(raw.last_error) ?? null,
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

function normalizeReviewDecision(raw: unknown): OperatorReviewDecision | null {
  if (!isRecord(raw)) return null
  const itemId = asString(raw.item_id)
  const fingerprint = asString(raw.fingerprint)
  const decision = asString(raw.decision)
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
    model_name: asString(raw.model_name) ?? null,
    runtime_name: asString(raw.runtime_name) ?? null,
    evidence_refs: asStringArray(raw.evidence_refs),
    recommended_action: normalizeRecommendedAction(raw.recommended_action),
    supersedes: asStringArray(raw.supersedes),
    fallback_used: asBoolean(raw.fallback_used),
    disagreement_with_truth: asBoolean(raw.disagreement_with_truth),
    provenance: asString(raw.provenance) ?? null,
  }
}

function normalizeLinkedAutoresearch(raw: unknown): OperatorLinkedAutoresearch | null {
  if (!isRecord(raw)) return null
  const loopId = asString(raw.loop_id)
  const status = asString(raw.status)
  if (!loopId && !status) return null
  return {
    loop_id: loopId ?? null,
    session_id: asString(raw.session_id) ?? null,
    status: status ?? null,
    current_cycle: asNumber(raw.current_cycle) ?? undefined,
    best_score: asNumber(raw.best_score) ?? null,
    last_decision: asString(raw.last_decision) ?? null,
    target_file: asString(raw.target_file) ?? null,
    workdir: asString(raw.workdir) ?? null,
    source_workdir: asString(raw.source_workdir) ?? null,
    program_note: asString(raw.program_note) ?? null,
    operation_id: asString(raw.operation_id) ?? null,
    queued_hypothesis: asString(raw.queued_hypothesis) ?? null,
    warnings: extractArray(raw.warnings)
      .map(item => (typeof item === 'string' ? item.trim() : ''))
      .filter(Boolean),
    error: asString(raw.error) ?? null,
  }
}

export function normalizeOperatorDigest(raw: unknown): OperatorDigest {
  const root = isRecord(raw) ? raw : {}
  return {
    trace_id: asString(root.trace_id),
    target_type: asString(root.target_type) ?? 'root',
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
    cascade_metrics: isRecord(raw.cascade_metrics) ? raw.cascade_metrics : isRecord(statusBlock?.cascade_metrics) ? statusBlock.cascade_metrics : undefined,
    report_paths: reportPaths,
    linked_autoresearch:
      normalizeLinkedAutoresearch(raw.linked_autoresearch)
      ?? normalizeLinkedAutoresearch(statusBlock?.linked_autoresearch)
      ?? null,
    session,
    recent_events: recentEvents,
  }
}

function normalizeKeeper(raw: unknown): OperatorKeeperSnapshot | null {
  if (!isRecord(raw)) return null
  const name = asString(raw.name)
  if (!name) return null
  const contextRaw = isRecord(raw.context) ? raw.context : undefined
  return {
    name,
    runtime_class: 'keeper' as const,
    registered: asBoolean(raw.registered),
    agent_name: asString(raw.agent_name),
    status: asString(raw.status),
    context_ratio: asNumber(raw.context_ratio) ?? asNumber(contextRaw?.context_ratio),
    generation: asNumber(raw.generation),
    active_goal_ids: asStringArray(raw.active_goal_ids),
    last_autonomous_action_at: asString(raw.last_autonomous_action_at) ?? null,
    last_turn_ago_s: asNumber(raw.last_turn_ago_s),
    model: asString(raw.model) ?? asString(raw.active_model) ?? asString(raw.primary_model),
  }
}

export function normalizeOperatorSnapshot(raw: unknown): OperatorSnapshot {
  const root = isRecord(raw) ? raw : {}
  const pendingConfirmEnvelope = normalizePendingConfirmEnvelope(root.pending_confirm_envelope)
  return {
    root: normalizeNamespace(root.root),
    sessions: extractArray(root.sessions, ['items', 'sessions'])
      .map(normalizeSession)
      .filter((item): item is OperatorSessionSnapshot => item !== null),
    keepers: extractArray(root.keepers, ['items', 'keepers'])
      .map(normalizeKeeper)
      .filter((item): item is OperatorKeeperSnapshot => item !== null),
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
