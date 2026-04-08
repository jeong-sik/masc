/**
 * Fleet Telemetry Panel — cross-keeper comparison dashboard.
 *
 * Shows: error categories, fleet tok/sec + latency, model cascade
 * distribution, and compaction timeline. Uses existing API endpoints.
 *
 * @since 2.262.0
 */
import { html } from 'htm/preact'
import { signal, type Signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { fetchKeeperConfig } from '../api/dashboard'
import type { KeeperConfigMetrics } from '../types/core'

// ── Types ─────────────────────────────────────────────────

interface KeeperFleetEntry {
  name: string
  metrics: KeeperConfigMetrics
  cascade_name: string
  model_used: string
  context_ratio: number
  compaction_count: number
}

interface ToolQualityData {
  total: number
  success: number
  failure: number
  success_rate: number
  by_tool: Array<{ name: string; calls: number; success_pct: number; avg_ms: number }>
  by_keeper: Array<{ name: string; calls: number; success_pct: number }>
  failure_categories: Array<{ category: string; count: number }>
}

// ── State ─────────────────────────────────────────────────

const fleet: Signal<KeeperFleetEntry[]> = signal([])
const toolQuality: Signal<ToolQualityData | null> = signal(null)
const loading: Signal<boolean> = signal(false)
const error: Signal<string | null> = signal(null)

async function fetchFleetData() {
  loading.value = true
  error.value = null
  try {
    // 1. Get keeper names from tool quality (already has by_keeper)
    const tqResp = await fetch('/api/v1/dashboard/tool-quality?n=5000')
    if (!tqResp.ok) throw new Error(`tool-quality: HTTP ${tqResp.status}`)
    const tq: ToolQualityData = await tqResp.json()
    toolQuality.value = tq

    // 2. Fetch each keeper's config for metrics
    const keeperNames = tq.by_keeper.map(k => k.name)
    const entries: KeeperFleetEntry[] = []
    const configs = await Promise.allSettled(
      keeperNames.map(name => fetchKeeperConfig(name))
    )
    for (let i = 0; i < keeperNames.length; i++) {
      const result = configs[i]
      if (result.status === 'fulfilled') {
        const cfg = result.value
        const m = (cfg as any).metrics as KeeperConfigMetrics | undefined
        if (m) {
          entries.push({
            name: keeperNames[i],
            metrics: m,
            cascade_name: (cfg as any).cascade_name ?? '',
            model_used: m.last_model_used || (cfg as any).cascade_name || '',
            context_ratio: (cfg as any).context?.ratio ?? 0,
            compaction_count: m.compaction_count ?? 0,
          })
        }
      }
    }
    fleet.value = entries
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'fetch failed'
  } finally {
    loading.value = false
  }
}

// ── 1. Error Category Breakdown ───────────────────────────

function ErrorCategoryPanel() {
  const tq = toolQuality.value
  if (!tq || tq.failure_categories.length === 0) {
    return html`<div class="text-[11px] text-[var(--text-dim)]">No failure data</div>`
  }
  const cats = tq.failure_categories.slice(0, 10)
  const maxCount = cats[0]?.count ?? 1
  return html`
    <div class="flex flex-col gap-1.5">
      ${cats.map(c => html`
        <div class="flex items-center gap-2 text-[11px]">
          <div class="flex-1 flex items-center gap-1.5">
            <div class="h-1.5 rounded-full bg-red-500/60 transition-all"
                 style="width: ${Math.max(4, (c.count / maxCount) * 100)}%" />
            <span class="font-mono text-red-400/80 truncate">${c.category.slice(0, 40)}</span>
          </div>
          <span class="text-[var(--text-dim)] shrink-0 tabular-nums">${c.count}</span>
        </div>
      `)}
    </div>
  `
}

// ── 2. Fleet Comparison Table ─────────────────────────────

function FleetComparisonTable() {
  const entries = fleet.value
  if (entries.length === 0) {
    return html`<div class="text-[11px] text-[var(--text-dim)]">No keeper data</div>`
  }
  // Sort by total tokens descending
  const sorted = [...entries].sort((a, b) => b.metrics.total_tokens - a.metrics.total_tokens)
  return html`
    <div class="overflow-x-auto">
      <table class="w-full text-[11px]">
        <thead>
          <tr class="text-[var(--text-dim)] border-b border-[var(--card-border)]">
            <th class="text-left py-1 font-normal">Keeper</th>
            <th class="text-right py-1 font-normal">Turns</th>
            <th class="text-right py-1 font-normal">tok/s</th>
            <th class="text-right py-1 font-normal">Latency</th>
            <th class="text-right py-1 font-normal">Ctx%</th>
            <th class="text-right py-1 font-normal">Model</th>
          </tr>
        </thead>
        <tbody>
          ${sorted.map(e => {
            const tokSec = e.metrics.last_output_tokens_per_sec
            const tokColor = tokSec != null
              ? (tokSec >= 30 ? 'text-emerald-400' : tokSec >= 10 ? 'text-yellow-400' : 'text-red-400')
              : 'text-[var(--text-dim)]'
            const ctxPct = (e.context_ratio * 100)
            const ctxColor = ctxPct >= 70 ? 'text-red-400' : ctxPct >= 40 ? 'text-yellow-400' : 'text-[var(--text-dim)]'
            return html`
              <tr class="border-b border-[var(--card-border)] border-opacity-30">
                <td class="py-0.5 font-mono">${e.name}</td>
                <td class="text-right py-0.5 text-[var(--text-dim)]">${e.metrics.total_turns}</td>
                <td class="text-right py-0.5 font-mono ${tokColor}">${tokSec != null ? tokSec.toFixed(1) : '-'}</td>
                <td class="text-right py-0.5 text-[var(--text-dim)]">${e.metrics.last_latency_ms > 0 ? `${(e.metrics.last_latency_ms / 1000).toFixed(1)}s` : '-'}</td>
                <td class="text-right py-0.5 font-mono ${ctxColor}">${ctxPct.toFixed(1)}%</td>
                <td class="text-right py-0.5 text-[10px] text-[var(--text-dim)] truncate max-w-[80px]">${e.model_used}</td>
              </tr>
            `
          })}
        </tbody>
      </table>
    </div>
  `
}

// ── 3. Model Distribution ─────────────────────────────────

function ModelDistribution() {
  const entries = fleet.value
  if (entries.length === 0) return null
  // Count models
  const modelCounts = new Map<string, number>()
  for (const e of entries) {
    const m = e.model_used || 'unknown'
    modelCounts.set(m, (modelCounts.get(m) ?? 0) + 1)
  }
  const sorted = [...modelCounts.entries()].sort((a, b) => b[1] - a[1])
  const total = entries.length
  const colors = ['bg-blue-500', 'bg-emerald-500', 'bg-amber-500', 'bg-purple-500', 'bg-red-500']
  return html`
    <div class="flex flex-col gap-2">
      <div class="flex h-3 rounded-full overflow-hidden">
        ${sorted.map(([, count], i) => html`
          <div class="${colors[i % colors.length]} transition-all"
               style="width: ${(count / total) * 100}%" />
        `)}
      </div>
      <div class="flex flex-wrap gap-x-3 gap-y-1">
        ${sorted.map(([model, count], i) => html`
          <div class="flex items-center gap-1 text-[10px]">
            <div class="w-2 h-2 rounded-full ${colors[i % colors.length]}" />
            <span class="text-[var(--text-dim)]">${model}</span>
            <span class="font-mono">${count}</span>
          </div>
        `)}
      </div>
    </div>
  `
}

// ── 4. Compaction Summary ─────────────────────────────────

function CompactionSummary() {
  const entries = fleet.value
  if (entries.length === 0) return null
  const totalCompactions = entries.reduce((sum, e) => sum + e.compaction_count, 0)
  const keepersWithCompaction = entries.filter(e => e.compaction_count > 0)
  if (totalCompactions === 0) {
    return html`
      <div class="flex items-center gap-2 p-2 rounded bg-[var(--bg-subtle)] text-[11px]">
        <span class="text-yellow-400">0</span>
        <span class="text-[var(--text-dim)]">compaction events across ${entries.length} keepers.
          Context ratios are low enough that compaction gates never trigger.</span>
      </div>
    `
  }
  return html`
    <div class="flex flex-col gap-1.5">
      <div class="flex items-center gap-2 text-[11px]">
        <span class="font-mono text-emerald-400">${totalCompactions}</span>
        <span class="text-[var(--text-dim)]">compactions from ${keepersWithCompaction.length}/${entries.length} keepers</span>
      </div>
      ${keepersWithCompaction.map(e => html`
        <div class="flex items-center justify-between text-[11px] px-2">
          <span class="font-mono">${e.name}</span>
          <span class="text-[var(--text-dim)]">${e.compaction_count}x</span>
        </div>
      `)}
    </div>
  `
}

// ── Main Panel ────────────────────────────────────────────

export function FleetTelemetryPanel() {
  useEffect(() => { void fetchFleetData() }, [])

  if (loading.value && fleet.value.length === 0) {
    return html`<div class="p-4 text-[11px] text-[var(--text-dim)]">Loading fleet telemetry...</div>`
  }
  if (error.value) {
    return html`<div class="p-4 text-[11px] text-red-400">Error: ${error.value}</div>`
  }

  return html`
    <div class="flex flex-col gap-4 p-4">
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-medium">Fleet Telemetry</h2>
        <button
          class="text-[10px] px-2 py-0.5 rounded bg-[var(--bg-subtle)] text-[var(--text-dim)] hover:text-[var(--text)]"
          onClick=${fetchFleetData}
        >Refresh</button>
      </div>

      <div>
        <div class="text-[10px] text-[var(--text-dim)] uppercase tracking-wider mb-1">Error Categories</div>
        <${ErrorCategoryPanel} />
      </div>

      <div>
        <div class="text-[10px] text-[var(--text-dim)] uppercase tracking-wider mb-1">Keeper Comparison</div>
        <${FleetComparisonTable} />
      </div>

      <div>
        <div class="text-[10px] text-[var(--text-dim)] uppercase tracking-wider mb-1">Model Distribution</div>
        <${ModelDistribution} />
      </div>

      <div>
        <div class="text-[10px] text-[var(--text-dim)] uppercase tracking-wider mb-1">Compaction</div>
        <${CompactionSummary} />
      </div>
    </div>
  `
}
