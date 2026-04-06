// Tool Metrics — P4 Phase 4.5
import { ActionButton } from './common/button'
// Displays tool usage statistics from Tool_unified.summary_report()

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { fetchToolMetrics, type ToolMetricsResponse, type ToolMetricsTopEntry } from '../api'
import { createAsyncResource } from '../lib/async-state'
import { toolCategory } from './tool-call-shared'

const metricsResource = createAsyncResource<ToolMetricsResponse>()

function loadMetrics() {
  return metricsResource.load(() => fetchToolMetrics())
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

/** Map category color CSS class (text-[...]) to a usable bar background color. */
function categoryBarColor(colorClass: string): string {
  const match = colorClass.match(/text-\[(.*)\]/)
  if (!match) return 'var(--accent)'
  const val = match[1]!
  // CSS variable references
  if (val.startsWith('var(')) return val
  // Direct hex/rgb
  return val
}

function BarChart({ items, maxCount }: { items: ToolMetricsTopEntry[]; maxCount: number }) {
  if (items.length === 0) return html`<p class="muted">아직 도구 호출 기록이 없습니다.</p>`
  const hasTier = items.some(item => item.tier != null && item.tier !== '')
  return html`
    <div class="flex flex-col gap-1.5">
      ${items.map(item => {
        const pct = maxCount > 0 ? (item.call_count / maxCount) * 100 : 0
        const cat = toolCategory(item.name)
        const barBg = categoryBarColor(cat.color)
        return html`
          <div class="tool-bar-row" key=${item.name}>
            <div class="flex items-center gap-1.5 overflow-hidden">
              <span class="flex-shrink-0 size-4 rounded text-[9px] font-mono font-bold flex items-center justify-center bg-[var(--white-5)] ${cat.color}">${cat.icon}</span>
              <span class="text-[var(--text-body)] overflow-hidden text-ellipsis whitespace-nowrap font-mono text-[11px]" title=${item.name}>${item.name}</span>
            </div>
            ${hasTier
              ? html`<span class="px-1.5 py-px rounded-[3px] text-[10px] font-semibold text-center ${tierBadgeClass(item.tier)}">${tierLabel(item.tier)}</span>`
              : html`<span class="px-1.5 py-px rounded-[3px] text-[10px] font-medium text-center text-[var(--text-dim)] bg-[var(--white-4)]">${cat.label}</span>`}
            <div class="h-3.5 rounded-[3px] bg-[var(--white-6)] overflow-hidden">
              <div class="h-full rounded-[3px] min-w-0.5 transition-[width] duration-300 ease-in-out" style=${{ width: `${pct}%`, backgroundColor: barBg }} />
            </div>
            <span class="text-[var(--text-muted)] text-[11px] text-right font-mono">${item.call_count}</span>
          </div>
        `
      })}
    </div>
  `
}

function TierDistribution({ dist }: { dist: Record<string, number> | null | undefined }) {
  if (!dist) return html`<div class="text-[11px] text-[var(--text-muted)] italic">서버에서 계층 분류 데이터를 제공하지 않습니다.</div>`
  const total = dist.total ?? dist.full ?? 0
  const essential = dist.essential ?? 0
  const standardOnly = dist.standard_only ?? dist.standard ?? 0
  const fullOnly = dist.full_only ?? (total - standardOnly)
  const essentialPct = total > 0 ? ((essential / total) * 100).toFixed(1) : '0'
  const standardPct = total > 0 ? ((standardOnly / total) * 100).toFixed(1) : '0'
  const fullOnlyPct = total > 0 ? ((fullOnly / total) * 100).toFixed(1) : '0'
  return html`
    <div class="flex flex-col gap-2">
      <div class="flex items-center gap-3">
        <span class="inline-block min-w-[72px] px-2 py-0.5 text-[11px] font-semibold text-center rounded badge-essential">필수</span>
        <span class="text-[var(--text-strong)] text-sm font-semibold min-w-9 text-right">${essential}</span>
        <span class="text-[var(--text-muted)] text-[13px] min-w-12 text-right">${essentialPct}%</span>
      </div>
      <div class="flex items-center gap-3">
        <span class="inline-block min-w-[72px] px-2 py-0.5 text-[11px] font-semibold text-center rounded badge-standard">표준</span>
        <span class="text-[var(--text-strong)] text-sm font-semibold min-w-9 text-right">${standardOnly}</span>
        <span class="text-[var(--text-muted)] text-[13px] min-w-12 text-right">${standardPct}%</span>
      </div>
      <div class="flex items-center gap-3">
        <span class="inline-block min-w-[72px] px-2 py-0.5 text-[11px] font-semibold text-center rounded badge-full">전체 전용</span>
        <span class="text-[var(--text-strong)] text-sm font-semibold min-w-9 text-right">${fullOnly}</span>
        <span class="text-[var(--text-muted)] text-[13px] min-w-12 text-right">${fullOnlyPct}%</span>
      </div>
    </div>
  `
}

export function ToolMetrics() {
  const s = metricsResource.state.value
  const data = s.status === 'loaded' ? s.data : undefined
  const loading = s.status === 'loading'
  const error = s.status === 'error' ? s.message : null

  useEffect(() => {
    if (s.status === 'idle') {
      void loadMetrics()
    }
  }, [])

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex justify-between items-center">
        <h3 class="text-[var(--text-strong)] text-lg font-semibold m-0">도구 사용 현황</h3>
        <${ActionButton}
          variant="ghost"
          onClick=${() => void loadMetrics()}
          disabled=${loading}
        >
          ${loading ? '불러오는 중...' : data ? '새로고침' : '불러오기'}
        <//>
      </div>

      ${error ? html`<div class="px-2.5 py-3 bg-[var(--bad-12)] border border-[rgba(239,68,68,0.34)] text-[#fecaca] text-base rounded-lg">${error}</div>` : null}

      ${data ? html`
        <div class="text-[11px] text-[var(--text-muted)] mb-3">
          서버 시작 이후 메모리 기반 집계. 재시작 시 초기화됩니다.
        </div>
        <div class="grid grid-cols-[repeat(5,minmax(0,1fr))] gap-3 max-[880px]:grid-cols-[repeat(2,minmax(0,1fr))]">
          <div class="flex flex-col items-center gap-1 rounded-lg border border-[var(--card-border)] bg-[var(--card)] p-3">
            <span class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${data.total_calls}</span>
            <span class="text-[11px] text-[var(--text-muted)] font-medium">총 호출 수</span>
          </div>
          <div class="flex flex-col items-center gap-1 rounded-lg border border-[var(--card-border)] bg-[var(--card)] p-3">
            <span class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${data.distinct_tools_called}</span>
            <span class="text-[11px] text-[var(--text-muted)] font-medium">사용된 도구</span>
          </div>
          <div class="flex flex-col items-center gap-1 rounded-lg border border-[var(--card-border)] bg-[var(--card)] p-3">
            <span class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${data.never_called_count}</span>
            <span class="text-[11px] text-[var(--text-muted)] font-medium">미사용 도구</span>
          </div>
          <div class="flex flex-col items-center gap-1 rounded-lg border border-[var(--card-border)] bg-[var(--card)] p-3">
            <span class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${data.registered_count}</span>
            <span class="text-[11px] text-[var(--text-muted)] font-medium">등록됨 (v2)</span>
          </div>
          <div class="flex flex-col items-center gap-1 rounded-lg border border-[var(--card-border)] bg-[var(--card)] p-3">
            <span class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${data.dispatch_v2_enabled ? 'ON' : 'OFF'}</span>
            <span class="text-[11px] text-[var(--text-muted)] font-medium">Dispatch v2</span>
          </div>
        </div>

        <div class="tool-metrics-sections">
          <div>
            <h4 class="text-[var(--text-muted)] text-[11px] uppercase tracking-[0.05em] mb-2.5 mt-0">계층 분포</h4>
            <${TierDistribution} dist=${data.tier_distribution} />
          </div>
          <div>
            <h4 class="text-[var(--text-muted)] text-[11px] uppercase tracking-[0.05em] mb-2.5 mt-0">상위 20 도구</h4>
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
