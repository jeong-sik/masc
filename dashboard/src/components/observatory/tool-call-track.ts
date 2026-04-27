// Observatory Tool Call Track (RFC-MASC-006 Phase 2b+2d)
// Renders tool call events (from telemetry) as markers, colored by outcome.
// Phase 2d: click marker → selectEntity → DetailPane opens.

import { html } from 'htm/preact'
import { useRef } from 'preact/hooks'
import type { TelemetryEntry } from '../../api/dashboard'
import { setCursorFromEvent, clearCursor } from './cursor-store'
import { CursorLine } from './cursor-line'
import { selectEntity, detailSelection } from './detail-selection-store'
import { entryTimestampMs, isToolCall, useTrackBucketCount } from './observatory-utils'

function toolCallOutcome(entry: TelemetryEntry): 'success' | 'failure' | 'unknown' {
  if (entry.success === true) return 'success'
  if (entry.success === false) return 'failure'
  const errorField = entry.error
  if (errorField != null && errorField !== '') return 'failure'
  return 'unknown'
}

function outcomeColor(outcome: ReturnType<typeof toolCallOutcome>): string {
  switch (outcome) {
    case 'success': return 'bg-[var(--ok-10)]'
    case 'failure': return 'bg-[var(--bad-10)]'
    default: return 'bg-text-dim'
  }
}

function toolName(entry: TelemetryEntry): string {
  if (typeof entry.tool_name === 'string') return entry.tool_name
  if (typeof entry.name === 'string') return entry.name
  return '?'
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
    }>()

    for (const { entry, ts } of toolEvents) {
      const pct = (ts - windowStart) / span
      const index = Math.min(bucketCount - 1, Math.max(0, Math.floor(pct * bucketCount)))
      const failure = toolCallOutcome(entry) === 'failure'
      const existing = buckets.get(index)
      if (existing) {
        existing.count += 1
        if (failure) existing.failureCount += 1
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
        })
      }
    }

    return [...buckets.entries()]
      .sort((left, right) => left[0] - right[0])
      .map(([, bucket]) => bucket)
  })()

  const successCount = toolEvents.filter(m => toolCallOutcome(m.entry) === 'success').length
  const failureCount = toolEvents.filter(m => toolCallOutcome(m.entry) === 'failure').length

  return html`
    <div class="flex items-center gap-3">
      <div class="w-24 shrink-0">
        <div class="text-2xs font-semibold text-text-muted">도구 호출</div>
        <div class="text-3xs text-text-dim">
          <span class="text-[var(--color-status-ok)]">${successCount}</span>
          <span class="text-text-dim/60 mx-0.5">·</span>
          <span class="text-[var(--bad-light)]">${failureCount}</span>
        </div>
      </div>
      <div
        ref=${trackRef}
        class="relative flex-1 h-8 rounded bg-bg-1/40 border border-card-border/50 cursor-crosshair"
        role="group"
        aria-label="도구 호출 타임라인 마커"
        onMouseMove=${(e: MouseEvent) => {
          if (trackRef.current) setCursorFromEvent(e, trackRef.current, windowStart, windowEnd)
        }}
        onMouseLeave=${clearCursor}
      >
        ${markers.length === 0
          ? html`<div class="absolute inset-0 flex items-center justify-center text-3xs text-text-dim">이 시간 범위에 도구 호출 없음</div>`
          : markers.map(({ entry, ts, count, failureCount: bucketFailures }) => {
              const pct = ((ts - windowStart) / span) * 100
              const outcome = bucketFailures > 0 ? 'failure' : toolCallOutcome(entry)
              const color = outcomeColor(outcome)
              const name = toolName(entry)
              const selected = detailSelection.value
              const isSelected = selected !== null
                && selected.kind === 'tool_call'
                && selected.entry === entry
              const ringClass = isSelected ? 'ring-2 ring-accent ring-offset-1 ring-offset-bg-1' : ''
              return html`
                <span
                  class="absolute top-1 bottom-1 w-[3px] ${color} rounded-px hover:w-1.5 transition-all cursor-pointer ${ringClass}"
                  style="left: ${pct}%;"
                  title=${`${new Date(ts).toLocaleTimeString()} · ${name} · ${outcome}${count > 1 ? ` · ${count} calls` : ''}`}
                  onClick=${(e: MouseEvent) => {
                    e.stopPropagation()
                    selectEntity({ kind: 'tool_call', entry, ts, bucketCount: count })
                  }}
                >${count > 1 ? html`
                  <span class="absolute -top-4 left-1/2 -translate-x-1/2 rounded bg-bg-0/90 px-1 py-0.5 text-3xs font-mono text-text-dim" aria-hidden="true">
                    ${count}
                  </span>
                ` : null}</span>
              `
            })
        }
        <${CursorLine} />
      </div>
    </div>
  `
}
