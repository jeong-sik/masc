// Shared utility functions for Observatory components.
// Extracted to eliminate 8 duplicated definitions across 4+ files.

import { useEffect, useState } from 'preact/hooks'
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

export interface TelemetryMarkerBucket {
  entry: TelemetryEntry
  ts: number
  count: number
}

const DEFAULT_MARKER_BUCKETS = 240

export function useTrackBucketCount(
  trackRef: { current: HTMLDivElement | null },
): number {
  const [bucketCount, setBucketCount] = useState(DEFAULT_MARKER_BUCKETS)

  useEffect(() => {
    const el = trackRef.current
    if (!el) return

    const update = () => {
      const width = Math.max(1, Math.floor(el.clientWidth))
      setBucketCount(Math.max(48, Math.floor(width / 3)))
    }

    update()
    if (typeof ResizeObserver === 'undefined') return

    const ro = new ResizeObserver(() => update())
    ro.observe(el)
    return () => ro.disconnect()
  }, [trackRef])

  return bucketCount
}

export function bucketTelemetryEntries(
  entries: TelemetryEntry[],
  windowStart: number,
  windowEnd: number,
  bucketCount: number,
  predicate?: (entry: TelemetryEntry) => boolean,
): TelemetryMarkerBucket[] {
  const span = windowEnd - windowStart
  if (span <= 0 || bucketCount <= 0) return []

  const buckets = new Map<number, TelemetryMarkerBucket>()

  for (const entry of entries) {
    if (predicate && !predicate(entry)) continue
    const ts = entryTimestampMs(entry)
    if (ts === null || ts < windowStart || ts > windowEnd) continue

    const pct = (ts - windowStart) / span
    const index = Math.min(bucketCount - 1, Math.max(0, Math.floor(pct * bucketCount)))
    const existing = buckets.get(index)
    if (existing) {
      existing.count += 1
      if (ts >= existing.ts) {
        existing.ts = ts
        existing.entry = entry
      }
    } else {
      buckets.set(index, { entry, ts, count: 1 })
    }
  }

  return [...buckets.entries()]
    .sort((left, right) => left[0] - right[0])
    .map(([, bucket]) => bucket)
}
