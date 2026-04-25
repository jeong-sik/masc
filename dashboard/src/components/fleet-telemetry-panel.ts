import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect, useMemo, useRef } from 'preact/hooks'
import { RotateCcw } from 'lucide-preact'
import { LoadingState } from './common/feedback-state'
import {
  fetchDashboardExecution,
  fetchDashboardNamespaceTruth,
  fetchTelemetrySummary,
  fetchToolQuality,
  type TelemetrySourceSummary,
  type ToolQualityResponse,
} from '../api/dashboard'
import { resetKeeper } from '../api/keeper'
import { TELEMETRY_AUTO_REFRESH_MS } from '../config/constants'
import { formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { useSavedSignal } from '../lib/saved-signal'
import { normalizeKeepers } from '../keeper-store-normalize'
import { normalizeNamespaceTruth } from '../namespace-truth-normalizers'
import { formatTimeAgo } from '../lib/format-time'
import { TimeAgo } from './common/time-ago'
import { isAbortError } from '../lib/async-state'
import { requestConfirm } from './common/confirm-dialog'
import { Sparkline } from './common/sparkline'
import { pushSnapshot, getTrend, type MetricKey, type TrendDirection } from './fleet-trend-store'
import type { DashboardAttentionEvent, DashboardReadinessPillar } from '../types'
import {
  EMPTY_TOOL_QUALITY,
  PRESSURE_WARN_RATIO,
  STALE_ACTIVITY_SEC,
  buildFleetRows,
  buildRuntimeWarnings,
  buildTelemetryWarnings,
  emptyState,
  errorMessage,
  fleetBand,
  formatActivitySignal,
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

/**
 * Pure filter for fleet rows.
 *
 * Case-insensitive substring match on `row.name`, `row.model`, and
 * `row.runtime_blocker_class` so operators can locate a keeper by
 * partial name, by the model it is running, or by its current blocker.
 *
 * Empty/whitespace query returns the input reference unchanged (no
 * new array allocation, preserves referential equality for memoisation).
 *
 * Input is never mutated.
 */
export function filterFleetRows(
  rows: readonly FleetRow[],
  query: string,
): readonly FleetRow[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return rows
  return rows.filter(row => {
    if (row.name.toLowerCase().includes(needle)) return true
    if (row.model && row.model.toLowerCase().includes(needle)) return true
    if (row.runtime_blocker_class && row.runtime_blocker_class.toLowerCase().includes(needle)) return true
    return false
  })
}

// Whether "up" is bad for a given metric. context_ratio and latency going up = bad.
function isUpBad(metric: MetricKey): boolean {
  return metric === 'context_ratio' || metric === 'last_latency_ms'
}

function trendArrow(direction: TrendDirection): string {
  if (direction === 'up') return '\u2191'
  if (direction === 'down') return '\u2193'
  return ''
}

function trendColorClass(direction: TrendDirection, metric: MetricKey): string {
  if (direction === 'flat') return 'text-[var(--text-dim)]'
  const bad = (direction === 'up' && isUpBad(metric)) || (direction === 'down' && !isUpBad(metric))
  return bad ? 'text-[var(--bad-light)]' : 'text-[var(--ok)]'
}

function sparklineColor(metric: MetricKey, direction: TrendDirection): string {
  if (direction === 'flat') return 'var(--slate-500)'
  const bad = (direction === 'up' && isUpBad(metric)) || (direction === 'down' && !isUpBad(metric))
  return bad ? 'var(--bad-light)' : '#34d399'
}

function auditFreshnessClass(isoTimestamp: string | null): string {
  if (!isoTimestamp) return 'text-[var(--text-dim)]'
  const ageMs = Date.now() - new Date(isoTimestamp).getTime()
  if (ageMs < 5 * 60 * 1000) return 'text-[var(--text)]'
  if (ageMs < 15 * 60 * 1000) return 'text-[var(--text-dim)]'
  return 'text-[var(--warn)]'
}

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
      ? 'border-[var(--ok-20)] bg-[var(--ok-10)]'
      : tone === 'warn'
        ? 'border-[var(--warn-20)] bg-[var(--warn-10)]'
        : 'border-[var(--card-border)] bg-[var(--white-1)]'

  return html`
    <div class="rounded border ${toneClass} p-3">
      <div class="text-3xs uppercase tracking-wider text-[var(--text-dim)]">${title}</div>
      <div class="mt-1 text-xl font-semibold text-[var(--text)]">${value}</div>
      <div class="mt-1 text-2xs leading-relaxed text-[var(--text-dim)]">${detail}</div>
    </div>
  `
}

function WarningBanner({ warnings }: { warnings: string[] }) {
  if (warnings.length === 0) return null
  return html`
    <div class="rounded border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs text-[var(--warn)]">
      <div class="font-medium text-[var(--warn)]">Partial telemetry</div>
      <div class="mt-1 flex flex-col gap-1">
        ${warnings.map(warning => html`<div>${warning}</div>`)}
      </div>
    </div>
  `
}

function readinessTone(status: string | null | undefined): 'neutral' | 'ok' | 'warn' {
  if (status === 'ok') return 'ok'
  if (status === 'warn' || status === 'bad') return 'warn'
  return 'neutral'
}

function readinessStatusClass(status: string | null | undefined): string {
  if (status === 'ok') return 'text-[var(--ok)]'
  if (status === 'warn') return 'text-[var(--warn)]'
  if (status === 'bad') return 'text-[var(--bad-light)]'
  return 'text-[var(--text-dim)]'
}

function attentionSeverityClass(severity: string | null | undefined): string {
  if (severity === 'bad') return 'border-[var(--bad-20)] bg-[var(--bad-10)] text-[var(--bad-light)]'
  if (severity === 'warn') return 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--warn)]'
  return 'border-[var(--card-border)] bg-[var(--white-1)] text-[var(--text-dim)]'
}

