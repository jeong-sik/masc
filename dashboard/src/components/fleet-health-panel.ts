// Tool Monitor Panel — consolidated monitor section for tool quality,
// tool event evidence, Gate metrics, and keeper/tool comparison.
// Deep-link view param (?view=comparison) selects a single sub-view.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { replaceRoute, route } from '../router'
import type { ToolQualityResponse } from '../api/dashboard'
import { MISSING_DATA_DASH } from '../lib/format-string'
import { formatNumber } from '../lib/format-number'
import { shellRuntimeResolution } from '../store'
import { FilterChips } from './common/filter-chips'
import { TelemetryUnified } from './telemetry-unified'
import { FleetTelemetryPanel } from './fleet-telemetry-panel'
import { ToolQualityPanel } from './tool-quality-panel'
import { GateMonitor } from './gate-monitor'
import { AttributionPanel } from './attribution-panel'
import { ToolMonitorOperationsBoard } from './tool-monitor/tool-monitor-operations'
import { ToolMonitorReactivityBoard } from './tool-monitor/tool-monitor-reactivity'
import type { DashboardFleetPressureHealth } from '../types'

type FleetHealthView = 'default' | 'event-log' | 'comparison' | 'tool-quality' | 'gate' | 'attribution' | 'keeper-health'

const FLEET_VIEWS: FleetHealthView[] = ['default', 'event-log', 'comparison', 'tool-quality', 'gate', 'attribution', 'keeper-health']

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
  { key: 'gate',           label: 'Gate' },
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

export interface ToolMonitorSummary {
  total: number
  successRate: number
  failure: number
  deferred: number
  rows: ToolMonitorTool[]
}

export function summarizeToolMonitorQuality(
  quality: ToolQualityResponse | null,
): ToolMonitorSummary {
  return {
    total: quality?.total ?? 0,
    successRate: quality?.success_rate ?? 0,
    failure: quality?.failure ?? 0,
    deferred: quality?.deferred ?? 0,
    rows: quality?.by_tool ?? [],
  }
}

function compactList(values: string[], limit = 3): string {
  if (values.length === 0) return MISSING_DATA_DASH
  const shown = values.slice(0, limit).join(', ')
  return values.length > limit ? `${shown} +${values.length - limit}` : shown
}

// Which keepers are not running is autoboot minus executable. The server
// reports both lists; taking the difference here keeps it out of the wire
// (#29602). Consumed by dashboard-shell and the tool-monitor board.
export function keepersNotRunning(
  fleet: DashboardFleetPressureHealth | null | undefined,
): string[] {
  const executable = new Set(fleet?.executable_keeper_names ?? [])
  return (fleet?.autoboot_enabled_keeper_names ?? [])
    .filter(name => !executable.has(name))
    .sort((a, b) => a.localeCompare(b))
}

function countText(value: number | null | undefined): string {
  return typeof value === 'number' && Number.isFinite(value) ? formatNumber(value) : MISSING_DATA_DASH
}

function FleetCommandStrip() {
  const runtime = shellRuntimeResolution.value
  const fleetSafety = runtime?.fleet_safety ?? null
  const fleet = fleetSafety?.keeper_fleet_safety
  const pausedHealth = fleetSafety?.paused_keepers_health
  const executable = fleet?.executable_keeper_fiber_count
  const target = fleet?.target_reaction_capacity_count
  const shortfall = fleet?.reaction_capacity_shortfall_count
  const pausedCount = pausedHealth?.count ?? fleet?.paused_keeper_count ?? fleetSafety?.paused_keepers
  // The tone follows the fleet's own verdict; no per-keeper fact row speaks
  // for the whole set (#29602).
  const tone = fleet?.status === 'ok' && runtime?.status === 'ready' ? 'ok' : 'warn'
  const runtimeLabel = runtime?.status === 'ready' ? '런타임 가동' : `런타임 ${runtime?.status ?? 'unknown'}`
  const tick = fleetSafety ? 'runtime sample' : 'no runtime sample'

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
            capacity ${countText(executable)}/${countText(target)}
          </span>
          <span class=${`fl-hpill ${pausedCount && pausedCount > 0 ? 'warn' : 'ok'}`}>
            일시정지 ${countText(pausedCount)}
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
          ? html`<${ToolMonitorOperationsBoard} />`
        : view === 'event-log'
          ? html`<${TelemetryUnified} />`
        : view === 'comparison'
          ? html`<${FleetTelemetryPanel} />`
        : view === 'tool-quality'
          ? html`<${ToolQualityPanel} />`
        : view === 'gate'
          ? html`<${GateMonitor} />`
        : view === 'keeper-health'
          ? html`<${ToolMonitorReactivityBoard} />`
        : html`<${AttributionPanel} />`}
      </div>
    </div>
  `
}
