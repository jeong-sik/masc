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
//   - Autoresearch cycle track (RFC-MASC-007 hook)
//   - Tool calls track, drill-down detail pane
//   - SSE live streaming (current: polling per filter change)

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import {
  currentKeeperFilter,
  currentTimeRangeFilter,
  setTimeRangeFilter,
  timeRangeLabel,
  TIME_RANGE_PRESETS,
  type TimeRangePreset,
} from '../../observatory-filter-store'
import {
  fetchTelemetry,
  fetchToolQuality,
  type TelemetryEntry,
  type ToolQualityHourlyPoint,
} from '../../api/dashboard'
import { EventTrack } from './event-track'
import { MetricTrack } from './metric-track'
import { ToolCallTrack } from './tool-call-track'
import { CrossSignalReadout } from './cross-signal-readout'
import { cursorPosition } from './cursor-store'
import { LoadingState } from '../common/feedback-state'

// --- Time range utilities ---

const RANGE_TO_MS: Record<TimeRangePreset, number> = {
  '5m': 5 * 60_000,
  '1h': 60 * 60_000,
  '24h': 24 * 60 * 60_000,
  '7d': 7 * 24 * 60 * 60_000,
}

export function timeRangeToMs(preset: TimeRangePreset): number {
  return (RANGE_TO_MS[preset] ?? RANGE_TO_MS['1h'] ?? 3_600_000)
}

const DEFAULT_RANGE: TimeRangePreset = '1h'

// --- Observatory state ---

interface ObservatoryData {
  loading: boolean
  error: string | null
  events: TelemetryEntry[]
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
    hourlyTrend: [],
    windowStart: now - RANGE_TO_MS[DEFAULT_RANGE],
    windowEnd: now,
  }
}

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

// --- Time axis header ---

function TimeAxis({ windowStart, windowEnd }: { windowStart: number; windowEnd: number }) {
  const span = windowEnd - windowStart
  if (span <= 0) return null

  const tickCount = 6
  const ticks = Array.from({ length: tickCount + 1 }, (_, i) => {
    const t = windowStart + (span * i) / tickCount
    return { t, pct: (i / tickCount) * 100 }
  })

  const formatTick = (t: number) => {
    const d = new Date(t)
    if (span <= 24 * 60 * 60_000) {
      return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
    }
    return `${d.getMonth() + 1}/${d.getDate()} ${String(d.getHours()).padStart(2, '0')}h`
  }

  return html`
    <div class="relative h-6 border-b border-card-border text-[10px] text-text-dim font-mono">
      ${ticks.map(tick => html`
        <span
          class="absolute top-0 -translate-x-1/2 whitespace-nowrap"
          style="left: ${tick.pct}%;"
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
    <div class="inline-flex items-center gap-0.5 rounded-md border border-card-border p-0.5 text-[11px]">
      ${TIME_RANGE_PRESETS.map((preset: TimeRangePreset) => html`
        <button
          type="button"
          class="rounded px-2 py-0.5 font-medium transition-colors ${
            current === preset
              ? 'bg-accent/20 text-accent'
              : 'text-text-muted hover:text-text-strong hover:bg-white/5'
          }"
          onClick=${() => setTimeRangeFilter(preset)}
          aria-pressed=${current === preset}
        >
          ${timeRangeLabel(preset).replace('최근 ', '')}
        </button>
      `)}
    </div>
  `
}

// --- Main container ---

export function Observatory() {
  const state = useSignal<ObservatoryData>(emptyData())
  const activeController = useRef<AbortController | null>(null)
  const latestRequestId = useRef(0)

  useEffect(() => {
    const keeper = currentKeeperFilter() ?? undefined
    const range = currentTimeRangeFilter() ?? DEFAULT_RANGE

    activeController.current?.abort()
    const controller = new AbortController()
    activeController.current = controller
    const requestId = ++latestRequestId.current

    const now = Date.now()
    const windowStart = now - RANGE_TO_MS[range]
    const windowEnd = now

    state.value = { ...state.value, loading: true, error: null }

    Promise.allSettled([
      fetchTelemetry({ keeper, n: 500, signal: controller.signal }),
      fetchToolQuality({ n: 2000, signal: controller.signal }),
    ]).then(([telemetryResult, toolQualityResult]) => {
      if (controller.signal.aborted || requestId !== latestRequestId.current) return

      const events = telemetryResult.status === 'fulfilled'
        ? telemetryResult.value.entries.filter(entry => {
            const ts = entryTimestampMs(entry)
            return ts !== null && ts >= windowStart && ts <= windowEnd
          })
        : []

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
        hourlyTrend,
        windowStart,
        windowEnd,
      }
    })

    return () => { controller.abort() }
  }, [currentKeeperFilter(), currentTimeRangeFilter()])

  const data = state.value

  if (data.loading && data.events.length === 0 && data.hourlyTrend.length === 0) {
    return html`<${LoadingState}>관찰소 데이터 불러오는 중...<//>`
  }

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center justify-between">
        <div class="flex flex-col gap-0.5">
          <h3 class="text-[13px] font-semibold text-text-strong">관찰소 (Observatory)</h3>
          <p class="text-[11px] text-text-dim">
            ${currentKeeperFilter() ? `keeper=${currentKeeperFilter()}` : '전체 keeper'}
            · ${timeRangeLabel(currentTimeRangeFilter() ?? DEFAULT_RANGE)}
            · ${data.events.length} events
          </p>
        </div>
        <${RangeSelector} />
      </div>

      ${data.error ? html`
        <div class="rounded-lg border border-amber-500/20 bg-amber-500/5 px-3 py-2 text-[11px] text-amber-200">
          일부 데이터 불러오기 실패: ${data.error}
        </div>
      ` : null}

      <div class="flex flex-col gap-2 rounded-xl border border-card-border bg-card/30 p-4">
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
          <div class="mt-1 text-[10px] text-text-dim italic">
            hover any track for cross-signal readout
          </div>
        ` : null}
      </div>

      <${CrossSignalReadout}
        events=${data.events}
        hourlyTrend=${data.hourlyTrend}
        eventWindowMs=${Math.max(30_000, (data.windowEnd - data.windowStart) * 0.05)}
      />

      <p class="text-[10px] text-text-dim italic">
        Phase 2c — cross-signal readout card. 추가 track(메모리, autoresearch)과 drill-down은 이후 단계에서.
      </p>
    </div>
  `
}
