// Tool Metrics — P4 Phase 4.5
import { StatTile } from './common/stat-tile'
// Displays tool usage statistics from Tool_unified.summary_report()

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { type ToolMetricsResponse, type ToolMetricsTopEntry } from '../api'
import { FilterChips } from './common/filter-chips'
import { TextInput } from './common/input'
import { toolCategory } from './tool-call-shared'

// Filter state (module-scoped so filters survive re-renders / refreshes).
const categoryFilter = signal<string>('all')
const searchQuery = signal('')

// Pure filter helpers — exported for isolated testing.
export function toolMatchesSearch(
  item: Pick<ToolMetricsTopEntry, 'name'>,
  query: string,
): boolean {
  const q = query.trim().toLowerCase()
  if (q === '') return true
  return item.name.toLowerCase().includes(q)
}

export function toolMatchesCategory(
  item: Pick<ToolMetricsTopEntry, 'name'>,
  category: string,
): boolean {
  if (category === 'all') return true
  return toolCategory(item.name).label === category
}

/**
 * SSOT for tool list filtering across the dashboard.
 *
 * Until 2026-05-27 `tool-quality-panel.ts` exposed its own compatible import
 * path for this operation. Callers now import the filter from this owning
 * module, while the category parameter still defaults to `'all'` for the
 * two-argument `filterTools(tools, query)` panel use case.
 */
export function filterTools<T extends { name: string }>(
  items: T[],
  query: string,
  category: string = 'all',
): T[] {
  const q = query.trim().toLowerCase()
  if (q === '' && category === 'all') return items
  return items.filter(
    (it) => toolMatchesSearch(it, q) && toolMatchesCategory(it, category),
  )
}

/** Map category color CSS class (text-[...]) to a usable bar background color. */
function categoryBarColor(colorClass: string): string {
  const match = colorClass.match(/text-\[(.*)\]/)
  if (!match) return 'var(--color-accent-fg)'
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
          <div class="tool-bar-row v2-lab-row" key=${item.name}>
            <div class="flex items-center gap-1.5 overflow-hidden">
              <span class="flex-shrink-0 size-4 rounded-[var(--r-1)] text-3xs font-mono font-bold flex items-center justify-center bg-[var(--color-bg-elevated)] ${cat.color}">${cat.icon}</span>
              <span class="text-[var(--color-fg-primary)] overflow-hidden text-ellipsis whitespace-nowrap font-mono text-2xs" title=${item.name}>${item.name}</span>
            </div>
            <span class="px-1.5 py-px rounded-xs text-3xs font-medium text-center text-[var(--color-fg-disabled)] bg-[var(--color-bg-elevated)]">${cat.label}</span>
            <div class="h-3.5 rounded-xs bg-[var(--color-bg-hover)] overflow-hidden">
              <div class="h-full rounded-xs min-w-0.5 transition-[width] duration-[var(--t-slow)] ease-[var(--ease-inout)]" style=${{ width: `${pct}%`, backgroundColor: barBg }} />
            </div>
            <span class="text-[var(--color-fg-muted)] text-2xs text-right font-mono">${item.call_count}</span>
          </div>
        `
      })}
    </div>
  `
}

function distSegStyle(pct: number): string {
  return pct > 0 ? `width:${pct.toFixed(1)}%` : ''
}

function ToolDistribution({ dist }: { dist: { total: number; public: number; visible: number; hidden: number } | null | undefined }) {
  if (!dist) return html`<div class="text-2xs text-[var(--color-fg-muted)] italic">도구 분포 데이터가 없습니다.</div>`
  const visibleExclusive = Math.max(0, dist.visible - dist.public)
  const pct = (n: number) => dist.total > 0 ? ((n / dist.total) * 100).toFixed(1) : '0'
  const segPct = (n: number) => dist.total > 0 ? (n / dist.total) * 100 : 0
  return html`
    <div class="flex flex-col gap-2">
      <div class="v2-lab-row flex items-center gap-3">
        <span class="inline-block min-w-18 px-2 py-0.5 text-2xs font-semibold text-center rounded-[var(--r-1)] badge-essential">공개 MCP</span>
        <span class="text-[var(--color-fg-secondary)] text-sm font-semibold min-w-9 text-right">${dist.public}</span>
        <span class="text-[var(--color-fg-muted)] text-sm min-w-12 text-right">${pct(dist.public)}%</span>
      </div>
      <div class="v2-lab-row flex items-center gap-3">
        <span class="inline-block min-w-18 px-2 py-0.5 text-2xs font-semibold text-center rounded-[var(--r-1)] badge-standard">내부 전용</span>
        <span class="text-[var(--color-fg-secondary)] text-sm font-semibold min-w-9 text-right">${visibleExclusive}</span>
        <span class="text-[var(--color-fg-muted)] text-sm min-w-12 text-right">${pct(visibleExclusive)}%</span>
      </div>
      <div class="v2-lab-row flex items-center gap-3">
        <span class="inline-block min-w-18 px-2 py-0.5 text-2xs font-semibold text-center rounded-[var(--r-1)] badge-full">숨김</span>
        <span class="text-[var(--color-fg-secondary)] text-sm font-semibold min-w-9 text-right">${dist.hidden}</span>
        <span class="text-[var(--color-fg-muted)] text-sm min-w-12 text-right">${pct(dist.hidden)}%</span>
      </div>
      ${dist.total > 0 ? html`
        <div class="bar-seg mt-1" style="height:var(--sp-1)">
          ${dist.public > 0 ? html`<span class="seg-ok" style=${distSegStyle(segPct(dist.public))}></span>` : null}
          ${visibleExclusive > 0 ? html`<span class="seg-idle" style=${distSegStyle(segPct(visibleExclusive))}></span>` : null}
          ${dist.hidden > 0 ? html`<span class="seg-warn" style=${distSegStyle(segPct(dist.hidden))}></span>` : null}
        </div>
      ` : null}
      <div class="text-3xs text-[var(--color-fg-disabled)] mt-1">전체 ${dist.total}개 (공개 ${dist.public} + 내부 ${visibleExclusive} + 숨김 ${dist.hidden})</div>
    </div>
  `
}

