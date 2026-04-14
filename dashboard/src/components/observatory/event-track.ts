// Observatory Event Track (RFC-MASC-006 Phase 2a)
// Renders discrete telemetry events as vertical markers on a shared time axis.

import { html } from 'htm/preact'
import type { TelemetryEntry } from '../../api/dashboard'

function entryTimestampMs(entry: TelemetryEntry): number | null {
  if (typeof entry.ts === 'number') return entry.ts * 1000
  if (typeof entry.ts_unix === 'number') return entry.ts_unix * 1000
  if (typeof entry.timestamp === 'number') return entry.timestamp
  if (typeof entry.ts_iso === 'string') {
    const parsed = Date.parse(entry.ts_iso)
    return Number.isNaN(parsed) ? null : parsed
  }
  return null
}

function sourceColor(source: string | undefined): string {
  switch (source) {
    case 'oas_event': return 'bg-accent'
    case 'agent_event': return 'bg-emerald-400'
    case 'tool_call_io': return 'bg-blue-400'
    case 'tool_usage': return 'bg-sky-400'
    case 'keeper_metrics': return 'bg-purple-400'
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
  const span = windowEnd - windowStart
  if (span <= 0) return null

  const markers = events
    .map(entry => ({ entry, ts: entryTimestampMs(entry) }))
    .filter((m): m is { entry: TelemetryEntry; ts: number } =>
      m.ts !== null && m.ts >= windowStart && m.ts <= windowEnd,
    )

  return html`
    <div class="flex items-center gap-3">
      <div class="w-24 shrink-0 text-[11px] font-semibold text-text-muted">
        이벤트 (${markers.length})
      </div>
      <div class="relative flex-1 h-8 rounded-md bg-bg-1/40 border border-card-border/50">
        ${markers.length === 0
          ? html`<div class="absolute inset-0 flex items-center justify-center text-[10px] text-text-dim">이 시간 범위에 이벤트 없음</div>`
          : markers.map(({ entry, ts }) => {
              const pct = ((ts - windowStart) / span) * 100
              const color = sourceColor(typeof entry.source === 'string' ? entry.source : undefined)
              const label = eventLabel(entry)
              return html`
                <span
                  class="absolute top-1 bottom-1 w-[2px] ${color} hover:w-1 transition-all cursor-pointer"
                  style="left: ${pct}%;"
                  title=${`${new Date(ts).toLocaleTimeString()} · ${label}`}
                ></span>
              `
            })
        }
      </div>
    </div>
  `
}
