import { asBoolean, asString, isRecord } from './components/common/normalize'
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
  const confirmToken = asString(raw.confirm_token)
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
  const actorFilter = raw.actor_filter === null ? null : asString(raw.actor_filter)
  const filterActive = asBoolean(raw.filter_active)
  const counts = [raw.visible_count, raw.total_count, raw.hidden_count]
  const hiddenActors = raw.hidden_actors
  const actions = raw.confirm_required_actions
  if (
    actorFilter === undefined
    || filterActive === undefined
    || !counts.every(value => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0)
    || !Array.isArray(hiddenActors)
    || !hiddenActors.every(value => typeof value === 'string' && value.trim() !== '')
    || !Array.isArray(actions)
  ) return null
  const normalizedActions = actions.map(normalizeOperatorActionDescriptor)
  if (normalizedActions.some(action => action === null)) return null
  return {
    actor_filter: actorFilter,
    filter_active: filterActive,
    visible_count: counts[0] as number,
    total_count: counts[1] as number,
    hidden_count: counts[2] as number,
    hidden_actors: hiddenActors,
    confirm_required_actions: normalizedActions as OperatorActionDescriptor[],
  }
}

export function normalizePendingConfirmEnvelope(raw: unknown): PendingConfirmEnvelope | null {
  if (!isRecord(raw)) return null
  if (!Array.isArray(raw.items)) return null
  const items = raw.items.map(normalizePendingConfirmation)
  if (items.some(item => item === null)) return null
  const summary = normalizePendingConfirmSummary(raw.summary)
  if (!summary) return null
  return {
    items: items as PendingConfirmation[],
    summary,
  }
}
