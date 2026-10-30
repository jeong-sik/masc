// Tool_result.recorded_call_outcome; only for records that carry a tool call's
// disposition or wire outcome (the tool-call log and the tool-usage log).
export type RecordedToolOutcome = 'succeeded' | 'failed' | 'deferred' | 'unsettled' | 'malformed'

export function recordedToolOutcome(row: Record<string, unknown>): RecordedToolOutcome {
  if (Object.hasOwn(row, 'disposition')) {
    switch (row.disposition) {
      case 'completed': return 'succeeded'
      case 'failed': return 'failed'
      case 'deferred': return 'deferred'
      default: return 'malformed'
    }
  }
  if (Object.hasOwn(row, 'wire_outcome')) {
    switch (row.wire_outcome) {
      case 'ok': return 'succeeded'
      case 'error': return 'failed'
      case 'unknown': return 'unsettled'
      default: return 'malformed'
    }
  }
  return 'unsettled'
}

/** The outcome of a telemetry row that stands for one tool call, or null when
 *  it reports none. `tool_call_io` rows (the tool-call log) and `tool_usage`
 *  rows (the tool-usage log) both carry `disposition`, and the first also
 *  `wire_outcome`; neither carries a top-level `success`, so the recorded rule
 *  decides and a leftover boolean decides nothing. A lifecycle marker is not an
 *  invocation and has no outcome. Other producers keep their own boolean
 *  `success` contract. */
export function telemetryToolOutcome(row: Record<string, unknown>): RecordedToolOutcome | null {
  if (row.record_kind === 'lifecycle_event') return null
  if (row.source === 'tool_call_io' || row.source === 'tool_usage') return recordedToolOutcome(row)
  if (typeof row.success === 'boolean') return row.success ? 'succeeded' : 'failed'
  return null
}
