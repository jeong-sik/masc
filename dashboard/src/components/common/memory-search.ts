// MemorySearch — AX molecule for vector-based semantic memory search.
//
// Kimi design system sec03 reference: 3.1.2 vector similarity search UX.

import { html } from 'htm/preact'
import type { FunctionComponent } from 'preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { useId } from '../../../design-system/headless-preact/use-id'

export interface MemorySearchResult {
  id: string
  content: string
  similarity: number
  cluster: string
}

export interface MemorySearchClusterSummary {
  readonly cluster: string
  readonly count: number
  readonly topSimilarity: number
}

export interface MemorySearchSummary {
  readonly resultCount: number
  readonly topSimilarity: number
  readonly averageSimilarity: number
  readonly clusterCount: number
  readonly clusters: MemorySearchClusterSummary[]
}

interface MemorySearchProps {
  query?: string
  results?: MemorySearchResult[]
  loading?: boolean
  onQueryChange?: (query: string) => void
  testId?: string
}

export function normalizeSimilarity(similarity: number): number {
  return Number.isFinite(similarity) ? Math.max(0, Math.min(1, similarity)) : 0
}

export function formatSimilarityPercent(similarity: number): string {
  return `${Math.round(normalizeSimilarity(similarity) * 100)}%`
}

export function summarizeMemorySearchResults(results: MemorySearchResult[]): MemorySearchSummary {
  const clusters = new Map<string, { count: number; topSimilarity: number }>()
  let totalSimilarity = 0
  let topSimilarity = 0

  results.forEach((result) => {
    const similarity = normalizeSimilarity(result.similarity)
    totalSimilarity += similarity
    topSimilarity = Math.max(topSimilarity, similarity)

    const cluster = clusters.get(result.cluster) ?? { count: 0, topSimilarity: 0 }
    cluster.count += 1
    cluster.topSimilarity = Math.max(cluster.topSimilarity, similarity)
    clusters.set(result.cluster, cluster)
  })

  const clusterSummaries = Array.from(clusters.entries())
    .map(([cluster, summary]) => ({ cluster, ...summary }))
    .sort((a, b) => b.count - a.count || b.topSimilarity - a.topSimilarity || a.cluster.localeCompare(b.cluster))

  return {
    resultCount: results.length,
    topSimilarity,
    averageSimilarity: results.length === 0 ? 0 : totalSimilarity / results.length,
    clusterCount: clusterSummaries.length,
    clusters: clusterSummaries,
  }
}

export const MemorySearch: FunctionComponent<MemorySearchProps> = ({
  query = '',
  results = [],
  loading = false,
  onQueryChange,
  testId,
}) => {
  const [localQuery, setLocalQuery] = useState(query)
  const summary = useMemo(() => summarizeMemorySearchResults(results), [results])
  const summaryId = `${useId()}-memory-search-summary`

  useEffect(() => {
    setLocalQuery(query)
  }, [query])

  const handleInput = (e: Event) => {
    const v = (e.currentTarget as HTMLInputElement).value
    setLocalQuery(v)
    onQueryChange?.(v)
  }

  return html`
    <div
      class="w-full"
      data-memory-search
      data-memory-search-result-count=${summary.resultCount}
      data-memory-search-cluster-count=${summary.clusterCount}
      data-memory-search-top-similarity=${Math.round(summary.topSimilarity * 100)}
      data-testid=${testId}
    >
      <div class="flex items-center gap-2">
        <input
          type="search"
          value=${localQuery}
          onInput=${handleInput}
          class="w-full rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-sm text-[var(--color-fg-primary)] outline-none focus:ring-1 focus:ring-[var(--color-accent)]"
          placeholder="기억 검색 (의미적 유사도)..."
          aria-label="메모리 검색"
          aria-describedby=${summaryId}
        />
      </div>
      <div
        id=${summaryId}
        class="mt-2 grid grid-cols-3 gap-2 text-3xs text-[var(--color-fg-secondary)]"
        data-memory-search-summary
      >
        <span>결과 ${summary.resultCount}개</span>
        <span>최고 ${formatSimilarityPercent(summary.topSimilarity)}</span>
        <span>클러스터 ${summary.clusterCount}개</span>
      </div>
      ${loading
        ? html`<div class="mt-2 animate-pulse text-3xs text-[var(--color-fg-secondary)]" role="status">검색 중...</div>`
        : null}
      ${!loading && localQuery && summary.resultCount === 0
        ? html`<div class="mt-2 text-3xs text-[var(--color-fg-muted)]" role="status">검색 결과 없음</div>`
        : null}
      ${summary.clusters.length > 0
        ? html`
            <div class="mt-2 flex flex-wrap gap-1.5" aria-label="관련 메모리 클러스터" data-memory-search-clusters>
              ${summary.clusters.map(
                cluster => html`
                  <span
                    key=${cluster.cluster}
                    class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-2 py-1 text-3xs text-[var(--color-fg-secondary)]"
                    data-memory-search-cluster=${cluster.cluster}
                    data-memory-search-cluster-count=${cluster.count}
                    data-memory-search-cluster-top=${Math.round(cluster.topSimilarity * 100)}
                  >
                    ${cluster.cluster} ${cluster.count} · ${formatSimilarityPercent(cluster.topSimilarity)}
                  </span>
                `,
              )}
            </div>
          `
        : null}
      <div class="mt-2 space-y-1" role="list" aria-label="검색 결과">
        ${results.map(
          (r, index) => {
            const similarity = normalizeSimilarity(r.similarity)
            const percent = Math.round(similarity * 100)
            return html`
            <div
              key=${r.id}
              class="group flex cursor-pointer items-center gap-3 rounded-[var(--r-1)] px-3 py-2 hover:bg-[var(--color-bg-hover)]"
              role="listitem"
              aria-label="${index + 1}위 ${r.content}, 유사도 ${percent}%, 클러스터 ${r.cluster}"
              data-memory-search-result-id=${r.id}
              data-memory-search-result-rank=${index + 1}
              data-memory-search-result-cluster=${r.cluster}
              data-memory-search-result-similarity=${percent}
            >
              <div class="h-1 w-12 overflow-hidden rounded-full bg-[var(--color-bg-elevated)]">
                <div
                  class="h-full rounded-full"
                  style=${{
                    width: `${percent}%`,
                    background: 'var(--color-accent)',
                  }}
                  role="progressbar"
                  aria-label="${r.content} 유사도"
                  aria-valuemin="0"
                  aria-valuemax="100"
                  aria-valuenow=${percent}
                ></div>
              </div>
              <span class="w-12 text-3xs text-[var(--color-fg-secondary)]"
                >${formatSimilarityPercent(similarity)}</span
              >
              <span class="flex-1 truncate text-sm text-[var(--color-fg-primary)]"
                >${r.content}</span
              >
              <span
                class="text-3xs text-[var(--color-accent)]"
                >${r.cluster}</span
              >
            </div>
          `
          },
        )}
      </div>
    </div>
  `
}
