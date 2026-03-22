// Tool Metrics — P4 Phase 4.5
// Displays tool usage statistics from Tool_unified.summary_report()

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { ActionButton } from './common/button'
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
    <div class="flex flex-col gap-1.5">
      ${items.map(item => {
        const pct = maxCount > 0 ? (item.call_count / maxCount) * 100 : 0
        return html`
          <div class="tool-bar-row" key=${item.name}>
            <span class="text-[color:var(--text-body)] overflow-hidden text-ellipsis whitespace-nowrap font-mono text-[length:var(--fs-xs)]">${item.name}</span>
            <span class="px-1.5 py-px rounded-[3px] text-[length:var(--fs-2xs)] font-semibold text-center ${tierBadgeClass(item.tier)}">${tierLabel(item.tier)}</span>
            <div class="h-3.5 rounded-[3px] bg-[var(--white-6)] overflow-hidden">
              <div class="h-full rounded-[3px] bg-[var(--accent)] min-w-0.5 transition-[width] duration-300 ease-in-out" style=${{ width: `${pct}%` }} />
            </div>
            <span class="text-[color:var(--text-muted)] text-[length:var(--fs-xs)] text-right font-mono">${item.call_count}</span>
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
    <div class="flex flex-col gap-2">
      <div class="flex items-center gap-2.5">
        <span class="inline-block min-w-[72px] px-2 py-0.5 text-[length:var(--fs-xs)] font-semibold text-center rounded badge-essential">필수</span>
        <span class="text-[color:var(--text-strong)] text-[length:var(--fs-md)] font-semibold min-w-9 text-right">${essential}</span>
        <span class="text-[color:var(--text-muted)] text-[length:var(--fs-sm)] min-w-12 text-right">${essentialPct}%</span>
      </div>
      <div class="flex items-center gap-2.5">
        <span class="inline-block min-w-[72px] px-2 py-0.5 text-[length:var(--fs-xs)] font-semibold text-center rounded badge-standard">표준</span>
        <span class="text-[color:var(--text-strong)] text-[length:var(--fs-md)] font-semibold min-w-9 text-right">${standardOnly}</span>
        <span class="text-[color:var(--text-muted)] text-[length:var(--fs-sm)] min-w-12 text-right">${standardPct}%</span>
      </div>
      <div class="flex items-center gap-2.5">
        <span class="inline-block min-w-[72px] px-2 py-0.5 text-[length:var(--fs-xs)] font-semibold text-center rounded badge-full">전체 전용</span>
        <span class="text-[color:var(--text-strong)] text-[length:var(--fs-md)] font-semibold min-w-9 text-right">${fullOnly}</span>
        <span class="text-[color:var(--text-muted)] text-[length:var(--fs-sm)] min-w-12 text-right">${fullOnlyPct}%</span>
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
    <div class="flex flex-col gap-4">
      <div class="flex justify-between items-center">
        <h3 class="text-[color:var(--text-strong)] text-[length:var(--fs-lg)] font-semibold m-0">도구 사용 현황</h3>
        <${ActionButton} variant="ghost" onClick=${() => void loadMetrics()} disabled=${loading}>
          ${loading ? '불러오는 중...' : data ? '새로고침' : '불러오기'}
        <//>
      </div>

      ${error ? html`<div class="px-2.5 py-3 bg-[var(--bad-12)] border border-[rgba(239,68,68,0.34)] text-[#fecaca] text-[length:var(--fs-base)] rounded-lg">${error}</div>` : null}

      ${data ? html`
        <div class="grid grid-cols-[repeat(5,minmax(0,1fr))] gap-2.5 max-[880px]:grid-cols-[repeat(2,minmax(0,1fr))]">
          <div class="tool-metrics-stat">
            <span class="mt-1.5 text-[color:var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${data.total_calls}</span>
            <span class="stat-label">총 호출 수</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="mt-1.5 text-[color:var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${data.distinct_tools_called}</span>
            <span class="stat-label">사용된 도구</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="mt-1.5 text-[color:var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${data.never_called_count}</span>
            <span class="stat-label">미사용 도구</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="mt-1.5 text-[color:var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${data.registered_count}</span>
            <span class="stat-label">등록됨 (v2)</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="mt-1.5 text-[color:var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${data.dispatch_v2_enabled ? 'ON' : 'OFF'}</span>
            <span class="stat-label">Dispatch v2</span>
          </div>
        </div>

        <div class="tool-metrics-sections">
          <div>
            <h4 class="text-[color:var(--text-muted)] text-[length:var(--fs-xs)] uppercase tracking-[0.05em] mb-2.5 mt-0">계층 분포</h4>
            <${TierDistribution} dist=${data.tier_distribution} />
          </div>
          <div>
            <h4 class="text-[color:var(--text-muted)] text-[length:var(--fs-xs)] uppercase tracking-[0.05em] mb-2.5 mt-0">상위 20 도구</h4>
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
