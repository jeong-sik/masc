// MASC Dashboard — keeper tool call log (full I/O).
// Extracted from dashboard.ts. Public symbols re-exported from dashboard.ts.

import { isRecord, asBoolean, asNumber, asRecordArray, asString } from '../components/common/normalize'
import { get, type AbortableRequestOptions } from './core'
import { decodeTelemetryFreshnessMetadata, type TelemetryFreshnessMetadata } from './dashboard-shared'

// Output is either an inline string (legacy / small payload) or a
// normalized blob descriptor — see lib/keeper_tool_call_log.ml
// `blob_aware_output_json`. The renderer must accept both shapes.
export type ToolCallOutputBlob = {
  _blob: {
    sha256: string
    bytes: number
    mime: string
    preview: string
  }
}

export type ToolCallEntry = {
  ts: number
  keeper: string
  tool: string
  input: unknown
  output: string | ToolCallOutputBlob
  success: boolean
  duration_ms: number | null
  model?: string
  trace_id?: string
  session_id?: string
  turn?: number
  keeper_turn_id?: number
  task_id?: string
  lane?: string
  // RFC-0233: canonical execution identity minted at dispatch (absent on pre-PR-1 rows)
  execution_id?: string
  // RFC-0233 PR-2: provider call id (oas-event join key). Equals the chat tool
  // row's tool_call_id for the same execution, so the chat ToolCallBubble can
  // join this entry's output onto the transcript. Absent when the call carried
  // no provider id (synthesised tc-<position> rows) or on pre-PR-2 logs.
  tool_use_id?: string
}

export type ToolCallsResponse = TelemetryFreshnessMetadata & {
  keeper: string
  count: number
  entries: ToolCallEntry[]
}

function decodeToolCallOutput(raw: unknown): string | ToolCallOutputBlob {
  if (typeof raw === 'string') return raw
  if (
    isRecord(raw) &&
    isRecord(raw._blob) &&
    typeof raw._blob.sha256 === 'string' &&
    typeof raw._blob.bytes === 'number' &&
    typeof raw._blob.mime === 'string' &&
    typeof raw._blob.preview === 'string'
  ) {
    return {
      _blob: {
        sha256: raw._blob.sha256,
        bytes: raw._blob.bytes,
        mime: raw._blob.mime,
        preview: raw._blob.preview,
      },
    }
  }
  return ''
}

function decodeToolCallEntry(raw: unknown): ToolCallEntry | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  const tool = asString(raw.tool)
  if (!keeper || !tool) return null
  return {
    ts: asNumber(raw.ts, 0),
    keeper,
    tool,
    input: raw.input,
    output: decodeToolCallOutput(raw.output),
    success: asBoolean(raw.success, false),
    duration_ms: asNumber(raw.duration_ms) ?? null,
    model: asString(raw.model),
    trace_id: asString(raw.trace_id),
    session_id: asString(raw.session_id),
    turn: asNumber(raw.turn),
    keeper_turn_id: asNumber(raw.keeper_turn_id),
    task_id: asString(raw.task_id),
    lane: asString(raw.lane),
    execution_id: asString(raw.execution_id),
    tool_use_id: asString(raw.tool_use_id),
  }
}

function decodeToolCallsResponse(raw: unknown): ToolCallsResponse | null {
  if (!isRecord(raw)) return null
  const keeper = asString(raw.keeper)
  if (!keeper) return null
  return {
    ...decodeTelemetryFreshnessMetadata(raw),
    keeper,
    count: asNumber(raw.count, 0),
    entries: asRecordArray(raw.entries)
      .map(decodeToolCallEntry)
      .filter((entry): entry is ToolCallEntry => entry !== null),
  }
}

export function fetchKeeperToolCalls(
  name: string,
  limit?: number,
  opts?: AbortableRequestOptions,
): Promise<ToolCallsResponse> {
  const params = limit != null ? `?limit=${limit}` : ''
  return get<Record<string, unknown>>(
    `/api/v1/keepers/${encodeURIComponent(name)}/tool-calls${params}`,
    { signal: opts?.signal },
  ).then((raw) => {
    const decoded = decodeToolCallsResponse(raw)
    if (!decoded) throw new Error('유효하지 않은 keeper tool call payload')
    return decoded
  })
}
