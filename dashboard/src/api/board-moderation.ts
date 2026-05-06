import { get, post, withRetries } from './core'
import {
  asBoolean,
  asInt,
  asNullableString,
  asNumber,
  asString,
  isRecord,
  toIsoTimestamp,
} from '../components/common/normalize'

const MODERATION_QUEUE_PATH = '/api/v1/dashboard/board/moderation/queue'
const MODERATION_FLAG_PATH = '/api/v1/dashboard/board/moderation/flag'
const MODERATION_ACTION_PATH = '/api/v1/dashboard/board/moderation/action'
const VALID_TARGET_KINDS = ['post', 'comment'] as const
const VALID_ACTION_KINDS = ['approve', 'remove', 'hide', 'warn'] as const
const VALID_REASON_HINT = 'spam, harassment, off_topic, policy:<non-empty>'

export type BoardModerationTargetKind = 'post' | 'comment'
export type BoardModerationFlagReason =
  | 'spam'
  | 'harassment'
  | 'off_topic'
  | `policy:${string}`
export type BoardModerationActionKind = 'approve' | 'remove' | 'hide' | 'warn'

export interface BoardModerationQueueEntry {
  entry_id: string
  target_kind: BoardModerationTargetKind
  target_id: string
  reporter: string
  reason: BoardModerationFlagReason
  flagged_at: number
  flagged_at_iso: string | null
  resolved: boolean
}

export interface BoardModerationAuditEntry {
  audit_id: string
  target_kind: BoardModerationTargetKind
  target_id: string
  actor: string
  action: BoardModerationActionKind
  reason: BoardModerationFlagReason | null
  note: string | null
  acted_at: number
  acted_at_iso: string | null
}

export interface BoardModerationQueue {
  entries: BoardModerationQueueEntry[]
  count: number
}

export interface BoardModerationActionResult {
  entry: BoardModerationAuditEntry
  delete_warning: string | null
}

function trimNonEmpty(value: string | null | undefined): string | null {
  const trimmed = value?.trim() ?? ''
  return trimmed ? trimmed : null
}

function describeInvalid(value: unknown): string {
  if (typeof value === 'string') return value.trim() || '<blank>'
  if (value === undefined) return '<undefined>'
  if (value === null) return '<null>'
  return String(value)
}

function normalizeTargetKind(value: unknown): BoardModerationTargetKind | null {
  const kind = asString(value, '').trim()
  if (kind === 'post' || kind === 'comment') return kind
  return null
}

function requireTargetKind(value: unknown): BoardModerationTargetKind {
  const kind = normalizeTargetKind(value)
  if (kind) return kind
  throw new Error(
    `unknown board moderation target_kind: ${describeInvalid(value)}; valid: ${VALID_TARGET_KINDS.join(', ')}`,
  )
}

function normalizeFlagReason(value: unknown): BoardModerationFlagReason | null {
  const reason = asString(value, '').trim()
  if (reason === 'spam' || reason === 'harassment' || reason === 'off_topic') {
    return reason
  }
  if (reason.startsWith('policy:') && reason.length > 'policy:'.length) {
    return reason as `policy:${string}`
  }
  return null
}

function normalizeActionKind(value: unknown): BoardModerationActionKind | null {
  const action = asString(value, '').trim()
  if (action === 'approve' || action === 'remove' || action === 'hide' || action === 'warn') {
    return action
  }
  return null
}

function requiredTimestamp(value: unknown): number | null {
  const timestamp = asNumber(value)
  return timestamp === undefined ? null : timestamp
}

export function normalizeBoardModerationQueueEntry(raw: unknown): BoardModerationQueueEntry | null {
  if (!isRecord(raw)) return null
  const entryId = asString(raw.entry_id, '').trim()
  const targetKind = normalizeTargetKind(raw.target_kind)
  const targetId = asString(raw.target_id, '').trim()
  const reporter = asString(raw.reporter, '').trim()
  const reason = normalizeFlagReason(raw.reason)
  const flaggedAt = requiredTimestamp(raw.flagged_at)
  if (!entryId || !targetKind || !targetId || !reporter || !reason || flaggedAt === null) {
    return null
  }
  return {
    entry_id: entryId,
    target_kind: targetKind,
    target_id: targetId,
    reporter,
    reason,
    flagged_at: flaggedAt,
    flagged_at_iso: toIsoTimestamp(flaggedAt) ?? null,
    resolved: asBoolean(raw.resolved, false),
  }
}

