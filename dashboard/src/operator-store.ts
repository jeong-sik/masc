import { signal } from '@preact/signals'
import { confirmOperatorAction, fetchOperatorDigest, fetchOperatorSnapshot, runOperatorAction } from './api'
import { normalizeSummarySnapshot } from './command-store'
import type {
  CommandPlaneSummarySnapshot,
  Message,
  OperatorActionLogEntry,
  OperatorActionRequest,
  OperatorActionResult,
  OperatorAttentionItem,
  OperatorDigest,
  OperatorKeeperSnapshot,
  OperatorSessionSnapshot,
  OperatorSnapshot,
  OperatorRoomSnapshot,
  PendingConfirmation,
} from './types'

export const operatorSnapshot = signal<OperatorSnapshot | null>(null)
export const operatorDigest = signal<OperatorDigest | null>(null)
export const operatorLoading = signal(false)
export const operatorError = signal<string | null>(null)
export const operatorActionBusy = signal(false)
export const operatorActionLog = signal<OperatorActionLogEntry[]>([])

let nextLogId = 1

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value : undefined
}

function asNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function asBoolean(value: unknown): boolean | undefined {
  return typeof value === 'boolean' ? value : undefined
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map(item => (typeof item === 'string' ? item.trim() : ''))
    .filter(Boolean)
}

function extractArray(value: unknown, keys: string[] = []): unknown[] {
  if (Array.isArray(value)) return value
  if (!isRecord(value)) return []
  for (const key of keys) {
    const candidate = value[key]
    if (Array.isArray(candidate)) return candidate
  }
  return []
}

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

function normalizeRoom(raw: unknown): OperatorRoomSnapshot {
  if (!isRecord(raw)) return {}
  return {
    room_id: asString(raw.room_id),
    current_room: asString(raw.current_room) ?? asString(raw.room),
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
    agent_name: asString(raw.agent_name),
    status: asString(raw.status),
    autonomy_level: asString(raw.autonomy_level),
    context_ratio: asNumber(raw.context_ratio) ?? asNumber(contextRaw?.context_ratio),
    generation: asNumber(raw.generation),
    active_goal_ids: asStringArray(raw.active_goal_ids),
    last_autonomous_action_at: asString(raw.last_autonomous_action_at) ?? null,
    last_turn_ago_s: asNumber(raw.last_turn_ago_s),
    model: asString(raw.model) ?? asString(raw.active_model) ?? asString(raw.primary_model),
  }
}

