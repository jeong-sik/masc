import { html } from 'htm/preact'
import { computed, signal } from '@preact/signals'
import { useEffect, useState } from 'preact/hooks'
import { type ToolQualityResponse } from '../api/dashboard'
import { TELEMETRY_AUTO_REFRESH_MS } from '../config/constants'
import { formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { ErrorState, LoadingState } from './common/feedback-state'
import { TextInput } from './common/input'
import { Eyebrow } from './common/eyebrow'
import { ProgressBar } from './common/progress-bar'
import {
  cancelSharedToolQuality,
  refreshSharedToolQuality,
  sharedToolQuality,
  sharedToolQualityError,
  sharedToolQualityLoading,
} from './fleet-data-core'
import { route } from '../router'
import {
  sourceHealthClass,
  freshnessText,
  coverageGapDisplay,
} from './common/source-health'
import { CoverageGapBlock, classifyCoverageError } from './common/coverage-gap-block'

// Re-export for backward compatibility with existing tests that imported
// classifyCoverageError from this module. The SSOT now lives in
// `./common/coverage-gap-block`; this alias keeps test fixtures working.
export { classifyCoverageError }

const TOOL_QUALITY_WINDOW_HOURS = 24

interface ToolStat {
  name: string
  calls: number
  success_pct: number
  avg_ms: number
  output_truncated_count: number
  avg_output_chars: number
}

interface KeeperStat {
  name: string
  calls: number
  success_pct: number
}

interface FailureCategory {
  category: string
  count: number
}

interface HourlyPoint {
  hour: string
  calls: number
  success: number
  success_rate: number
}

type ToolQualityData = Omit<
  ToolQualityResponse,
  'by_tool' | 'generated_at' | 'sampling_mode' | 'sample_limit' | 'window_hours'
> & {
  generated_at: string | null
  sampling_mode: string
  sample_limit: number
  window_hours: number | null
  by_cascade: KeeperStat[]
  by_tool: ToolStat[]
}

function normalizeToolQualityData(json: ToolQualityResponse): ToolQualityData {
  return {
    ...json,
    generated_at: json.generated_at ?? null,
    sampling_mode: json.sampling_mode ?? 'recent_n',
    sample_limit: json.sample_limit ?? json.total,
    window_hours: json.window_hours ?? null,
    by_cascade: json.by_cascade ?? [],
    by_tool: json.by_tool.map(t => ({
      ...t,
      output_truncated_count: t.output_truncated_count ?? 0,
      avg_output_chars: t.avg_output_chars ?? 0,
    })),
  }
}

// Panel-local view over the shared fleet-data-core signals. Normalization is
// applied on read so the component can continue to consume `data.value` as
// before; the actual fetch/request-lifecycle lives in fleet-data-core.
const data = computed<ToolQualityData | null>(() =>
  sharedToolQuality.value ? normalizeToolQualityData(sharedToolQuality.value) : null,
)
const loading = sharedToolQualityLoading
const error = sharedToolQualityError

/**
 * Public refresh API consumed by tab-refresh.ts. Signature is preserved as a
 * no-argument async function so the refresh pipeline remains source-compatible.
 * The underlying fetch is shared across panels via fleet-data-core.
 */
export async function refreshToolQuality(): Promise<void> {
  await refreshSharedToolQuality({ windowHours: TOOL_QUALITY_WINDOW_HOURS })
}

function handleRefreshToolQualityClick() {
  void refreshToolQuality()
}

const successColor = computed(() => {
  const rate = data.value?.success_rate ?? 0
  if (rate >= 95) return 'text-[var(--color-status-ok)]'
  if (rate >= 90) return 'text-[var(--color-status-warn)]'
  return 'text-[var(--bad-light)]'
})

// Per-tool search (case-insensitive substring on raw tool name).
// Kept as a pure function so it can be tested in isolation and re-used if the
// tool table later moves out of this panel.
const toolSearchQuery = signal('')

// Re-export from SSOT — identical logic in tool-metrics.ts
export { toolMatchesSearch } from './tool-metrics'

export function filterTools<T extends Pick<ToolStat, 'name'>>(tools: T[], query: string): T[] {
  const q = query.trim().toLowerCase()
  if (q === '') return tools
  return tools.filter(t => t.name.toLowerCase().includes(q))
}

function RateGauge({ rate, label }: { rate: number; label: string }) {
  const fillClass = rate >= 95 ? 'bg-[var(--ok-10)]' : rate >= 90 ? 'bg-[var(--warn-10)]' : 'bg-[var(--bad-10)]'
  return html`
    <div class="flex flex-col gap-1">
      <div class="text-3xs text-[var(--color-fg-disabled)] uppercase tracking-wider">${label}</div>
      <div class="flex items-center gap-2">
        <${ProgressBar} pct=${rate} size="sm" class=${fillClass} trackClass="flex-1 bg-[var(--bg-subtle)]" />
        <span class="text-xs font-mono ${rate >= 95 ? 'text-[var(--color-status-ok)]' : rate >= 90 ? 'text-[var(--color-status-warn)]' : 'text-[var(--bad-light)]'}">${rate.toFixed(1)}%</span>
      </div>
    </div>
  `
}

function ToolTable({
  tools,
  highlightTool,
  query,
}: {
  tools: ToolStat[]
  highlightTool?: string
  query: string
}) {
  const filtered = filterTools(tools, query)
  const top = filtered.slice(0, 15)
  const displayed = top
  if (highlightTool && !top.some(t => t.name === highlightTool)) {
    const pinned = filtered.find(t => t.name === highlightTool)
    if (pinned) displayed.unshift(pinned)
  }
  const hasQuery = query.trim() !== ''
  if (hasQuery && filtered.length === 0) {
    return html`
      <div class="text-2xs text-[var(--color-fg-disabled)] py-2">조건에 맞는 도구가 없습니다.</div>
    `
  }
  return html`
    <div class="overflow-x-auto">
      <table class="w-full text-2xs" aria-label="도구 품질 메트릭">
        <thead>
          <tr class="text-[var(--color-fg-disabled)] border-b border-[var(--color-border-default)]">
            <th scope="col" class="text-left py-1 font-normal">도구</th>
            <th scope="col" class="text-right py-1 font-normal">호출</th>
            <th scope="col" class="text-right py-1 font-normal">성공</th>
            <th scope="col" class="text-right py-1 font-normal">평균 ms</th>
            <th scope="col" class="text-right py-1 font-normal">출력</th>
          </tr>
        </thead>
        <tbody>
          ${displayed.map(t => {
            const color = t.success_pct >= 95 ? 'text-[var(--color-status-ok)]'
              : t.success_pct >= 80 ? 'text-[var(--color-status-warn)]' : 'text-[var(--bad-light)]'
            const isHighlighted = highlightTool && t.name === highlightTool
            const rowClass = isHighlighted
              ? 'border-b border-[var(--warn-20)] bg-[var(--warn-10)] ring-1 ring-[var(--warn-20)]0/40'
              : 'border-b border-[var(--color-border-default)] border-opacity-30'
            return html`
              <tr class=${rowClass} ref=${isHighlighted ? ((el: HTMLElement | null) => el?.scrollIntoView({ block: 'nearest', behavior: 'smooth' })) : undefined}>
                <td class="py-0.5 font-mono">${t.name.replace('keeper_', '').replace('masc_', 'm:')}${isHighlighted ? html`<span class="ml-1 text-3xs text-[var(--color-status-warn)]">◀ selected</span>` : null}</td>
                <td class="text-right py-0.5 text-[var(--color-fg-disabled)]">${t.calls}</td>
                <td class="text-right py-0.5 font-mono ${color}">${t.success_pct.toFixed(0)}%</td>
                <td class="text-right py-0.5 text-[var(--color-fg-disabled)]">${t.avg_ms.toFixed(0)}</td>
                <td class="text-right py-0.5 font-mono ${t.output_truncated_count > 0 ? 'text-[var(--color-status-warn)]' : 'text-[var(--color-fg-disabled)]'}">${
                  t.output_truncated_count > 0
                    ? `${(t.avg_output_chars / 1000).toFixed(1)}k ✂${t.output_truncated_count}`
                    : `${(t.avg_output_chars / 1000).toFixed(1)}k`
                }</td>
              </tr>
            `
          })}
        </tbody>
      </table>
    </div>
  `
}

// Tone classifier shared between trend header and tooltip — keeps the
// thresholds in one place so a tooltip never disagrees with the headline.
export function rateColorVar(rate: number): string {
  if (rate >= 95) return 'var(--color-status-ok)'
  if (rate >= 90) return 'var(--color-status-warn)'
  return 'var(--color-status-err)'
}

// Pick ~4 evenly-spaced indices for x-axis labels, always including first
// and last. For very short ranges (≤6 points), only the edges are shown.
export function pickAxisLabelIndices(n: number): number[] {
  if (n <= 2) return [0, n - 1]
  if (n <= 6) return [0, n - 1]
  return [0, Math.floor(n / 3), Math.floor((2 * n) / 3), n - 1]
}

function TrendSparkline({ points }: { points: HourlyPoint[] }) {
  if (points.length < 2) return null
  // Hover state is component-local and ephemeral — useState (not signal) so
  // it lives with the mount and is dropped on unmount without manual cleanup.
  const [activeIdx, setActiveIdx] = useState<number | null>(null)

  const W = 200, H = 40, pad = 2
  const n = points.length
  const maxCalls = Math.max(...points.map(p => p.calls), 1)

  const xOf = (i: number) => pad + (i / (n - 1)) * (W - 2 * pad)
  const yRate = (rate: number) => H - pad - (rate / 100) * (H - 2 * pad)

  const rateLine = points.map((p, i) => `${xOf(i).toFixed(1)},${yRate(p.success_rate).toFixed(1)}`).join(' ')

  const barW = Math.max(1, ((W - 2 * pad) / n) * 0.6)
  const colW = (W - 2 * pad) / n  // full-height invisible hit area per bucket

  const lastRate = points[points.length - 1]?.success_rate ?? 0
  const lineColor = rateColorVar(lastRate)

  const active = activeIdx != null ? points[activeIdx] : null
  const labelIndices = pickAxisLabelIndices(n)

  return html`
    <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
      <div class="flex items-baseline justify-between mb-1.5 gap-2">
        <${Eyebrow}>성공률 추이</${Eyebrow}>
        <div class="flex items-baseline gap-1.5 leading-tight">
          <span class="text-3xs text-[var(--color-fg-disabled)]">최근 1시간</span>
          <span class="text-xs font-mono" style="color:${lineColor}">${lastRate.toFixed(1)}%</span>
        </div>
      </div>
      <div class="relative">
        <svg
          viewBox="0 0 ${W} ${H}"
          width="${W}"
          height="${H}"
          class="rounded-[var(--r-1)] w-full"
          role="img"
          aria-label="성공률 추이 차트 — ${n}시간 호버하면 시간별 상세"
          data-testid="trend-sparkline-svg"
          style="background:var(--bg-deepest);"
          onMouseLeave=${() => setActiveIdx(null)}
        >
          <!-- 100% reference line so operators can read absolute rate, not just delta -->
          <line x1="${pad}" y1="${pad.toFixed(1)}" x2="${W - pad}" y2="${pad.toFixed(1)}"
            stroke="var(--color-border-default)" stroke-width="0.3" stroke-dasharray="1 1.5" />

          ${points.map((p, i) => {
            const x = xOf(i) - barW / 2
            const barH = (p.calls / maxCalls) * (H - 2 * pad)
            const y = H - pad - barH
            const failures = p.calls - p.success
            const isActive = i === activeIdx
            return html`<rect
              x="${x.toFixed(1)}" y="${y.toFixed(1)}"
              width="${barW.toFixed(1)}" height="${barH.toFixed(1)}"
              fill="${failures > 0 ? 'var(--bad-20)' : 'var(--ok-soft)'}"
              opacity="${isActive ? '1' : '0.85'}"
              rx="0.5" />`
          })}

          <polyline points="${rateLine}" fill="none" stroke="${lineColor}" stroke-width="1.5"/>

          ${points.map((p, i) => {
            const isActive = i === activeIdx
            return html`<circle
              cx="${xOf(i).toFixed(1)}" cy="${yRate(p.success_rate).toFixed(1)}"
              r="${isActive ? '2.2' : '1.2'}"
              fill="${lineColor}" />`
          })}

          ${activeIdx != null ? html`<line
            x1="${xOf(activeIdx).toFixed(1)}" y1="${pad}"
            x2="${xOf(activeIdx).toFixed(1)}" y2="${H - pad}"
            stroke="${lineColor}" stroke-width="0.4" stroke-dasharray="1 1" opacity="0.55" />` : null}

          <!-- Invisible hit areas — full column height per bucket so the
               mouse target is the bucket region, not just the bar pixels. -->
          ${points.map((_, i) => {
            const x = xOf(i) - colW / 2
            return html`<rect
              x="${x.toFixed(1)}" y="0"
              width="${colW.toFixed(1)}" height="${H}"
              fill="transparent"
              data-testid=${`trend-bucket-${i}`}
              onMouseEnter=${() => setActiveIdx(i)}
              style="cursor:crosshair" />`
          })}
        </svg>

        ${active && activeIdx != null ? html`
          <div
            class="pointer-events-none absolute z-10 -translate-x-1/2 -translate-y-full -mt-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-3xs font-mono shadow-lg whitespace-nowrap"
            style="left:${((xOf(activeIdx) / W) * 100).toFixed(1)}%; top:0"
            role="tooltip"
            data-testid="trend-tooltip"
          >
            <div class="text-[var(--color-fg-primary)]">${active.hour}</div>
            <div style="color:${rateColorVar(active.success_rate)}">${active.success_rate.toFixed(1)}%</div>
            <div class="text-[var(--color-fg-disabled)]">
              ${active.calls.toLocaleString()} calls · ${(active.calls - active.success).toLocaleString()} fail
            </div>
          </div>
        ` : null}
      </div>

      <!-- Multiple x-axis labels (was: only start/end). Absolute positioning
           inside a relative container so labels line up with their data point. -->
      <div class="relative mt-1 h-3 text-3xs text-[var(--color-fg-disabled)] font-mono">
        ${labelIndices.map(i => {
          const xPct = (xOf(i) / W) * 100
          // Edge labels get edge-anchored to avoid clipping outside the box.
          const transform = i === 0
            ? 'translateX(0)'
            : i === n - 1
              ? 'translateX(-100%)'
              : 'translateX(-50%)'
          return html`<span
            class="absolute"
            style="left:${xPct.toFixed(1)}%; transform:${transform}"
          >${points[i]?.hour?.slice(5) ?? ''}</span>`
        })}
      </div>
    </div>
  `
}

function KeeperRateBars({ keepers }: { keepers: KeeperStat[] }) {
  if (keepers.length === 0) return null
  return html`
    <div class="flex flex-col gap-1.5">
      ${keepers.map(k => {
        const fillClass = k.success_pct >= 95 ? 'bg-[var(--ok-10)]' : k.success_pct >= 90 ? 'bg-[var(--warn-10)]' : 'bg-[var(--bad-10)]'
        const textColor = k.success_pct >= 95 ? 'text-[var(--color-status-ok)]' : k.success_pct >= 90 ? 'text-[var(--color-status-warn)]' : 'text-[var(--bad-light)]'
        return html`
          <div class="flex items-center gap-2 text-2xs">
            <span class="w-40 truncate text-[var(--color-fg-disabled)] font-mono" title=${k.name}>${k.name}</span>
            <${ProgressBar} pct=${k.success_pct} size="sm" class=${fillClass} trackClass="flex-1 bg-[var(--bg-subtle)]" />
            <span class="w-12 text-right font-mono ${textColor}">${k.success_pct.toFixed(1)}%</span>
            <span class="w-10 text-right text-[var(--color-fg-disabled)]">${k.calls}</span>
          </div>
        `
      })}
    </div>
  `
}

function FailureList({ categories }: { categories: FailureCategory[] }) {
  const top = categories.slice(0, 8)
  if (top.length === 0) return html`<div class="text-2xs text-[var(--color-fg-disabled)]">실패 없음</div>`
  return html`
    <div class="flex flex-col gap-1">
      ${top.map(c => html`
        <div class="flex items-center justify-between text-2xs">
          <span class="font-mono text-[var(--bad-light)]/80 truncate flex-1 mr-2">${c.category}</span>
          <span class="text-[var(--color-fg-disabled)] shrink-0">${c.count}x</span>
        </div>
      `)}
    </div>
  `
}

export function ToolQualityPanel() {
  useEffect(() => {
    const lifecycleController = new AbortController()
    const runRefresh = () =>
      refreshSharedToolQuality({
        signal: lifecycleController.signal,
        windowHours: TOOL_QUALITY_WINDOW_HOURS,
      })

    void runRefresh()
    const disposeAutoRefresh = setupVisibleAutoRefresh(() => {
      if (lifecycleController.signal.aborted) return
      void runRefresh()
    }, TELEMETRY_AUTO_REFRESH_MS)

    return () => {
      lifecycleController.abort()
      cancelSharedToolQuality()
      disposeAutoRefresh()
    }
  }, [])

  const d = data.value
  if (loading.value && !d) return html`<${LoadingState}>도구 품질 불러오는 중...<//>`
  if (error.value) return html`<${ErrorState} message=${error.value} class="m-4" />`
  if (!d || d.total === 0) return html`<div class="p-4 text-2xs text-[var(--color-fg-disabled)]">도구 호출 데이터 없음</div>`
  const coverageGap = coverageGapDisplay(d)

  return html`
    <div class="flex flex-col gap-4 p-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-sm font-medium">도구 호출 품질</h2>
          <div class="text-3xs text-[var(--color-fg-disabled)]">
            ${d.sampling_mode === 'recent_n'
              ? `최근 ${d.sample_limit.toLocaleString()}건 기준 집계`
              : `최근 ${(d.window_hours ?? TOOL_QUALITY_WINDOW_HOURS).toLocaleString()}시간 기준 집계`}
          </div>
          <div class="mt-0.5 text-3xs text-[var(--color-fg-disabled)]">
            <span class="font-mono">${d.source ?? 'tool_call_io'}</span>
            <span class="mx-1" aria-hidden="true">·</span>
            <span class="font-mono ${sourceHealthClass(d.health)}">${d.health ?? 'unknown'}</span>
            <span class="mx-1" aria-hidden="true">·</span>
            <span>${freshnessText(d)}</span>
            <span class="mx-1" aria-hidden="true">·</span>
            <span>${(d.entry_count ?? d.total).toLocaleString()} rows</span>
          </div>
          ${coverageGap ? html`<${CoverageGapBlock} display=${coverageGap} />` : null}
        </div>
        <div class="flex flex-col items-end gap-0.5 leading-tight shrink-0">
          <button
            class="text-3xs px-2 py-0.5 rounded-[var(--r-1)] bg-[var(--bg-subtle)] text-[var(--color-fg-disabled)] hover:text-[var(--text)]"
            onClick=${handleRefreshToolQualityClick}
            aria-label="도구 품질 새로고침"
          >새로고침</button>
          <span class="text-3xs text-[var(--color-fg-disabled)]">${formatAutoRefreshLabel(TELEMETRY_AUTO_REFRESH_MS)}</span>
        </div>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <div class="text-center">
          <div class="text-lg font-mono ${successColor.value}">${d.success_rate.toFixed(1)}%</div>
          <div class="text-3xs text-[var(--color-fg-disabled)] uppercase">성공률</div>
        </div>
        <div class="text-center">
          <div class="text-lg font-mono text-[var(--text)]">${d.total.toLocaleString()}</div>
          <div class="text-3xs text-[var(--color-fg-disabled)] uppercase">
            ${d.sampling_mode === 'recent_n' ? 'Sampled Calls' : 'Window Calls'}
          </div>
        </div>
        <div class="text-center">
          <div class="text-lg font-mono text-[var(--bad-light)]/80">${d.failure}</div>
          <div class="text-3xs text-[var(--color-fg-disabled)] uppercase">실패</div>
        </div>
      </div>

      <${RateGauge} rate=${d.success_rate} label="전체" />

      ${d.hourly_trend && d.hourly_trend.length >= 2 ? html`
        <${TrendSparkline} points=${d.hourly_trend} />
      ` : null}

      ${d.by_cascade.length > 0 ? html`
        <div>
          <div class="text-3xs text-[var(--color-fg-disabled)] uppercase tracking-wider mb-1">캐스케이드별</div>
          <${KeeperRateBars} keepers=${d.by_cascade} />
        </div>
      ` : null}

      <div>
        <div class="text-3xs text-[var(--color-fg-disabled)] uppercase tracking-wider mb-1">키퍼별</div>
        <${KeeperRateBars} keepers=${d.by_keeper} />
      </div>

      <div>
        <div class="flex items-center justify-between mb-1 gap-2">
          <div class="text-3xs text-[var(--color-fg-disabled)] uppercase tracking-wider">도구별 성공률</div>
          <${TextInput}
            class="max-w-45"
            name="tool_quality_search"
            ariaLabel="도구 이름 검색"
            autoComplete="off"
            placeholder="도구 이름 검색..."
            value=${toolSearchQuery.value}
            onInput=${(e: Event) => { toolSearchQuery.value = (e.target as HTMLInputElement).value }}
          />
        </div>
        <${ToolTable}
          tools=${d.by_tool}
          highlightTool=${route.value.params.tool}
          query=${toolSearchQuery.value}
        />
      </div>

      <div>
        <div class="text-3xs text-[var(--color-fg-disabled)] uppercase tracking-wider mb-1">실패 분류</div>
        <${FailureList} categories=${d.failure_categories} />
      </div>
    </div>
  `
}