export function ToolMetrics({ data }: { data: ToolMetricsResponse | null }) {
  const catalog = data?.catalog_usage
  return html`
    <div class="flex flex-col gap-4">
      <div class="flex justify-between items-center">
        <h3 class="text-[var(--color-fg-secondary)] text-lg font-semibold m-0">도구 사용 현황</h3>
      </div>

      ${data ? html`
        <div class="text-2xs text-[var(--color-fg-muted)] mb-3">
          ${data.metrics_source
            ? '현재 프로세스 호출과 복원에 성공한 SQLite 보존 기록을 합산합니다. 이 응답은 복원·저장 상태를 확인하지 않습니다. 보존 범위 밖의 과거 사용 여부는 알 수 없습니다.'
            : '사용 집계의 원천 정보가 아직 없습니다.'}
        </div>
        <div class="grid grid-cols-[repeat(4,minmax(0,1fr))] gap-3 max-[880px]:grid-cols-[repeat(2,minmax(0,1fr))]">
          <${StatTile} label="총 호출 수" value=${String(data.total_calls)} status="brass" />
          <${StatTile} label="사용이 관측된 전체 도구" value=${String(data.distinct_tools_called)} status="brass" />
        </div>
        ${catalog ? html`
          <div class="text-xs text-[var(--color-fg-muted)]">
            현재 비숨김 도구 ${catalog.visible_total}개: 사용 관측 ${catalog.visible_called}개 · 현재 집계에 호출 없음 ${catalog.visible_without_observed_call}개
          </div>
          <div class="text-xs text-[var(--color-fg-muted)]">
            별도 사용 관측: 숨김 도구 ${catalog.hidden_called}개 · 현재 카탈로그 밖 도구 ${catalog.outside_catalog_called}개
          </div>
        ` : html`<p class="muted">카탈로그별 사용 범위를 아직 확인하지 못했습니다.</p>`}

        <div class="tool-metrics-sections">
          <div>
            <h4 class="text-[var(--color-fg-muted)] text-2xs uppercase tracking-[0.05em] mb-2.5 mt-0">도구 분포</h4>
            <${ToolDistribution} dist=${data.tool_distribution} />
          </div>
          <div>
            <h4 class="text-[var(--color-fg-muted)] text-2xs uppercase tracking-[0.05em] mb-2.5 mt-0">상위 20 도구</h4>
            ${(() => {
              // Build category chips from labels actually present in top_20.
              const labelCounts = new Map<string, number>()
              for (const it of data.top_20) {
                const label = toolCategory(it.name).label
                labelCounts.set(label, (labelCounts.get(label) ?? 0) + 1)
              }
              const categoryChips: { key: string; label: string; count: number }[] = [
                { key: 'all', label: '전체', count: data.top_20.length },
                ...Array.from(labelCounts.entries())
                  .sort((a, b) => b[1] - a[1])
                  .map(([label, count]) => ({ key: label, label, count })),
              ]
              const filtered = filterTools(data.top_20, searchQuery.value, categoryFilter.value)
              const filterMaxCount = filtered.length > 0 ? filtered[0]!.call_count : 0
              return html`
                <div class="flex flex-col gap-2 mb-3 sm:flex-row sm:items-center sm:justify-between">
                  <${FilterChips}
                    chips=${categoryChips}
                    active=${categoryFilter}
                  />
                  <${TextInput}
                    class="sm:max-w-60"
                    name="tool_metrics_search"
                    ariaLabel="도구 이름 검색"
                    autoComplete="off"
                    placeholder="도구 이름 검색..."
                    value=${searchQuery.value}
                    onInput=${(e: Event) => {
                      searchQuery.value = (e.target as HTMLInputElement).value
                    }}
                  />
                </div>
                ${(categoryFilter.value !== 'all' || searchQuery.value.trim() !== '') ? html`
                  <div class="mb-2 text-2xs text-[var(--color-fg-muted)]">
                    ${filtered.length} / ${data.top_20.length}개 도구
                  </div>
                ` : null}
                ${filtered.length === 0 ? html`
                  <p class="muted">조건에 맞는 도구 없음</p>
                ` : html`
                  <${BarChart}
                    items=${filtered}
                    maxCount=${filterMaxCount}
                  />
                `}
              `
            })()}
          </div>
        </div>
      ` : html`
        <p class="muted">도구 사용 통계를 불러오는 중입니다.</p>
      `}
    </div>
  `
}
