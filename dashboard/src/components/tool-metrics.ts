// Tool Metrics — P4 Phase 4.5
// Displays tool usage statistics from Tool_unified.summary_report()

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { fetchToolMetrics, type ToolMetricsResponse, type ToolMetricsTopEntry } from '../api'

const metricsData = signal<ToolMetricsResponse | null>(null)
const metricsError = signal<string | null>(null)
const metricsLoading = signal(false)

async function loadMetrics() {
  if (metricsLoading.value) return
  metricsLoading.value = true
  metricsError.value = null
  try {
    metricsData.value = await fetchToolMetrics()
  } catch (err) {
    metricsError.value = err instanceof Error ? err.message : String(err)
  } finally {
    metricsLoading.value = false
  }
}

function tierBadgeClass(tier: string): string {
  switch (tier) {
    case 'essential': return 'badge-essential'
    case 'standard': return 'badge-standard'
    default: return 'badge-full'
  }
}

function BarChart({ items, maxCount }: { items: ToolMetricsTopEntry[]; maxCount: number }) {
  if (items.length === 0) return html`<p class="muted">No tool calls recorded yet.</p>`
  return html`
    <div class="tool-bar-chart">
      ${items.map(item => {
        const pct = maxCount > 0 ? (item.call_count / maxCount) * 100 : 0
        return html`
          <div class="tool-bar-row" key=${item.name}>
            <span class="tool-bar-name">${item.name}</span>
            <span class="tool-bar-tier ${tierBadgeClass(item.tier)}">${item.tier}</span>
            <div class="tool-bar-track">
              <div class="tool-bar-fill" style=${{ width: `${pct}%` }} />
            </div>
            <span class="tool-bar-count">${item.call_count}</span>
          </div>
        `
      })}
    </div>
  `
}

function TierDistribution({ dist }: { dist: { essential: number; standard: number; full: number } }) {
  const total = dist.full
  const essentialPct = total > 0 ? ((dist.essential / total) * 100).toFixed(1) : '0'
  const standardPct = total > 0 ? ((dist.standard / total) * 100).toFixed(1) : '0'
  const fullOnlyCount = total - dist.standard
  const fullOnlyPct = total > 0 ? ((fullOnlyCount / total) * 100).toFixed(1) : '0'
  return html`
    <div class="tier-dist">
      <div class="tier-dist-row">
        <span class="tier-dist-label badge-essential">Essential</span>
        <span class="tier-dist-count">${dist.essential}</span>
        <span class="tier-dist-pct">${essentialPct}%</span>
      </div>
      <div class="tier-dist-row">
        <span class="tier-dist-label badge-standard">Standard</span>
        <span class="tier-dist-count">${dist.standard}</span>
        <span class="tier-dist-pct">${standardPct}%</span>
      </div>
      <div class="tier-dist-row">
        <span class="tier-dist-label badge-full">Full-only</span>
        <span class="tier-dist-count">${fullOnlyCount}</span>
        <span class="tier-dist-pct">${fullOnlyPct}%</span>
      </div>
    </div>
  `
}

export function ToolMetrics() {
  const data = metricsData.value
  const loading = metricsLoading.value
  const error = metricsError.value

  return html`
    <div class="tool-metrics">
      <div class="tool-metrics-header">
        <h3 class="tool-metrics-title">Tool Usage</h3>
        <button
          class="control-btn ghost"
          onClick=${() => void loadMetrics()}
          disabled=${loading}
        >
          ${loading ? 'Loading...' : data ? 'Refresh' : 'Load'}
        </button>
      </div>

      ${error ? html`<div class="tool-metrics-error">${error}</div>` : null}

      ${data ? html`
        <div class="tool-metrics-summary">
          <div class="tool-metrics-stat">
            <span class="stat-value">${data.total_calls}</span>
            <span class="stat-label">Total Calls</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${data.distinct_tools_called}</span>
            <span class="stat-label">Distinct Tools</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${data.never_called_count}</span>
            <span class="stat-label">Never Called</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${data.registered_count}</span>
            <span class="stat-label">Registered (v2)</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${data.dispatch_v2_enabled ? 'ON' : 'OFF'}</span>
            <span class="stat-label">Dispatch v2</span>
          </div>
        </div>

        <div class="tool-metrics-sections">
          <div class="tool-metrics-section">
            <h4>Tier Distribution</h4>
            <${TierDistribution} dist=${data.tier_distribution} />
          </div>
          <div class="tool-metrics-section">
            <h4>Top 20 Tools</h4>
            <${BarChart}
              items=${data.top_20}
              maxCount=${data.top_20.length > 0 ? data.top_20[0]!.call_count : 0}
            />
          </div>
        </div>
      ` : !loading ? html`
        <p class="muted">Click Load to fetch tool usage statistics.</p>
      ` : null}
    </div>
  `
}