function ReadinessPillarCard({ pillar }: { pillar: DashboardReadinessPillar }) {
  return html`
    <div class="rounded border border-[var(--card-border)] bg-[var(--white-1)] p-3">
      <div class="flex items-center justify-between gap-3">
        <div class="text-2xs font-medium text-[var(--text)]">${pillar.label}</div>
        <div class="font-mono text-2xs ${readinessStatusClass(pillar.status)}">
          ${pillar.score.toFixed(2)}
        </div>
      </div>
      <div class="mt-1 text-3xs ${readinessStatusClass(pillar.status)}">${pillar.summary}</div>
      ${pillar.blocking_reasons.length > 0
        ? html`
          <div class="mt-2 flex flex-col gap-1 text-3xs text-[var(--text-dim)]">
            ${pillar.blocking_reasons.slice(0, 2).map(reason => html`<div>${reason}</div>`)}
          </div>
        `
        : null}
    </div>
  `
}

function AttentionEventList({ events }: { events: DashboardAttentionEvent[] }) {
  if (events.length === 0) {
    return html`
      <div class="rounded border border-[var(--card-border)] bg-[var(--white-1)] p-3 text-2xs text-[var(--text-dim)]">
        No decision-needed or blocker events are active.
      </div>
    `
  }

  return html`
    <div class="flex flex-col gap-2">
      ${events.slice(0, 6).map(event => html`
        <div class="rounded border px-3 py-2 ${attentionSeverityClass(event.severity)}">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="text-2xs font-medium">
                ${event.keeper_name ? `${event.keeper_name} · ${event.kind}` : event.kind}
              </div>
              <div class="mt-0.5 text-3xs leading-relaxed">${event.summary}</div>
            </div>
            ${event.requires_decision
              ? html`<span class="rounded bg-[var(--white-8)] px-1.5 py-0.5 text-3xs font-semibold">DECISION</span>`
              : null}
          </div>
          ${event.recommended_action
            ? html`<div class="mt-1 text-3xs text-[var(--text-dim)]">Next: ${event.recommended_action}</div>`
            : null}
        </div>
      `)}
    </div>
  `
}

