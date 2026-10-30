// Observatory Event Track — keeper-v2 monitor-more design (ObservatoryPanel).
// Design vocabulary: .ob-track > .ob-track-k + .ob-lane, with toned .ob-ev
// dot markers (t-ok/t-warn/t-bad/t-info) positioned by shared time axis.
// Bucketing stays: dense windows collapse to one marker per pixel bucket,
// with the bucket count in the marker title. Click → detail-selection-store.
// Hover cursor lives on the parent .ob-panel (observatory.ts), not per track.

import { html } from 'htm/preact'
import { useRef } from 'preact/hooks'
import type { TelemetryEntry } from '../../api/dashboard'
import { selectEntity, detailSelection } from './detail-selection-store'
import { bucketTelemetryEntries, useTrackBucketCount } from './observatory-utils'

type ObTone = 'ok' | 'warn' | 'bad' | 'info'

// Mirrors the design's OB_KINDS tones (wake→ok, compact→warn, gate→info,
// fail→bad, fusion→info) keyed off the live entry's event_type.
function eventTone(entry: TelemetryEntry): ObTone | null {
  const raw = typeof entry.event_type === 'string' ? entry.event_type.toLowerCase() : ''
  if (!raw) return null
  if (/(fail|error|dead|overflow|quarantine)/.test(raw)) return 'bad'
  if (/compact/.test(raw)) return 'warn'
  if (/(gate|fusion)/.test(raw)) return 'info'
  if (/(wake|woken|start|restart|resume)/.test(raw)) return 'ok'
  return null
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

  const markers = bucketTelemetryEntries(events, windowStart, windowEnd, bucketCount)

  return html`
    <div class="ob-track">
      <span class="ob-track-k mono">events</span>
      <div
        ref=${trackRef}
        class="ob-lane"
        role="group"
        aria-label="이벤트 타임라인 마커"
      >
        ${markers.length === 0
          ? html`<div class="absolute inset-0 flex items-center justify-center text-3xs text-text-dim">이 시간 범위에 이벤트 없음</div>`
          : markers.map(({ entry, ts, count }) => {
              const pct = ((ts - windowStart) / span) * 100
              const tone = eventTone(entry)
              const label = eventLabel(entry)
              const selected = detailSelection.value
              const isSelected = selected !== null
                && selected.kind === 'event'
                && selected.entry === entry
              return html`
                <button
                  type="button"
                  class="ob-ev ${tone ? `t-${tone}` : ''} ${isSelected ? 'ring-2 ring-accent-fg ring-offset-1 ring-offset-bg-1' : ''}"
                  style="left: ${pct}%;"
                  title=${`${new Date(ts).toLocaleTimeString()} · ${label}${count > 1 ? ` · ${count} events` : ''}`}
                  aria-label=${label}
                  onClick=${(e: MouseEvent) => {
                    e.stopPropagation()
                    selectEntity({ kind: 'event', entry, ts, bucketCount: count })
                  }}
                ></button>
              `
            })
        }
      </div>
    </div>
  `
}
