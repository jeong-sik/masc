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
