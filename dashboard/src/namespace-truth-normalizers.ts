import { asBoolean, asNumber, asString, asStringArray, isRecord, extractArray } from './components/common/normalize'
import {
  normalizeServerStatus,
  normalizeExecutionSummary,
  normalizeExecutionQueueItem,
  normalizeAttentionItem,
  normalizeRecommendedAction,
  normalizeShellMetaCognitionSummary,
} from './store-normalizers'
import type {
  DashboardAttentionEvent,
  DashboardNamespaceTruthAttentionSummary,
  DashboardNamespaceTruthFocus,
  DashboardNamespaceTruthMetaCognitionDigest,
  DashboardReadinessPillar,
  DashboardReadinessSummary,
  DashboardNamespaceTruthRecommendationSummary,
  DashboardNamespaceTruthResponse,
  PendingConfirmSummary,
} from './types'

function normalizePendingConfirmSummary(raw: unknown): PendingConfirmSummary | null {
  if (!isRecord(raw)) return null
  return {
    actor_filter: asString(raw.actor_filter) ?? null,
    filter_active: asBoolean(raw.filter_active) ?? false,
    visible_count: asNumber(raw.visible_count) ?? 0,
    total_count: asNumber(raw.total_count) ?? 0,
    hidden_count: asNumber(raw.hidden_count) ?? 0,
    hidden_actors: asStringArray(raw.hidden_actors),
    confirm_required_actions: extractArray(raw.confirm_required_actions).flatMap(item => {
      if (!isRecord(item)) return []
      const actionType = asString(item.action_type)
      const targetType = asString(item.target_type)
      if (!actionType || !targetType) return []
      return [{
        action_type: actionType,
        target_type: targetType,
        description: asString(item.description),
        confirm_required: asBoolean(item.confirm_required),
      }]
    }),
  }
}

function normalizeAttentionSummary(raw: unknown): DashboardNamespaceTruthAttentionSummary | null {
  if (!isRecord(raw)) return null
  return {
    count: asNumber(raw.count) ?? 0,
    bad_count: asNumber(raw.bad_count) ?? 0,
    warn_count: asNumber(raw.warn_count) ?? 0,
    provenance: asString(raw.provenance) ?? null,
    top_item: normalizeAttentionItem(raw.top_item),
  }
}

function normalizeRecommendationSummary(raw: unknown): DashboardNamespaceTruthRecommendationSummary | null {
  if (!isRecord(raw)) return null
  return {
    count: asNumber(raw.count) ?? 0,
    provenance: asString(raw.provenance) ?? null,
    top_action: normalizeRecommendedAction(raw.top_action),
  }
}

function normalizeMetaCognitionDigest(raw: unknown): DashboardNamespaceTruthMetaCognitionDigest | null {
  if (!isRecord(raw)) return null
  const postId = asString(raw.post_id)
  const title = asString(raw.title)
  const createdAt = asString(raw.created_at)
  if (!postId || !title || !createdAt) return null
  return {
    post_id: postId,
    title,
    created_at: createdAt,
    updated_at: asString(raw.updated_at) ?? null,
    hearth: asString(raw.hearth) ?? null,
    digest_key: asString(raw.digest_key) ?? null,
    matches_summary: asBoolean(raw.matches_summary) ?? false,
    provenance: asString(raw.provenance) ?? null,
  }
}

function normalizeFocus(raw: unknown): DashboardNamespaceTruthFocus | null {
  if (!isRecord(raw)) return null
  const label = asString(raw.label)
  const reason = asString(raw.reason)
  const source = asString(raw.source)
  const provenance = asString(raw.provenance)
  if (!label || !reason || !source || !provenance) return null
  return {
    label,
    reason,
    source,
    provenance,
    target_kind: asString(raw.target_kind) ?? null,
    target_id: asString(raw.target_id) ?? null,
    suggested_tab: asString(raw.suggested_tab) ?? null,
    suggested_surface: asString(raw.suggested_surface) ?? null,
    suggested_params: isRecord(raw.suggested_params)
      ? Object.fromEntries(
          Object.entries(raw.suggested_params)
            .map(([key, value]) => {
              const text = asString(value)
              return text ? [key, text] : null
            })
            .filter((entry): entry is [string, string] => entry !== null),
        )
      : {},
  }
}

