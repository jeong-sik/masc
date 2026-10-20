// Tool_result.recorded_call_outcome; only for records from the tool-call log.
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
 *  its source reports none. A `tool_call_io` row is a tool-call log row, which
 *  carries no top-level `success`, so the recorded rule decides. Other
 *  producers keep their own boolean `success` contract. */
export function telemetryToolOutcome(row: Record<string, unknown>): RecordedToolOutcome | null {
  if (row.source === 'tool_call_io') return recordedToolOutcome(row)
  if (typeof row.success === 'boolean') return row.success ? 'succeeded' : 'failed'
  return null
}
