// Shared type-safe normalization utilities for unknown API/SSE payloads.
// Single source of truth — all dashboard modules import from here.
//
// Generic coercion helpers live in `lib/json-coerce.ts` so that lib-layer
// modules can reuse them without importing upward into `components/`. This
// module re-exports them for existing component consumers.

import { isRecord, hasNonEmptyStringField } from '../../lib/type-guards'
import { unixSecondsToDate } from '../../lib/format-time'
import { asNullableString } from '../../lib/json-coerce'
export {
  asString,
  asNumber,
  asBoolean,
  asInt,
  asStringArray,
  asRecordArray,
  asNullableString,
  asRecord,
  asStringList,
  extractArray,
} from '../../lib/json-coerce'
export { isRecord, hasNonEmptyStringField }

/**
 * Type predicate for "positive integer that fits in a JS Number safely".
 *
 * `typeof === 'number'` plus `Number.isSafeInteger` plus `>= 1` was the
 * inline check used by `idString`, `positiveLine`, three IDE panels
 * (`ide-context-lens`, `ide-activity-panel`, `ide-shell`), and the run
 * activity store — same three-clause guard written seven times. Named
 * here so the guard rule (positive, integer, safe, ≥ 1) lives in one
 * place and callers benefit from the `value is number` narrowing.
 */
export function isPositiveSafeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 1
}

export function idString(value: unknown): string | undefined {
  const text = asNullableString(value)
  if (text) return text
  return isPositiveSafeInteger(value) ? String(value) : undefined
}

/**
 * Parse a `^[1-9]\d*$` string into a positive safe-integer `number`,
 * returning `undefined` on any non-matching input (empty, sign,
 * leading zero, decimal, non-digit) and on regex-passes-but-not-safe
 * inputs like `'9999999999999999999'` (digit string too long to fit
 * a safe JS integer).
 *
 * Two call sites previously inlined the regex test + parseInt only:
 * `positiveLine` here (string branch) and `ide-shell.routeFocusLine`.
 * The latter additionally guarded the parsed value with
 * `isPositiveSafeInteger`; the former did not, so the unsafe-integer
 * edge case silently returned a non-safe number through `positiveLine`.
 * Centralising the parser closes that gap.
 */
export function parsePositiveLineString(raw: string): number | undefined {
  if (!/^[1-9]\d*$/.test(raw)) return undefined
  const value = Number.parseInt(raw, 10)
  return isPositiveSafeInteger(value) ? value : undefined
}

export function positiveLine(value: unknown): number | undefined {
  if (isPositiveSafeInteger(value)) return value
  if (typeof value !== 'string') return undefined
  return parsePositiveLineString(value.trim())
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
  return unixSecondsToDate(value).toISOString()
}
