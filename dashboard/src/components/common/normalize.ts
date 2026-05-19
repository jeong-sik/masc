// Shared type-safe normalization utilities for unknown API/SSE payloads.
// Single source of truth — all dashboard modules import from here.

import { isRecord } from '../../lib/type-guards'
export { isRecord }

export function asString(value: unknown): string | undefined
export function asString(value: unknown, fallback: string): string
export function asString(value: unknown, fallback?: string): string | undefined {
  if (typeof value === 'string') {
    if (fallback === undefined) {
      const trimmed = value.trim()
      return trimmed !== '' ? trimmed : undefined
    }
    return value
  }
  return fallback ?? undefined
}

export function asNumber(value: unknown): number | undefined
export function asNumber(value: unknown, fallback: number): number
export function asNumber(value: unknown, fallback?: number): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : (fallback ?? undefined)
}

export function asBoolean(value: unknown): boolean | undefined
export function asBoolean(value: unknown, fallback: boolean): boolean
export function asBoolean(value: unknown, fallback?: boolean): boolean | undefined {
  return typeof value === 'boolean' ? value : (fallback ?? undefined)
}

export function asInt(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) return Math.trunc(value)
  if (typeof value !== 'string') return undefined
  const parsed = Number.parseInt(value.trim(), 10)
  return Number.isFinite(parsed) ? parsed : undefined
}

export function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map(item => (typeof item === 'string' ? item.trim() : ''))
    .filter(Boolean)
}

export function asRecordArray(value: unknown): Record<string, unknown>[] {
  if (!Array.isArray(value)) return []
  return value.filter(isRecord)
}

export function asNullableString(value: unknown): string | null {
  return asString(value) ?? null
}

export function asRecord(value: unknown): Record<string, unknown> | null {
  return isRecord(value) ? value : null
}

export function asStringList(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map(item => {
      if (typeof item === 'string') return item.trim()
      if (isRecord(item)) {
        return asString(item.name, '').trim()
          || asString(item.id, '').trim()
          || asString(item.skill, '').trim()
      }
      return ''
    })
    .filter((item): item is string => item.length > 0)
}

export function extractArray(value: unknown, keys: string[] = []): unknown[] {
  if (Array.isArray(value)) return value
  if (!isRecord(value)) return []
  for (const key of keys) {
    const candidate = value[key]
    if (Array.isArray(candidate)) return candidate
  }
  return []
}

export function idString(value: unknown): string | undefined {
  const text = asNullableString(value)
  if (text) return text
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 1
    ? String(value)
    : undefined
}

export function positiveLine(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isSafeInteger(value) && value >= 1) return value
  if (typeof value !== 'string') return undefined
  const trimmed = value.trim()
  return /^[1-9]\d*$/.test(trimmed) ? Number.parseInt(trimmed, 10) : undefined
}

export interface CodeLocation {
  readonly filePath: string
  readonly line?: number
}

export function extractCodeLocation(record: Record<string, unknown> | null): CodeLocation | null {
  if (!record) return null
  const filePath =
    asNullableString(record.file_path)
    ?? asNullableString(record.path)
    ?? asNullableString(record.file)
  if (!filePath) return null
  return {
    filePath,
    line: positiveLine(record.line) ?? positiveLine(record.line_start) ?? positiveLine(record.lineno),
  }
}

export interface MutableRouteContext {
  filePath?: string
  line?: number
  goalId?: string
  taskId?: string
  boardPostId?: string
  commentId?: string
  prId?: string
  gitRef?: string
  logId?: string
  sessionId?: string
  operationId?: string
  workerRunId?: string
}

export function mergeRouteRecord(
  context: MutableRouteContext,
  record: Record<string, unknown> | null,
  overwrite = false,
): void {
  if (!record) return
  const location = extractCodeLocation(record)
  if (location?.filePath && (overwrite || context.filePath === undefined)) context.filePath = location.filePath
  if (location?.line !== undefined && (overwrite || context.line === undefined)) context.line = location.line

  const goalId = idString(record.goal_id)
  if (goalId && (overwrite || context.goalId === undefined)) context.goalId = goalId
  const taskId = idString(record.task_id)
  if (taskId && (overwrite || context.taskId === undefined)) context.taskId = taskId
  const boardPostId = idString(record.board_post_id) ?? idString(record.post_id)
  if (boardPostId && (overwrite || context.boardPostId === undefined)) context.boardPostId = boardPostId
  const commentId = idString(record.comment_id) ?? idString(record.reply_id) ?? idString(record.comment_number)
  if (commentId && (overwrite || context.commentId === undefined)) context.commentId = commentId
  const prId = idString(record.pr_id) ?? idString(record.pull_request) ?? idString(record.pr_number)
  if (prId && (overwrite || context.prId === undefined)) context.prId = prId
  const gitRef = idString(record.git_ref) ?? idString(record.commit) ?? idString(record.branch)
  if (gitRef && (overwrite || context.gitRef === undefined)) context.gitRef = gitRef
  const logId = idString(record.log_id)
  if (logId && (overwrite || context.logId === undefined)) context.logId = logId
  const sessionId = idString(record.session_id)
  if (sessionId && (overwrite || context.sessionId === undefined)) context.sessionId = sessionId
  const operationId = idString(record.operation_id)
  if (operationId && (overwrite || context.operationId === undefined)) context.operationId = operationId
  const workerRunId = idString(record.worker_run_id)
  if (workerRunId && (overwrite || context.workerRunId === undefined)) context.workerRunId = workerRunId
}

export function hasRouteContext(context: MutableRouteContext): boolean {
  return context.filePath !== undefined
    || context.goalId !== undefined
    || context.taskId !== undefined
    || context.boardPostId !== undefined
    || context.commentId !== undefined
    || context.prId !== undefined
    || context.gitRef !== undefined
    || context.logId !== undefined
    || context.sessionId !== undefined
    || context.operationId !== undefined
    || context.workerRunId !== undefined
}

export function toIsoTimestamp(value: unknown): string | undefined {
  if (typeof value === 'string' && value.trim() !== '') return value
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return undefined
  return new Date(value * 1000).toISOString()
}
