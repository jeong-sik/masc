// Tool Monitor Panel — consolidated monitor section for tool quality,
// tool event evidence, governance, and keeper/tool comparison.
// Deep-link view param (?view=comparison) selects a single sub-view.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { replaceRoute, route } from '../router'
import type { ToolQualityResponse } from '../api/dashboard'
import { TELEMETRY_AUTO_REFRESH_MS } from '../config/constants'
import { MISSING_DATA_DASH } from '../lib/format-string'
import { formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { formatMsCompact, formatNumber } from '../lib/format-number'
import { refreshShell, shellRuntimeResolution } from '../store'
import type {
  DashboardCdalHealth,
  DashboardFleetSafetyHealth,
  DashboardPausedKeeperDetail,
} from '../types'
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
      <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-8 text-center text-2xs text-[var(--color-fg-muted)]">
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
            class="v2-monitoring-card block rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-3"
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
                <div class="font-mono text-[var(--color-fg-secondary)]">${formatMsCompact(row.avg_ms, MISSING_DATA_DASH)}</div>
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
    <div class="v2-monitoring-card hidden overflow-x-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] sm:block">
      <table class="v2-monitoring-table w-full text-2xs" aria-label="Tool attention rows">
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
              <tr class="v2-monitoring-row border-b border-[var(--color-border-default)]/30 last:border-b-0">
                <td class="max-w-[18rem] truncate px-3 py-2 font-mono text-[var(--color-fg-primary)]" title=${row.name}>
                  <${RouteLink}
                    tab="monitoring"
                    params=${{ section: 'fleet-health', view: 'tool-quality', tool: row.name }}
                    class="inline-flex items-center hover:text-[var(--color-accent-fg)]"
                  >${normalizedToolName(row.name)}<//>
                </td>
                <td class="px-3 py-2 text-right font-mono text-[var(--color-fg-secondary)]">${formatNumber(row.calls)}</td>
                <td class="px-3 py-2 text-right font-mono ${successTone}">${row.success_pct.toFixed(1)}%</td>
                <td class="px-3 py-2 text-right font-mono text-[var(--color-fg-muted)]">${formatMsCompact(row.avg_ms, MISSING_DATA_DASH)}</td>
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

function countText(value: number | null | undefined): string {
  return typeof value === 'number' && Number.isFinite(value) ? formatNumber(value) : MISSING_DATA_DASH
}

function FleetCommandStrip() {
  const runtime = shellRuntimeResolution.value
  const fleetSafety = runtime?.fleet_safety ?? null
  const fleet = fleetSafety?.keeper_fleet_safety
  const pausedHealth = fleetSafety?.paused_keepers_health
  const cdal = runtime?.cdal ?? null
  const effective = fleet?.effective_reaction_capacity_count ?? fleet?.running_keeper_fiber_count ?? fleetSafety?.keeper_fibers
  const executable = fleet?.executable_reaction_capacity_count ?? fleet?.executable_keeper_fiber_count
  const target = fleet?.target_reaction_capacity_count ?? fleet?.autoboot_enabled_keeper_count
  const shortfall = fleet?.reaction_capacity_shortfall_count
  const pausedCount = pausedHealth?.count ?? fleet?.paused_keeper_count ?? fleetSafety?.paused_keepers
  const tone = fleet?.status === 'blocked'
    ? 'bad'
    : fleet?.operator_action_required || fleet?.reaction_capacity_below_target || (pausedCount && pausedCount > 0)
      ? 'warn'
      : runtime?.status === 'ready' ? 'ok' : 'warn'
  const runtimeLabel = runtime?.status === 'ready' ? '런타임 가동' : `런타임 ${runtime?.status ?? 'unknown'}`
  const tick = cdal?.proof_store?.latest_activity_at ?? (fleetSafety ? 'runtime sample' : 'no runtime sample')

  return html`
    <section class="fl-shell v2-monitoring-card" data-testid="fleet-command-strip">
      <div class="fl-top">
        <div class="fl-brand">
          <span class="fl-title">Keeper Fleet</span>
          <span class="fl-tick mono">${tick}</span>
        </div>
        <div class="fl-health" aria-label="Fleet health">
          <span class=${`fl-hpill ${tone}`}>${runtimeLabel}</span>
          <span class=${`fl-hpill ${shortfall && shortfall > 0 ? 'warn' : 'ok'}`}>
            capacity ${countText(effective)}/${countText(target)}
          </span>
          <span class="fl-hpill">exec ${countText(executable)}</span>
          <span class=${`fl-hpill ${pausedCount && pausedCount > 0 ? 'warn' : 'ok'}`}>
            일시정지 ${countText(pausedCount)}
          </span>
          <span class=${`fl-hpill ${cdalTone(cdal) === 'crit' ? 'bad' : cdalTone(cdal) === 'warn' ? 'warn' : 'ok'}`}>
            Contract verification ${cdal?.writer_status ?? 'unknown'}
          </span>
        </div>
      </div>
      <div class="fl-foot">
        <span>target ${countText(target)}</span>
        <span>shortfall ${countText(shortfall)}</span>
        <span>paused names ${compactList(pausedHealth?.names ?? [])}</span>
      </div>
    </section>
  `
}

function secondsText(value: number | null | undefined): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return MISSING_DATA_DASH
  if (value < 60) return `${Math.max(0, Math.round(value))}s`
  if (value < 3600) return `${Math.round(value / 60)}m`
  return `${Math.round(value / 3600)}h`
}

