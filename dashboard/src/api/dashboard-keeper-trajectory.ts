// MASC Dashboard — closed keeper trajectory codec.

import { isRecord, asNumber } from '../components/common/normalize'
import { get } from './core'

export type TrajectoryInvalidReasons = {
  missing_required_field: number
  invalid_field: number
  unexpected_field: number
  duplicate_field: number
  unsupported_row_type: number
  malformed_json: number
}

export type TrajectoryReadError = { path: string; message: string }

export type TrajectoryToolEntry = {
  type?: undefined
  ts: number
  ts_iso: string
  turn: number
  execution_id?: string
  round: number
  tool_name: string
  args: Record<string, unknown>
  result: string | null
  duration_ms: number
  error: string | null
}

export type TrajectoryThinkingEntry = {
  type: 'thinking'
  ts: number
  ts_iso: string
  turn: number
  content: string
  content_length: number
  redacted: boolean
}

export type TrajectoryEntry = TrajectoryToolEntry | TrajectoryThinkingEntry

export type TrajectoryLineDecode = {
  tool_call_count: number
  thinking_count: number
  skipped_summary_count: number
  invalid_line_count: number
  invalid_reasons: TrajectoryInvalidReasons
}

export type TrajectoryResponse = {
  keeper: string
  trace_id: string
  generation: number
  total_entries: number
  total_entries_scope: 'tail'
  total_entries_exact: false
  tail_scan_lines: number
  showing: number
  decode: TrajectoryLineDecode
  io_errors: TrajectoryReadError[]
  entries: TrajectoryEntry[]
}

