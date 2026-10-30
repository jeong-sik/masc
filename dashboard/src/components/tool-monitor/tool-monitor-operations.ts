// Tool Monitor Operations board — keeper-v2 monitor-more design (TmOperations).
//
// Design vocabulary: .tm-board / .tm-src / .tm-tiles / .tm-tile / .tm-sec /
// .tm-split / .tm-side / .tm-lanes / .tm-lane(-t/-m/-o) / .tm-cats / .tm-cat /
// .tm-link / .tm-sub, with .ai-tablewrap/.ai-table tables and .ai-b/.ai-d cells.
//
// Live data (mark, don't fake):
//   - tool source strip + Success/Calls/Failures tiles + tool table + failure
//     categories  → sharedToolQuality (/api/v1/dashboard/tool-quality)
//   - Reaction capacity / Paused keepers tiles + not-running keepers + paused
//     diagnostics → shellRuntimeResolution.fleet_safety (runtime sample;
//     not-running is the local autoboot-minus-executable subtraction, #29602)
// Empty states render dim "없음" text; no invented rows.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { navigate } from '../../router'
import { TELEMETRY_AUTO_REFRESH_MS } from '../../config/constants'
import { MISSING_DATA_DASH } from '../../lib/format-string'
import { formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../../lib/auto-refresh'
import { formatMsCompact, formatNumber } from '../../lib/format-number'
import { refreshShell, shellRuntimeResolution } from '../../store'
import {
  cancelSharedToolQuality,
  refreshSharedToolQuality,
  sharedToolQuality,
  sharedToolQualityError,
  sharedToolQualityLoading,
} from '../fleet-data-core'
import { freshnessText } from '../common/source-health'
import { keepersNotRunning, summarizeToolMonitorQuality } from '../fleet-health-panel'

const TOOL_MONITOR_WINDOW_HOURS = 24

type FleetHealthSubView = 'tool-quality' | 'gate' | 'event-log' | 'comparison'

function openView(view: FleetHealthSubView) {
  navigate('monitoring', { section: 'fleet-health', view })
}

function countText(value: number | null | undefined): string {
  return typeof value === 'number' && Number.isFinite(value) ? formatNumber(value) : MISSING_DATA_DASH
}

function elapsedText(value: number | null | undefined): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return MISSING_DATA_DASH
  if (value < 60) return `${Math.max(0, Math.round(value))}s`
  if (value < 3600) return `${Math.round(value / 60)}m`
  return `${Math.round(value / 3600)}h`
}

function normalizedToolName(name: string): string {
  return name.replace('keeper_', '').replace('masc_', 'm:')
}

function outputText(row: { output_truncated_count?: number; avg_output_chars?: number }): string {
  return row.output_truncated_count
    ? `${formatNumber(row.output_truncated_count)} clipped`
    : `${((row.avg_output_chars ?? 0) / 1000).toFixed(1)}k`
}

function TmTile({ k, v, tone, sub }: { k: string; v: string | number; tone?: string; sub?: string }) {
  return html`
    <div class="tm-tile" data-tone=${tone ?? 'neutral'}>
      <span class="k">${k}</span>
      <span class="v mono">${v}</span>
      ${sub ? html`<span class="s mono">${sub}</span>` : null}
    </div>
  `
}

function ToolObservationTable() {
  const quality = sharedToolQuality.value
  const rows = summarizeToolMonitorQuality(quality).rows.slice(0, 6)
  if (rows.length === 0) {
    return html`<div class="dim">관측된 도구 호출 없음</div>`
  }
  return html`
    <div class="ai-tablewrap">
      <table class="ai-table">
        <thead>
          <tr><th>도구</th><th class="r">호출</th><th class="r">성공</th><th class="r">지연</th><th class="r">출력</th></tr>
        </thead>
        <tbody>
          ${rows.map(row => html`
            <tr key=${row.name}>
              <td class="mono" title=${row.name}>${normalizedToolName(row.name)}</td>
              <td class="mono r">${formatNumber(row.calls)}</td>
              <td class="mono r ${row.success_pct < 90 ? 'bad' : ''}">${row.success_pct.toFixed(1)}%</td>
              <td class="mono r dim">${formatMsCompact(row.avg_ms, MISSING_DATA_DASH)}</td>
              <td class="mono r dim">${outputText(row)}</td>
            </tr>
          `)}
        </tbody>
      </table>
    </div>
  `
}