function compactList(values: string[], limit = 3): string {
  if (values.length === 0) return MISSING_DATA_DASH
  const shown = values.slice(0, limit).join(', ')
  return values.length > limit ? `${shown} +${values.length - limit}` : shown
}

function cdalTone(cdal: DashboardCdalHealth | null): 'crit' | 'warn' | 'ok' | undefined {
  if (!cdal) return undefined
  if (cdal.operator_action_required === true) return 'crit'
  return cdal.writer_status === 'active' ? 'ok' : 'warn'
}

function blockerClassText(row: DashboardPausedKeeperDetail): string | null {
  const klass = row.last_blocker?.klass
  if (typeof klass === 'string') return klass
  return klass?.name ?? null
}

const NO_PROGRESS_LOOP_DISPLAY =
  'progress-safety latch · repeated no-evidence turns; resume clears the latch'

function blockerClassDisplayText(row: DashboardPausedKeeperDetail): string | null {
  const blockerClass = blockerClassText(row)
  if (blockerClass === 'no_progress_loop') return 'no-progress safety pause'
  return blockerClass
}

function blockerDetailText(row: DashboardPausedKeeperDetail): string | null {
  if (blockerClassText(row) === 'no_progress_loop') return NO_PROGRESS_LOOP_DISPLAY
  return row.last_blocker?.detail ?? null
}

function pausedKindText(row: DashboardPausedKeeperDetail): string {
  const blockerClass = blockerClassDisplayText(row)
  const parts = [
    row.pause_kind ?? 'unknown',
    blockerClass ? `blocker=${blockerClass}` : null,
    row.auto_resume_source ? `resume=${row.auto_resume_source}` : null,
  ].filter((part): part is string => part != null)
  return parts.join(' · ')
}

