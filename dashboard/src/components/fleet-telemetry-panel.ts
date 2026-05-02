import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect, useMemo, useRef } from 'preact/hooks'
import { RotateCcw } from 'lucide-preact'
import { LoadingState } from './common/feedback-state'
import { Eyebrow } from './common/eyebrow'
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
import { isAbortError } from '../lib/async-state'
import { requestConfirm } from './common/confirm-dialog'
import { Sparkline } from './common/sparkline'
import { TextInput } from './common/input'
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
 * Case-insensitive substring match on keeper identity, runtime model,
 * cascade/provider/fallback labels, and runtime blocker.
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
    if (row.cascade_label && row.cascade_label.toLowerCase().includes(needle)) return true
    if (row.provider_label && row.provider_label.toLowerCase().includes(needle)) return true
    if (row.fallback_label && row.fallback_label.toLowerCase().includes(needle)) return true
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
  if (direction === 'flat') return 'text-[var(--color-fg-disabled)]'
  const bad = (direction === 'up' && isUpBad(metric)) || (direction === 'down' && !isUpBad(metric))
  return bad ? 'text-[var(--bad-light)]' : 'text-[var(--color-status-ok)]'
}

function sparklineColor(metric: MetricKey, direction: TrendDirection): string {
  if (direction === 'flat') return 'var(--color-fg-muted)'
  const bad = (direction === 'up' && isUpBad(metric)) || (direction === 'down' && !isUpBad(metric))
  return bad ? 'var(--bad-light)' : 'var(--color-emerald)'
}

function auditFreshnessClass(isoTimestamp: string | null): string {
  if (!isoTimestamp) return 'text-[var(--color-fg-disabled)]'
  const ageMs = Date.now() - new Date(isoTimestamp).getTime()
  if (ageMs < 5 * 60 * 1000) return 'text-[var(--text)]'
  if (ageMs < 15 * 60 * 1000) return 'text-[var(--color-fg-disabled)]'
  return 'text-[var(--color-status-warn)]'
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
        : 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)]'

  return html`
    <div class="rounded-[var(--r-1)] border ${toneClass} p-3">
      <${Eyebrow} tone="disabled">${title}</${Eyebrow}>
      <div class="mt-1 text-xl font-semibold text-[var(--text)]">${value}</div>
      <div class="mt-1 text-2xs leading-relaxed text-[var(--color-fg-disabled)]">${detail}</div>
    </div>
  `
}