function KeeperOperatorFactsSection() {
  const fleet = shellRuntimeResolution.value?.fleet_safety?.keeper_fleet_safety
  const missing = keepersNotRunning(fleet)
  return html`
    <section class="tm-sec">
      <h4>기동하지 않는 Keeper</h4>
      ${missing.length === 0
        ? html`<div class="dim">모든 Keeper 가 돌고 있습니다.</div>`
        : html`
          <div class="ai-tablewrap">
            <table class="ai-table">
              <thead>
                <tr><th>키퍼</th><th>상태</th></tr>
              </thead>
              <tbody>
                ${missing.map(name => html`
                  <tr key=${name}>
                    <td class="mono">${name}</td>
                    <td>기동하지 않음</td>
                  </tr>
                `)}
              </tbody>
            </table>
          </div>
          ${fleet?.blocker
            ? html`<div class="mono dim tm-sub">blocker: ${fleet.blocker}</div>`
            : null}
        `}
    </section>
  `
}

function PausedKeeperDiagnosticsSection() {
  const pausedHealth = shellRuntimeResolution.value?.fleet_safety?.paused_keepers_health
  const details = pausedHealth?.details ?? []
  const readErrors = pausedHealth?.read_errors ?? []
  return html`
    <section class="tm-sec">
      <h4>Paused keeper diagnostics</h4>
      ${details.length === 0 && readErrors.length === 0
        ? html`<div class="dim">일시정지된 키퍼 없음</div>`
        : html`
          <div class="ai-tablewrap">
            <table class="ai-table">
              <thead>
                <tr><th>키퍼</th><th>일시정지</th><th class="r">경과</th></tr>
              </thead>
              <tbody>
                ${details.map(row => {
                  return html`
                    <tr key=${row.name}>
                      <td class="mono">${row.name}</td>
                      <td>
                        ${row.pause_kind ?? 'unknown'}
                      </td>
                      <td class="mono r dim">${elapsedText(row.paused_elapsed_sec)}</td>
                    </tr>
                  `
                })}
                ${readErrors.map(row => html`
                  <tr key=${row.keeper} class="fail">
                    <td class="mono bad">${row.keeper}</td>
                    <td class="bad" colspan="2">${row.error}</td>
                  </tr>
                `)}
              </tbody>
            </table>
          </div>
        `}
    </section>
  `
}

const LANES: Array<{ view: FleetHealthSubView; title: string; meta: string }> = [
  { view: 'tool-quality', title: 'Tool Quality', meta: 'success · latency · output truncation' },
  { view: 'gate', title: 'Gate', meta: 'HITL 큐 · 도구 거절 관측' },
  { view: 'event-log', title: 'Keeper Tool I/O', meta: 'durable tool-call 증거' },
  { view: 'comparison', title: 'Keeper Comparison', meta: 'keeper 행 · tool confidence' },
]

function FailureCategories() {
  const categories = sharedToolQuality.value?.failure_categories?.slice(0, 5) ?? []
  if (categories.length === 0) {
    return html`<div class="dim">실패 카테고리 없음</div>`
  }
  return html`
    <div class="tm-cats">
      ${categories.map(c => html`
        <div key=${c.category} class="tm-cat">
          <span class="mono">${c.category}</span>
          <span class="mono dim">${c.count}x</span>
        </div>
      `)}
    </div>
  `
}

