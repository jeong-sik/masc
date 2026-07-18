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

export type TrajectoryToolOutcome =
  | { status: 'succeeded'; output: string }
  | { status: 'failed'; error: string }

export type TrajectoryToolEntry = {
  type?: undefined
  ts: number
  ts_iso: string
  turn: number
  execution_id: string
  round: number
  tool_name: string
  args: Record<string, unknown>
  outcome: TrajectoryToolOutcome
  duration_ms: number
}

export type TrajectoryThinkingEntry = {
  type: 'thinking'
  ts: number
  ts_iso: string
  turn: number
  block_index: number
  block: TrajectoryThinkingBlock
}

export type TrajectoryThinkingBlock =
  | { type: 'thinking'; thinking: string; signature?: string }
  | { type: 'reasoning_details'; reasoning_content?: string; details: unknown[] }
  | { type: 'redacted_thinking'; data: string }

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
  if (!isRecord(raw) || !hasOnlyKeys(raw, INVALID_REASON_KEYS)) return null
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
    if (!isRecord(item) || !hasOnlyKeys(item, READ_ERROR_KEYS)) return null
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

const TOOL_ENTRY_KEYS = new Set([
  'ts', 'ts_iso', 'turn', 'round', 'tool_name', 'args', 'outcome',
  'duration_ms', 'execution_id',
])
const THINKING_ENTRY_KEYS = new Set([
  'type', 'ts', 'ts_iso', 'turn', 'block_index', 'block',
])
const INVALID_REASON_KEYS = new Set([
  'missing_required_field', 'invalid_field', 'unexpected_field',
  'duplicate_field', 'unsupported_row_type', 'malformed_json',
])
const READ_ERROR_KEYS = new Set(['path', 'message'])
const LINE_DECODE_KEYS = new Set([
  'tool_call_count', 'thinking_count', 'skipped_summary_count',
  'invalid_line_count', 'invalid_reasons',
])
const TRAJECTORY_RESPONSE_KEYS = new Set([
  'keeper', 'trace_id', 'generation', 'total_entries', 'total_entries_scope',
  'total_entries_exact', 'tail_scan_lines', 'showing', 'decode', 'io_errors',
  'entries',
])
const SUCCEEDED_OUTCOME_KEYS = new Set(['status', 'output'])
const FAILED_OUTCOME_KEYS = new Set(['status', 'error'])
const THINKING_BLOCK_KEYS = new Set(['type', 'thinking', 'signature'])
const REASONING_DETAILS_BLOCK_KEYS = new Set(['type', 'reasoning_content', 'details'])
const REDACTED_THINKING_BLOCK_KEYS = new Set(['type', 'data'])

function hasOnlyKeys(raw: Record<string, unknown>, allowed: ReadonlySet<string>): boolean {
  return Object.keys(raw).every(key => allowed.has(key))
}

function decodeToolOutcome(raw: unknown): TrajectoryToolOutcome | null {
  if (!isRecord(raw)) return null
  if (raw.status === 'succeeded' && hasOnlyKeys(raw, SUCCEEDED_OUTCOME_KEYS)) {
    const output = decodeTrajectoryExactString(raw.output)
    return output === null ? null : { status: 'succeeded', output }
  }
  if (raw.status === 'failed' && hasOnlyKeys(raw, FAILED_OUTCOME_KEYS)) {
    const error = decodeTrajectoryNonBlankString(raw.error)
    return error === null ? null : { status: 'failed', error }
  }
  return null
}

function decodeThinkingBlock(raw: unknown): TrajectoryThinkingBlock | null {
  if (!isRecord(raw)) return null
  if (raw.type === 'thinking' && hasOnlyKeys(raw, THINKING_BLOCK_KEYS)) {
    const thinking = decodeTrajectoryExactString(raw.thinking)
    if (thinking === null) return null
    if (raw.signature === undefined) return { type: 'thinking', thinking }
    const signature = decodeTrajectoryExactString(raw.signature)
    return signature === null ? null : { type: 'thinking', thinking, signature }
  }
  if (
    raw.type === 'reasoning_details'
    && hasOnlyKeys(raw, REASONING_DETAILS_BLOCK_KEYS)
    && Array.isArray(raw.details)
  ) {
    if (raw.reasoning_content === undefined) {
      return { type: 'reasoning_details', details: raw.details }
    }
    const reasoningContent = decodeTrajectoryExactString(raw.reasoning_content)
    return reasoningContent === null
      ? null
      : { type: 'reasoning_details', reasoning_content: reasoningContent, details: raw.details }
  }
  if (raw.type === 'redacted_thinking' && hasOnlyKeys(raw, REDACTED_THINKING_BLOCK_KEYS)) {
    const data = decodeTrajectoryExactString(raw.data)
    return data === null ? null : { type: 'redacted_thinking', data }
  }
  return null
}

