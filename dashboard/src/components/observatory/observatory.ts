// Observatory — Unified Investigation Surface, re-skinned onto the keeper-v2
// monitor-more design (ObservatoryPanel).
//
// Design vocabulary: .ia-wrap/.ia-head/.ia-count/.ia-route/.ia-lede header,
// .ob-ranges range switch (.ia-filter), one .ob-panel holding .ob-axis plus
// three .ob-track lanes (events · tool calls · success %) and the shared
// .ob-cursor line, then .ob-readout and .ob-detail strips.
//
// Live data (mark, don't fake):
//   - events / tool-call tracks → fetchTelemetry (agent_event · tool_call_io …)
//   - success-% track           → fetchToolQuality hourly_trend
//   - shared hover cursor       → cursor-store, driven by .ob-panel mousemove
//   - detail pane               → detail-selection-store (click a marker)

import { html } from 'htm/preact'
import { signal, useSignal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import {
  currentKeeperFilter,
  currentTimeRangeFilter,
  setTimeRangeFilter,
  timeRangeLabel,
  timeRangeShortLabel,
  timeRangeToMs,
  TIME_RANGE_PRESETS,
  type TimeRangePreset,
} from '../../observatory-filter-store'
import {
  fetchTelemetry,
  fetchToolQuality,
  type TelemetryEntry,
  type ToolQualityHourlyPoint,
} from '../../api/dashboard'
import { registerActivityRefresh } from '../../sse-store'
import { entryTimestampMs } from './observatory-utils'
import { EventTrack } from './event-track'
import { MetricTrack } from './metric-track'
import { ToolCallTrack } from './tool-call-track'
import { CrossSignalReadout } from './cross-signal-readout'
import { DetailPane } from './detail-pane'
import { CursorLine } from './cursor-line'
import { setCursorFromEvent, clearCursor } from './cursor-store'

const DEFAULT_RANGE: TimeRangePreset = '1h'
const observatoryRefreshVersion = signal(0)

// --- Observatory state ---

interface ObservatoryData {
  loading: boolean
  error: string | null
  events: TelemetryEntry[]
  totalMatchingEvents: number
  truncatedEvents: boolean
  hourlyTrend: ToolQualityHourlyPoint[]
  windowStart: number
  windowEnd: number
}

function emptyData(): ObservatoryData {
  const now = Date.now()
  return {
    loading: false,
    error: null,
    events: [],
    totalMatchingEvents: 0,
    truncatedEvents: false,
    hourlyTrend: [],
    windowStart: now - timeRangeToMs(DEFAULT_RANGE),
    windowEnd: now,
  }
}

// --- Time axis header (.ob-axis) ---

function TimeAxis({ windowStart, windowEnd }: { windowStart: number; windowEnd: number }) {
  const span = windowEnd - windowStart
  if (span <= 0) return null

  const tickCount = 6
  const ticks = Array.from({ length: tickCount + 1 }, (_, i) => {
    const t = windowStart + (span * i) / tickCount
    return { t, index: i }
  })

  const formatTick = (t: number) => {
    const d = new Date(t)
    if (span <= 24 * 60 * 60_000) {
      return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
    }
    return `${d.getMonth() + 1}/${d.getDate()} ${String(d.getHours()).padStart(2, '0')}h`
  }

  return html`
    <div class="ob-axis mono">
      ${ticks.map(tick => html`
        <span key=${tick.index} title=${formatTick(tick.t)}>
          ${formatTick(tick.t)}
        </span>
      `)}
    </div>
  `
}

// --- Range selector (.ob-ranges) ---

function RangeSelector() {
  const current = currentTimeRangeFilter() ?? DEFAULT_RANGE
  return html`
    <div class="ob-ranges">
      ${TIME_RANGE_PRESETS.map((preset: TimeRangePreset) => html`
        <button
          type="button"
          class="ia-filter ${current === preset ? 'on' : ''}"
          onClick=${() => setTimeRangeFilter(preset)}
          aria-pressed=${current === preset}
        >
          ${timeRangeShortLabel(preset)}
        </button>
      `)}
    </div>
  `
}

// --- Main container ---

export function refreshObservatorySurface(): void {
  observatoryRefreshVersion.value += 1
}

export function Observatory() {
  const state = useSignal<ObservatoryData>(emptyData())
  const activeController = useRef<AbortController | null>(null)
  const latestRequestId = useRef(0)
  const panelRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => registerActivityRefresh(() => {
    refreshObservatorySurface()
  }), [])

  useEffect(() => {
    const keeper = currentKeeperFilter() ?? undefined
    const range = currentTimeRangeFilter() ?? DEFAULT_RANGE

    activeController.current?.abort()
    const controller = new AbortController()
    activeController.current = controller
    const requestId = ++latestRequestId.current

    const now = Date.now()
    const windowStart = now - timeRangeToMs(range)
    const windowEnd = now

    state.value = { ...state.value, loading: true, error: null }

    Promise.allSettled([
      fetchTelemetry({
        keeper,
        since_ms: windowStart,
        until_ms: windowEnd,
        signal: controller.signal,
      }),
      fetchToolQuality({ n: 2000, signal: controller.signal }),
    ]).then(([telemetryResult, toolQualityResult]) => {
      if (controller.signal.aborted || requestId !== latestRequestId.current) return

      const telemetry = telemetryResult.status === 'fulfilled'
        ? telemetryResult.value
        : null

      const events = telemetry?.entries.filter(entry => {
        const ts = entryTimestampMs(entry)
        return ts !== null && ts >= windowStart && ts <= windowEnd
      }) ?? []

      const hourlyTrend = toolQualityResult.status === 'fulfilled'
        ? toolQualityResult.value.hourly_trend ?? []
        : []

      const errors = [telemetryResult, toolQualityResult]
        .filter((r): r is PromiseRejectedResult => r.status === 'rejected')
        .map(r => r.reason instanceof Error ? r.reason.message : String(r.reason))

      state.value = {
        loading: false,
        error: errors.length > 0 ? errors.join(' · ') : null,
        events,
        totalMatchingEvents: telemetry?.total_matching_entries ?? events.length,
        truncatedEvents: telemetry?.truncated ?? false,
        hourlyTrend,
        windowStart,
        windowEnd,
      }
    })

    return () => { controller.abort() }
  }, [currentKeeperFilter(), currentTimeRangeFilter(), observatoryRefreshVersion.value])

  const data = state.value
  const range = currentTimeRangeFilter() ?? DEFAULT_RANGE

  return html`
    <div class="v2-monitoring-surface ia-wrap">
      <div class="ia-head">
        <h3>Observatory</h3>
        <span class="ia-count mono">
          이벤트 ${data.totalMatchingEvents}건${data.truncatedEvents ? ` · showing ${data.events.length}` : ''}${data.loading ? ' · loading' : ''}
        </span>
        <span class="ia-route mono">monitoring?section=observatory&range=${range}</span>
      </div>
      <p class="ia-lede">
        ${currentKeeperFilter() ? `keeper=${currentKeeperFilter()}` : '전체 keeper'}
        · ${timeRangeLabel(range)}.
        하나의 시간축 위에 텔레메트리 이벤트 · 도구 호출 · 성공률 지표를 겹쳐 봅니다.
        갱신은 필터 변경 시 폴링이며, 라이브 스트리밍은 아직 없습니다.
      </p>
      <${RangeSelector} />

      ${data.error ? html`
        <div class="rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs text-[var(--color-status-warn)]">
          일부 데이터 불러오기 실패: ${data.error}
        </div>
      ` : null}

      <div
        ref=${panelRef}
        class="ob-panel"
        onMouseMove=${(e: MouseEvent) => {
          if (panelRef.current) setCursorFromEvent(e, panelRef.current, data.windowStart, data.windowEnd)
        }}
        onMouseLeave=${clearCursor}
      >
        <${TimeAxis} windowStart=${data.windowStart} windowEnd=${data.windowEnd} />
        <${EventTrack}
          events=${data.events}
          windowStart=${data.windowStart}
          windowEnd=${data.windowEnd}
        />
        <${ToolCallTrack}
          events=${data.events}
          windowStart=${data.windowStart}
          windowEnd=${data.windowEnd}
        />
        <${MetricTrack}
          points=${data.hourlyTrend}
          windowStart=${data.windowStart}
          windowEnd=${data.windowEnd}
        />
        <${CursorLine} />
      </div>

      <${CrossSignalReadout}
        events=${data.events}
        hourlyTrend=${data.hourlyTrend}
        eventWindowMs=${Math.max(30_000, (data.windowEnd - data.windowStart) * 0.05)}
      />

      <${DetailPane} />
    </div>
  `
}
