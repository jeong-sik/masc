// Tool Monitor Panel — consolidated monitor section for tool quality,
// tool event evidence, governance, and keeper/tool comparison.
// Deep-link view param (?view=comparison) selects a single sub-view.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { replaceRoute, route } from '../router'
import type { ToolQualityResponse } from '../api/dashboard'
import { TELEMETRY_AUTO_REFRESH_MS } from '../config/constants'
import { formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { formatMsCompact, formatNumber } from '../lib/format-number'
import { FilterChips } from './common/filter-chips'
import { RouteLink } from './common/route-link'
import { StatTile } from './common/stat-tile'
import { StatusChip } from './common/status-chip'
import { TelemetryUnified } from './telemetry-unified'
import { FleetTelemetryPanel } from './fleet-telemetry-panel'
import { ToolQualityPanel } from './tool-quality-panel'
import { GovernanceMonitor } from './governance-monitor'
import { AttributionPanel } from './attribution-panel'
import { KeeperReactivityMonitor } from './keeper-reactivity-monitor'
import {
  cancelSharedToolQuality,
  refreshSharedToolQuality,
  sharedToolQuality,
  sharedToolQualityError,
  sharedToolQualityLoading,
} from './fleet-data-core'
import { coverageGapDisplay, freshnessText, sourceHealthClass } from './common/source-health'
import { CoverageGapBlock } from './common/coverage-gap-block'

type FleetHealthView = 'default' | 'event-log' | 'comparison' | 'tool-quality' | 'governance' | 'attribution' | 'keeper-health'

const FLEET_VIEWS: FleetHealthView[] = ['default', 'event-log', 'comparison', 'tool-quality', 'governance', 'attribution', 'keeper-health']
const TOOL_MONITOR_WINDOW_HOURS = 24
const TOOL_ATTENTION_SUCCESS_PCT = 90
const TOOL_ATTENTION_LIMIT = 6

function isFleetView(v: string | undefined): v is FleetHealthView {
  return !!v && (FLEET_VIEWS as string[]).includes(v)
}

// Derive the active view from route params. Single source of truth — no
// local writable signal needed. FilterChips uses the `value` prop (read-only)
// + `onChange` to update the URL, which flows back through the route signal.
const activeView = computed<FleetHealthView>(() => {
  const v = route.value.params.view
  return isFleetView(v) ? v : 'default'
})

const VIEW_CHIPS: Array<{ key: FleetHealthView; label: string }> = [
  { key: 'default',        label: 'Operations' },
  { key: 'tool-quality',   label: 'Tool Quality' },
  { key: 'governance',     label: 'Governance' },
  { key: 'event-log',      label: 'Evidence Log' },
  { key: 'comparison',     label: 'Keeper 비교' },
  { key: 'attribution',    label: 'Attribution' },
  { key: 'keeper-health',  label: '반응성 모니터' },
]

function updateViewParam(view: FleetHealthView) {
  replaceRoute(
    'monitoring',
    view === 'default'
      ? { section: 'fleet-health' }
      : { section: 'fleet-health', view },
  )
}

interface ToolMonitorTool {
  name: string
  calls: number
  success_pct: number
  avg_ms: number
  output_truncated_count?: number
  avg_output_chars?: number
}

interface ToolAttentionRow extends ToolMonitorTool {
  riskScore: number
}

export interface ToolMonitorSummary {
  total: number
  successRate: number
  failure: number
  attentionToolCount: number
  attentionRows: ToolAttentionRow[]
}

function normalizedToolName(name: string): string {
  return name.replace('keeper_', '').replace('masc_', 'm:')
}

export function summarizeToolMonitorQuality(
  quality: ToolQualityResponse | null,
): ToolMonitorSummary {
  const tools = quality?.by_tool ?? []
  const attentionRows = tools
    .map((tool): ToolAttentionRow => {
      const truncated = tool.output_truncated_count ?? 0
      const failures = Math.max(0, Math.round(tool.calls * (100 - tool.success_pct) / 100))
      const riskScore = failures * 10
        + (tool.success_pct < TOOL_ATTENTION_SUCCESS_PCT ? TOOL_ATTENTION_SUCCESS_PCT - tool.success_pct : 0)
        + truncated * 2
      return {
        name: tool.name,
        calls: tool.calls,
        success_pct: tool.success_pct,
        avg_ms: tool.avg_ms,
        output_truncated_count: truncated,
        avg_output_chars: tool.avg_output_chars ?? 0,
        riskScore,
      }
    })
    .filter(tool =>
      tool.calls > 0
      && (
        tool.success_pct < TOOL_ATTENTION_SUCCESS_PCT
        || (tool.output_truncated_count ?? 0) > 0
        || tool.riskScore > 0
      ),
    )
    .sort((a, b) => b.riskScore - a.riskScore || b.calls - a.calls || a.name.localeCompare(b.name))

  return {
    total: quality?.total ?? 0,
    successRate: quality?.success_rate ?? 0,
    failure: quality?.failure ?? 0,
    attentionToolCount: attentionRows.length,
    attentionRows: attentionRows.slice(0, TOOL_ATTENTION_LIMIT),
  }
}

function ToolMonitorLaneLink({
  view,
  title,
  meta,
  source,
}: {
  view: FleetHealthView
  title: string
  meta: string
  source?: string
}) {
  return html`
    <${RouteLink}
      tab="monitoring"
      params=${{
        section: 'fleet-health',
        ...(view === 'default' ? {} : { view }),
        ...(source ? { source } : {}),
      }}
      class="group flex items-center justify-between gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2 text-left transition hover:border-[var(--color-border-strong)] hover:bg-[var(--color-bg-hover)]"
    >
      <span class="min-w-0">
        <span class="block text-xs font-medium text-[var(--color-fg-primary)]">${title}</span>
        <span class="block truncate text-3xs text-[var(--color-fg-muted)]">${meta}</span>
      </span>
      <span class="shrink-0 text-2xs text-[var(--color-fg-disabled)] group-hover:text-[var(--color-fg-secondary)]">Open</span>
    <//>
  `
}

function ToolAttentionTable({ rows }: { rows: ToolAttentionRow[] }) {
  if (rows.length === 0) {
    return html`
      <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-8 text-center text-2xs text-[var(--color-fg-muted)]">
        No tool attention rows.
      </div>
    `
  }

  return html`
    <div class="grid gap-2 sm:hidden">
      ${rows.map(row => {
        const successTone = row.success_pct >= 95
          ? 'text-[var(--color-status-ok)]'
          : row.success_pct >= TOOL_ATTENTION_SUCCESS_PCT
            ? 'text-[var(--color-status-warn)]'
            : 'text-[var(--bad-light)]'
        return html`
          <${RouteLink}
            tab="monitoring"
            params=${{ section: 'fleet-health', view: 'tool-quality', tool: row.name }}
            class="block rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-3"
          >
            <div class="truncate font-mono text-xs text-[var(--color-fg-primary)]" title=${row.name}>${normalizedToolName(row.name)}</div>
            <div class="mt-2 grid grid-cols-2 gap-2 text-3xs">
              <div>
                <div class="uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Calls</div>
                <div class="font-mono text-[var(--color-fg-secondary)]">${formatNumber(row.calls)}</div>
              </div>
              <div>
                <div class="uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Success</div>
                <div class="font-mono ${successTone}">${row.success_pct.toFixed(1)}%</div>
              </div>
              <div>
                <div class="uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Latency</div>
                <div class="font-mono text-[var(--color-fg-secondary)]">${formatMsCompact(row.avg_ms, '--')}</div>
              </div>
              <div>
                <div class="uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Output</div>
                <div class="font-mono ${row.output_truncated_count ? 'text-[var(--color-status-warn)]' : 'text-[var(--color-fg-secondary)]'}">
                  ${row.output_truncated_count
                    ? `${formatNumber(row.output_truncated_count)} clipped`
                    : `${((row.avg_output_chars ?? 0) / 1000).toFixed(1)}k`}
                </div>
              </div>
            </div>
          <//>
        `
      })}
    </div>
    <div class="hidden overflow-x-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] sm:block">
      <table class="w-full text-2xs" aria-label="Tool attention rows">
        <thead>
          <tr class="border-b border-[var(--color-border-default)] text-[var(--color-fg-muted)]">
            <th scope="col" class="px-3 py-2 text-left font-medium">Tool</th>
            <th scope="col" class="px-3 py-2 text-right font-medium">Calls</th>
            <th scope="col" class="px-3 py-2 text-right font-medium">Success</th>
            <th scope="col" class="px-3 py-2 text-right font-medium">Latency</th>
            <th scope="col" class="px-3 py-2 text-right font-medium">Output</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map(row => {
            const successTone = row.success_pct >= 95
              ? 'text-[var(--color-status-ok)]'
              : row.success_pct >= TOOL_ATTENTION_SUCCESS_PCT
                ? 'text-[var(--color-status-warn)]'
                : 'text-[var(--bad-light)]'
            return html`
              <tr class="border-b border-[var(--color-border-default)]/30 last:border-b-0">
                <td class="max-w-[18rem] truncate px-3 py-2 font-mono text-[var(--color-fg-primary)]" title=${row.name}>
                  <${RouteLink}
                    tab="monitoring"
                    params=${{ section: 'fleet-health', view: 'tool-quality', tool: row.name }}
                    class="hover:text-[var(--color-accent-fg)]"
                  >${normalizedToolName(row.name)}<//>
                </td>
                <td class="px-3 py-2 text-right font-mono text-[var(--color-fg-secondary)]">${formatNumber(row.calls)}</td>
                <td class="px-3 py-2 text-right font-mono ${successTone}">${row.success_pct.toFixed(1)}%</td>
                <td class="px-3 py-2 text-right font-mono text-[var(--color-fg-muted)]">${formatMsCompact(row.avg_ms, '--')}</td>
                <td class="px-3 py-2 text-right font-mono ${row.output_truncated_count ? 'text-[var(--color-status-warn)]' : 'text-[var(--color-fg-muted)]'}">
                  ${row.output_truncated_count
                    ? `${formatNumber(row.output_truncated_count)} clipped`
                    : `${((row.avg_output_chars ?? 0) / 1000).toFixed(1)}k`}
                </td>
              </tr>
            `
          })}
        </tbody>
      </table>
    </div>
  `
}

function FailureCategoryList({ quality }: { quality: ToolQualityResponse | null }) {
  const categories = quality?.failure_categories?.slice(0, 5) ?? []
  if (categories.length === 0) {
    return html`<div class="text-2xs text-[var(--color-fg-muted)]">No failure categories.</div>`
  }
  return html`
    <div class="grid gap-1">
      ${categories.map(category => html`
        <div class="flex items-center justify-between gap-3 text-2xs">
          <span class="min-w-0 truncate font-mono text-[var(--bad-light)]/90">${category.category}</span>
          <span class="shrink-0 tabular-nums text-[var(--color-fg-muted)]">${category.count}x</span>
        </div>
      `)}
    </div>
  `
}

function ToolMonitorDefaultBoard() {
  useEffect(() => {
    const controller = new AbortController()
    const runRefresh = () => refreshSharedToolQuality({
      signal: controller.signal,
      windowHours: TOOL_MONITOR_WINDOW_HOURS,
    })

    void runRefresh()
    const disposeAutoRefresh = setupVisibleAutoRefresh(() => {
      if (!controller.signal.aborted) void runRefresh()
    }, TELEMETRY_AUTO_REFRESH_MS)

    return () => {
      controller.abort()
      cancelSharedToolQuality()
      disposeAutoRefresh()
    }
  }, [])

  const quality = sharedToolQuality.value
  const summary = summarizeToolMonitorQuality(quality)
  const coverageGap = quality ? coverageGapDisplay(quality) : null
  const loading = sharedToolQualityLoading.value
  const error = sharedToolQualityError.value

  const successStatus = summary.successRate >= 95 ? 'ok' : summary.successRate >= TOOL_ATTENTION_SUCCESS_PCT ? 'warn' : 'crit'
  const attentionStatus = summary.attentionToolCount === 0 ? 'ok' : summary.attentionToolCount > 3 ? 'warn' : 'brass'

  return html`
    <section class="grid gap-4" data-testid="tool-monitor-default">
      <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div class="min-w-0">
            <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Tool Monitor</div>
            <h2 class="mt-1 text-base font-semibold text-[var(--color-fg-primary)]">Keeper tool readiness</h2>
            <div class="mt-1 flex flex-wrap items-center gap-2 text-3xs text-[var(--color-fg-muted)]">
              <span class="font-mono">${quality?.source ?? 'tool_call_io'}</span>
              <span aria-hidden="true">·</span>
              <span class="font-mono ${sourceHealthClass(quality?.health)}">${quality?.health ?? 'unknown'}</span>
              <span aria-hidden="true">·</span>
              <span>${quality ? freshnessText(quality) : 'no sample'}</span>
              <span aria-hidden="true">·</span>
              <span>${formatAutoRefreshLabel(TELEMETRY_AUTO_REFRESH_MS)}</span>
            </div>
          </div>
          <div class="flex items-center gap-2">
            ${loading ? html`<span class="text-3xs text-[var(--color-fg-muted)]" role="status">refreshing</span>` : null}
            <button
              class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2.5 py-1 text-3xs text-[var(--color-fg-secondary)] hover:border-[var(--color-border-strong)] hover:text-[var(--color-fg-primary)]"
              onClick=${() => { void refreshSharedToolQuality({ windowHours: TOOL_MONITOR_WINDOW_HOURS }) }}
              aria-label="Tool monitor refresh"
            >Refresh</button>
          </div>
        </div>

        ${error ? html`
          <div class="mt-3 rounded-[var(--r-1)] border border-[var(--color-status-warn)]/40 bg-[var(--warn-10)] px-3 py-2 text-2xs text-[var(--color-status-warn)]">${error}</div>
        ` : null}

        ${coverageGap ? html`
          <div class="mt-3">
            <${CoverageGapBlock} display=${coverageGap} />
          </div>
        ` : null}
      </div>

      <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <${StatTile}
          label="Success"
          value=${`${summary.successRate.toFixed(1)}%`}
          status=${successStatus}
        />
        <${StatTile}
          label="Calls"
          value=${formatNumber(summary.total)}
        />
        <${StatTile}
          label="Failures"
          value=${formatNumber(summary.failure)}
          status=${summary.failure > 0 ? 'warn' : 'ok'}
        />
        <div class="flex items-center gap-2">
          <${StatTile}
            label="Attention"
            value=${formatNumber(summary.attentionToolCount)}
            status=${attentionStatus}
          />
          <${StatusChip}
            label=${summary.attentionToolCount === 0 ? 'clean' : 'inspect'}
            tone=${summary.attentionToolCount === 0 ? 'ok' : 'warn'}
          />
        </div>
      </div>

      <div class="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,1.45fr)_minmax(18rem,0.8fr)]">
        <div class="min-w-0">
          <div class="mb-2 flex items-center justify-between gap-3">
            <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Attention tools</div>
            <${RouteLink}
              tab="monitoring"
              params=${{ section: 'fleet-health', view: 'tool-quality' }}
              class="text-3xs text-[var(--color-fg-muted)] hover:text-[var(--color-fg-primary)]"
            >Full quality table<//>
          </div>
          <${ToolAttentionTable} rows=${summary.attentionRows} />
        </div>

        <div class="grid content-start gap-4">
          <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
            <div class="mb-2 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Lanes</div>
            <div class="grid gap-2">
              <${ToolMonitorLaneLink}
                view="tool-quality"
                title="Tool Quality"
                meta="success, latency, output truncation"
              />
              <${ToolMonitorLaneLink}
                view="governance"
                title="Governance"
                meta="approvals and tool rejection reasons"
              />
              <${ToolMonitorLaneLink}
                view="event-log"
                title="Keeper Tool I/O"
                meta="durable tool-call evidence"
                source="tool_call_io"
              />
              <${ToolMonitorLaneLink}
                view="comparison"
                title="Keeper Comparison"
                meta="keeper rows with tool confidence"
              />
            </div>
          </div>

          <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
            <div class="mb-2 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Failure categories</div>
            <${FailureCategoryList} quality=${quality} />
          </div>
        </div>
      </div>
    </section>
  `
}

export function FleetHealthPanel() {
  const view = activeView.value

  return html`
    <div class="contain-content flex flex-col gap-4">
      <div class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Keeper tool operations</div>
      <${FilterChips}
        chips=${VIEW_CHIPS}
        value=${view}
        onChange=${updateViewParam}
        size="sm"
        tone="accent"
      />
      <div class="transition-opacity duration-[var(--t-med)]">
        ${view === 'default'
          ? html`<${ToolMonitorDefaultBoard} />`
        : view === 'event-log'
          ? html`<${TelemetryUnified} />`
        : view === 'comparison'
          ? html`<${FleetTelemetryPanel} />`
        : view === 'tool-quality'
          ? html`<${ToolQualityPanel} />`
        : view === 'governance'
          ? html`<${GovernanceMonitor} />`
        : view === 'keeper-health'
          ? html`<${KeeperReactivityMonitor} />`
        : html`<${AttributionPanel} />`}
      </div>
    </div>
  `
}
