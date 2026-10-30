// Shared utility functions for Observatory components.
// Extracted to eliminate 8 duplicated definitions across 4+ files.

import { useEffect, useState } from 'preact/hooks'
import type { TelemetryEntry } from '../../api/dashboard'
import { telemetryToolOutcome, type RecordedToolOutcome } from '../../lib/recorded-tool-outcome'

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

/** tool-quality's hourly_trend buckets arrive as "2026-08-18T07" — hour precision,
    no minutes. The shortest date-time ECMAScript parses is YYYY-MM-DDTHH:mm, so
    that string yields NaN and every point is dropped downstream. Fill the missing
    minutes and seconds; anything already complete is passed through. */
export function hourToMs(hour: string): number | null {
  const parsed = Date.parse(/T\d{2}$/.test(hour) ? `${hour}:00:00Z` : hour)
  return Number.isNaN(parsed) ? null : parsed
}

/** A tool invocation row. The tool-call log also holds lifecycle markers, which
 *  are not invocations; the server leaves them out of its quality denominator
 *  (lib/dashboard/dashboard_http_tool_quality.ml), so this does too. */
export function isToolCall(entry: TelemetryEntry): boolean {
  const src = typeof entry.source === 'string' ? entry.source : ''
  if (entry.record_kind === 'lifecycle_event') return false
  return src === 'tool_call_io' || src === 'tool_usage'
}

/** The tool a call row names: `tool` on tool-call log rows, `tool_name` on
 *  tool-usage rows. */
export function toolCallName(entry: TelemetryEntry): string {
  if (typeof entry.tool === 'string') return entry.tool
  if (typeof entry.tool_name === 'string') return entry.tool_name
  if (typeof entry.name === 'string') return entry.name
  return '?'
}

/** The recorded outcome of a tool-call telemetry row, or null when it has none. */
export function toolCallOutcome(entry: TelemetryEntry): RecordedToolOutcome | null {
  return telemetryToolOutcome(entry)
}

// Every outcome is named, so a new one fails typecheck here instead of
// silently counting as "not a failure".
const OUTCOME_IS_FAILURE: Record<RecordedToolOutcome, boolean> = {
  succeeded: false,
  failed: true,
  deferred: false,
  unsettled: false,
  malformed: false,
}

/** Whether a tool-call row failed. Only a recorded failure counts: a deferred,
 *  unsettled or malformed row is not guessed to be one. One rule for the call
 *  bars and the cursor readout, so the two cannot disagree. */
export function isToolCallFailure(entry: TelemetryEntry): boolean {
  const outcome = toolCallOutcome(entry)
  return outcome !== null && OUTCOME_IS_FAILURE[outcome]
}

/** The word a call bar's tooltip uses: `ok` for a settled success, otherwise the
 *  outcome's own name, so a deferred or unsettled call is not labelled ok. */
export function toolCallOutcomeWord(entry: TelemetryEntry): string {
  const outcome = toolCallOutcome(entry)
  if (outcome === null) return '?'
  return outcome === 'succeeded' ? 'ok' : outcome
}

interface TelemetryMarkerBucket {
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
