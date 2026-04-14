// Shared utility functions for Observatory components.
// Extracted to eliminate 8 duplicated definitions across 4+ files.

import type { TelemetryEntry } from '../../api/dashboard'

export function entryTimestampMs(entry: TelemetryEntry): number | null {
  if (typeof entry.ts === 'number') return entry.ts * 1000
  if (typeof entry.ts_unix === 'number') return entry.ts_unix * 1000
  if (typeof entry.timestamp === 'number') return entry.timestamp
  if (typeof entry.ts_iso === 'string') {
    const parsed = Date.parse(entry.ts_iso)
    return Number.isNaN(parsed) ? null : parsed
  }
  return null
}

export function hourToMs(hour: string): number | null {
  const parsed = Date.parse(hour.includes('T') ? hour : `${hour}:00:00Z`)
  return Number.isNaN(parsed) ? null : parsed
}

export function isToolCall(entry: TelemetryEntry): boolean {
  const src = typeof entry.source === 'string' ? entry.source : ''
  return src === 'tool_call_io' || src === 'tool_usage'
}
