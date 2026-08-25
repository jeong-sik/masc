import type { LogEntry } from '../api/dashboard-logs'

export type LogDisplayKind =
  | 'tool'
  | 'turn'
  | 'lifecycle'
  | 'approval'
  | 'broadcast'
  | 'log'

export function entryDetails(entry: LogEntry): Record<string, unknown> | null {
  return entry.details
}

export function detailLabel(details: Record<string, unknown> | null, key: string): string | null {
  if (!details) return null
  const value = details[key]
  if (typeof value === 'string' && value.trim() !== '') return value.trim()
  if (typeof value === 'number' && Number.isFinite(value)) return String(value)
  return null
}

/** The chip a row belongs to is a projection of the producer's typed
    category alone: no detail-key sniffing, no turn_id fallback. */
export function logDisplayKind(entry: LogEntry): LogDisplayKind {
  switch (entry.category) {
    case 'tool':
      return 'tool'
    case 'turn':
      return 'turn'
    case 'lifecycle':
    case 'fsm':
    case 'heartbeat':
      return 'lifecycle'
    case 'directive':
    case 'boundary':
      return 'approval'
    case 'broadcast':
      return 'broadcast'
    case 'routine':
    case null:
      return 'log'
  }
}
