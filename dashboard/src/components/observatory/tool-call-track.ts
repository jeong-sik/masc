// Observatory Tool Call Track — keeper-v2 monitor-more design (ObservatoryPanel).
// Design vocabulary: .ob-track > .ob-track-k + .ob-lane, with .ob-call bars
// (failed calls .bad) whose height scales with real call duration:
// height = min(100, 18 + ms / 4200 * 82)%, per the prototype.
// Bucketing stays: dense windows collapse to one bar per pixel bucket,
// keeping the bucket's max duration for the height. Click → detail-selection-store.
// Hover cursor lives on the parent .ob-panel (observatory.ts), not per track.

import { html } from 'htm/preact'
import { useRef } from 'preact/hooks'
import type { TelemetryEntry } from '../../api/dashboard'
import { selectEntity, detailSelection } from './detail-selection-store'
import { entryTimestampMs, isToolCall, useTrackBucketCount } from './observatory-utils'

function isFailure(entry: TelemetryEntry): boolean {
  if (entry.success === false) return true
  if (entry.success === true) return false
  const errorField = entry.error
  return errorField != null && errorField !== ''
}

function toolName(entry: TelemetryEntry): string {
  if (typeof entry.tool_name === 'string') return entry.tool_name
  if (typeof entry.name === 'string') return entry.name
  return '?'
}

function durationMs(entry: TelemetryEntry): number {
  return typeof entry.duration_ms === 'number' && Number.isFinite(entry.duration_ms)
    ? Math.max(0, entry.duration_ms)
    : 0
}

// Prototype scale: 4200ms saturates the lane, short calls sit near the 18% base.
function barHeightPct(ms: number): number {
  return Math.round(Math.min(100, 18 + (ms / 4200) * 82))
}

interface Props {
  events: TelemetryEntry[]
  windowStart: number
  windowEnd: number
}

export function ToolCallTrack({ events, windowStart, windowEnd }: Props) {
  const trackRef = useRef<HTMLDivElement | null>(null)
  const bucketCount = useTrackBucketCount(trackRef)
  const span = windowEnd - windowStart
  if (span <= 0) return null

  const toolEvents = events
    .filter(isToolCall)
    .map(entry => ({ entry, ts: entryTimestampMs(entry) }))
    .filter((m): m is { entry: TelemetryEntry; ts: number } =>
      m.ts !== null && m.ts >= windowStart && m.ts <= windowEnd,
    )

  const markers = (() => {
    const buckets = new Map<number, {
      entry: TelemetryEntry
      ts: number
      count: number
      failureCount: number
      maxMs: number
    }>()

    for (const { entry, ts } of toolEvents) {
      const pct = (ts - windowStart) / span
      const index = Math.min(bucketCount - 1, Math.max(0, Math.floor(pct * bucketCount)))
      const failure = isFailure(entry)
      const ms = durationMs(entry)
      const existing = buckets.get(index)
      if (existing) {
        existing.count += 1
        if (failure) existing.failureCount += 1
        if (ms > existing.maxMs) existing.maxMs = ms
        if (ts >= existing.ts) {
          existing.entry = entry
          existing.ts = ts
        }
      } else {
        buckets.set(index, {
          entry,
          ts,
          count: 1,
          failureCount: failure ? 1 : 0,
          maxMs: ms,
        })
      }
    }

    return [...buckets.entries()]
      .sort((left, right) => left[0] - right[0])
      .map(([, bucket]) => bucket)
  })()

  return html`
    <div class="ob-track">
      <span class="ob-track-k mono">tool calls</span>
      <div
        ref=${trackRef}
        class="ob-lane"
        role="group"
        aria-label="도구 호출 타임라인 마커"
      >
        ${markers.length === 0
          ? html`<div class="absolute inset-0 flex items-center justify-center text-3xs text-text-dim">이 시간 범위에 도구 호출 없음</div>`
          : markers.map(({ entry, ts, count, failureCount: bucketFailures, maxMs }) => {
              const pct = ((ts - windowStart) / span) * 100
              const failed = bucketFailures > 0 || isFailure(entry)
              const name = toolName(entry)
              const selected = detailSelection.value
              const isSelected = selected !== null
                && selected.kind === 'tool_call'
                && selected.entry === entry
              return html`
                <span
                  class="ob-call ${failed ? 'bad' : ''} ${isSelected ? 'ring-1 ring-accent-fg' : ''}"
                  style="left: ${pct}%; height: ${barHeightPct(maxMs)}%;"
                  title=${`${new Date(ts).toLocaleTimeString()} · ${name} · ${maxMs}ms · ${failed ? 'failed' : 'ok'}${count > 1 ? ` · ${count} calls` : ''}`}
                  onClick=${(e: MouseEvent) => {
                    e.stopPropagation()
                    selectEntity({ kind: 'tool_call', entry, ts, bucketCount: count })
                  }}
                ></span>
              `
            })
        }
      </div>
    </div>
  `
}
