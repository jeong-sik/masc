// Cross-signal readout card (RFC-MASC-006 Phase 2c)
//
// When the cursor is active, show aligned values across all tracks at the
// cursor's time — the core "읽기" primitive of Observatory. Reads directly
// from `cursorPosition` signal + track data passed by parent.

import { html } from 'htm/preact'
import type { TelemetryEntry, ToolQualityHourlyPoint } from '../../api/dashboard'
import { cursorPosition } from './cursor-store'
import { entryTimestampMs, hourToMs, isToolCall } from './observatory-utils'

interface Props {
  events: TelemetryEntry[]
  hourlyTrend: ToolQualityHourlyPoint[]
  /** Tolerance in ms for "nearby" event (both halves of cursor). */
  eventWindowMs: number
}

function countEventsNear(
  events: TelemetryEntry[],
  cursorMs: number,
  windowMs: number,
  predicate?: (entry: TelemetryEntry) => boolean,
): number {
  const half = windowMs / 2
  return events.filter(entry => {
    if (predicate && !predicate(entry)) return false
    const ts = entryTimestampMs(entry)
    return ts !== null && Math.abs(ts - cursorMs) <= half
  }).length
}

function nearestTrendPoint(
  points: ToolQualityHourlyPoint[],
  cursorMs: number,
): ToolQualityHourlyPoint | null {
  let best: { point: ToolQualityHourlyPoint; dist: number } | null = null
  for (const point of points) {
    const ts = hourToMs(point.hour)
    if (ts === null) continue
    const dist = Math.abs(ts - cursorMs)
    if (best === null || dist < best.dist) best = { point, dist }
  }
  return best?.point ?? null
}

function Row({
  label,
  value,
  tone = 'neutral',
}: {
  label: string
  value: string | number
  tone?: 'neutral' | 'ok' | 'warn' | 'bad'
}) {
  const toneClass =
    tone === 'ok' ? 'text-[var(--color-status-ok)]'
      : tone === 'warn' ? 'text-[var(--color-status-warn)]'
      : tone === 'bad' ? 'text-[var(--bad-light)]'
      : 'text-text-strong'
  return html`
    <div class="flex items-center justify-between gap-4 text-2xs">
      <span class="text-text-dim">${label}</span>
      <span class="font-mono font-semibold ${toneClass}">${value}</span>
    </div>
  `
}

export function CrossSignalReadout({ events, hourlyTrend, eventWindowMs }: Props) {
  const cursor = cursorPosition.value
  if (cursor === null) return null

  const totalEvents = countEventsNear(events, cursor.ts, eventWindowMs)
  const toolCalls = countEventsNear(events, cursor.ts, eventWindowMs, isToolCall)
  const toolFailures = countEventsNear(
    events,
    cursor.ts,
    eventWindowMs,
    entry => isToolCall(entry) && (entry.success === false || Boolean(entry.error)),
  )
  const trendPoint = nearestTrendPoint(hourlyTrend, cursor.ts)

  const successRateTone: 'ok' | 'warn' | 'bad' | 'neutral' =
    trendPoint == null ? 'neutral'
      : trendPoint.success_rate >= 97 ? 'ok'
      : trendPoint.success_rate >= 90 ? 'neutral'
      : 'bad'

  const windowLabel = eventWindowMs >= 60_000
    ? `±${Math.round(eventWindowMs / 60_000 / 2)}m`
    : `±${Math.round(eventWindowMs / 1000 / 2)}s`

  return html`
    <div class="rounded-[var(--r-1)] border border-accent/20 bg-accent/5 px-3 py-2 shadow-[var(--shadow-1)]" role="status" aria-live="polite" aria-label="커서 위치 메트릭 요약">
      <div class="mb-1.5 flex items-center justify-between">
        <span class="text-3xs uppercase tracking-widest text-accent font-semibold">cursor</span>
        <span class="text-2xs font-mono text-text-strong">
          ${new Date(cursor.ts).toLocaleTimeString()}
        </span>
      </div>
      <div class="grid grid-cols-2 gap-x-4 gap-y-1">
        <${Row} label=${`이벤트 (${windowLabel})`} value=${totalEvents} />
        <${Row}
          label=${`도구 호출 (${windowLabel})`}
          value=${toolFailures > 0 ? `${toolCalls} / ${toolFailures} 실패` : toolCalls}
          tone=${toolFailures > 0 ? 'warn' : 'neutral'}
        />
        <${Row}
          label="성공률 (최근 hour)"
          value=${trendPoint != null ? `${trendPoint.success_rate.toFixed(1)}%` : '-'}
          tone=${successRateTone}
        />
        <${Row}
          label="최근 호출 건수"
          value=${trendPoint != null ? trendPoint.calls : '-'}
        />
      </div>
    </div>
  `
}
