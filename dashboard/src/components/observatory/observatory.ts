// Observatory — Unified Investigation Surface (RFC-MASC-006 Phase 2a skeleton)
//
// v1 scope (this file):
//   - Shared time axis for 1h / 24h / etc. ranges
//   - 2 initial tracks: Events (telemetry markers), Metrics (success rate line)
//   - Global filter integration (keeper / range from observatory-filter-store)
//
// Out of scope for Phase 2a (deferred to 2b+):
//   - Cross-signal hover cursor
//   - Memory subsystems track (backend snapshot-only)
//   - Tool calls track, drill-down detail pane
//   - SSE live streaming (current: polling per filter change)

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
import { cursorPosition } from './cursor-store'

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

// --- Time axis header ---

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
    <div class="grid grid-cols-7 gap-1 border-b border-card-border px-1 pb-1 text-3xs text-text-dim font-mono">
      ${ticks.map(tick => html`
        <span
          class="min-w-0 truncate ${
            tick.index === 0 ? 'text-left'
              : tick.index === tickCount ? 'text-right'
              : 'text-center'
          }"
          title=${formatTick(tick.t)}
        >
          ${formatTick(tick.t)}
        </span>
      `)}
    </div>
  `
}

// --- Range selector ---

function RangeSelector() {
  const current = currentTimeRangeFilter() ?? DEFAULT_RANGE
  return html`
    <div class="flex flex-wrap items-center gap-0.5 rounded-[var(--r-1)] border border-card-border p-0.5 text-2xs">
      ${TIME_RANGE_PRESETS.map((preset: TimeRangePreset) => html`
        <button
          type="button"
          class="v2-monitoring-action rounded-[var(--r-1)] px-2 py-0.5 font-medium transition-colors ${
            current === preset
              ? 'bg-[var(--accent-20)] text-accent-fg'
              : 'text-text-muted hover:text-text-strong hover:bg-[var(--color-bg-elevated)]'
          }"
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

  return html`
    <div class="v2-monitoring-surface flex flex-col gap-5">
      <div class="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div class="flex flex-col gap-0.5">
          <h3 class="text-sm font-semibold text-text-strong">Observatory</h3>
          <p class="text-2xs text-text-dim">
            ${currentKeeperFilter() ? `keeper=${currentKeeperFilter()}` : '전체 keeper'}
            · ${timeRangeLabel(currentTimeRangeFilter() ?? DEFAULT_RANGE)}
            · ${data.totalMatchingEvents} events
            ${data.truncatedEvents ? ` · showing ${data.events.length}` : ''}
            ${data.loading ? ' · loading' : ''}
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <${RangeSelector} />
        </div>
      </div>

      ${data.error ? html`
        <div class="rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs text-[var(--color-status-warn)]">
          일부 데이터 불러오기 실패: ${data.error}
        </div>
      ` : null}

      <div class="v2-monitoring-panel flex flex-col gap-2 rounded-[var(--r-1)] border border-card-border bg-card/30 p-4">
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
        ${cursorPosition.value === null ? html`
          <div class="mt-1 h-1" aria-hidden="true"></div>
        ` : null}
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
