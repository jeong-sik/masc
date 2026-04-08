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

interface ToolQualityData {
  total: number
  success: number
  failure: number
  success_rate: number
  by_tool: ToolStat[]
  by_keeper: KeeperStat[]
  failure_categories: FailureCategory[]
}

const data: Signal<ToolQualityData | null> = signal(null)
const loading: Signal<boolean> = signal(false)
const error: Signal<string | null> = signal(null)

async function fetchToolQuality() {
  loading.value = true
  error.value = null
  try {
    const resp = await fetch('/api/v1/dashboard/tool-quality?n=5000')
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`)
    data.value = await resp.json()
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'fetch failed'
  } finally {
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
          <tr class="text-[var(--text-dim)] border-b border-[var(--border)]">
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
              <tr class="border-b border-[var(--border)] border-opacity-30">
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

function KeeperGrid({ keepers }: { keepers: KeeperStat[] }) {
  return html`
    <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
      ${keepers.map(k => {
        const color = k.success_pct >= 95 ? 'border-emerald-500/30'
          : k.success_pct >= 90 ? 'border-yellow-500/30' : 'border-red-500/30'
        return html`
          <div class="px-2 py-1.5 rounded border ${color} bg-[var(--bg-subtle)]">
            <div class="text-[10px] text-[var(--text-dim)] truncate">${k.name}</div>
            <div class="text-xs font-mono">${k.success_pct.toFixed(1)}%</div>
            <div class="text-[9px] text-[var(--text-dim)]">${k.calls} calls</div>
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
        >Refresh</button>
      </div>

      <div class="grid grid-cols-3 gap-3">
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

      <div>
        <div class="text-[10px] text-[var(--text-dim)] uppercase tracking-wider mb-1">Per Keeper</div>
        <${KeeperGrid} keepers=${d.by_keeper} />
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
