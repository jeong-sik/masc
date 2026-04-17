import { asBoolean, asNumber, asString, asStringArray, extractArray, isRecord } from './components/common/normalize'
import type {
  OperatorActionDescriptor,
  PendingConfirmEnvelope,
  PendingConfirmation,
  PendingConfirmSummary,
} from './types'

export function normalizeOperatorActionDescriptor(raw: unknown): OperatorActionDescriptor | null {
  if (!isRecord(raw)) return null
  const actionType = asString(raw.action_type)
  const targetType = asString(raw.target_type)
  if (!actionType || !targetType) return null
  return {
    action_type: actionType,
    target_type: targetType,
    description: asString(raw.description),
    confirm_required: asBoolean(raw.confirm_required),
  }
}

export function normalizePendingConfirmation(raw: unknown): PendingConfirmation | null {
  if (!isRecord(raw)) return null
  const confirmToken = asString(raw.confirm_token) ?? asString(raw.token)
  if (!confirmToken) return null
  return {
    confirm_token: confirmToken,
    actor: asString(raw.actor),
    action_type: asString(raw.action_type),
    target_type: asString(raw.target_type),
    target_id: asString(raw.target_id) ?? null,
    delegated_tool: asString(raw.delegated_tool),
    created_at: asString(raw.created_at),
    preview: raw.preview,
  }
}

export function normalizePendingConfirmSummary(raw: unknown): PendingConfirmSummary | null {
  if (!isRecord(raw)) return null
  return {
    actor_filter: asString(raw.actor_filter) ?? null,
    filter_active: asBoolean(raw.filter_active) ?? false,
    visible_count: asNumber(raw.visible_count) ?? 0,
    total_count: asNumber(raw.total_count) ?? 0,
    hidden_count: asNumber(raw.hidden_count) ?? 0,
    hidden_actors: asStringArray(raw.hidden_actors),
    confirm_required_actions: extractArray(raw.confirm_required_actions)
      .map(normalizeOperatorActionDescriptor)
      .filter((item): item is OperatorActionDescriptor => item !== null),
  }
}

export function normalizePendingConfirmEnvelope(raw: unknown): PendingConfirmEnvelope | null {
  if (!isRecord(raw)) return null
  const items = extractArray(raw.items, ['confirms'])
    .map(normalizePendingConfirmation)
    .filter((item): item is PendingConfirmation => item !== null)
  const summary = normalizePendingConfirmSummary(raw.summary)
  if (!summary && items.length === 0) return null
  return {
    items,
    summary: summary ?? {
      actor_filter: null,
      filter_active: false,
      visible_count: items.length,
      total_count: items.length,
      hidden_count: 0,
      hidden_actors: [],
      confirm_required_actions: [],
    },
  }
}

interface PendingConfirmSource {
  pending_confirm_envelope?: PendingConfirmEnvelope | null
  pending_confirms?: PendingConfirmation[] | null
  pending_confirm_summary?: PendingConfirmSummary | null
  available_actions?: OperatorActionDescriptor[] | null
}

export interface PendingConfirmState {
  items: PendingConfirmation[]
  summary: PendingConfirmSummary
  actor_filter: string | null
  visible_count: number
  total_count: number
  hidden_count: number
  hidden_actors: string[]
  confirm_required_actions: OperatorActionDescriptor[]
}

export function selectPendingConfirmState(source: PendingConfirmSource | null | undefined): PendingConfirmState {
  const envelope = source?.pending_confirm_envelope ?? null
  const items = envelope?.items ?? source?.pending_confirms ?? []
  const summary = envelope?.summary ?? source?.pending_confirm_summary ?? {
    actor_filter: null,
    filter_active: false,
    visible_count: items.length,
    total_count: items.length,
    hidden_count: 0,
    hidden_actors: [],
    confirm_required_actions: source?.available_actions?.filter(action => action.confirm_required) ?? [],
  }
  return {
    items,
    summary,
    actor_filter: summary.actor_filter?.trim() || null,
    visible_count: summary.visible_count ?? items.length,
    total_count: summary.total_count ?? items.length,
    hidden_count: summary.hidden_count ?? 0,
    hidden_actors: summary.hidden_actors ?? [],
    confirm_required_actions:
      summary.confirm_required_actions?.length
        ? summary.confirm_required_actions
        : (source?.available_actions?.filter(action => action.confirm_required) ?? []),
  }
}
