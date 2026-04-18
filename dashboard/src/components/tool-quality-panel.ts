import { html } from 'htm/preact'
import { computed, signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { type ToolQualityResponse } from '../api/dashboard'
import { TELEMETRY_AUTO_REFRESH_MS } from '../config/constants'
import { formatAutoRefreshLabel, setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { ErrorState, LoadingState } from './common/feedback-state'
import { TextInput } from './common/input'
import {
  cancelSharedToolQuality,
  refreshSharedToolQuality,
  sharedToolQuality,
  sharedToolQualityError,
  sharedToolQualityLoading,
} from './fleet-data-core'
import { route } from '../router'

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
  by_tool: ToolStat[]
}

function normalizeToolQualityData(json: ToolQualityResponse): ToolQualityData {
  return {
    ...json,
    generated_at: json.generated_at ?? null,
    sampling_mode: json.sampling_mode ?? 'recent_n',
    sample_limit: json.sample_limit ?? json.total,
    window_hours: json.window_hours ?? null,
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
  if (rate >= 95) return 'text-[var(--ok)]'
  if (rate >= 90) return 'text-[var(--warn)]'
  return 'text-[var(--bad-light)]'
})

// Per-tool search (case-insensitive substring on raw tool name).
// Kept as a pure function so it can be tested in isolation and re-used if the
// tool table later moves out of this panel.
const toolSearchQuery = signal('')

export function toolMatchesSearch(tool: Pick<ToolStat, 'name'>, query: string): boolean {
  const q = query.trim().toLowerCase()
  if (q === '') return true
  return tool.name.toLowerCase().includes(q)
}

export function filterTools<T extends Pick<ToolStat, 'name'>>(tools: T[], query: string): T[] {
  const q = query.trim().toLowerCase()
  if (q === '') return tools
  return tools.filter(t => t.name.toLowerCase().includes(q))
}

function RateGauge({ rate, label }: { rate: number; label: string }) {
  const color = rate >= 95 ? 'bg-[var(--ok-10)]' : rate >= 90 ? 'bg-[var(--warn-10)]' : 'bg-[var(--bad-10)]'
  return html`
    <div class="flex flex-col gap-1">
      <div class="text-3xs text-[var(--text-dim)] uppercase tracking-wider">${label}</div>
      <div class="flex items-center gap-2">
        <div class="flex-1 h-1.5 bg-[var(--bg-subtle)] rounded-sm overflow-hidden">
          <div class="${color} h-full rounded-sm transition-all" style="width: ${Math.min(rate, 100)}%" />
        </div>
        <span class="text-xs font-mono ${rate >= 95 ? 'text-[var(--ok)]' : rate >= 90 ? 'text-[var(--warn)]' : 'text-[var(--bad-light)]'}">${rate.toFixed(1)}%</span>
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
      <div class="text-2xs text-[var(--text-dim)] py-2">조건에 맞는 도구가 없습니다.</div>
    `
  }
  return html`
    <div class="overflow-x-auto">
      <table class="w-full text-2xs">
        <thead>
          <tr class="text-[var(--text-dim)] border-b border-[var(--card-border)]">
            <th class="text-left py-1 font-normal">Tool</th>
            <th class="text-right py-1 font-normal">Calls</th>
            <th class="text-right py-1 font-normal">Success</th>
            <th class="text-right py-1 font-normal">Avg ms</th>
            <th class="text-right py-1 font-normal">Output</th>
          </tr>
        </thead>
        <tbody>
          ${displayed.map(t => {
            const color = t.success_pct >= 95 ? 'text-[var(--ok)]'
              : t.success_pct >= 80 ? 'text-[var(--warn)]' : 'text-[var(--bad-light)]'
            const isHighlighted = highlightTool && t.name === highlightTool
            const rowClass = isHighlighted
              ? 'border-b border-[var(--warn-20)] bg-[var(--warn-10)] ring-1 ring-[var(--warn-20)]0/40'
              : 'border-b border-[var(--card-border)] border-opacity-30'
            return html`
              <tr class=${rowClass} ref=${isHighlighted ? ((el: HTMLElement | null) => el?.scrollIntoView({ block: 'nearest', behavior: 'smooth' })) : undefined}>
                <td class="py-0.5 font-mono">${t.name.replace('keeper_', '').replace('masc_', 'm:')}${isHighlighted ? html`<span class="ml-1 text-3xs text-[var(--warn)]">◀ selected</span>` : null}</td>
                <td class="text-right py-0.5 text-[var(--text-dim)]">${t.calls}</td>
                <td class="text-right py-0.5 font-mono ${color}">${t.success_pct.toFixed(0)}%</td>
                <td class="text-right py-0.5 text-[var(--text-dim)]">${t.avg_ms.toFixed(0)}</td>
                <td class="text-right py-0.5 font-mono ${t.output_truncated_count > 0 ? 'text-[var(--warn)]' : 'text-[var(--text-dim)]'}">${
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

function TrendSparkline({ points }: { points: HourlyPoint[] }) {
  if (points.length < 2) return null
  const W = 200, H = 40, pad = 2
  const n = points.length
  const maxCalls = Math.max(...points.map(p => p.calls), 1)

  // Success rate line
  const rateLine = points.map((p, i) => {
    const x = pad + (i / (n - 1)) * (W - 2 * pad)
    const y = H - pad - (p.success_rate / 100) * (H - 2 * pad)
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')

  // Call volume bars
  const barW = Math.max(1, ((W - 2 * pad) / n) * 0.6)
  const bars = points.map((p, i) => {
    const x = pad + (i / (n - 1)) * (W - 2 * pad) - barW / 2
    const barH = (p.calls / maxCalls) * (H - 2 * pad)
    return { x, y: H - pad - barH, w: barW, h: barH, failures: p.calls - p.success }
  })

  const lastRate = points[points.length - 1]?.success_rate ?? 0
  const lineColor = lastRate >= 95 ? 'var(--ok)' : lastRate >= 90 ? 'var(--warn)' : 'var(--bad)'

  return html`
    <div class="rounded border border-[var(--card-border)] bg-[var(--white-3)] p-3">
      <div class="flex items-center justify-between mb-1.5">
        <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">성공률 추이</span>
        <span class="text-xs font-mono" style="color:${lineColor}">${lastRate.toFixed(1)}%</span>
      </div>
      <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded w-full" style="background:var(--bg-deepest);">
        ${bars.map(b => html`
          <rect x="${b.x.toFixed(1)}" y="${b.y.toFixed(1)}" width="${b.w.toFixed(1)}" height="${b.h.toFixed(1)}" fill="${b.failures > 0 ? 'rgba(239,68,68,0.3)' : 'var(--ok-soft)'}" rx="0.5" />
        `)}
        <polyline points="${rateLine}" fill="none" stroke="${lineColor}" stroke-width="1.5"/>
      </svg>
      <div class="flex justify-between mt-1 text-4xs text-[var(--text-dim)] font-mono">
        <span>${points[0]?.hour?.slice(5) ?? ''}</span>
        <span>${points[points.length - 1]?.hour?.slice(5) ?? ''}</span>
      </div>
    </div>
  `
}

function KeeperRateBars({ keepers }: { keepers: KeeperStat[] }) {
  if (keepers.length === 0) return null
  return html`
    <div class="flex flex-col gap-1.5">
      ${keepers.map(k => {
        const color = k.success_pct >= 95 ? 'bg-[var(--ok-10)]' : k.success_pct >= 90 ? 'bg-[var(--warn-10)]' : 'bg-[var(--bad-10)]'
        const textColor = k.success_pct >= 95 ? 'text-[var(--ok)]' : k.success_pct >= 90 ? 'text-[var(--warn)]' : 'text-[var(--bad-light)]'
        return html`
          <div class="flex items-center gap-2 text-2xs">
            <span class="w-24 truncate text-[var(--text-dim)] font-mono" title=${k.name}>${k.name}</span>
            <div class="flex-1 h-1.5 bg-[var(--bg-subtle)] rounded-sm overflow-hidden">
              <div class="${color} h-full rounded-sm transition-all" style="width:${Math.min(k.success_pct, 100)}%" />
            </div>
            <span class="w-12 text-right font-mono ${textColor}">${k.success_pct.toFixed(1)}%</span>
            <span class="w-10 text-right text-[var(--text-dim)]">${k.calls}</span>
          </div>
        `
      })}
    </div>
  `
}

function FailureList({ categories }: { categories: FailureCategory[] }) {
  const top = categories.slice(0, 8)
  if (top.length === 0) return html`<div class="text-2xs text-[var(--text-dim)]">실패 없음</div>`
  return html`
    <div class="flex flex-col gap-1">
      ${top.map(c => html`
        <div class="flex items-center justify-between text-2xs">
          <span class="font-mono text-[var(--bad-light)]/80 truncate flex-1 mr-2">${c.category}</span>
          <span class="text-[var(--text-dim)] shrink-0">${c.count}x</span>
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
  if (!d || d.total === 0) return html`<div class="p-4 text-2xs text-[var(--text-dim)]">도구 호출 데이터 없음</div>`

  return html`
    <div class="flex flex-col gap-4 p-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-sm font-medium">도구 호출 품질</h2>
          <div class="text-3xs text-[var(--text-dim)]">
            ${d.sampling_mode === 'recent_n'
              ? `최근 ${d.sample_limit.toLocaleString()}건 기준 집계`
              : `최근 ${(d.window_hours ?? TOOL_QUALITY_WINDOW_HOURS).toLocaleString()}시간 기준 집계`}
          </div>
        </div>
        <button
          class="text-3xs px-2 py-0.5 rounded bg-[var(--bg-subtle)] text-[var(--text-dim)] hover:text-[var(--text)]"
          onClick=${handleRefreshToolQualityClick}
          aria-label="도구 품질 새로고침"
        >새로고침</button>
        <span class="text-3xs text-[var(--text-dim)]">${formatAutoRefreshLabel(TELEMETRY_AUTO_REFRESH_MS)}</span>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <div class="text-center">
          <div class="text-lg font-mono ${successColor.value}">${d.success_rate.toFixed(1)}%</div>
          <div class="text-3xs text-[var(--text-dim)] uppercase">성공률</div>
        </div>
        <div class="text-center">
          <div class="text-lg font-mono text-[var(--text)]">${d.total.toLocaleString()}</div>
          <div class="text-3xs text-[var(--text-dim)] uppercase">
            ${d.sampling_mode === 'recent_n' ? 'Sampled Calls' : 'Window Calls'}
          </div>
        </div>
        <div class="text-center">
          <div class="text-lg font-mono text-[var(--bad-light)]/80">${d.failure}</div>
          <div class="text-3xs text-[var(--text-dim)] uppercase">Failures</div>
        </div>
      </div>

      <${RateGauge} rate=${d.success_rate} label="Overall" />

      ${d.hourly_trend && d.hourly_trend.length >= 2 ? html`
        <${TrendSparkline} points=${d.hourly_trend} />
      ` : null}

      <div>
        <div class="text-3xs text-[var(--text-dim)] uppercase tracking-wider mb-1">Per Keeper</div>
        <${KeeperRateBars} keepers=${d.by_keeper} />
      </div>

      <div>
        <div class="flex items-center justify-between mb-1 gap-2">
          <div class="text-3xs text-[var(--text-dim)] uppercase tracking-wider">도구별 성공률</div>
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
        <div class="text-3xs text-[var(--text-dim)] uppercase tracking-wider mb-1">Failure Categories</div>
        <${FailureList} categories=${d.failure_categories} />
      </div>
    </div>
  `
}