function ControlRoomPanel({ state }: { state: FleetTelemetryState }) {
  const truth = state.namespace_truth
  const readiness = truth?.readiness ?? null
  const attentionEvents = truth?.attention_events ?? []
  const pendingApprovals = truth?.operator?.pending_confirm_summary?.visible_count
    ?? truth?.operator?.pending_confirm_summary?.total_count
    ?? 0

  if (!truth || !readiness) {
    return html`
      <div class="rounded border border-[var(--card-border)] bg-[var(--white-1)] p-3 text-2xs text-[var(--text-dim)]">
        Control room readiness is unavailable for this refresh.
      </div>
    `
  }

  return html`
    <div class="flex flex-col gap-3">
      <div class="grid grid-cols-1 gap-3 xl:grid-cols-4">
        <${SummaryCard}
          title="Readiness"
          value=${readiness.score.toFixed(2)}
          detail=${`${readiness.blocking_count} blockers · ${readiness.decision_required_count} decisions required.`}
          tone=${readinessTone(readiness.status)}
        />
        <${SummaryCard}
          title="Approvals"
          value=${pendingApprovals.toString()}
          detail=${pendingApprovals > 0 ? 'Operator approval queue is non-empty.' : 'No pending approvals are visible.'}
          tone=${pendingApprovals > 0 ? 'warn' : 'ok'}
        />
        <${SummaryCard}
          title="Attention"
          value=${attentionEvents.length.toString()}
          detail=${attentionEvents.length > 0 ? 'Critical blockers and pause-worthy states are surfaced here.' : 'No active attention events are reported.'}
          tone=${attentionEvents.length > 0 ? 'warn' : 'ok'}
        />
        <${SummaryCard}
          title="Goal Scope"
          value=${state.rows.length > 0 ? `${state.rows.filter(row => row.goal_linked).length}/${state.rows.length}` : '0/0'}
          detail=${state.rows.some(row => !row.goal_linked) ? 'Some keepers are active without a visible goal link.' : 'All surfaced keepers have a goal anchor.'}
          tone=${state.rows.length === 0 || state.rows.every(row => row.goal_linked) ? 'ok' : 'warn'}
        />
      </div>

      <div class="grid grid-cols-1 gap-3 xl:grid-cols-[minmax(0,2fr)_minmax(0,1.3fr)]">
        <div>
          <div class="mb-1 text-3xs uppercase tracking-wider text-[var(--text-dim)]">준비 상태 핵심 지표</div>
          <div class="grid grid-cols-1 gap-2 md:grid-cols-2">
            ${readiness.pillars.map(pillar => html`<${ReadinessPillarCard} pillar=${pillar} />`)}
          </div>
        </div>
        <div>
          <div class="mb-1 text-3xs uppercase tracking-wider text-[var(--text-dim)]">주의 이벤트</div>
          <${AttentionEventList} events=${attentionEvents} />
        </div>
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
      <div class="rounded border border-[var(--card-border)] bg-[var(--white-1)] p-3 text-2xs text-[var(--text-dim)]">
        No keepers are near context pressure or stale activity thresholds.
      </div>
    `
  }

  return html`
    <div class="rounded border border-[var(--card-border)] bg-[var(--white-1)]">
      ${watchlist.map(row => html`
        <div class="flex items-center justify-between gap-3 border-b border-[var(--card-border)] px-3 py-2 text-2xs last:border-b-0">
          <div class="min-w-0">
            <div class="font-mono text-[var(--text)]">${row.name}</div>
            <div class="text-[var(--text-dim)]">
              ${row.last_activity_ago_s != null && row.last_activity_ago_s >= STALE_ACTIVITY_SEC
                ? `stale ${formatActivitySignal(row)}`
                : `ctx ${formatPercent(row.context_ratio * 100, 1)}`}
            </div>
          </div>
          <div class="text-right">
            <div class="font-mono ${pressureClass(row.context_ratio)}">${formatPercent(row.context_ratio * 100, 1)}</div>
            <div class="text-[var(--text-dim)]">${formatActivitySignal(row)}</div>
          </div>
        </div>
      `)}
    </div>
  `
}

