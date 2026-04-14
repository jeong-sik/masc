import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect, useMemo, useRef } from 'preact/hooks'
import { LoadingState } from './common/feedback-state'
import {
  fetchDashboardExecution,
  fetchTelemetrySummary,
  fetchToolQuality,
  type TelemetrySourceSummary,
  type ToolQualityResponse,
} from '../api/dashboard'
import { TELEMETRY_AUTO_REFRESH_MS } from '../config/constants'
import { formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { normalizeKeepers } from '../keeper-store-normalize'
import { formatTimeAgo } from '../lib/format-time'
import { isAbortError } from '../lib/async-state'
import {
  EMPTY_TOOL_QUALITY,
  PRESSURE_WARN_RATIO,
  STALE_ACTIVITY_SEC,
  buildFleetRows,
  buildRuntimeWarnings,
  buildTelemetryWarnings,
  emptyState,
  errorMessage,
  formatActivity,
  formatLatency,
  formatPercent,
  pressureClass,
  sourceCountClass,
  sourceDetail,
  sourceLabel,
  statusClass,
  successClass,
  summaryCounts,
  toneForPressure,
  toneForToolSuccess,
  toolSummary,
  type FleetRow,
  type FleetTelemetryState,
} from './fleet-telemetry-utils'

export { buildFleetRows }

function SummaryCard({
  title,
  value,
  detail,
  tone = 'neutral',
}: {
  title: string
  value: string
  detail: string
  tone?: 'neutral' | 'ok' | 'warn'
}) {
  const toneClass =
    tone === 'ok'
      ? 'border-emerald-500/20 bg-emerald-500/5'
      : tone === 'warn'
        ? 'border-amber-500/20 bg-amber-500/5'
        : 'border-[var(--card-border)] bg-[rgba(255,255,255,0.02)]'

  return html`
    <div class="rounded-lg border ${toneClass} p-3">
      <div class="text-[10px] uppercase tracking-wider text-[var(--text-dim)]">${title}</div>
      <div class="mt-1 text-xl font-semibold text-[var(--text)]">${value}</div>
      <div class="mt-1 text-[11px] leading-relaxed text-[var(--text-dim)]">${detail}</div>
    </div>
  `
}

function WarningBanner({ warnings }: { warnings: string[] }) {
  if (warnings.length === 0) return null
  return html`
    <div class="rounded-lg border border-amber-500/20 bg-amber-500/5 px-3 py-2 text-[11px] text-amber-200">
      <div class="font-medium text-amber-100">Partial telemetry</div>
      <div class="mt-1 flex flex-col gap-1">
        ${warnings.map(warning => html`<div>${warning}</div>`)}
      </div>
    </div>
  `
}

function PressureWatchlist({ rows }: { rows: FleetRow[] }) {
  const watchlist = rows
    .filter(row =>
      row.keepalive_running
      && (
        row.context_ratio >= PRESSURE_WARN_RATIO
        || (row.last_activity_ago_s != null && row.last_activity_ago_s >= STALE_ACTIVITY_SEC)
      ),
    )
    .slice(0, 5)

  if (watchlist.length === 0) {
    return html`
      <div class="rounded-lg border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)] p-3 text-[11px] text-[var(--text-dim)]">
        No keepers are near context pressure or stale activity thresholds.
      </div>
    `
  }

  return html`
    <div class="rounded-lg border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)]">
      ${watchlist.map(row => html`
        <div class="flex items-center justify-between gap-3 border-b border-[var(--card-border)] px-3 py-2 text-[11px] last:border-b-0">
          <div class="min-w-0">
            <div class="font-mono text-[var(--text)]">${row.name}</div>
            <div class="text-[var(--text-dim)]">
              ${row.last_activity_ago_s != null && row.last_activity_ago_s >= STALE_ACTIVITY_SEC
                ? `stale ${formatActivity(row.last_activity_ago_s)}`
                : `ctx ${formatPercent(row.context_ratio * 100, 1)}`}
            </div>
          </div>
          <div class="text-right">
            <div class="font-mono ${pressureClass(row.context_ratio)}">${formatPercent(row.context_ratio * 100, 1)}</div>
            <div class="text-[var(--text-dim)]">${formatActivity(row.last_activity_ago_s)}</div>
          </div>
        </div>
      `)}
    </div>
  `
}

function FleetComparisonTable({ rows }: { rows: FleetRow[] }) {
  if (rows.length === 0) {
    return html`<div class="text-[11px] text-[var(--text-dim)]">키퍼 fleet 데이터 없음.</div>`
  }

  return html`
    <div class="overflow-x-auto">
      <table class="w-full text-[11px]">
        <thead>
          <tr class="border-b border-[var(--card-border)] text-[var(--text-dim)]">
            <th class="py-1 text-left font-normal">Keeper</th>
            <th class="py-1 text-right font-normal">Status</th>
            <th class="py-1 text-right font-normal">Activity</th>
            <th class="py-1 text-right font-normal">Tools</th>
            <th class="py-1 text-right font-normal">Success</th>
            <th class="py-1 text-right font-normal">Ctx</th>
            <th class="py-1 text-right font-normal">Latency</th>
            <th class="py-1 text-right font-normal">Model</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map(row => {
            const toolInfo = toolSummary(row)
            return html`
            <tr class="border-b border-[var(--card-border)] border-opacity-30 align-top">
              <td class="py-1.5">
                <div class="font-mono text-[var(--text)]">${row.name}</div>
                ${row.runtime_blocker_summary
                  ? html`
                    <div class="max-w-[240px] truncate text-[10px] text-amber-300" title=${row.runtime_blocker_summary}>
                      ${row.runtime_blocker_summary}
                    </div>
                  `
                  : null}
                <div class="max-w-[240px] truncate text-[10px] text-[var(--text-dim)]" title=${toolInfo.title}>
                  ${toolInfo.label}
                </div>
              </td>
              <td class="py-1.5 text-right font-mono ${statusClass(row)}">${row.status}</td>
              <td class="py-1.5 text-right text-[var(--text-dim)]">${formatActivity(row.last_activity_ago_s)}</td>
              <td class="py-1.5 text-right font-mono text-[var(--text)]">${row.tool_calls.toLocaleString()}</td>
              <td class="py-1.5 text-right font-mono ${successClass(row.tool_success_pct)}">
                ${formatPercent(row.tool_success_pct, 1)}
              </td>
              <td class="py-1.5 text-right font-mono ${pressureClass(row.context_ratio)}">${formatPercent(row.context_ratio * 100, 1)}</td>
              <td class="py-1.5 text-right text-[var(--text-dim)]">${formatLatency(row.last_latency_ms)}</td>
              <td class="py-1.5 text-right text-[10px] text-[var(--text-dim)]">${row.model}</td>
            </tr>
          `})}
        </tbody>
      </table>
    </div>
  `
}

function TelemetrySourcesPanel({ sources }: { sources: TelemetrySourceSummary[] }) {
  if (sources.length === 0) {
    return html`<div class="text-[11px] text-[var(--text-dim)]">Telemetry store summary is unavailable.</div>`
  }

  const sorted = [...sources].sort((a, b) => b.entry_count - a.entry_count)
  return html`
    <div class="grid grid-cols-1 gap-2 md:grid-cols-2">
      ${sorted.map(source => html`
        <div class="rounded-lg border border-[var(--card-border)] bg-[rgba(255,255,255,0.02)] p-3">
          <div class="flex items-center justify-between gap-3">
            <div class="text-[11px] font-medium text-[var(--text)]">${sourceLabel(source.source)}</div>
            <div class="font-mono text-[11px] ${sourceCountClass(source)}">
              ${source.entry_count.toLocaleString()}
            </div>
          </div>
          <div class="mt-1 text-[10px] text-[var(--text-dim)]">${sourceDetail(source)}</div>
        </div>
      `)}
    </div>
  `
}

function FailureCategoryPanel({ toolQuality }: { toolQuality: ToolQualityResponse }) {
  if (toolQuality.failure_categories.length === 0) {
    return html`<div class="text-[11px] text-[var(--text-dim)]">최근 실패 카테고리 없음.</div>`
  }

  const top = toolQuality.failure_categories.slice(0, 8)
  const maxCount = top[0]?.count ?? 1

  return html`
    <div class="flex flex-col gap-1.5">
      ${top.map(category => html`
        <div class="flex items-center gap-2 text-[11px]">
          <div class="flex min-w-0 flex-1 items-center gap-1.5">
            <div
              class="h-1.5 rounded-full bg-red-500/60"
              style="width: ${Math.max(6, (category.count / maxCount) * 100)}%"
            ></div>
            <span class="truncate font-mono text-red-300" title=${category.category}>${category.category}</span>
          </div>
          <span class="text-[var(--text-dim)]">${category.count}</span>
        </div>
      `)}
    </div>
  `
}

export function FleetTelemetryPanel() {
  const latestRequestId = useRef(0)
  const activeController = useRef<AbortController | null>(null)
  const state = useSignal<FleetTelemetryState>(emptyState())

  const loadFleetTelemetry = async () => {
    activeController.current?.abort()
    const controller = new AbortController()
    activeController.current = controller
    const requestId = ++latestRequestId.current
    state.value = {
      ...state.value,
      loading: true,
      error: null,
      warnings: [],
    }

    try {
      const [executionResult, toolQualityResult, telemetrySummaryResult] = await Promise.allSettled([
        fetchDashboardExecution({ signal: controller.signal }),
        fetchToolQuality({ n: 5000, signal: controller.signal }),
        fetchTelemetrySummary({ signal: controller.signal }),
      ])

      if (controller.signal.aborted || requestId !== latestRequestId.current) return

      const warnings: string[] = []

      const keepers =
        executionResult.status === 'fulfilled'
          ? normalizeKeepers(executionResult.value.keepers)
          : []
      if (executionResult.status === 'rejected' && !isAbortError(executionResult.reason)) {
        warnings.push(`Execution snapshot unavailable: ${errorMessage(executionResult.reason)}`)
      }

      const toolQuality =
        toolQualityResult.status === 'fulfilled'
          ? toolQualityResult.value
          : EMPTY_TOOL_QUALITY
      if (toolQualityResult.status === 'rejected' && !isAbortError(toolQualityResult.reason)) {
        warnings.push(`Tool quality unavailable: ${errorMessage(toolQualityResult.reason)}`)
      }

      const telemetrySummary =
        telemetrySummaryResult.status === 'fulfilled'
          ? telemetrySummaryResult.value
          : { generated_at: '', sources: [], total_entries: 0 }
      if (telemetrySummaryResult.status === 'rejected' && !isAbortError(telemetrySummaryResult.reason)) {
        warnings.push(`Telemetry store summary unavailable: ${errorMessage(telemetrySummaryResult.reason)}`)
      }
      warnings.push(...buildTelemetryWarnings(telemetrySummary.sources))

      const rows = buildFleetRows(keepers, toolQuality)
      warnings.push(...buildRuntimeWarnings(rows))
      const updatedAt =
        (executionResult.status === 'fulfilled' ? executionResult.value.generated_at : null)
        || telemetrySummary.generated_at
        || new Date().toISOString()

      const hasAnyData =
        rows.length > 0
        || toolQuality.total > 0
        || telemetrySummary.total_entries > 0

      state.value = {
        loading: false,
        error: hasAnyData ? null : 'No fleet telemetry data available.',
        warnings,
        rows,
        tool_quality: toolQuality,
        telemetry_sources: telemetrySummary.sources,
        total_telemetry_entries: telemetrySummary.total_entries,
        updated_at: updatedAt,
      }
    } finally {
      if (activeController.current === controller) {
        activeController.current = null
      }
    }
  }

  useEffect(() => {
    void loadFleetTelemetry()
    const disposeAutoRefresh = setupVisibleAutoRefresh(loadFleetTelemetry, TELEMETRY_AUTO_REFRESH_MS)
    return () => {
      disposeAutoRefresh()
      activeController.current?.abort()
      activeController.current = null
    }
  }, [])

  const value = state.value
  const counts = useMemo(() => summaryCounts(value.rows), [value.rows])
  const liveTone: 'neutral' | 'ok' | 'warn' =
    value.rows.length === 0
      ? 'neutral'
      : counts.live === value.rows.length
        ? 'ok'
        : 'warn'
  const sourcesWithData = value.telemetry_sources.filter(source => source.entry_count > 0).length

  if (value.loading && value.rows.length === 0) {
    return html`<${LoadingState}>Fleet 텔레메트리 불러오는 중...<//>`
  }

  if (value.error) {
    return html`<div class="p-4 text-[11px] text-red-400">${value.error}</div>`
  }

  return html`
    <div class="flex flex-col gap-4 p-4">
      <div class="flex items-start justify-between gap-3">
        <div>
          <h2 class="text-sm font-medium">Fleet Telemetry</h2>
          <div class="text-[10px] text-[var(--text-dim)]">
            ${value.updated_at ? `Updated ${formatTimeAgo(value.updated_at)}` : 'Runtime + telemetry store view'}
          </div>
        </div>
        <div class="flex items-center gap-2">
          <button
            class="rounded bg-[var(--bg-subtle)] px-2 py-0.5 text-[10px] text-[var(--text-dim)] hover:text-[var(--text)]"
            onClick=${() => { void loadFleetTelemetry() }}
            aria-label="Fleet 텔레메트리 새로고침"
          >새로고침</button>
          <span class="text-[10px] text-[var(--text-dim)]">${formatAutoRefreshLabel(TELEMETRY_AUTO_REFRESH_MS)}</span>
        </div>
      </div>

      <${WarningBanner} warnings=${value.warnings} />

      <div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-4">
        <${SummaryCard}
          title="Fleet Coverage"
          value=${`${counts.live}/${value.rows.length || 0}`}
          detail=${`${counts.toolCovered}/${value.rows.length || 0} keepers surfaced recent tool activity.`}
          tone=${liveTone}
        />
        <${SummaryCard}
          title="Runtime Pressure"
          value=${`${counts.hot} hot / ${counts.warn} warn`}
          detail=${counts.stale > 0 ? `${counts.stale} keepers are stale beyond ${Math.round(STALE_ACTIVITY_SEC / 60)}m.` : 'No stale keepers crossed the activity threshold.'}
          tone=${toneForPressure(counts.hot, counts.warn)}
        />
        <${SummaryCard}
          title="Tool Success"
          value=${value.tool_quality.total > 0 ? formatPercent(value.tool_quality.success_rate, 1) : 'n/a'}
          detail=${value.tool_quality.total > 0
            ? `${value.tool_quality.failure.toLocaleString()} failures across ${value.tool_quality.total.toLocaleString()} recent calls.`
            : 'No recent tool quality samples were recorded.'}
          tone=${value.tool_quality.total > 0 ? toneForToolSuccess(value.tool_quality.success_rate) : 'neutral'}
        />
        <${SummaryCard}
          title="Telemetry Stores"
          value=${value.total_telemetry_entries.toLocaleString()}
          detail=${`${sourcesWithData}/${value.telemetry_sources.length || 0} stores currently have data.`}
          tone=${sourcesWithData > 0 ? 'ok' : 'warn'}
        />
      </div>

      <div>
        <div class="mb-1 text-[10px] uppercase tracking-wider text-[var(--text-dim)]">Pressure Watchlist</div>
        <${PressureWatchlist} rows=${value.rows} />
      </div>

      <div>
        <div class="mb-1 text-[10px] uppercase tracking-wider text-[var(--text-dim)]">Keeper Comparison</div>
        <${FleetComparisonTable} rows=${value.rows} />
      </div>

      <div>
        <div class="mb-1 text-[10px] uppercase tracking-wider text-[var(--text-dim)]">Telemetry Sources</div>
        <${TelemetrySourcesPanel} sources=${value.telemetry_sources} />
      </div>

      <div>
        <div class="mb-1 text-[10px] uppercase tracking-wider text-[var(--text-dim)]">Failure Categories</div>
        <${FailureCategoryPanel} toolQuality=${value.tool_quality} />
      </div>
    </div>
  `
}