function WarningBanner({ warnings }: { warnings: string[] }) {
  if (warnings.length === 0) return null
  return html`
    <div class="rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs text-[var(--color-status-warn)]">
      <div class="font-medium text-[var(--color-status-warn)]">부분 텔레메트리</div>
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
  if (status === 'ok') return 'text-[var(--color-status-ok)]'
  if (status === 'warn') return 'text-[var(--color-status-warn)]'
  if (status === 'bad') return 'text-[var(--bad-light)]'
  return 'text-[var(--color-fg-disabled)]'
}

function attentionSeverityClass(severity: string | null | undefined): string {
  if (severity === 'bad') return 'border-[var(--bad-20)] bg-[var(--bad-10)] text-[var(--bad-light)]'
  if (severity === 'warn') return 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--color-status-warn)]'
  return 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-disabled)]'
}

function ReadinessPillarCard({ pillar }: { pillar: DashboardReadinessPillar }) {
  return html`
    <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
      <div class="flex items-center justify-between gap-3">
        <div class="text-2xs font-medium text-[var(--text)]">${pillar.label}</div>
        <div class="font-mono text-2xs ${readinessStatusClass(pillar.status)}">
          ${pillar.score.toFixed(2)}
        </div>
      </div>
      <div class="mt-1 text-3xs ${readinessStatusClass(pillar.status)}">${pillar.summary}</div>
      ${pillar.blocking_reasons.length > 0
        ? html`
          <div class="mt-2 flex flex-col gap-1 text-3xs text-[var(--color-fg-disabled)]">
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
      <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3 text-2xs text-[var(--color-fg-disabled)]">
        No decision-needed or blocker events are active.
      </div>
    `
  }

  return html`
    <div class="flex flex-col gap-2">
      ${events.slice(0, 6).map(event => html`
        <div class="rounded-[var(--r-1)] border px-3 py-2 ${attentionSeverityClass(event.severity)}">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="text-2xs font-medium">
                ${event.keeper_name ? `${event.keeper_name} · ${event.kind}` : event.kind}
              </div>
              <div class="mt-0.5 text-3xs leading-relaxed">${event.summary}</div>
            </div>
            ${event.requires_decision
              ? html`<span class="rounded-[var(--r-1)] bg-[var(--color-bg-hover)] px-1.5 py-0.5 text-3xs font-semibold">DECISION</span>`
              : null}
          </div>
          ${event.recommended_action
            ? html`<div class="mt-1 text-3xs text-[var(--color-fg-disabled)]">다음: ${event.recommended_action}</div>`
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
      <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3 text-2xs text-[var(--color-fg-disabled)]">
        Control room readiness is unavailable for this refresh.
      </div>
    `
  }

  return html`
    <div class="flex flex-col gap-3">
      <div class="grid grid-cols-1 gap-3 xl:grid-cols-4">
        <${SummaryCard}
          title="준비 상태"
          value=${readiness.score.toFixed(2)}
          detail=${`차단 ${readiness.blocking_count} · 결정 필요 ${readiness.decision_required_count}.`}
          tone=${readinessTone(readiness.status)}
        />
        <${SummaryCard}
          title="승인 대기"
          value=${pendingApprovals.toString()}
          detail=${pendingApprovals > 0 ? '오퍼레이터 승인 대기열이 비어있지 않습니다.' : '대기 중인 승인이 없습니다.'}
          tone=${pendingApprovals > 0 ? 'warn' : 'ok'}
        />
        <${SummaryCard}
          title="주의"
          value=${attentionEvents.length.toString()}
          detail=${attentionEvents.length > 0 ? '심각한 차단 요인과 일시정지 후보 상태를 표시합니다.' : '활성 주의 이벤트가 없습니다.'}
          tone=${attentionEvents.length > 0 ? 'warn' : 'ok'}
        />
        <${SummaryCard}
          title="목표 범위"
          value=${state.rows.length > 0 ? `${state.rows.filter(row => row.goal_linked).length}/${state.rows.length}` : '0/0'}
          detail=${state.rows.some(row => !row.goal_linked) ? '일부 키퍼가 목표 링크 없이 활동 중입니다.' : '모든 표시된 키퍼에 목표가 연결되어 있습니다.'}
          tone=${state.rows.length === 0 || state.rows.every(row => row.goal_linked) ? 'ok' : 'warn'}
        />
      </div>

      <div class="grid grid-cols-1 gap-3 xl:grid-cols-[minmax(0,2fr)_minmax(0,1.3fr)]">
        <div>
          <${Eyebrow} tone="disabled" class="mb-1">준비 상태 항목</${Eyebrow}>
          <div class="grid grid-cols-1 gap-2 md:grid-cols-2">
            ${readiness.pillars.map(pillar => html`<${ReadinessPillarCard} pillar=${pillar} />`)}
          </div>
        </div>
        <div>
          <${Eyebrow} tone="disabled" class="mb-1">주의 대기열</${Eyebrow}>
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
      <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3 text-2xs text-[var(--color-fg-disabled)]">
        No keepers are near context pressure or stale activity thresholds.
      </div>
    `
  }

  return html`
    <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
      ${watchlist.map(row => html`
        <div class="flex items-center justify-between gap-3 border-b border-[var(--color-border-default)] px-3 py-2 text-2xs last:border-b-0">
          <div class="min-w-0">
            <div class="font-mono text-[var(--text)]">${row.name}</div>
            <div class="text-[var(--color-fg-disabled)]">
              ${row.last_activity_ago_s != null && row.last_activity_ago_s >= STALE_ACTIVITY_SEC
                ? `stale ${formatActivitySignal(row)}`
                : `ctx ${formatPercent(row.context_ratio * 100, 1)}`}
            </div>
          </div>
          <div class="text-right">
            <div class="font-mono ${pressureClass(row.context_ratio)}">${formatPercent(row.context_ratio * 100, 1)}</div>
            <div class="text-[var(--color-fg-disabled)]">${formatActivitySignal(row)}</div>
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
  const sColor = trend ? sparklineColor(metric, trend.direction) : 'var(--color-fg-muted)'

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

function ThRight({ children }: { children: unknown }) {
  return html`<th scope="col" class="py-1 text-right font-normal">${children}</th>`
}

function FleetComparisonTable({ rows, onReset }: { rows: FleetRow[]; onReset: (name: string) => void }) {
  if (rows.length === 0) {
    return html`<div class="text-2xs text-[var(--color-fg-disabled)]">Keeper 데이터 없음.</div>`
  }

  return html`
    <div class="overflow-x-auto">
      <table class="w-full text-2xs" aria-label="키퍼 텔레메트리 현황">
        <thead>
          <tr class="border-b border-[var(--color-border-default)] text-[var(--color-fg-disabled)]">
            <th scope="col" class="py-1 text-left font-normal">키퍼</th>
            <${ThRight}>상태</${ThRight}>
            <${ThRight}>활동</${ThRight}>
            <${ThRight}>측정</${ThRight}>
            <${ThRight}>도구</${ThRight}>
            <${ThRight}>성공</${ThRight}>
            <${ThRight}>Ctx</${ThRight}>
            <${ThRight}>지연</${ThRight}>
            <${ThRight}>런타임</${ThRight}>
            <th scope="col" class="py-1 text-center font-normal">예산</th>
            <th scope="col" class="w-8 py-1"></th>
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
                : 'text-[var(--color-status-warn)]'
            return html`
            <tr class="border-b border-[var(--color-border-default)] border-opacity-30 align-top">
              <td class="py-1.5">
                <div class="font-mono text-[var(--text)]">${row.name}</div>
                ${rowHint
                  ? html`
                    <div class="max-w-60 truncate text-3xs ${rowHintClass}" title=${rowHint}>
                      ${rowHint}
                    </div>
                  `
                  : null}
                <div class="max-w-60 truncate text-3xs text-[var(--color-fg-disabled)]" title=${toolInfo.title}>
                  ${toolInfo.label}
                </div>
                <div class="mt-1 flex max-w-60 flex-wrap gap-1">
                  <span
                    class=${row.goal_linked
                      ? 'rounded-[var(--r-1)] bg-[var(--ok-10)] px-1.5 py-0.5 text-3xs text-[var(--color-status-ok)]'
                      : 'rounded-[var(--r-1)] bg-[var(--warn-10)] px-1.5 py-0.5 text-3xs text-[var(--color-status-warn)]'}
                    title=${row.goal_label ?? '이 키퍼에 연결된 활성 목표가 없습니다.'}
                  >
                    ${row.goal_label
                      ? (row.active_goal_count > 1 ? `goal ${row.active_goal_count}` : 'goal linked')
                      : 'goal missing'}
                  </span>
                  <span
                    class=${row.sandbox_profile
                      ? 'rounded-[var(--r-1)] bg-[var(--color-bg-hover)] px-1.5 py-0.5 text-3xs text-[var(--color-fg-disabled)]'
                      : 'rounded-[var(--r-1)] bg-[var(--warn-10)] px-1.5 py-0.5 text-3xs text-[var(--color-status-warn)]'}
                    title=${row.effective_sandbox_image ?? row.sandbox_profile ?? '샌드박스 프로필 정보 없음.'}
                  >
                    ${row.sandbox_profile ? `sandbox ${row.sandbox_profile}` : 'sandbox unknown'}
                  </span>
                  ${row.decision_required
                    ? html`<span class="rounded-[var(--r-1)] bg-[var(--bad-10)] px-1.5 py-0.5 text-3xs text-[var(--bad-light)]">decision</span>`
                    : null}
                </div>
                ${row.goal_label
                  ? html`<div class="max-w-60 truncate text-3xs text-[var(--color-fg-disabled)]" title=${row.goal_label}>${row.goal_label}</div>`
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
              <td class="py-1.5 text-right text-[var(--color-fg-disabled)]">${formatActivitySignal(row)}</td>
              <td class="py-1.5 text-right text-3xs ${auditFreshnessClass(row.tool_audit_at)}" title=${row.tool_audit_at ?? ''}>
                ${row.tool_audit_at ? formatTimeAgo(row.tool_audit_at) : '-'}
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
                valueClass="text-[var(--color-fg-disabled)]"
              />
              <td class="py-1.5 text-right text-3xs text-[var(--color-fg-disabled)]">
                <div class="font-mono text-[var(--color-fg-secondary)]">${row.model}</div>
                ${row.cascade_label
                  ? html`<div class="max-w-56 truncate" title=${row.cascade_label}>cascade ${row.cascade_label}</div>`
                  : null}
                ${row.provider_label
                  ? html`<div class="max-w-56 truncate" title=${row.provider_label}>provider ${row.provider_label}</div>`
                  : null}
                ${row.fallback_label
                  ? html`<div class="max-w-56 truncate text-[var(--color-status-warn)]" title=${row.fallback_label}>fallback ${row.fallback_label}</div>`
                  : null}
              </td>
              <td class="py-1.5 text-center">
                ${row.budget_source === 'override_invalid'
                  ? html`<span class="rounded-[var(--r-1)] bg-[var(--bad-10)] px-1.5 py-0.5 text-3xs font-semibold text-[var(--bad-light)]" title="TOML override가 범위를 벗어남">ERR</span>`
                  : row.budget_source === 'override'
                    ? html`<span class="rounded-[var(--r-1)] bg-[var(--warn-10)] px-1.5 py-0.5 text-3xs font-semibold text-[var(--color-status-warn)]" title="TOML override 적용됨">OVR</span>`
                    : html`<span class="text-3xs text-[var(--color-fg-disabled)]">\u2014</span>`}
              </td>
              <td class="py-1.5 text-center">
                <button
                  class="rounded-[var(--r-1)] min-w-6 min-h-6 p-1.5 text-[var(--color-fg-disabled)] hover:text-[var(--bad-light)] hover:bg-[var(--bad-10)] transition-colors inline-flex items-center justify-center"
                  onClick=${() => onReset(row.name)}
                  title="초기화"
                  aria-label=${`${row.name} 초기화`}
                >
                  <${RotateCcw} size=${12} />
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
    return html`<div class="text-2xs text-[var(--color-fg-disabled)]">Telemetry store 요약 사용 불가.</div>`
  }

  const sorted = [...sources].sort((a, b) => b.entry_count - a.entry_count)
  return html`
    <div class="grid grid-cols-1 gap-2 md:grid-cols-2">
      ${sorted.map(source => html`
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
          <div class="flex items-center justify-between gap-3">
            <div class="text-2xs font-medium text-[var(--text)]">${sourceLabel(source.source)}</div>
            <div class="font-mono text-2xs ${sourceCountClass(source)}">
              ${source.entry_count.toLocaleString()}
            </div>
          </div>
          <div class="mt-1 text-3xs text-[var(--color-fg-disabled)]">${sourceDetail(source)}</div>
        </div>
      `)}
    </div>
  `
}

function FailureCategoryPanel({ toolQuality }: { toolQuality: ToolQualityResponse }) {
  if (toolQuality.failure_categories.length === 0) {
    return html`<div class="text-2xs text-[var(--color-fg-disabled)]">최근 실패 카테고리 없음.</div>`
  }

  const top = toolQuality.failure_categories.slice(0, 8)
  const maxCount = top[0]?.count ?? 1

  return html`
    <div class="flex flex-col gap-1.5">
      ${top.map(category => html`
        <div class="flex items-center gap-2 text-2xs">
          <div class="flex min-w-0 flex-1 items-center gap-1.5">
            <div
              class="h-1.5 rounded-[var(--r-0)] bg-[var(--bad-10)]"
              style="width: ${Math.max(6, (category.count / maxCount) * 100)}%"
            ></div>
            <span class="truncate font-mono text-[var(--bad-light)]" title=${category.category}>${category.category}</span>
          </div>
          <span class="text-[var(--color-fg-disabled)]">${category.count}</span>
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
        warnings.push(`실행 스냅샷 사용 불가: ${errorMessage(executionResult.reason)}`)
      }

      const toolQuality =
        toolQualityResult.status === 'fulfilled'
          ? toolQualityResult.value
          : EMPTY_TOOL_QUALITY
      if (toolQualityResult.status === 'rejected' && !isAbortError(toolQualityResult.reason)) {
        warnings.push(`도구 품질 데이터 사용 불가: ${errorMessage(toolQualityResult.reason)}`)
      }

      const telemetrySummary =
        telemetrySummaryResult.status === 'fulfilled'
          ? telemetrySummaryResult.value
          : { generated_at: '', sources: [], total_entries: 0 }
      if (telemetrySummaryResult.status === 'rejected' && !isAbortError(telemetrySummaryResult.reason)) {
        warnings.push(`텔레메트리 저장소 요약 사용 불가: ${errorMessage(telemetrySummaryResult.reason)}`)
      }
      warnings.push(...buildTelemetryWarnings(telemetrySummary.sources))

      const namespaceTruth =
        namespaceTruthResult.status === 'fulfilled'
          ? normalizeNamespaceTruth(namespaceTruthResult.value)
          : null
      if (namespaceTruthResult.status === 'rejected' && !isAbortError(namespaceTruthResult.reason)) {
        warnings.push(`Control room 사용 불가: ${errorMessage(namespaceTruthResult.reason)}`)
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
        error: hasAnyData ? null : '함대 텔레메트리 데이터가 없습니다.',
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
    return html`<div class="p-4 text-2xs text-[var(--bad-light)]">${value.error}</div>`
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
    <div class="contain-content flex flex-col gap-4 p-4">
      <div class="flex items-start justify-between gap-3">
        <div class="flex items-center gap-3">
          <h2 class="text-sm font-medium">Keeper 텔레메트리</h2>
          <div class="flex items-center gap-2 text-3xs">
            ${activeCount > 0 ? html`<span class="rounded-[var(--r-0)] bg-[var(--ok-10)] px-1.5 py-0.5 text-[var(--color-status-ok)]">${activeCount} 가동</span>` : null}
            ${attentionCount > 0 ? html`<span class="rounded-[var(--r-0)] bg-[var(--warn-10)] px-1.5 py-0.5 text-[var(--color-status-warn)]">${attentionCount} 주의</span>` : null}
            ${offlineCount > 0 ? html`<span class="rounded-[var(--r-0)] bg-[var(--color-bg-hover)] px-1.5 py-0.5 text-[var(--color-fg-disabled)]">${offlineCount} 오프라인</span>` : null}
            ${budgetOverrideCount > 0 ? html`<span class="rounded-[var(--r-0)] bg-[var(--warn-10)] px-1.5 py-0.5 text-[var(--color-status-warn)]">${budgetOverrideCount} 예산 재정의</span>` : null}
          </div>
        </div>
        <div class="flex items-center gap-2">
          <span class="text-3xs text-[var(--color-fg-disabled)]">
            ${value.updated_at ? `${formatTimeAgo(value.updated_at)} 갱신` : ''}
          </span>
          <button
            class="rounded-[var(--r-1)] bg-[var(--bg-subtle)] px-2 py-0.5 text-3xs text-[var(--color-fg-disabled)] hover:text-[var(--text)]"
            onClick=${() => { void loadFleetTelemetry() }}
            aria-label="Keeper 텔레메트리 새로고침"
          >새로고침</button>
          <span class="text-3xs text-[var(--color-fg-disabled)]">${formatAutoRefreshLabel(TELEMETRY_AUTO_REFRESH_MS)}</span>
        </div>
      </div>

      <${WarningBanner} warnings=${value.warnings} />

      <div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-4">
        <${SummaryCard}
          title="키퍼 가동률"
          value=${`${counts.live}/${value.rows.length || 0}`}
          detail=${`${counts.toolCovered}/${value.rows.length || 0} 키퍼가 최근 도구 활동을 보였습니다.`}
          tone=${liveTone}
        />
        <${SummaryCard}
          title="런타임 압박"
          value=${`${counts.hot} hot / ${counts.warn} warn`}
          detail=${counts.stale > 0 ? `${counts.stale}개 키퍼가 ${Math.round(STALE_ACTIVITY_SEC / 60)}분 이상 정체 중입니다.` : '정체된 키퍼가 활동 임계값을 넘기지 않았습니다.'}
          tone=${toneForPressure(counts.hot, counts.warn)}
        />
        <${SummaryCard}
          title="도구 성공률"
          value=${value.tool_quality.total > 0 ? formatPercent(value.tool_quality.success_rate, 1) : 'n/a'}
          detail=${value.tool_quality.total > 0
            ? `${value.tool_quality.total.toLocaleString()}회 중 ${value.tool_quality.failure.toLocaleString()}회 실패${value.tool_quality.sampling_mode === 'window_hours' && value.tool_quality.window_hours != null ? ` (최근 ${value.tool_quality.window_hours}시간).` : ' (최근 호출).'}`
            : value.tool_quality.sampling_mode === 'window_hours' && value.tool_quality.window_hours != null
              ? `최근 ${value.tool_quality.window_hours}시간 동안 도구 품질 샘플이 없습니다.`
              : '최근 도구 품질 샘플이 없습니다.'}
          tone=${value.tool_quality.total > 0 ? toneForToolSuccess(value.tool_quality.success_rate) : 'neutral'}
        />
        <${SummaryCard}
          title="텔레메트리 저장소"
          value=${value.total_telemetry_entries.toLocaleString()}
          detail=${`${sourcesWithData}/${value.telemetry_sources.length || 0} 저장소에 데이터가 있습니다.`}
          tone=${sourcesWithData > 0 ? 'ok' : 'warn'}
        />
      </div>

      <div>
        <${Eyebrow} tone="disabled" class="mb-1">함대 통제실</${Eyebrow}>
        <${ControlRoomPanel} state=${value} />
      </div>

      <div>
        <${Eyebrow} tone="disabled" class="mb-1">압박 감시 목록</${Eyebrow}>
        <${PressureWatchlist} rows=${value.rows} />
      </div>

      <div>
        <div class="mb-1 flex items-center justify-between gap-2">
          <${Eyebrow} tone="disabled">Keeper 비교</${Eyebrow}>
          <${TextInput}
            type="search"
            value=${query.value}
            placeholder="name / model / blocker 필터"
            ariaLabel="Keeper 필터"
            onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
            class="min-w-40 max-w-60 flex-1 !px-2 !py-1 !text-2xs"
          />
        </div>
        ${isFiltering && visibleRows.length === 0 && value.rows.length > 0
          ? html`<div class="py-4 text-center text-2xs text-[var(--color-fg-disabled)]">필터 결과 없음 (${value.rows.length} keepers)</div>`
          : html`<${FleetComparisonTable} rows=${visibleRows} onReset=${handleReset} />`}
      </div>

      <div>
        <${Eyebrow} tone="disabled" class="mb-1">텔레메트리 출처</${Eyebrow}>
        <${TelemetrySourcesPanel} sources=${value.telemetry_sources} />
      </div>

      <div>
        <${Eyebrow} tone="disabled" class="mb-1">실패 분류</${Eyebrow}>
        <${FailureCategoryPanel} toolQuality=${value.tool_quality} />
      </div>
    </div>
  `
}
