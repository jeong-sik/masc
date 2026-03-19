// Tool Metrics — P4 Phase 4.5
// Displays tool usage statistics from Tool_unified.summary_report()

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
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

function tierLabel(tier: string): string {
  switch (tier) {
    case 'essential': return '필수'
    case 'standard': return '표준'
    default: return '전체'
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
  if (items.length === 0) return html`<p class="muted">아직 도구 호출 기록이 없습니다.</p>`
  return html`
    <div class="tool-bar-chart">
      ${items.map(item => {
        const pct = maxCount > 0 ? (item.call_count / maxCount) * 100 : 0
        return html`
          <div class="tool-bar-row" key=${item.name}>
            <span class="tool-bar-name">${item.name}</span>
            <span class="tool-bar-tier ${tierBadgeClass(item.tier)}">${tierLabel(item.tier)}</span>
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

function TierDistribution({ dist }: { dist: Record<string, number> }) {
  const total = dist.total ?? dist.full ?? 0
  const essential = dist.essential ?? 0
  const standardOnly = dist.standard_only ?? dist.standard ?? 0
  const fullOnly = dist.full_only ?? (total - standardOnly)
  const essentialPct = total > 0 ? ((essential / total) * 100).toFixed(1) : '0'
  const standardPct = total > 0 ? ((standardOnly / total) * 100).toFixed(1) : '0'
  const fullOnlyPct = total > 0 ? ((fullOnly / total) * 100).toFixed(1) : '0'
  return html`
    <div class="tier-dist">
      <div class="tier-dist-row">
        <span class="tier-dist-label badge-essential">필수</span>
        <span class="tier-dist-count">${essential}</span>
        <span class="tier-dist-pct">${essentialPct}%</span>
      </div>
      <div class="tier-dist-row">
        <span class="tier-dist-label badge-standard">표준</span>
        <span class="tier-dist-count">${standardOnly}</span>
        <span class="tier-dist-pct">${standardPct}%</span>
      </div>
      <div class="tier-dist-row">
        <span class="tier-dist-label badge-full">전체 전용</span>
        <span class="tier-dist-count">${fullOnly}</span>
        <span class="tier-dist-pct">${fullOnlyPct}%</span>
      </div>
    </div>
  `
}

export function ToolMetrics() {
  const data = metricsData.value
  const loading = metricsLoading.value
  const error = metricsError.value

  useEffect(() => {
    if (!metricsData.value && !metricsLoading.value) {
      void loadMetrics()
    }
  }, [])

  return html`
    <div class="tool-metrics">
      <div class="tool-metrics-header">
        <h3 class="tool-metrics-title">도구 사용 현황</h3>
        <button
          class="control-btn ghost"
          onClick=${() => void loadMetrics()}
          disabled=${loading}
        >
          ${loading ? '불러오는 중...' : data ? '새로고침' : '불러오기'}
        </button>
      </div>

      ${error ? html`<div class="tool-metrics-error">${error}</div>` : null}

      ${data ? html`
        <div class="tool-metrics-summary">
          <div class="tool-metrics-stat">
            <span class="stat-value">${data.total_calls}</span>
            <span class="stat-label">총 호출 수</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${data.distinct_tools_called}</span>
            <span class="stat-label">사용된 도구</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${data.never_called_count}</span>
            <span class="stat-label">미사용 도구</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${data.registered_count}</span>
            <span class="stat-label">등록됨 (v2)</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${data.dispatch_v2_enabled ? 'ON' : 'OFF'}</span>
            <span class="stat-label">Dispatch v2</span>
          </div>
        </div>

        <div class="tool-metrics-sections">
          <div class="tool-metrics-section">
            <h4>계층 분포</h4>
            <${TierDistribution} dist=${data.tier_distribution} />
          </div>
          <div class="tool-metrics-section">
            <h4>상위 20 도구</h4>
            <${BarChart}
              items=${data.top_20}
              maxCount=${data.top_20.length > 0 ? data.top_20[0]!.call_count : 0}
            />
          </div>
        </div>
      ` : !loading ? html`
        <p class="muted">불러오기를 눌러 도구 사용 통계를 확인하세요.</p>
      ` : null}
    </div>
  `
}