export function normalizeBoardModerationAuditEntry(raw: unknown): BoardModerationAuditEntry | null {
  if (!isRecord(raw)) return null
  const auditId = asString(raw.audit_id, '').trim()
  const targetKind = normalizeTargetKind(raw.target_kind)
  const targetId = asString(raw.target_id, '').trim()
  const actor = asString(raw.actor, '').trim()
  const action = normalizeActionKind(raw.action)
  const actedAt = requiredTimestamp(raw.acted_at)
  if (!auditId || !targetKind || !targetId || !actor || !action || actedAt === null) {
    return null
  }
  return {
    audit_id: auditId,
    target_kind: targetKind,
    target_id: targetId,
    actor,
    action,
    reason: normalizeFlagReason(raw.reason),
    note: asNullableString(raw.note),
    acted_at: actedAt,
    acted_at_iso: toIsoTimestamp(actedAt) ?? null,
  }
}

export async function fetchBoardModerationQueue(
  options: { resolved?: boolean } = {},
): Promise<BoardModerationQueue> {
  return withRetries('fetchBoardModerationQueue', async () => {
    const params = new URLSearchParams()
    if (typeof options.resolved === 'boolean') {
      params.set('resolved', options.resolved ? 'true' : 'false')
    }
    const qs = params.toString()
    const raw = await get<unknown>(`${MODERATION_QUEUE_PATH}${qs ? `?${qs}` : ''}`)
    if (!isRecord(raw)) return { entries: [], count: 0 }
    const entries = Array.isArray(raw.entries)
      ? raw.entries
          .map(normalizeBoardModerationQueueEntry)
          .filter((row): row is BoardModerationQueueEntry => row !== null)
      : []
    return {
      entries,
      count: asInt(raw.count) ?? entries.length,
    }
  })
}

export async function flagBoardModerationTarget(args: {
  target_kind?: BoardModerationTargetKind
  target_id: string
  reporter?: string
  reason?: BoardModerationFlagReason
}): Promise<BoardModerationQueueEntry> {
  const targetId = trimNonEmpty(args.target_id)
  if (!targetId) throw new Error('target_id is required')
  const targetKind = args.target_kind === undefined ? 'post' : requireTargetKind(args.target_kind)
  const reason = args.reason === undefined ? 'spam' : normalizeFlagReason(args.reason)
  if (!reason) {
    throw new Error(
      `unknown board moderation reason: ${describeInvalid(args.reason)}; valid: ${VALID_REASON_HINT}`,
    )
  }
  const reporter = trimNonEmpty(args.reporter)

  const body: Record<string, string> = {
    target_kind: targetKind,
    target_id: targetId,
    reason,
  }
  if (reporter) body.reporter = reporter

  const raw = await post<unknown>(MODERATION_FLAG_PATH, body)
  const entry = isRecord(raw) ? normalizeBoardModerationQueueEntry(raw.entry) : null
  if (!entry) {
    throw new Error('Malformed board moderation flag response')
  }
  return entry
}

export async function submitBoardModerationAction(args: {
  target_kind?: BoardModerationTargetKind
  target_id: string
  action: BoardModerationActionKind
  actor?: string
  reason?: BoardModerationFlagReason
  note?: string
}): Promise<BoardModerationActionResult> {
  const targetId = trimNonEmpty(args.target_id)
  if (!targetId) throw new Error('target_id is required')
  const targetKind = args.target_kind === undefined ? 'post' : requireTargetKind(args.target_kind)
  const action = normalizeActionKind(args.action)
  if (!action) {
    throw new Error(
      `unknown board moderation action: ${describeInvalid(args.action)}; valid: ${VALID_ACTION_KINDS.join(', ')}`,
    )
  }
  const reason = args.reason === undefined ? null : normalizeFlagReason(args.reason)
  if (args.reason !== undefined && !reason) {
    throw new Error(
      `unknown board moderation reason: ${describeInvalid(args.reason)}; valid: ${VALID_REASON_HINT}`,
    )
  }

  const body: Record<string, string> = {
    target_kind: targetKind,
    target_id: targetId,
    action,
  }
  const actor = trimNonEmpty(args.actor)
  const note = trimNonEmpty(args.note)
  if (actor) body.actor = actor
  if (reason) body.reason = reason
  if (note) body.note = note

  const raw = await post<unknown>(MODERATION_ACTION_PATH, body)
  const entry = isRecord(raw) ? normalizeBoardModerationAuditEntry(raw.entry) : null
  if (!entry) {
    throw new Error('Malformed board moderation action response')
  }
  return {
    entry,
    delete_warning: isRecord(raw) ? asNullableString(raw.delete_warning) : null,
  }
}