function RuntimePausedKeeperTable({ fleetSafety }: { fleetSafety: DashboardFleetSafetyHealth | null }) {
  const details = fleetSafety?.paused_keepers_health?.details ?? []
  const readErrors = fleetSafety?.paused_keepers_health?.read_errors ?? []
  if (details.length === 0 && readErrors.length === 0) {
    return html`
      <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-5 text-center text-2xs text-[var(--color-fg-muted)]">
        No paused keeper detail rows.
      </div>
    `
  }
  return html`
    <div class="v2-monitoring-card overflow-x-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]">
      <table class="v2-monitoring-table w-full text-2xs" aria-label="Paused keeper blockers">
        <thead>
          <tr class="border-b border-[var(--color-border-default)] text-[var(--color-fg-muted)]">
            <th scope="col" class="px-3 py-2 text-left font-medium">Keeper</th>
            <th scope="col" class="px-3 py-2 text-left font-medium">Pause</th>
            <th scope="col" class="px-3 py-2 text-right font-medium">Elapsed</th>
            <th scope="col" class="px-3 py-2 text-right font-medium">Resume</th>
          </tr>
        </thead>
        <tbody>
          ${details.map(row => html`
            <tr class="v2-monitoring-row border-b border-[var(--color-border-default)]/30 last:border-b-0">
              <td class="px-3 py-2 font-mono text-[var(--color-fg-primary)]">${row.name}</td>
              <td class="px-3 py-2 text-[var(--color-fg-secondary)]" title=${blockerDetailText(row) ?? undefined}>${pausedKindText(row)}</td>
              <td class="px-3 py-2 text-right font-mono text-[var(--color-fg-muted)]">${secondsText(row.paused_elapsed_sec)}</td>
              <td class="px-3 py-2 text-right font-mono text-[var(--color-fg-muted)]">${secondsText(row.auto_resume_remaining_sec)}</td>
            </tr>
          `)}
          ${readErrors.map(row => html`
            <tr class="v2-monitoring-row border-b border-[var(--color-border-default)]/30 last:border-b-0">
              <td class="px-3 py-2 font-mono text-[var(--bad-light)]">${row.keeper}</td>
              <td class="px-3 py-2 text-[var(--bad-light)]" colspan="3">${row.error}</td>
            </tr>
          `)}
        </tbody>
      </table>
    </div>
  `
}

function RuntimeCdalBlock({ cdal }: { cdal: DashboardCdalHealth | null }) {
  const proof = cdal?.proof_store
  const completeness = proof?.completeness
  const task = cdal?.task_scope
  const staleSamples = completeness?.sample_stale_incomplete_run_ids ?? []
  const terminalSamples = completeness?.sample_terminal_incomplete_run_ids ?? []
  if (!cdal) {
    return html`
      <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-5 text-center text-2xs text-[var(--color-fg-muted)]">
        Contract verification snapshot unavailable.
      </div>
    `
  }
  return html`
    <div class="v2-monitoring-card grid gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-3 text-2xs">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <span class="font-mono text-[var(--color-fg-primary)]">${cdal.writer_status ?? 'unknown'}</span>
        <${StatusChip}
          label=${cdal.operator_action_required ? 'action' : 'ok'}
          tone=${cdal.operator_action_required ? 'warn' : 'ok'}
        />
      </div>
      <div class="grid gap-1 text-[var(--color-fg-muted)]">
        <div class="flex justify-between gap-3">
          <span>Proof store</span>
          <span class="font-mono text-[var(--color-fg-secondary)]">${proof?.status ?? 'unknown'}</span>
        </div>
        <div class="flex justify-between gap-3">
          <span>Incomplete</span>
          <span class="font-mono text-[var(--color-fg-secondary)]">
            ${countText(completeness?.incomplete_run_dirs)}
            <span class="text-[var(--color-fg-disabled)]"> stale ${countText(completeness?.stale_incomplete_run_dirs)} · terminal ${countText(completeness?.terminal_incomplete_run_dirs)}</span>
          </span>
        </div>
        <div class="flex justify-between gap-3">
          <span>Task scope</span>
          <span class="font-mono text-[var(--color-fg-secondary)]">
            ${task?.status ?? 'unknown'}
            <span class="text-[var(--color-fg-disabled)]"> missing ${countText(task?.missing_task_scope_rows)} · current ${countText(task?.current_writer_missing_task_scope_rows)}</span>
          </span>
        </div>
        ${staleSamples.length > 0 ? html`
          <div class="truncate" title=${staleSamples.join(', ')}>stale samples: <span class="font-mono text-[var(--color-fg-secondary)]">${compactList(staleSamples)}</span></div>
        ` : null}
        ${terminalSamples.length > 0 ? html`
          <div class="truncate" title=${terminalSamples.join(', ')}>terminal samples: <span class="font-mono text-[var(--color-fg-secondary)]">${compactList(terminalSamples)}</span></div>
        ` : null}
      </div>
    </div>
  `
}

