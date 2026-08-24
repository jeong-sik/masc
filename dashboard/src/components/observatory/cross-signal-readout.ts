// Cross-signal readout — keeper-v2 monitor-more design (.ob-readout).
//
// One dashed strip under the panel: an .ia-k label plus either the dim hint
// (no cursor) or a mono line reading all three tracks at the cursor's time —
// events, tool calls (+ failures), success rate, recent call count.
// Live values come from cursorPosition + track data passed by the parent.

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

export function CrossSignalReadout({ events, hourlyTrend, eventWindowMs }: Props) {
  const cursor = cursorPosition.value

  if (cursor === null) {
    return html`
      <div class="ob-readout" role="status" aria-live="polite" aria-label="커서 위치 메트릭 요약">
        <span class="ia-k">Cross-signal readout</span>
        <span class="dim">트랙 위에 커서를 올리면 같은 시점의 이벤트 · 도구 호출 · 지표를 함께 읽습니다.</span>
      </div>
    `
  }

  const totalEvents = countEventsNear(events, cursor.ts, eventWindowMs)
  const toolCalls = countEventsNear(events, cursor.ts, eventWindowMs, isToolCall)
  const toolFailures = countEventsNear(
    events,
    cursor.ts,
    eventWindowMs,
    entry => isToolCall(entry) && (entry.success === false || Boolean(entry.error)),
  )
  const trendPoint = nearestTrendPoint(hourlyTrend, cursor.ts)

  const windowLabel = eventWindowMs >= 60_000
    ? `±${Math.round(eventWindowMs / 60_000 / 2)}m`
    : `±${Math.round(eventWindowMs / 1000 / 2)}s`

  return html`
    <div class="ob-readout" role="status" aria-live="polite" aria-label="커서 위치 메트릭 요약">
      <span class="ia-k">Cross-signal readout</span>
      <span class="mono">
        ${new Date(cursor.ts).toLocaleTimeString()}
        · 이벤트 ${totalEvents} (${windowLabel})
        · 도구 호출 ${toolCalls}${toolFailures > 0 ? ` / ${toolFailures} 실패` : ''}
        · 성공률 ${trendPoint != null ? `${trendPoint.success_rate.toFixed(1)}%` : '—'}
        · 최근 호출 ${trendPoint != null ? trendPoint.calls : '—'}
      </span>
    </div>
  `
}