export function ToolMonitorOperationsBoard() {
  useEffect(() => {
    const controller = new AbortController()
    const runRefresh = () => {
      void refreshSharedToolQuality({
        signal: controller.signal,
        windowHours: TOOL_MONITOR_WINDOW_HOURS,
      })
      void refreshShell({ force: true })
    }

    runRefresh()
    const disposeAutoRefresh = setupVisibleAutoRefresh(() => {
      if (!controller.signal.aborted) runRefresh()
    }, TELEMETRY_AUTO_REFRESH_MS)

    return () => {
      controller.abort()
      cancelSharedToolQuality()
      disposeAutoRefresh()
    }
  }, [])

  const quality = sharedToolQuality.value
  const summary = summarizeToolMonitorQuality(quality)
  const fleetSafety = shellRuntimeResolution.value?.fleet_safety ?? null
  const fleet = fleetSafety?.keeper_fleet_safety
  const pausedHealth = fleetSafety?.paused_keepers_health
  const executable = fleet?.executable_keeper_fiber_count
  const target = fleet?.target_reaction_capacity_count
  const shortfall = fleet?.reaction_capacity_shortfall_count
  const pausedCount = pausedHealth?.count ?? fleet?.paused_keeper_count ?? fleetSafety?.paused_keepers
  const pausedNames = pausedHealth?.names ?? []

  return html`
    <div class="tm-board" data-testid="tool-monitor-operations">
      <div class="tm-src">
        <span class="mono">${quality?.source ?? 'tool_call_io'}</span>
        <span class="mono ${quality?.health === 'ok' ? 'ok' : 'dim'}">${quality?.health ?? 'unknown'}</span>
        <span class="mono dim">
          ${quality ? freshnessText(quality) : 'no sample'}${quality?.entry_count != null ? ` · ${formatNumber(quality.entry_count)} durable rows` : ''}
        </span>
        <span class="mono dim">최근 ${TOOL_MONITOR_WINDOW_HOURS}h · ${formatAutoRefreshLabel(TELEMETRY_AUTO_REFRESH_MS)}</span>
        ${sharedToolQualityLoading.value ? html`<span class="mono dim" role="status">refreshing</span>` : null}
      </div>
      ${sharedToolQualityError.value ? html`
        <div class="tm-src"><span class="mono dim">${sharedToolQualityError.value}</span></div>
      ` : null}

      <div class="tm-tiles">
        <${TmTile} k="Success" v=${`${summary.successRate.toFixed(1)}%`} tone="ok" />
        <${TmTile} k="Calls" v=${formatNumber(summary.total)} />
        <${TmTile} k="Failures" v=${formatNumber(summary.failure)} tone=${summary.failure ? 'warn' : 'neutral'} />
        <${TmTile}
          k="Reaction capacity"
          v=${`${countText(executable)}/${countText(target)}`}
          tone=${typeof shortfall === 'number' && shortfall > 0 ? 'warn' : 'neutral'}
          sub=${shortfall != null ? `shortfall ${countText(shortfall)}` : undefined}
        />
        <${TmTile}
          k="Paused keepers"
          v=${countText(pausedCount)}
          tone=${typeof pausedCount === 'number' && pausedCount > 0 ? 'warn' : 'neutral'}
          sub=${pausedNames.length > 0 ? pausedNames.join(', ') : undefined}
        />
      </div>

      <${KeeperOperatorFactsSection} />
      <${PausedKeeperDiagnosticsSection} />

      <div class="tm-split">
        <section class="tm-sec">
          <h4>Tool observations</h4>
          <${ToolObservationTable} />
          <button type="button" class="tm-link" onClick=${() => openView('tool-quality')}>전체 품질 표 →</button>
        </section>
        <div class="tm-side">
          <section class="tm-sec">
            <h4>Lanes</h4>
            <div class="tm-lanes">
              ${LANES.map(lane => html`
                <button key=${lane.view} type="button" class="tm-lane" onClick=${() => openView(lane.view)}>
                  <span class="tm-lane-t">${lane.title}</span>
                  <span class="tm-lane-m">${lane.meta}</span>
                  <span class="tm-lane-o mono">Open</span>
                </button>
              `)}
            </div>
          </section>
          <section class="tm-sec">
            <h4>Failure categories</h4>
            <${FailureCategories} />
          </section>
        </div>
      </div>
    </div>
  `
}