function RuntimeBlockerBoard() {
  useEffect(() => {
    void refreshShell({ force: true })
  }, [])

  const runtime = shellRuntimeResolution.value
  const fleetSafety = runtime?.fleet_safety ?? null
  const fleet = fleetSafety?.keeper_fleet_safety
  const pausedHealth = fleetSafety?.paused_keepers_health
  const cdal = runtime?.cdal ?? null
  const effective = fleet?.effective_reaction_capacity_count ?? fleet?.running_keeper_fiber_count ?? fleetSafety?.keeper_fibers
  const executable = fleet?.executable_reaction_capacity_count ?? fleet?.executable_keeper_fiber_count
  const target = fleet?.target_reaction_capacity_count ?? fleet?.autoboot_enabled_keeper_count
  const shortfall = fleet?.reaction_capacity_shortfall_count
  const pausedCount = pausedHealth?.count ?? fleet?.paused_keeper_count ?? fleetSafety?.paused_keepers
  const pausedNames = pausedHealth?.names ?? []
  const capacityStatus = fleet?.status === 'blocked'
    ? 'crit'
    : fleet?.operator_action_required || fleet?.reaction_capacity_below_target
      ? 'warn'
      : fleet ? 'ok' : undefined

  return html`
    <section class="grid gap-3" data-testid="runtime-blocker-board">
      <div class="grid grid-cols-1 gap-3 lg:grid-cols-3">
        <${StatTile}
          label="Reaction capacity"
          value=${`${countText(effective)}/${countText(target)}`}
          status=${capacityStatus}
          delta=${{ direction: capacityStatus === 'ok' ? 'up' : 'down', text: `exec ${countText(executable)} · short ${countText(shortfall)}` }}
        />
        <${StatTile}
          label="Paused keepers"
          value=${countText(pausedCount)}
          status=${pausedCount && pausedCount > 0 ? 'warn' : 'ok'}
          delta=${{ direction: pausedCount && pausedCount > 0 ? 'down' : 'flat', text: compactList(pausedNames) }}
        />
        <${StatTile}
          label="Contract writer"
          value=${cdal?.writer_status ?? MISSING_DATA_DASH}
          status=${cdalTone(cdal)}
          delta=${{ direction: cdal?.operator_action_required ? 'down' : 'flat', text: cdal?.proof_store?.status ?? 'proof unknown' }}
        />
      </div>
      <div class="grid grid-cols-1 gap-3 xl:grid-cols-[minmax(0,1.1fr)_minmax(18rem,0.9fr)]">
        <div>
          <div class="mb-2 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Paused keeper blockers</div>
          <${RuntimePausedKeeperTable} fleetSafety=${fleetSafety} />
        </div>
        <div>
          <div class="mb-2 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Contract blockers</div>
          <${RuntimeCdalBlock} cdal=${cdal} />
        </div>
      </div>
    </section>
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
      <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
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
              class="v2-monitoring-action rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2.5 py-1 text-3xs text-[var(--color-fg-secondary)] hover:border-[var(--color-border-strong)] hover:text-[var(--color-fg-primary)]"
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

      <${RuntimeBlockerBoard} />

      <div class="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,1.45fr)_minmax(18rem,0.8fr)]">
        <div class="min-w-0">
          <div class="mb-2 flex items-center justify-between gap-3">
            <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Attention tools</div>
            <${RouteLink}
              tab="monitoring"
              params=${{ section: 'fleet-health', view: 'tool-quality' }}
              class="inline-flex items-center text-3xs text-[var(--color-fg-muted)] hover:text-[var(--color-fg-primary)]"
            >Full quality table<//>
          </div>
          <${ToolAttentionTable} rows=${summary.attentionRows} />
        </div>

        <div class="grid content-start gap-4">
          <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
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

          <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
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
    <div class="v2-monitoring-surface contain-content flex flex-col gap-4">
      <${FleetCommandStrip} />
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