function TrendCell({ name, metric, value, valueClass }: {
  name: string
  metric: MetricKey
  value: string
  valueClass: string
}) {
  const trend = getTrend(name, metric)
  const arrow = trend ? trendArrow(trend.direction) : ''
  const colorClass = trend ? trendColorClass(trend.direction, metric) : ''
  const sColor = trend ? sparklineColor(metric, trend.direction) : 'var(--slate-500)'

  return html`
    <td class="py-1.5 text-right">
      <div class="flex items-center justify-end gap-1">
        <span class="font-mono ${valueClass}">${value}</span>
        ${arrow ? html`<span class="text-3xs ${colorClass}">${arrow}</span>` : null}
      </div>
      ${trend && trend.values.length >= 2
        ? html`<div class="mt-0.5 flex justify-end"><${Sparkline} values=${trend.values} width=${48} height=${14} color=${sColor} /></div>`
        : null}
    </td>
  `
}

function FleetComparisonTable({ rows, onReset }: { rows: FleetRow[]; onReset: (name: string) => void }) {
  if (rows.length === 0) {
    return html`<div class="text-2xs text-[var(--text-dim)]" role="status">Keeper 데이터 없음.</div>`
  }

  return html`
    <div class="overflow-x-auto">
      <table class="w-full text-2xs" aria-label="Fleet 텔레메트리">
        <thead>
          <tr class="border-b border-[var(--card-border)] text-[var(--text-dim)]">
            <th scope="col" class="py-1 text-left font-normal">Keeper</th>
            <th scope="col" class="py-1 text-right font-normal">Status</th>
            <th scope="col" class="py-1 text-right font-normal">Activity</th>
            <th scope="col" class="py-1 text-right font-normal">측정</th>
            <th scope="col" class="py-1 text-right font-normal">Tools</th>
            <th scope="col" class="py-1 text-right font-normal">Success</th>
            <th scope="col" class="py-1 text-right font-normal">Ctx</th>
            <th scope="col" class="py-1 text-right font-normal">Latency</th>
            <th scope="col" class="py-1 text-right font-normal">Model</th>
            <th scope="col" class="py-1 text-center font-normal">Budget</th>
            <th scope="col" class="w-8 py-1"><span class="sr-only">확장</span></th>
          </tr>
        </thead>
        <tbody>
          ${rows.map(row => {
            const toolInfo = toolSummary(row)
            const diagnosticState = row.diagnostic_health_state?.trim().toLowerCase() ?? null
            const rowHint =
              row.runtime_blocker_summary
              ?? (
                diagnosticState
                && diagnosticState !== 'healthy'
                && diagnosticState !== 'idle'
                  ? row.diagnostic_summary ?? null
                  : null
              )
            const rowHintClass =
              diagnosticState === 'offline' || diagnosticState === 'dead'
                ? 'text-[var(--bad-light)]'
                : 'text-[var(--warn)]'
            return html`
            <tr class="border-b border-[var(--card-border)] border-opacity-30 align-top">
              <td class="py-1.5">
                <div class="font-mono text-[var(--text)]">${row.name}</div>
                ${rowHint
                  ? html`
                    <div class="max-w-60 truncate text-3xs ${rowHintClass}" title=${rowHint}>
                      ${rowHint}
                    </div>
                  `
                  : null}
                <div class="max-w-60 truncate text-3xs text-[var(--text-dim)]" title=${toolInfo.title}>
                  ${toolInfo.label}
                </div>
                <div class="mt-1 flex max-w-60 flex-wrap gap-1">
                  <span
                    class=${row.goal_linked
                      ? 'rounded bg-[var(--ok-10)] px-1.5 py-0.5 text-3xs text-[var(--ok)]'
                      : 'rounded bg-[var(--warn-10)] px-1.5 py-0.5 text-3xs text-[var(--warn)]'}
                    title=${row.goal_label ?? 'No active goal is linked to this keeper.'}
                  >
                    ${row.goal_label
                      ? (row.active_goal_count > 1 ? `goal ${row.active_goal_count}` : 'goal linked')
                      : 'goal missing'}
                  </span>
                  <span
                    class=${row.sandbox_profile
                      ? 'rounded bg-[var(--white-8)] px-1.5 py-0.5 text-3xs text-[var(--text-dim)]'
                      : 'rounded bg-[var(--warn-10)] px-1.5 py-0.5 text-3xs text-[var(--warn)]'}
                    title=${row.effective_sandbox_image ?? row.sandbox_profile ?? 'Sandbox profile unavailable.'}
                  >
                    ${row.sandbox_profile ? `sandbox ${row.sandbox_profile}` : 'sandbox unknown'}
                  </span>
                  ${row.decision_required
                    ? html`<span class="rounded bg-[var(--bad-10)] px-1.5 py-0.5 text-3xs text-[var(--bad-light)]">decision</span>`
                    : null}
                </div>
                ${row.goal_label
                  ? html`<div class="max-w-60 truncate text-3xs text-[var(--text-dim)]" title=${row.goal_label}>${row.goal_label}</div>`
                  : null}
                ${row.sandbox_last_error
                  ? html`
                    <div class="max-w-60 truncate text-3xs text-[var(--bad-light)]" title=${row.sandbox_last_error}>
                      ${row.sandbox_last_error}
                    </div>
                  `
                  : null}
              </td>
              <td class="py-1.5 text-right font-mono ${statusClass(row)}">${row.status}</td>
              <td class="py-1.5 text-right text-[var(--text-dim)]">${formatActivitySignal(row)}</td>
              <td class="py-1.5 text-right text-3xs ${auditFreshnessClass(row.tool_audit_at)}" title=${row.tool_audit_at ?? ''}>
                ${row.tool_audit_at ? html`<${TimeAgo} timestamp=${row.tool_audit_at} />` : '-'}
              </td>
              <${TrendCell}
                name=${row.name} metric="tool_calls"
                value=${row.tool_calls.toLocaleString()}
                valueClass="text-[var(--text)]"
              />
              <${TrendCell}
                name=${row.name} metric="tool_success_pct"
                value=${formatPercent(row.tool_success_pct, 1)}
                valueClass=${successClass(row.tool_success_pct)}
              />
              <${TrendCell}
                name=${row.name} metric="context_ratio"
                value=${formatPercent(row.context_ratio * 100, 1)}
                valueClass=${pressureClass(row.context_ratio)}
              />
              <${TrendCell}
                name=${row.name} metric="last_latency_ms"
                value=${formatLatency(row.last_latency_ms)}
                valueClass="text-[var(--text-dim)]"
              />
              <td class="py-1.5 text-right text-3xs text-[var(--text-dim)]">${row.model}</td>
              <td class="py-1.5 text-center">
                ${row.budget_source === 'override_invalid'
                  ? html`<span class="rounded bg-[var(--bad-10)] px-1.5 py-0.5 text-3xs font-semibold text-[var(--bad-light)]" title="TOML override가 범위를 벗어남">ERR</span>`
                  : row.budget_source === 'override'
                    ? html`<span class="rounded bg-[var(--warn-10)] px-1.5 py-0.5 text-3xs font-semibold text-[var(--warn)]" title="TOML override 적용됨">OVR</span>`
                    : html`<span class="text-3xs text-[var(--text-dim)]">\u2014</span>`}
              </td>
              <td class="py-1.5 text-center">
                <button type="button"
                  class="rounded p-0.5 text-[var(--text-dim)] hover:text-[var(--bad-light)] hover:bg-[var(--bad-10)] transition-colors"
                  onClick=${() => onReset(row.name)}
                  title="초기화"
                  aria-label=${`${row.name} 초기화`}
                >
                  <${RotateCcw} size=${12} aria-hidden="true" />
                </button>
              </td>
            </tr>
          `})}
        </tbody>
      </table>
    </div>
  `
}

