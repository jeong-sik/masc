// Observatory Event Track (RFC-MASC-006 Phase 2a+2b+2d)
// Renders discrete telemetry events as vertical markers on a shared time axis.
// Phase 2b: mousemove updates cursor-store, CursorLine renders across track.
// Phase 2d: click marker → selectEntity → DetailPane opens.

import { html } from 'htm/preact'
import { useRef } from 'preact/hooks'
import type { TelemetryEntry } from '../../api/dashboard'
import { setCursorFromEvent, clearCursor } from './cursor-store'
import { CursorLine } from './cursor-line'
import { selectEntity, detailSelection } from './detail-selection-store'
import { bucketTelemetryEntries, entryTimestampMs, useTrackBucketCount } from './observatory-utils'

function sourceColor(source: string | undefined): string {
  switch (source) {
    case 'oas_event': return 'bg-accent'
    case 'agent_event': return 'bg-[var(--ok-10)]'
    case 'tool_call_io': return 'bg-[var(--accent-10)]'
    case 'tool_usage': return 'bg-[var(--accent-10)]'
    case 'keeper_metrics': return 'bg-[var(--accent-10)]'
    default: return 'bg-text-dim'
  }
}

function eventLabel(entry: TelemetryEntry): string {
  const source = typeof entry.source === 'string' ? entry.source : '?'
  const eventType = typeof entry.event_type === 'string' ? entry.event_type : ''
  return eventType ? `${source}:${eventType}` : source
}

interface Props {
  events: TelemetryEntry[]
  windowStart: number
  windowEnd: number
}

export function EventTrack({ events, windowStart, windowEnd }: Props) {
  const trackRef = useRef<HTMLDivElement | null>(null)
  const bucketCount = useTrackBucketCount(trackRef)
  const span = windowEnd - windowStart
  if (span <= 0) return null

  const windowedEvents = events
    .map(entry => ({ entry, ts: entryTimestampMs(entry) }))
    .filter((m): m is { entry: TelemetryEntry; ts: number } =>
      m.ts !== null && m.ts >= windowStart && m.ts <= windowEnd,
    )
  const markers = bucketTelemetryEntries(events, windowStart, windowEnd, bucketCount)

  return html`
    <div class="flex items-center gap-3">
      <div class="w-24 shrink-0 text-2xs font-semibold text-text-muted">
        이벤트 (${windowedEvents.length})
      </div>
      <div
        ref=${trackRef}
        class="relative flex-1 h-8 rounded-[var(--r-1)] bg-bg-1/40 border border-card-border/50 cursor-crosshair"
        role="group"
        aria-label="이벤트 타임라인 마커"
        onMouseMove=${(e: MouseEvent) => {
          if (trackRef.current) setCursorFromEvent(e, trackRef.current, windowStart, windowEnd)
        }}
        onMouseLeave=${clearCursor}
      >
        ${markers.length === 0
          ? html`<div class="absolute inset-0 flex items-center justify-center text-3xs text-text-dim">이 시간 범위에 이벤트 없음</div>`
          : markers.map(({ entry, ts, count }) => {
              const pct = ((ts - windowStart) / span) * 100
              const color = sourceColor(typeof entry.source === 'string' ? entry.source : undefined)
              const label = eventLabel(entry)
              const selected = detailSelection.value
              const isSelected = selected !== null
                && selected.kind === 'event'
                && selected.entry === entry
              const ringClass = isSelected ? 'ring-2 ring-accent ring-offset-1 ring-offset-bg-1' : ''
              return html`
                <span
                  class="absolute top-1 bottom-1 w-[2px] ${color} hover:w-1 transition-[width] cursor-pointer ${ringClass}"
                  style="left: ${pct}%;"
                  title=${`${new Date(ts).toLocaleTimeString()} · ${label}${count > 1 ? ` · ${count} events` : ''}`}
                  onClick=${(e: MouseEvent) => {
                    e.stopPropagation()
                    selectEntity({ kind: 'event', entry, ts, bucketCount: count })
                  }}
                >${count > 1 ? html`
                  <span class="absolute -top-4 left-1/2 -translate-x-1/2 rounded-[var(--r-1)] bg-bg-0/90 px-1 py-0.5 text-3xs font-mono text-text-dim" aria-hidden="true">
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
