import { signal } from '@preact/signals'
import { fetchDashboardRoomTruth } from './api'
import type {
  DashboardExecutionQueueItem,
  DashboardExecutionSummary,
  DashboardRoomTruthAttentionSummary,
  DashboardRoomTruthFocus,
  DashboardRoomTruthRecommendationSummary,
  DashboardRoomTruthResponse,
  OperatorAttentionItem,
  OperatorRecommendedAction,
  PendingConfirmSummary,
  ServerStatus,
} from './types'
import { asBoolean, asNumber, asString, asStringArray, isRecord, extractArray } from './components/common/normalize'

export const roomTruth = signal<DashboardRoomTruthResponse | null>(null)
export const roomTruthLoading = signal(false)
export const roomTruthError = signal<string | null>(null)

function normalizeServerStatus(raw: unknown): ServerStatus | null {
  if (!isRecord(raw)) return null
  return {
    room: asString(raw.room) ?? asString(raw.current_room),
    room_base_path: asString(raw.room_base_path),
    cluster: asString(raw.cluster),
    project: asString(raw.project),
    paused: asBoolean(raw.paused),
    version: asString(raw.version),
    generated_at: asString(raw.generated_at),
    tempo_interval_s: asNumber(raw.tempo_interval_s),
  }
}

function normalizeExecutionSummary(raw: unknown): DashboardExecutionSummary | null {
  if (!isRecord(raw)) return null
  return {
    active_sessions: asNumber(raw.active_sessions),
    blocked_sessions: asNumber(raw.blocked_sessions),
    active_operations: asNumber(raw.active_operations),
    blocked_operations: asNumber(raw.blocked_operations),
    runtime_pressure: asNumber(raw.runtime_pressure),
    worker_alerts: asNumber(raw.worker_alerts),
    continuity_alerts: asNumber(raw.continuity_alerts),
    priority_items: asNumber(raw.priority_items),
    keepers: asNumber(raw.keepers),
  }
}

function normalizeExecutionQueueItem(raw: unknown): DashboardExecutionQueueItem | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const kind = asString(raw.kind)
  const severity = asString(raw.severity)
  const summary = asString(raw.summary)
  const targetType = asString(raw.target_type)
  const targetId = asString(raw.target_id)
  if (!id || !kind || !severity || !summary || !targetType || !targetId) return null
  return {
    id,
    kind: kind as DashboardExecutionQueueItem['kind'],
    severity: severity as DashboardExecutionQueueItem['severity'],
    summary,
    target_type: targetType,
    target_id: targetId,
    status: asString(raw.status),
    linked_session_id: asString(raw.linked_session_id) ?? null,
    linked_operation_id: asString(raw.linked_operation_id) ?? null,
    last_seen_at: asString(raw.last_seen_at) ?? null,
    top_handoff: isRecord(raw.top_handoff) ? raw.top_handoff as unknown as DashboardExecutionQueueItem['top_handoff'] : null,
    intervene_handoff: isRecord(raw.intervene_handoff) ? raw.intervene_handoff as unknown as DashboardExecutionQueueItem['intervene_handoff'] : null,
    command_handoff: isRecord(raw.command_handoff) ? raw.command_handoff as unknown as DashboardExecutionQueueItem['command_handoff'] : null,
  }
}

function normalizeAttentionItem(raw: unknown): OperatorAttentionItem | null {
  if (!isRecord(raw)) return null
  const kind = asString(raw.kind)
  const summary = asString(raw.summary)
  const targetType = asString(raw.target_type)
  if (!kind || !summary || !targetType) return null
  return {
    kind,
    severity: asString(raw.severity) ?? 'warn',
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
    severity: asString(raw.severity) ?? 'warn',
    reason,
    confirm_required: asBoolean(raw.confirm_required),
    suggested_payload: isRecord(raw.suggested_payload) ? raw.suggested_payload : undefined,
    preview: raw.preview,
  }
}

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

function normalizeAttentionSummary(raw: unknown): DashboardRoomTruthAttentionSummary | null {
  if (!isRecord(raw)) return null
  return {
    count: asNumber(raw.count) ?? 0,
    bad_count: asNumber(raw.bad_count) ?? 0,
    warn_count: asNumber(raw.warn_count) ?? 0,
    provenance: asString(raw.provenance) ?? null,
    top_item: normalizeAttentionItem(raw.top_item),
  }
}

function normalizeRecommendationSummary(raw: unknown): DashboardRoomTruthRecommendationSummary | null {
  if (!isRecord(raw)) return null
  return {
    count: asNumber(raw.count) ?? 0,
    provenance: asString(raw.provenance) ?? null,
    top_action: normalizeRecommendedAction(raw.top_action),
  }
}

function normalizeFocus(raw: unknown): DashboardRoomTruthFocus | null {
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

function normalizeRoomTruth(raw: unknown): DashboardRoomTruthResponse {
  const root = isRecord(raw) ? raw : {}
  const roomBlock = isRecord(root.room) ? root.room : {}
  const executionBlock = isRecord(root.execution) ? root.execution : {}
  const commandBlock = isRecord(root.command) ? root.command : {}
  const operatorBlock = isRecord(root.operator) ? root.operator : {}
  return {
    generated_at: asString(root.generated_at),
    room: {
      status: normalizeServerStatus(roomBlock.status),
      counts: isRecord(roomBlock.counts)
        ? {
            agents: asNumber(roomBlock.counts.agents),
            tasks: asNumber(roomBlock.counts.tasks),
            keepers: asNumber(roomBlock.counts.keepers),
          }
        : undefined,
      provenance: asString(roomBlock.provenance) ?? null,
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
      moving_lanes: asNumber(commandBlock.moving_lanes),
      active_lanes: asNumber(commandBlock.active_lanes),
      provenance: asString(commandBlock.provenance) ?? null,
    },
    operator: {
      health: asString(operatorBlock.health) ?? null,
      attention_summary: normalizeAttentionSummary(operatorBlock.attention_summary),
      recommendation_summary: normalizeRecommendationSummary(operatorBlock.recommendation_summary),
      pending_confirm_summary: normalizePendingConfirmSummary(operatorBlock.pending_confirm_summary),
      provenance: asString(operatorBlock.provenance) ?? null,
    },
    focus: normalizeFocus(root.focus),
  }
}

export async function refreshRoomTruth(): Promise<void> {
  roomTruthLoading.value = true
  roomTruthError.value = null
  try {
    const raw = await fetchDashboardRoomTruth()
    roomTruth.value = normalizeRoomTruth(raw)
  } catch (err) {
    roomTruthError.value = err instanceof Error ? err.message : 'Failed to load room truth'
  } finally {
    roomTruthLoading.value = false
  }
}