function TelemetrySourcesPanel({ sources }: { sources: TelemetrySourceSummary[] }) {
  if (sources.length === 0) {
    return html`<div class="text-2xs text-[var(--text-dim)]" role="status">Telemetry store summary is unavailable.</div>`
  }

  const sorted = [...sources].sort((a, b) => b.entry_count - a.entry_count)
  return html`
    <div class="grid grid-cols-1 gap-2 md:grid-cols-2">
      ${sorted.map(source => html`
        <div class="rounded border border-[var(--card-border)] bg-[var(--white-1)] p-3">
          <div class="flex items-center justify-between gap-3">
            <div class="text-2xs font-medium text-[var(--text)]">${sourceLabel(source.source)}</div>
            <div class="font-mono text-2xs ${sourceCountClass(source)}">
              ${source.entry_count.toLocaleString()}
            </div>
          </div>
          <div class="mt-1 text-3xs text-[var(--text-dim)]">${sourceDetail(source)}</div>
        </div>
      `)}
    </div>
  `
}

function FailureCategoryPanel({ toolQuality }: { toolQuality: ToolQualityResponse }) {
  if (toolQuality.failure_categories.length === 0) {
    return html`<div class="text-2xs text-[var(--text-dim)]" role="status">최근 실패 카테고리 없음.</div>`
  }

  const top = toolQuality.failure_categories.slice(0, 8)
  const maxCount = top[0]?.count ?? 1

  return html`
    <div class="flex flex-col gap-1.5">
      ${top.map(category => html`
        <div class="flex items-center gap-2 text-2xs">
          <div class="flex min-w-0 flex-1 items-center gap-1.5">
            <div
              class="h-1.5 rounded-sm bg-[var(--bad-10)]"
              style="width: ${Math.max(6, (category.count / maxCount) * 100)}%"
              role="progressbar"
              aria-valuenow=${category.count}
              aria-valuemin="0"
              aria-valuemax=${maxCount}
              aria-label=${`${category.category}: ${category.count}건`}
            ></div>
            <span class="truncate font-mono text-[var(--bad-light)]" title=${category.category}>${category.category}</span>
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
  const [query] = useSavedSignal('dash:filter:fleet-telemetry:query', '')

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
      const [executionResult, toolQualityResult, telemetrySummaryResult, namespaceTruthResult] = await Promise.allSettled([
        fetchDashboardExecution({ signal: controller.signal }),
        fetchToolQuality({ n: 5000, windowHours: 24, signal: controller.signal }),
        fetchTelemetrySummary({ signal: controller.signal }),
        fetchDashboardNamespaceTruth({ signal: controller.signal }),
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

      const namespaceTruth =
        namespaceTruthResult.status === 'fulfilled'
          ? normalizeNamespaceTruth(namespaceTruthResult.value)
          : null
      if (namespaceTruthResult.status === 'rejected' && !isAbortError(namespaceTruthResult.reason)) {
        warnings.push(`Control room unavailable: ${errorMessage(namespaceTruthResult.reason)}`)
      }

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

      pushSnapshot(rows)

      state.value = {
        loading: false,
        error: hasAnyData ? null : 'No fleet telemetry data available.',
        warnings,
        rows,
        tool_quality: toolQuality,
        telemetry_sources: telemetrySummary.sources,
        total_telemetry_entries: telemetrySummary.total_entries,
        namespace_truth: namespaceTruth,
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
  const visibleRows = useMemo(
    () => filterFleetRows(value.rows, query.value),
    [value.rows, query.value],
  )
  const isFiltering = query.value.trim() !== ''
  const liveTone: 'neutral' | 'ok' | 'warn' =
    value.rows.length === 0
      ? 'neutral'
      : counts.live === value.rows.length
        ? 'ok'
        : 'warn'
  const sourcesWithData = value.telemetry_sources.filter(source => source.entry_count > 0).length
  const budgetOverrideCount = value.rows.filter(r => r.budget_source === 'override' || r.budget_source === 'override_invalid').length

  if (value.loading && value.rows.length === 0) {
    return html`<${LoadingState}>Keeper 텔레메트리 불러오는 중...<//>`
  }

  if (value.error) {
    return html`<div class="p-4 text-2xs text-[var(--bad-light)]" role="alert">${value.error}</div>`
  }

  const handleReset = async (name: string) => {
    const confirmed = await requestConfirm({
      title: `${name} 초기화`,
      message: `이 키퍼의 사용량 지표(턴 수, 토큰 수, 비용, 지연시간)가 0으로 초기화됩니다.\n되돌릴 수 없습니다.`,
      confirmText: '초기화',
      cancelText: '취소',
      tone: 'danger',
    })
    if (!confirmed) return
    const result = await resetKeeper(name)
    if (result.ok) {
      void loadFleetTelemetry()
    }
  }

  const activeCount = counts.live
  const attentionCount = value.rows.filter(row => fleetBand(row) === 'attention').length
  const offlineCount = value.rows.length - activeCount

  return html`
    <div class="flex flex-col gap-4 p-4" role="region" aria-label="Keeper 텔레메트리">
      <div class="flex items-start justify-between gap-3">
        <div class="flex items-center gap-3">
          <h2 class="text-sm font-medium">Keeper 텔레메트리</h2>
          <div class="flex items-center gap-2 text-3xs">
            ${activeCount > 0 ? html`<span class="rounded-sm bg-[var(--ok-10)] px-1.5 py-0.5 text-[var(--ok)]">${activeCount} 가동</span>` : null}
            ${attentionCount > 0 ? html`<span class="rounded-sm bg-[var(--warn-10)] px-1.5 py-0.5 text-[var(--warn)]">${attentionCount} 주의</span>` : null}
            ${offlineCount > 0 ? html`<span class="rounded-sm bg-[var(--white-8)] px-1.5 py-0.5 text-[var(--text-dim)]">${offlineCount} 오프라인</span>` : null}
            ${budgetOverrideCount > 0 ? html`<span class="rounded-sm bg-[var(--warn-10)] px-1.5 py-0.5 text-[var(--warn)]">${budgetOverrideCount} 예산 재정의</span>` : null}
          </div>
        </div>
        <div class="flex items-center gap-2">
          <span class="text-3xs text-[var(--text-dim)]">
            ${value.updated_at ? html`<${TimeAgo} timestamp=${value.updated_at} /> 갱신` : ''}
          </span>
          <button type="button"
            class="rounded bg-[var(--bg-subtle)] px-2 py-0.5 text-3xs text-[var(--text-dim)] hover:text-[var(--text)]"
            onClick=${() => { void loadFleetTelemetry() }}
            aria-label="Keeper 텔레메트리 새로고침"
          >새로고침</button>
          <span class="text-3xs text-[var(--text-dim)]">${formatAutoRefreshLabel(TELEMETRY_AUTO_REFRESH_MS)}</span>
        </div>
      </div>

      <${WarningBanner} warnings=${value.warnings} />

      <div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-4">
        <${SummaryCard}
          title="Keeper 가동률"
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
            ? `${value.tool_quality.failure.toLocaleString()} failures across ${value.tool_quality.total.toLocaleString()}${value.tool_quality.sampling_mode === 'window_hours' && value.tool_quality.window_hours != null ? ` calls in the last ${value.tool_quality.window_hours}h.` : ' recent calls.'}`
            : value.tool_quality.sampling_mode === 'window_hours' && value.tool_quality.window_hours != null
              ? `No tool quality samples were recorded in the last ${value.tool_quality.window_hours}h.`
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
        <div class="mb-1 text-3xs uppercase tracking-wider text-[var(--text-dim)]">Fleet 제어반</div>
        <${ControlRoomPanel} state=${value} />
      </div>

      <div>
        <div class="mb-1 text-3xs uppercase tracking-wider text-[var(--text-dim)]">부하 감시 목록</div>
        <${PressureWatchlist} rows=${value.rows} />
      </div>

      <div>
        <div class="mb-1 flex items-center justify-between gap-2">
          <div class="text-3xs uppercase tracking-wider text-[var(--text-dim)]">Keeper 비교</div>
          <input
            type="search"
            value=${query.value}
            placeholder="name / model / blocker 필터"
            aria-label="Keeper 필터"
            onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
            class="min-w-40 max-w-60 flex-1 rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-2xs text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)] focus-visible:ring-2 focus-visible:ring-[var(--accent)]/50"
          />
        </div>
        ${isFiltering && visibleRows.length === 0 && value.rows.length > 0
          ? html`<div class="py-4 text-center text-2xs text-[var(--text-dim)]" role="status">필터 결과 없음 (${value.rows.length} keepers)</div>`
          : html`<${FleetComparisonTable} rows=${visibleRows} onReset=${handleReset} />`}
      </div>

      <div>
        <div class="mb-1 text-3xs uppercase tracking-wider text-[var(--text-dim)]">Telemetry 소스</div>
        <${TelemetrySourcesPanel} sources=${value.telemetry_sources} />
      </div>

      <div>
        <div class="mb-1 text-3xs uppercase tracking-wider text-[var(--text-dim)]">실패 카테고리</div>
        <${FailureCategoryPanel} toolQuality=${value.tool_quality} />
      </div>
    </div>
  `
}
