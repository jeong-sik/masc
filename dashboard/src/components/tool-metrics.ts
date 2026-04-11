// Tool Metrics — P4 Phase 4.5
import { ActionButton } from './common/button'
import { ErrorState } from './common/feedback-state'
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
            <span class="px-1.5 py-px rounded-[3px] text-[10px] font-medium text-center text-[var(--text-dim)] bg-[var(--white-4)]">${cat.label}</span>
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

function ToolDistribution({ dist }: { dist: { total: number; public: number; visible: number; hidden: number } | null | undefined }) {
  if (!dist) return html`<div class="text-[11px] text-[var(--text-muted)] italic">도구 분포 데이터가 없습니다.</div>`
  // Mutually exclusive segments: public ⊂ visible, hidden = total - visible
  const visibleExclusive = Math.max(0, dist.visible - dist.public)
  const pct = (n: number) => dist.total > 0 ? ((n / dist.total) * 100).toFixed(1) : '0'
  return html`
    <div class="flex flex-col gap-2">
      <div class="flex items-center gap-3">
        <span class="inline-block min-w-[72px] px-2 py-0.5 text-[11px] font-semibold text-center rounded badge-essential">공개 MCP</span>
        <span class="text-[var(--text-strong)] text-sm font-semibold min-w-9 text-right">${dist.public}</span>
        <span class="text-[var(--text-muted)] text-[13px] min-w-12 text-right">${pct(dist.public)}%</span>
      </div>
      <div class="flex items-center gap-3">
        <span class="inline-block min-w-[72px] px-2 py-0.5 text-[11px] font-semibold text-center rounded badge-standard">내부 전용</span>
        <span class="text-[var(--text-strong)] text-sm font-semibold min-w-9 text-right">${visibleExclusive}</span>
        <span class="text-[var(--text-muted)] text-[13px] min-w-12 text-right">${pct(visibleExclusive)}%</span>
      </div>
      <div class="flex items-center gap-3">
        <span class="inline-block min-w-[72px] px-2 py-0.5 text-[11px] font-semibold text-center rounded badge-full">숨김</span>
        <span class="text-[var(--text-strong)] text-sm font-semibold min-w-9 text-right">${dist.hidden}</span>
        <span class="text-[var(--text-muted)] text-[13px] min-w-12 text-right">${pct(dist.hidden)}%</span>
      </div>
      <div class="text-[10px] text-[var(--text-dim)] mt-1">전체 ${dist.total}개 (공개 ${dist.public} + 내부 ${visibleExclusive} + 숨김 ${dist.hidden})</div>
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

      ${error ? html`<${ErrorState} message=${error} />` : null}

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
            <h4 class="text-[var(--text-muted)] text-[11px] uppercase tracking-[0.05em] mb-2.5 mt-0">도구 분포</h4>
            <${ToolDistribution} dist=${data.tool_distribution} />
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
