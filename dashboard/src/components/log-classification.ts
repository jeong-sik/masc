import type { LogEntry } from '../api/dashboard.js'

export type LogDisplayKind =
  | 'tool'
  | 'turn'
  | 'lifecycle'
  | 'approval'
  | 'broadcast'
  | 'telemetry'
  | 'task'
  | 'log'

export function entryDetails(entry: LogEntry): Record<string, unknown> | null {
  const details = entry.details
  if (!details || typeof details !== 'object' || Array.isArray(details)) return null
  return details
}

export function detailLabel(details: Record<string, unknown> | null, key: string): string | null {
  if (!details) return null
  const value = details[key]
  if (typeof value === 'string' && value.trim() !== '') return value.trim()
  if (typeof value === 'number' && Number.isFinite(value)) return String(value)
  return null
}

export function logDisplayKind(entry: LogEntry): LogDisplayKind {
  const details = entryDetails(entry)
  const toolName = detailLabel(details, 'tool_name') ?? detailLabel(details, 'tool')
  if (toolName) return 'tool'
  switch (entry.category) {
    case 'tool':
      return 'tool'
    case 'task':
      return 'task'
    case 'lifecycle':
    case 'fsm':
    case 'heartbeat':
    case 'presence':
      return 'lifecycle'
    case 'directive':
    case 'boundary':
      return 'approval'
    case 'telemetry':
    case 'memory':
      return 'telemetry'
    case 'routine':
      return entry.turn_id ? 'turn' : 'log'
    default:
      return entry.turn_id ? 'turn' : 'log'
  }
}
