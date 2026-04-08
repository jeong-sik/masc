import { html } from 'htm/preact'
import { signal, computed, type Signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'

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

interface ToolQualityData {
  total: number
  success: number
  failure: number
  success_rate: number
  by_tool: ToolStat[]
  by_keeper: KeeperStat[]
  failure_categories: FailureCategory[]
  hourly_trend?: HourlyPoint[]
}

const data: Signal<ToolQualityData | null> = signal(null)
const loading: Signal<boolean> = signal(false)
const error: Signal<string | null> = signal(null)

async function fetchToolQuality() {
  loading.value = true
  error.value = null
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 15_000)
  try {
    const resp = await fetch('/api/v1/dashboard/tool-quality?n=5000', { signal: controller.signal })
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`)
    const json = await resp.json()
    if (typeof json?.total !== 'number') throw new Error('unexpected response shape')
    data.value = json as ToolQualityData
  } catch (e) {
    if (e instanceof DOMException && e.name === 'AbortError') {
      error.value = 'request timeout (15s)'
    } else {
      error.value = e instanceof Error ? e.message : 'fetch failed'
    }
  } finally {
    clearTimeout(timeout)
    loading.value = false
  }
}

const successColor = computed(() => {
  const rate = data.value?.success_rate ?? 0
  if (rate >= 95) return 'text-emerald-400'
  if (rate >= 90) return 'text-yellow-400'
  return 'text-red-400'
})

function RateGauge({ rate, label }: { rate: number; label: string }) {
  const color = rate >= 95 ? 'bg-emerald-500' : rate >= 90 ? 'bg-yellow-500' : 'bg-red-500'
  return html`
    <div class="flex flex-col gap-1">
      <div class="text-[10px] text-[var(--text-dim)] uppercase tracking-wider">${label}</div>
      <div class="flex items-center gap-2">
        <div class="flex-1 h-1.5 bg-[var(--bg-subtle)] rounded-full overflow-hidden">
          <div class="${color} h-full rounded-full transition-all" style="width: ${Math.min(rate, 100)}%" />
        </div>
        <span class="text-xs font-mono ${rate >= 95 ? 'text-emerald-400' : rate >= 90 ? 'text-yellow-400' : 'text-red-400'}">${rate.toFixed(1)}%</span>
      </div>
    </div>
  `
}

function ToolTable({ tools }: { tools: ToolStat[] }) {
  const top = tools.slice(0, 15)
  return html`
    <div class="overflow-x-auto">
      <table class="w-full text-[11px]">
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
          ${top.map(t => {
            const color = t.success_pct >= 95 ? 'text-emerald-400'
              : t.success_pct >= 80 ? 'text-yellow-400' : 'text-red-400'
            return html`
              <tr class="border-b border-[var(--card-border)] border-opacity-30">
                <td class="py-0.5 font-mono">${t.name.replace('keeper_', '').replace('masc_', 'm:')}</td>
                <td class="text-right py-0.5 text-[var(--text-dim)]">${t.calls}</td>
                <td class="text-right py-0.5 font-mono ${color}">${t.success_pct.toFixed(0)}%</td>
                <td class="text-right py-0.5 text-[var(--text-dim)]">${t.avg_ms.toFixed(0)}</td>
                <td class="text-right py-0.5 font-mono ${t.output_truncated_count > 0 ? 'text-amber-400' : 'text-[var(--text-dim)]'}">${
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
  const lineColor = lastRate >= 95 ? '#4ade80' : lastRate >= 90 ? '#fbbf24' : '#ef4444'

  return html`
    <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] p-3">
      <div class="flex items-center justify-between mb-1.5">
        <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">Success Rate Trend</span>
        <span class="text-xs font-mono" style="color:${lineColor}">${lastRate.toFixed(1)}%</span>
      </div>
      <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded w-full" style="background:#0b1220;">
        ${bars.map(b => html`
          <rect x="${b.x.toFixed(1)}" y="${b.y.toFixed(1)}" width="${b.w.toFixed(1)}" height="${b.h.toFixed(1)}" fill="${b.failures > 0 ? 'rgba(239,68,68,0.3)' : 'rgba(74,222,128,0.15)'}" rx="0.5" />
        `)}
        <polyline points="${rateLine}" fill="none" stroke="${lineColor}" stroke-width="1.5"/>
      </svg>
      <div class="flex justify-between mt-1 text-[8px] text-[var(--text-dim)] font-mono">
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
        const color = k.success_pct >= 95 ? 'bg-emerald-500' : k.success_pct >= 90 ? 'bg-yellow-500' : 'bg-red-500'
        const textColor = k.success_pct >= 95 ? 'text-emerald-400' : k.success_pct >= 90 ? 'text-yellow-400' : 'text-red-400'
        return html`
          <div class="flex items-center gap-2 text-[11px]">
            <span class="w-24 truncate text-[var(--text-dim)] font-mono" title=${k.name}>${k.name}</span>
            <div class="flex-1 h-1.5 bg-[var(--bg-subtle)] rounded-full overflow-hidden">
              <div class="${color} h-full rounded-full transition-all" style="width:${Math.min(k.success_pct, 100)}%" />
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
  if (top.length === 0) return html`<div class="text-[11px] text-[var(--text-dim)]">No failures</div>`
  return html`
    <div class="flex flex-col gap-1">
      ${top.map(c => html`
        <div class="flex items-center justify-between text-[11px]">
          <span class="font-mono text-red-400/80 truncate flex-1 mr-2">${c.category}</span>
          <span class="text-[var(--text-dim)] shrink-0">${c.count}x</span>
        </div>
      `)}
    </div>
  `
}

export function ToolQualityPanel() {
  useEffect(() => { void fetchToolQuality() }, [])

  const d = data.value
  if (loading.value && !d) return html`<div class="p-4 text-[11px] text-[var(--text-dim)]">Loading tool quality...</div>`
  if (error.value) return html`<div class="p-4 text-[11px] text-red-400">Error: ${error.value}</div>`
  if (!d || d.total === 0) return html`<div class="p-4 text-[11px] text-[var(--text-dim)]">No tool call data</div>`

  return html`
    <div class="flex flex-col gap-4 p-4">
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-medium">Tool Call Quality</h2>
        <button
          class="text-[10px] px-2 py-0.5 rounded bg-[var(--bg-subtle)] text-[var(--text-dim)] hover:text-[var(--text)]"
          onClick=${fetchToolQuality}
          aria-label="Refresh tool quality metrics"
        >Refresh</button>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <div class="text-center">
          <div class="text-lg font-mono ${successColor.value}">${d.success_rate.toFixed(1)}%</div>
          <div class="text-[9px] text-[var(--text-dim)] uppercase">Success Rate</div>
        </div>
        <div class="text-center">
          <div class="text-lg font-mono text-[var(--text)]">${d.total.toLocaleString()}</div>
          <div class="text-[9px] text-[var(--text-dim)] uppercase">Total Calls</div>
        </div>
        <div class="text-center">
          <div class="text-lg font-mono text-red-400/80">${d.failure}</div>
          <div class="text-[9px] text-[var(--text-dim)] uppercase">Failures</div>
        </div>
      </div>

      <${RateGauge} rate=${d.success_rate} label="Overall" />

      ${d.hourly_trend && d.hourly_trend.length >= 2 ? html`
        <${TrendSparkline} points=${d.hourly_trend} />
      ` : null}

      <div>
        <div class="text-[10px] text-[var(--text-dim)] uppercase tracking-wider mb-1">Per Keeper</div>
        <${KeeperRateBars} keepers=${d.by_keeper} />
      </div>

      <div>
        <div class="text-[10px] text-[var(--text-dim)] uppercase tracking-wider mb-1">Tool Success Rate</div>
        <${ToolTable} tools=${d.by_tool} />
      </div>

      <div>
        <div class="text-[10px] text-[var(--text-dim)] uppercase tracking-wider mb-1">Failure Categories</div>
        <${FailureList} categories=${d.failure_categories} />
      </div>
    </div>
  `
}