function normalizeReadinessPillar(raw: unknown): DashboardReadinessPillar | null {
  if (!isRecord(raw)) return null
  const key = asString(raw.key)
  const label = asString(raw.label)
  const status = asString(raw.status)
  const summary = asString(raw.summary)
  const score = asNumber(raw.score)
  if (!key || !label || !status || !summary || score == null) return null
  return {
    key,
    label,
    status,
    score,
    summary,
    blocking_reasons: asStringArray(raw.blocking_reasons),
    metrics: isRecord(raw.metrics)
      ? Object.fromEntries(
          Object.entries(raw.metrics)
            .map(([metricKey, value]) => {
              const numeric = asNumber(value)
              return numeric == null ? null : [metricKey, numeric]
            })
            .filter((entry): entry is [string, number] => entry !== null),
        )
      : {},
  }
}

function normalizeReadiness(raw: unknown): DashboardReadinessSummary | null {
  if (!isRecord(raw)) return null
  const status = asString(raw.status)
  const score = asNumber(raw.score)
  if (!status || score == null) return null
  return {
    status,
    score,
    decision_required_count: asNumber(raw.decision_required_count) ?? 0,
    blocking_count: asNumber(raw.blocking_count) ?? 0,
    pillars: extractArray(raw.pillars)
      .map(normalizeReadinessPillar)
      .filter((pillar): pillar is DashboardReadinessPillar => pillar !== null),
  }
}

function normalizeAttentionEvent(raw: unknown): DashboardAttentionEvent | null {
  if (!isRecord(raw)) return null
  const severity = asString(raw.severity)
  const kind = asString(raw.kind)
  const summary = asString(raw.summary)
  if (!severity || !kind || !summary) return null
  return {
    severity,
    kind,
    summary,
    requires_decision: asBoolean(raw.requires_decision) ?? false,
    keeper_name: asString(raw.keeper_name) ?? null,
    target_type: asString(raw.target_type) ?? null,
    target_id: asString(raw.target_id) ?? null,
    recommended_action: asString(raw.recommended_action) ?? null,
    provenance: asString(raw.provenance) ?? null,
  }
}

export function normalizeNamespaceTruth(raw: unknown): DashboardNamespaceTruthResponse {
  const root = isRecord(raw) ? raw : {}
  const namespaceBlock = isRecord(root.root) ? root.root : {}
  const executionBlock = isRecord(root.execution) ? root.execution : {}
  const commandBlock = isRecord(root.command) ? root.command : {}
  const metaCognitionBlock = isRecord(root.meta_cognition) ? root.meta_cognition : {}
  const operatorBlock = isRecord(root.operator) ? root.operator : {}
  return {
    generated_at: asString(root.generated_at),
    root: {
      status: normalizeServerStatus(namespaceBlock.status),
      counts: isRecord(namespaceBlock.counts)
        ? {
            agents: asNumber(namespaceBlock.counts.agents),
            tasks: asNumber(namespaceBlock.counts.tasks),
            keepers: asNumber(namespaceBlock.counts.keepers),
            total_runtimes: asNumber(namespaceBlock.counts.total_runtimes),
          }
        : undefined,
      configured_keepers: asNumber(namespaceBlock.configured_keepers),
      provenance: asString(namespaceBlock.provenance) ?? null,
    },
    execution: {
      summary: normalizeExecutionSummary(executionBlock.summary),
      top_queue: normalizeExecutionQueueItem(executionBlock.top_queue),
      provenance: asString(executionBlock.provenance) ?? null,
    },
    command: {
      active_operations: asNumber(commandBlock.active_operations),
      active_detachments: asNumber(commandBlock.active_detachments),
      pending_approvals: asNumber(commandBlock.pending_approvals),
      bad_alerts: asNumber(commandBlock.bad_alerts),
      warn_alerts: asNumber(commandBlock.warn_alerts),
      provenance: asString(commandBlock.provenance) ?? null,
    },
    meta_cognition: {
      summary: normalizeShellMetaCognitionSummary(metaCognitionBlock.summary),
      latest_digest: normalizeMetaCognitionDigest(metaCognitionBlock.latest_digest),
      provenance: asString(metaCognitionBlock.provenance) ?? null,
    },
    operator: {
      health: asString(operatorBlock.health) ?? null,
      attention_summary: normalizeAttentionSummary(operatorBlock.attention_summary),
      recommendation_summary: normalizeRecommendationSummary(operatorBlock.recommendation_summary),
      pending_confirm_summary: normalizePendingConfirmSummary(operatorBlock.pending_confirm_summary),
      provenance: asString(operatorBlock.provenance) ?? null,
    },
    readiness: normalizeReadiness(root.readiness),
    attention_events: extractArray(root.attention_events)
      .map(normalizeAttentionEvent)
      .filter((event): event is DashboardAttentionEvent => event !== null),
    focus: normalizeFocus(root.focus),
  }
}