function decodeToolEntry(raw: Record<string, unknown>): TrajectoryToolEntry | null {
  if (raw.type !== undefined || !hasOnlyKeys(raw, TOOL_ENTRY_KEYS)) return null
  const ts = decodeFiniteNumber(raw.ts)
  const tsIso = decodeTrajectoryNonBlankString(raw.ts_iso)
  const turn = decodeTrajectoryCount(raw.turn)
  const round = decodeTrajectoryCount(raw.round)
  const toolName = decodeTrajectoryNonBlankString(raw.tool_name)
  const args = isRecord(raw.args) ? raw.args : null
  const outcome = decodeToolOutcome(raw.outcome)
  const durationMs = decodeTrajectoryCount(raw.duration_ms)
  const executionId = decodeTrajectoryNonBlankString(raw.execution_id)
  if (
    ts === null
    || tsIso === null
    || turn === null
    || round === null
    || toolName === null
    || args === null
    || outcome === null
    || durationMs === null
    || executionId === null
  ) return null
  return {
    ts,
    ts_iso: tsIso,
    turn,
    round,
    tool_name: toolName,
    args,
    outcome,
    duration_ms: durationMs,
    execution_id: executionId,
  }
}

function decodeThinkingEntry(raw: Record<string, unknown>): TrajectoryThinkingEntry | null {
  if (raw.type !== 'thinking' || !hasOnlyKeys(raw, THINKING_ENTRY_KEYS)) return null
  const ts = decodeFiniteNumber(raw.ts)
  const tsIso = decodeTrajectoryNonBlankString(raw.ts_iso)
  const turn = decodeTrajectoryCount(raw.turn)
  const blockIndex = decodeTrajectoryCount(raw.block_index)
  const block = decodeThinkingBlock(raw.block)
  if (
    ts === null
    || tsIso === null
    || turn === null
    || blockIndex === null
    || block === null
  ) return null
  return {
    type: 'thinking',
    ts,
    ts_iso: tsIso,
    turn,
    block_index: blockIndex,
    block,
  }
}

function decodeTrajectoryEntry(raw: unknown): TrajectoryEntry | null {
  if (!isRecord(raw)) return null
  return raw.type === 'thinking' ? decodeThinkingEntry(raw) : decodeToolEntry(raw)
}

function decodeLineDecode(raw: unknown): TrajectoryLineDecode | null {
  if (!isRecord(raw) || !hasOnlyKeys(raw, LINE_DECODE_KEYS)) return null
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
  if (
    !isRecord(raw)
    || !hasOnlyKeys(raw, TRAJECTORY_RESPONSE_KEYS)
    || !Array.isArray(raw.entries)
  ) return null
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
  const decodedToolCallCount = entries.filter(entry => entry.type !== 'thinking').length
  const decodedThinkingCount = entries.length - decodedToolCallCount
  if (
    entries.length !== showing
    || decode.tool_call_count !== decodedToolCallCount
    || decode.thinking_count !== decodedThinkingCount
  ) return null
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
): Promise<TrajectoryResponse> {
  const params = new URLSearchParams()
  if (limit != null) params.set('limit', String(limit))
  const qs = params.toString()
  return get<unknown>(
    `/api/v1/keepers/${encodeURIComponent(name)}/trajectory${qs ? `?${qs}` : ''}`,
  ).then((raw) => {
    const decoded = decodeTrajectoryResponse(raw)
    if (decoded === null) throw new Error('유효하지 않은 keeper trajectory payload')
    return decoded
  })
}
