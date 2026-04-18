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
import { LoadingState } from '../common/feedback-state'
import { Live } from '../live'
import { ObservatoryActivityPanels } from '../activity-graph'

const DEFAULT_RANGE: TimeRangePreset = '1h'
const observatoryRefreshVersion = signal(0)
type ObservatoryView = 'timeline' | 'live'

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
          ${timeRangeShortLabel(preset)}
        </button>
      `)}
    </div>
  `
}

function ViewSelector({
  current,
  onSelect,
}: {
  current: ObservatoryView
  onSelect: (view: ObservatoryView) => void
}) {
  return html`
    <div class="inline-flex items-center gap-0.5 rounded-md border border-card-border p-0.5 text-[11px]">
      ${([
        { key: 'timeline', label: '타임라인' },
        { key: 'live', label: '라이브' },
      ] as const).map(view => html`
        <button
          type="button"
          class="rounded px-2 py-0.5 font-medium transition-colors ${
            current === view.key
              ? 'bg-accent/20 text-accent'
              : 'text-text-muted hover:text-text-strong hover:bg-white/5'
          }"
          onClick=${() => onSelect(view.key)}
          aria-pressed=${current === view.key}
        >
          ${view.label}
        </button>
      `)}
    </div>
  `
}

// --- Main container ---

const LIVE_INTERVAL_MS = 30_000

export function refreshObservatorySurface(): void {
  observatoryRefreshVersion.value += 1
}

export function Observatory() {
  const state = useSignal<ObservatoryData>(emptyData())
  const liveMode = useSignal(false)
  const refreshTick = useSignal(0)
  const activeView = useSignal<ObservatoryView>('timeline')
  const activeController = useRef<AbortController | null>(null)
  const latestRequestId = useRef(0)

  useEffect(() => {
    if (activeView.value !== 'timeline' || !liveMode.value) return
    const id = setInterval(() => { refreshTick.value++ }, LIVE_INTERVAL_MS)
    return () => clearInterval(id)
  }, [activeView.value, liveMode.value])

  useEffect(() => registerActivityRefresh(() => {
    refreshObservatorySurface()
  }), [])

  useEffect(() => {
    if (activeView.value !== 'timeline') {
      activeController.current?.abort()
      activeController.current = null
      return
    }

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
  }, [activeView.value, currentKeeperFilter(), currentTimeRangeFilter(), refreshTick.value, observatoryRefreshVersion.value])

  const data = state.value
  const hasTrackData = data.events.length > 0 || data.hourlyTrend.length > 0

  return html`
    <div class="flex flex-col gap-5">
      <div class="flex items-center justify-between">
        <div class="flex flex-col gap-0.5">
          <h3 class="text-[13px] font-semibold text-text-strong">관찰소 (Observatory)</h3>
          <p class="text-[11px] text-text-dim">
            ${activeView.value === 'timeline'
              ? html`
                  ${currentKeeperFilter() ? `keeper=${currentKeeperFilter()}` : '전체 keeper'}
                  · ${timeRangeLabel(currentTimeRangeFilter() ?? DEFAULT_RANGE)}
                  · ${data.totalMatchingEvents} events
                  ${data.truncatedEvents ? ` · showing ${data.events.length}` : ''}
                  ${liveMode.value ? ' · 30s 자동 갱신' : ''}
                `
              : '실시간 스트림과 에이전트 상태를 한곳에서 봅니다.'}
          </p>
        </div>
        <div class="flex items-center gap-2">
          <${ViewSelector}
            current=${activeView.value}
            onSelect=${(view: ObservatoryView) => { activeView.value = view }}
          />
          ${activeView.value === 'timeline' ? html`
            <${RangeSelector} />
            <button
              type="button"
              class="inline-flex items-center gap-1.5 rounded-md border px-2.5 py-1 text-[11px] font-medium transition-colors ${
                liveMode.value
                  ? 'border-emerald-500/40 bg-emerald-500/10 text-[var(--ok)]'
                  : 'border-card-border text-text-muted hover:text-text-strong hover:bg-white/5'
              }"
              onClick=${() => {
                liveMode.value = !liveMode.value
                if (liveMode.value) refreshTick.value++
              }}
              aria-pressed=${liveMode.value}
            >
              ${liveMode.value ? html`
                <span class="relative flex h-2 w-2">
                  <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span>
                  <span class="relative inline-flex rounded-full h-2 w-2 bg-emerald-400"></span>
                </span>
                자동 갱신
              ` : '자동 갱신'}
            </button>
          ` : null}
        </div>
      </div>

      ${activeView.value === 'timeline' && data.error ? html`
        <div class="rounded-lg border border-amber-500/20 bg-amber-500/5 px-3 py-2 text-[11px] text-[var(--warn)]">
          일부 데이터 불러오기 실패: ${data.error}
        </div>
      ` : null}

      ${activeView.value === 'live'
        ? html`<${Live} variant="observatory" />`
        : !hasTrackData && data.loading
        ? html`<${LoadingState}>관찰소 데이터 불러오는 중...<//>`
        : html`
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

            <${DetailPane} />
          `}

      ${activeView.value === 'timeline' ? html`<${ObservatoryActivityPanels} />` : null}

      ${activeView.value === 'timeline' ? html`
        <p class="text-[10px] text-text-dim italic">
        Phase 3a — anomaly highlight. 추가 track(메모리, autoresearch)과 compare mode는 이후 단계에서.
        </p>
      ` : null}
    </div>
  `
}