function normalizePendingConfirm(raw: unknown): PendingConfirmation | null {
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

function normalizeOperatorSnapshot(raw: unknown): OperatorSnapshot {
  const root = isRecord(raw) ? raw : {}
  return {
    room: normalizeRoom(root.room),
    sessions: extractArray(root.sessions, ['items', 'sessions'])
      .map(normalizeSession)
      .filter((item): item is OperatorSessionSnapshot => item !== null),
    keepers: extractArray(root.keepers, ['items', 'keepers'])
      .map(normalizeKeeper)
      .filter((item): item is OperatorKeeperSnapshot => item !== null),
    recent_messages: extractArray(root.recent_messages, ['messages'])
      .map(normalizeMessage)
      .filter((item): item is Message => item !== null),
    pending_confirms: extractArray(root.pending_confirms, ['items', 'confirms'])
      .map(normalizePendingConfirm)
      .filter((item): item is PendingConfirmation => item !== null),
    available_actions: extractArray(root.available_actions, ['actions'])
      .filter(isRecord)
      .map(item => ({
        action_type: asString(item.action_type) ?? 'unknown',
        target_type: asString(item.target_type) ?? 'unknown',
        description: asString(item.description),
        confirm_required: asBoolean(item.confirm_required),
      })),
  }
}

function normalizeAttentionItem(raw: unknown): OperatorAttentionItem | null {
  if (!isRecord(raw)) return null
  const kind = asString(raw.kind)
  if (!kind) return null
  return {
    kind,
    severity: asString(raw.severity),
    summary: asString(raw.summary),
    target_type: asString(raw.target_type),
    target_id: asString(raw.target_id) ?? null,
    actor: asString(raw.actor) ?? null,
    evidence: raw.evidence,
  }
}

function normalizeAttentionSummary(raw: unknown) {
  if (!isRecord(raw)) return undefined
  return {
    count: asNumber(raw.count),
    bad_count: asNumber(raw.bad_count),
    warn_count: asNumber(raw.warn_count),
    top_item: normalizeAttentionItem(raw.top_item),
  }
}

function normalizeRecommendationSummary(raw: unknown) {
  if (!isRecord(raw)) return undefined
  return {
    count: asNumber(raw.count),
    top_action: raw.top_action,
  }
}

function normalizeCommandPlaneSummary(raw: unknown): CommandPlaneSummarySnapshot | undefined {
  if (!isRecord(raw)) return undefined
  return normalizeSummarySnapshot(raw)
}

function normalizeOperatorDigest(raw: unknown): OperatorDigest {
  const root = isRecord(raw) ? raw : {}
  return {
    target_type: asString(root.target_type),
    target_id: asString(root.target_id) ?? null,
    health: asString(root.health),
    swarm_status: isRecord(root.swarm_status)
      ? (root.swarm_status as unknown as OperatorDigest['swarm_status'])
      : undefined,
    command_plane: normalizeCommandPlaneSummary(root.command_plane),
    attention_items: extractArray(root.attention_items).map(normalizeAttentionItem)
      .filter((item): item is OperatorAttentionItem => item !== null),
    attention_summary: normalizeAttentionSummary(root.attention_summary),
    recommended_actions: extractArray(root.recommended_actions),
    recommendation_summary: normalizeRecommendationSummary(root.recommendation_summary),
    session_cards: extractArray(root.session_cards).filter(isRecord),
    worker_cards: extractArray(root.worker_cards).filter(isRecord),
  }
}

function stringifyUnknown(value: unknown): string {
  if (typeof value === 'string') return value
  if (value === null || value === undefined) return ''
  try {
    return JSON.stringify(value)
  } catch {
    return String(value)
  }
}

function targetLabelOf(request: Pick<OperatorActionRequest, 'target_type' | 'target_id'>): string {
  return request.target_id ? `${request.target_type}:${request.target_id}` : request.target_type
}

function appendLog(entry: Omit<OperatorActionLogEntry, 'id' | 'at'>): void {
  operatorActionLog.value = [
    {
      ...entry,
      id: nextLogId++,
      at: new Date().toISOString(),
    },
    ...operatorActionLog.value,
  ].slice(0, 20)
}

function logMessageFromResult(result: OperatorActionResult): string {
  if (result.confirm_required) {
    return stringifyUnknown(result.preview) || 'Confirmation required'
  }
  return stringifyUnknown(result.result)
    || stringifyUnknown(result.executed_action)
    || stringifyUnknown(result.delegated_tool_result)
    || result.status
}

export async function refreshOperatorSnapshot(): Promise<void> {
  operatorLoading.value = true
  operatorError.value = null
  try {
    const [snapshotRaw, digestRaw] = await Promise.all([
      fetchOperatorSnapshot(),
      fetchOperatorDigest(),
    ])
    operatorSnapshot.value = normalizeOperatorSnapshot(snapshotRaw)
    operatorDigest.value = normalizeOperatorDigest(digestRaw)
  } catch (err) {
    operatorError.value = err instanceof Error ? err.message : 'Failed to load operator snapshot'
  } finally {
    operatorLoading.value = false
  }
}

export async function dispatchOperatorAction(request: OperatorActionRequest): Promise<OperatorActionResult> {
  operatorActionBusy.value = true
  operatorError.value = null
  try {
    const result = await runOperatorAction(request)
    appendLog({
      actor: request.actor,
      action_type: request.action_type,
      target_label: targetLabelOf(request),
      outcome: result.confirm_required ? 'preview' : 'executed',
      message: logMessageFromResult(result),
      delegated_tool: result.delegated_tool,
    })
    await refreshOperatorSnapshot()
    return result
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Operator action failed'
    operatorError.value = message
    appendLog({
      actor: request.actor,
      action_type: request.action_type,
      target_label: targetLabelOf(request),
      outcome: 'error',
      message,
    })
    throw err
  } finally {
    operatorActionBusy.value = false
  }
}

export async function confirmOperatorPendingAction(actor: string, confirmToken: string): Promise<OperatorActionResult> {
  operatorActionBusy.value = true
  operatorError.value = null
  try {
    const result = await confirmOperatorAction(actor, confirmToken)
    appendLog({
      actor,
      action_type: 'confirm',
      target_label: confirmToken,
      outcome: 'confirmed',
      message: logMessageFromResult(result),
      delegated_tool: result.delegated_tool,
    })
    await refreshOperatorSnapshot()
    return result
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Operator confirmation failed'
    operatorError.value = message
    appendLog({
      actor,
      action_type: 'confirm',
      target_label: confirmToken,
      outcome: 'error',
      message,
    })
    throw err
  } finally {
    operatorActionBusy.value = false
  }
}
