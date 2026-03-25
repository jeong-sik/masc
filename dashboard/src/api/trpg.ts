// Parse utilities for unknown API/SSE payloads (with default fallback values).
// Kept here for backward compatibility — imported by dashboard.ts, actions.ts, board.ts.

import { isRecord } from '../components/common/normalize'

export function asString(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback
}

export function asNumber(value: unknown, fallback = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

export function asInt(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) return Math.trunc(value)
  if (typeof value !== 'string') return undefined
  const parsed = Number.parseInt(value.trim(), 10)
  return Number.isFinite(parsed) ? parsed : undefined
}

export function asStringList(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map(item => {
      if (typeof item === 'string') return item.trim()
      if (isRecord(item)) {
        return asString(item.name, '').trim()
          || asString(item.id, '').trim()
          || asString(item.skill, '').trim()
      }
      return ''
    })
    .filter((item): item is string => item.length > 0)
}
