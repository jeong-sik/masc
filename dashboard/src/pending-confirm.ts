import { asBoolean, asString, isRecord } from './components/common/normalize'
import type {
  OperatorActionDescriptor,
  PendingConfirmEnvelope,
  PendingConfirmation,
  PendingConfirmSummary,
} from './types'

const ACTION_DESCRIPTOR_KEYS = [
  'action_type', 'tool_name', 'target_type', 'description', 'confirm_required',
] as const
const PENDING_CONFIRM_KEYS = [
  'confirm_token', 'trace_id', 'actor', 'action_type', 'target_type', 'target_id',
  'payload', 'delegated_tool', 'created_at', 'expires_at',
] as const
const PENDING_CONFIRM_SUMMARY_KEYS = [
  'actor_filter', 'filter_active', 'visible_count', 'total_count', 'hidden_count',
  'hidden_actors', 'confirm_required_actions',
] as const
const PENDING_CONFIRM_ENVELOPE_KEYS = ['items', 'summary'] as const

function hasExactKeys(raw: Record<string, unknown>, allowed: readonly string[]): boolean {
  const keys = Object.keys(raw)
  return keys.length === allowed.length && keys.every(key => allowed.includes(key))
}

function timestampMs(value: string): number | null {
  const parsed = Date.parse(value)
  return Number.isFinite(parsed) ? parsed : null
}

export function normalizeOperatorActionDescriptor(raw: unknown): OperatorActionDescriptor | null {
  if (!isRecord(raw) || !hasExactKeys(raw, ACTION_DESCRIPTOR_KEYS)) return null
  const actionType = asString(raw.action_type)
  const toolName = asString(raw.tool_name)
  const targetType = asString(raw.target_type)
  const description = asString(raw.description)
  const confirmRequired = asBoolean(raw.confirm_required)
  if (!actionType || !toolName || !targetType || !description || confirmRequired === undefined) return null
  return {
    action_type: actionType,
    tool_name: toolName,
    target_type: targetType,
    description,
    confirm_required: confirmRequired,
  }
}

export function normalizePendingConfirmation(raw: unknown): PendingConfirmation | null {
  if (!isRecord(raw) || !hasExactKeys(raw, PENDING_CONFIRM_KEYS)) return null
  const confirmToken = asString(raw.confirm_token)
  const traceId = asString(raw.trace_id)
  const actor = asString(raw.actor)
  const actionType = asString(raw.action_type)
  const targetType = asString(raw.target_type)
  const delegatedTool = asString(raw.delegated_tool)
  const createdAt = asString(raw.created_at)
  const targetId = raw.target_id === null ? null : asString(raw.target_id)
  const expiresAt = raw.expires_at === null ? null : asString(raw.expires_at)
  const createdAtMs = createdAt ? timestampMs(createdAt) : null
  const expiresAtMs = expiresAt === null || expiresAt === undefined
    ? expiresAt
    : timestampMs(expiresAt)
  if (
    !confirmToken
    || !traceId
    || !actor
    || !actionType
    || !targetType
    || targetId === undefined
    || !isRecord(raw.payload)
    || !delegatedTool
    || !createdAt
    || createdAtMs === null
    || expiresAt === undefined
    || (expiresAt !== null
      && (expiresAtMs === undefined || expiresAtMs === null || expiresAtMs <= createdAtMs))
  ) return null
  return {
    confirm_token: confirmToken,
    trace_id: traceId,
    actor,
    action_type: actionType,
    target_type: targetType,
    target_id: targetId,
    payload: raw.payload,
    delegated_tool: delegatedTool,
    created_at: createdAt,
    expires_at: expiresAt,
  }
}

export function normalizePendingConfirmSummary(raw: unknown): PendingConfirmSummary | null {
  if (!isRecord(raw) || !hasExactKeys(raw, PENDING_CONFIRM_SUMMARY_KEYS)) return null
  const actorFilter = raw.actor_filter === null ? null : asString(raw.actor_filter)
  const filterActive = asBoolean(raw.filter_active)
  const counts = [raw.visible_count, raw.total_count, raw.hidden_count]
  const hiddenActors = raw.hidden_actors
  const actions = raw.confirm_required_actions
  if (
    actorFilter === undefined
    || filterActive === undefined
    || filterActive !== (actorFilter !== null)
    || !counts.every(value => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0)
    || (counts[0] as number) + (counts[2] as number) !== counts[1]
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
  if (!isRecord(raw) || !hasExactKeys(raw, PENDING_CONFIRM_ENVELOPE_KEYS)) return null
  if (!Array.isArray(raw.items)) return null
  const items = raw.items.map(normalizePendingConfirmation)
  if (items.some(item => item === null)) return null
  const normalizedItems = items as PendingConfirmation[]
  if (new Set(normalizedItems.map(item => item.confirm_token)).size !== normalizedItems.length) return null
  const summary = normalizePendingConfirmSummary(raw.summary)
  if (!summary || summary.visible_count !== normalizedItems.length) return null
  return { items: normalizedItems, summary }
}