export function decodeTrajectoryExactString(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

export function decodeTrajectoryNonBlankString(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value : null
}

export function decodeTrajectoryCount(value: unknown): number | null {
  const decoded = asNumber(value)
  return decoded !== undefined && Number.isSafeInteger(decoded) && decoded >= 0
    ? decoded
    : null
}

export function decodeTrajectoryInvalidReasons(raw: unknown): TrajectoryInvalidReasons | null {
  if (!isRecord(raw)) return null
  const missingRequiredField = decodeTrajectoryCount(raw.missing_required_field)
  const invalidField = decodeTrajectoryCount(raw.invalid_field)
  const unexpectedField = decodeTrajectoryCount(raw.unexpected_field)
  const duplicateField = decodeTrajectoryCount(raw.duplicate_field)
  const unsupportedRowType = decodeTrajectoryCount(raw.unsupported_row_type)
  const malformedJson = decodeTrajectoryCount(raw.malformed_json)
  if (
    missingRequiredField === null
    || invalidField === null
    || unexpectedField === null
    || duplicateField === null
    || unsupportedRowType === null
    || malformedJson === null
  ) return null
  return {
    missing_required_field: missingRequiredField,
    invalid_field: invalidField,
    unexpected_field: unexpectedField,
    duplicate_field: duplicateField,
    unsupported_row_type: unsupportedRowType,
    malformed_json: malformedJson,
  }
}

export function trajectoryInvalidReasonCount(reasons: TrajectoryInvalidReasons): number {
  return Object.values(reasons).reduce((sum, count) => sum + count, 0)
}

export function decodeTrajectoryReadErrors(raw: unknown): TrajectoryReadError[] | null {
  if (!Array.isArray(raw)) return null
  const errors: TrajectoryReadError[] = []
  for (const item of raw) {
    if (!isRecord(item)) return null
    const path = decodeTrajectoryNonBlankString(item.path)
    const message = decodeTrajectoryNonBlankString(item.message)
    if (path === null || message === null) return null
    errors.push({ path, message })
  }
  return errors
}

function decodeFiniteNumber(value: unknown): number | null {
  const decoded = asNumber(value)
  return decoded !== undefined && Number.isFinite(decoded) ? decoded : null
}

function decodeNullableString(value: unknown): string | null | undefined {
  if (value === null) return null
  const decoded = decodeTrajectoryExactString(value)
  return decoded === null ? undefined : decoded
}

const TOOL_ENTRY_KEYS = new Set([
  'ts', 'ts_iso', 'turn', 'round', 'tool_name', 'args', 'result',
  'duration_ms', 'error', 'execution_id',
])
const THINKING_ENTRY_KEYS = new Set([
  'type', 'ts', 'ts_iso', 'turn', 'content', 'content_length', 'redacted',
])

function hasOnlyKeys(raw: Record<string, unknown>, allowed: ReadonlySet<string>): boolean {
  return Object.keys(raw).every(key => allowed.has(key))
}

function decodeToolEntry(raw: Record<string, unknown>): TrajectoryToolEntry | null {
  if (raw.type !== undefined || !hasOnlyKeys(raw, TOOL_ENTRY_KEYS)) return null
  const ts = decodeFiniteNumber(raw.ts)
  const tsIso = decodeTrajectoryNonBlankString(raw.ts_iso)
  const turn = decodeTrajectoryCount(raw.turn)
  const round = decodeTrajectoryCount(raw.round)
  const toolName = decodeTrajectoryNonBlankString(raw.tool_name)
  const args = isRecord(raw.args) ? raw.args : null
  const result = decodeNullableString(raw.result)
  const durationMs = decodeTrajectoryCount(raw.duration_ms)
  const error = decodeNullableString(raw.error)
  const executionId = raw.execution_id === undefined
    ? undefined
    : decodeTrajectoryNonBlankString(raw.execution_id)
  if (
    ts === null
    || tsIso === null
    || turn === null
    || round === null
    || toolName === null
    || args === null
    || result === undefined
    || durationMs === null
    || error === undefined
    || (raw.execution_id !== undefined && executionId === null)
  ) return null
  return {
    ts,
    ts_iso: tsIso,
    turn,
    round,
    tool_name: toolName,
    args,
    result,
    duration_ms: durationMs,
    error,
    ...(typeof executionId === 'string' ? { execution_id: executionId } : {}),
  }
}

function decodeThinkingEntry(raw: Record<string, unknown>): TrajectoryThinkingEntry | null {
  if (raw.type !== 'thinking' || !hasOnlyKeys(raw, THINKING_ENTRY_KEYS)) return null
  const ts = decodeFiniteNumber(raw.ts)
  const tsIso = decodeTrajectoryNonBlankString(raw.ts_iso)
  const turn = decodeTrajectoryCount(raw.turn)
  const content = decodeTrajectoryExactString(raw.content)
  const contentLength = decodeTrajectoryCount(raw.content_length)
  if (
    ts === null
    || tsIso === null
    || turn === null
    || content === null
    || contentLength === null
    || typeof raw.redacted !== 'boolean'
  ) return null
  return {
    type: 'thinking',
    ts,
    ts_iso: tsIso,
    turn,
    content,
    content_length: contentLength,
    redacted: raw.redacted,
  }
}

function decodeTrajectoryEntry(raw: unknown): TrajectoryEntry | null {
  if (!isRecord(raw)) return null
  return raw.type === 'thinking' ? decodeThinkingEntry(raw) : decodeToolEntry(raw)
}

function decodeLineDecode(raw: unknown): TrajectoryLineDecode | null {
  if (!isRecord(raw)) return null
  const toolCallCount = decodeTrajectoryCount(raw.tool_call_count)
  const thinkingCount = decodeTrajectoryCount(raw.thinking_count)
  const skippedSummaryCount = decodeTrajectoryCount(raw.skipped_summary_count)
  const invalidLineCount = decodeTrajectoryCount(raw.invalid_line_count)
  const invalidReasons = decodeTrajectoryInvalidReasons(raw.invalid_reasons)
  if (
    toolCallCount === null
    || thinkingCount === null
    || skippedSummaryCount === null
    || invalidLineCount === null
    || invalidReasons === null
    || trajectoryInvalidReasonCount(invalidReasons) !== invalidLineCount
  ) return null
  return {
    tool_call_count: toolCallCount,
    thinking_count: thinkingCount,
    skipped_summary_count: skippedSummaryCount,
    invalid_line_count: invalidLineCount,
    invalid_reasons: invalidReasons,
  }
}

function decodeTrajectoryResponse(raw: unknown): TrajectoryResponse | null {
  if (!isRecord(raw) || !Array.isArray(raw.entries)) return null
  const keeper = decodeTrajectoryNonBlankString(raw.keeper)
  const traceId = decodeTrajectoryNonBlankString(raw.trace_id)
  const generation = decodeTrajectoryCount(raw.generation)
  const totalEntries = decodeTrajectoryCount(raw.total_entries)
  const tailScanLines = decodeTrajectoryCount(raw.tail_scan_lines)
  const showing = decodeTrajectoryCount(raw.showing)
  const decode = decodeLineDecode(raw.decode)
  const ioErrors = decodeTrajectoryReadErrors(raw.io_errors)
  if (
    keeper === null
    || traceId === null
    || generation === null
    || totalEntries === null
    || raw.total_entries_scope !== 'tail'
    || raw.total_entries_exact !== false
    || tailScanLines === null
    || showing === null
    || showing > totalEntries
    || decode === null
    || ioErrors === null
  ) return null
  const entries: TrajectoryEntry[] = []
  for (const item of raw.entries) {
    const entry = decodeTrajectoryEntry(item)
    if (entry === null) return null
    entries.push(entry)
  }
  if (entries.length !== showing) return null
  return {
    keeper,
    trace_id: traceId,
    generation,
    total_entries: totalEntries,
    total_entries_scope: 'tail',
    total_entries_exact: false,
    tail_scan_lines: tailScanLines,
    showing,
    decode,
    io_errors: ioErrors,
    entries,
  }
}

export function fetchKeeperTrajectory(
  name: string,
  limit?: number,
  fullOutput = false,
): Promise<TrajectoryResponse> {
  const params = new URLSearchParams()
  if (limit != null) params.set('limit', String(limit))
  if (fullOutput) {
    params.set('result_max_len', '0')
    params.set('content_max_len', '0')
  }
  const qs = params.toString()
  return get<unknown>(
    `/api/v1/keepers/${encodeURIComponent(name)}/trajectory${qs ? `?${qs}` : ''}`,
  ).then((raw) => {
    const decoded = decodeTrajectoryResponse(raw)
    if (decoded === null) throw new Error('유효하지 않은 keeper trajectory payload')
    return decoded
  })
}
