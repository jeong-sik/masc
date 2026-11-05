import type { LogEntry } from '../api/dashboard-logs'
import {
  LOG_CATEGORIES,
  type LogCategory,
  type LogCategorySelector,
} from '../api/schemas/logs'

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
  return categoryDisplayKind(entry.category)
}

function categoryDisplayKind(category: LogCategory | null): LogDisplayKind {
  switch (category) {
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

/** The route's category selectors for one chip, read back from the same
    projection, so a chip asks the server for exactly the rows it shows. */
export function logKindCategories(kind: LogDisplayKind): readonly LogCategorySelector[] {
  const categories: LogCategorySelector[] = LOG_CATEGORIES.filter(
    category => categoryDisplayKind(category) === kind,
  )
  return categoryDisplayKind(null) === kind ? [...categories, 'uncategorized'] : categories
}
