// AgentMemory — AX molecule that visualizes short-term + long-term memory tiers.
//
// Kimi design system sec02 reference: 2.2.2 memory hierarchy with recency fade
// for short-term and cluster grouping for long-term.

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import { formatPct1 } from '../../lib/format-number'

export interface MemoryEntry {
  id: string
  content: string
  type: 'short_term' | 'long_term'
  timestamp: number
  similarity?: number
  cluster?: string
}

export type AgentMemoryStatus = 'empty' | 'short_only' | 'long_only' | 'mixed'

export interface AgentMemorySummary {
  totalCount: number
  shortTermCount: number
  visibleShortTermCount: number
  hiddenShortTermCount: number
  longTermCount: number
  clusterCount: number
  unclusteredCount: number
  maxSimilarity: number | null
  latestTimestamp: number | null
  status: AgentMemoryStatus
}

interface AgentMemoryProps {
  entries: MemoryEntry[]
  testId?: string
}

const SHORT_TERM_LIMIT = 10

function formatTime(ts: number): string {
  const d = new Date(ts)
  if (!Number.isFinite(d.getTime())) return '--:--'
  return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`
}

function formatDateTime(ts: number): string | undefined {
  const d = new Date(ts)
  if (!Number.isFinite(d.getTime())) return undefined
  return d.toISOString()
}

export function getVisibleShortTermMemory(entries: MemoryEntry[]): MemoryEntry[] {
  return entries
    .filter(e => e.type === 'short_term')
    .sort((a, b) => b.timestamp - a.timestamp)
    .slice(0, SHORT_TERM_LIMIT)
}

export function groupByCluster(entries: MemoryEntry[]): Record<string, MemoryEntry[]> {
  const groups: Record<string, MemoryEntry[]> = {}
  for (const e of entries) {
    const key = e.cluster || '미분류'
    if (!groups[key]) groups[key] = []
    groups[key].push(e)
  }
  return groups
}

export function summarizeAgentMemory(entries: MemoryEntry[]): AgentMemorySummary {
  const shortTermCount = entries.filter(e => e.type === 'short_term').length
  const visibleShortTermCount = getVisibleShortTermMemory(entries).length
  const longTerm = entries.filter(e => e.type === 'long_term')
  const clusters = groupByCluster(longTerm)
  const similarities = longTerm
    .map(e => e.similarity)
    .filter((value): value is number => typeof value === 'number' && Number.isFinite(value))
  const status: AgentMemoryStatus =
    entries.length === 0
      ? 'empty'
      : shortTermCount > 0 && longTerm.length > 0
        ? 'mixed'
        : shortTermCount > 0
          ? 'short_only'
          : 'long_only'

  return {
    totalCount: entries.length,
    shortTermCount,
    visibleShortTermCount,
    hiddenShortTermCount: Math.max(0, shortTermCount - visibleShortTermCount),
    longTermCount: longTerm.length,
    clusterCount: Object.keys(clusters).length,
    unclusteredCount: clusters['미분류']?.length ?? 0,
    maxSimilarity: similarities.length > 0 ? Math.max(...similarities) : null,
    latestTimestamp: entries.reduce<number | null>(
      (latest, entry) => latest == null || entry.timestamp > latest ? entry.timestamp : latest,
      null,
    ),
    status,
  }
}

export function AgentMemory({ entries, testId }: AgentMemoryProps) {
  const summary = useMemo(() => summarizeAgentMemory(entries), [entries])
  const shortTerm = useMemo(() => getVisibleShortTermMemory(entries), [entries])
  const longTerm = useMemo(() => entries.filter(e => e.type === 'long_term'), [entries])
  const clusters = useMemo(() => groupByCluster(longTerm), [longTerm])

  return html`
    <div
      class="flex min-h-64 flex-col gap-2 md:h-64"
      data-agent-memory
      data-agent-memory-total-count=${summary.totalCount}
      data-agent-memory-short-term-count=${summary.shortTermCount}
      data-agent-memory-visible-short-term-count=${summary.visibleShortTermCount}
      data-agent-memory-hidden-short-term-count=${summary.hiddenShortTermCount}
      data-agent-memory-long-term-count=${summary.longTermCount}
      data-agent-memory-cluster-count=${summary.clusterCount}
      data-agent-memory-unclustered-count=${summary.unclusteredCount}
      data-agent-memory-max-similarity=${summary.maxSimilarity ?? ''}
      data-agent-memory-latest-timestamp=${summary.latestTimestamp ?? ''}
      data-agent-memory-status=${summary.status}
      data-testid=${testId}
      aria-label="에이전트 메모리, 전체 ${summary.totalCount}개, 클러스터 ${summary.clusterCount}개"
    >
      <div
        class="grid grid-cols-3 gap-2 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] p-2"
        aria-label="에이전트 메모리 요약"
      >
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">전체</div>
          <div class="font-mono text-sm text-[var(--color-fg-primary)]">${summary.totalCount}</div>
        </div>
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">단기</div>
          <div class="font-mono text-sm text-[var(--color-fg-primary)]">
            ${summary.visibleShortTermCount}/${summary.shortTermCount}
          </div>
        </div>
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">클러스터</div>
          <div class="font-mono text-sm text-[var(--color-fg-primary)]">${summary.clusterCount}</div>
        </div>
      </div>

      <div class="grid min-h-0 flex-1 grid-cols-1 gap-3 md:grid-cols-2">
        <div class="min-h-0 overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2">
          <h4 class="mb-2 text-3xs font-semibold uppercase tracking-wider text-[var(--color-fg-secondary)]">
            단기 기억 (최근 ${shortTerm.length}개)
          </h4>
          <div
            role="list"
            aria-label="단기 기억 목록"
            data-memory-section="short_term"
            data-memory-section-count=${summary.shortTermCount}
            data-memory-section-visible-count=${summary.visibleShortTermCount}
          >
            ${shortTerm.length === 0
              ? html`<div class="py-2 text-3xs text-[var(--color-fg-muted)]" role="listitem">단기 기억 없음</div>`
              : shortTerm.map(
                  (e, i) => html`
                    <div
                      key=${e.id}
                      class="flex min-w-0 items-center gap-2 py-1 text-sm"
                      style=${{ opacity: `${Math.max(0.3, 1 - i * 0.08)}` }}
                      role="listitem"
                      data-memory-entry-id=${e.id}
                      data-memory-entry-type=${e.type}
                      data-memory-entry-timestamp=${e.timestamp}
                      data-memory-entry-recency-index=${i}
                    >
                      <span class="text-[var(--color-accent-fg)]" aria-hidden="true">◆</span>
                      <span class="min-w-0 flex-1 truncate text-[var(--color-fg-primary)]">${e.content}</span>
                      <time
                        class="shrink-0 text-3xs text-[var(--color-fg-secondary)]"
                        datetime=${formatDateTime(e.timestamp)}
                        >${formatTime(e.timestamp)}</time
                      >
                    </div>
                  `,
                )}
          </div>
        </div>

        <div class="min-h-0 overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2">
          <h4 class="mb-2 text-3xs font-semibold uppercase tracking-wider text-[var(--color-fg-secondary)]">
            장기 기억 (${summary.clusterCount}개 클러스터)
          </h4>
          <div
            role="list"
            aria-label="장기 기억 클러스터 목록"
            data-memory-section="long_term"
            data-memory-section-count=${summary.longTermCount}
            data-memory-section-cluster-count=${summary.clusterCount}
          >
            ${Object.keys(clusters).length === 0
              ? html`<div class="py-2 text-3xs text-[var(--color-fg-muted)]" role="listitem">장기 기억 없음</div>`
              : Object.entries(clusters).map(
                  ([cluster, items]) => html`
                    <div
                      key=${cluster}
                      class="mb-2"
                      role="listitem"
                      data-memory-cluster=${cluster}
                      data-memory-cluster-count=${items.length}
                    >
                      <span class="text-3xs font-medium text-[var(--color-accent-fg)]">${cluster}</span>
                      <div class="mt-1 flex flex-wrap gap-1">
                        ${items.map(
                          item => html`
                            <span
                              key=${item.id}
                              class="inline-block max-w-full truncate rounded-full bg-[var(--color-bg-elevated)] px-1.5 py-0.5 text-3xs text-[var(--color-fg-secondary)]"
                              title=${item.similarity != null
                                ? `유사도: ${formatPct1(item.similarity)}`
                                : undefined}
                              data-memory-entry-id=${item.id}
                              data-memory-entry-type=${item.type}
                              data-memory-entry-cluster=${cluster}
                              data-memory-entry-similarity=${item.similarity ?? ''}
                            >
                              ${item.content.slice(0, 20)}
                            </span>
                          `,
                        )}
                      </div>
                    </div>
                  `,
                )}
          </div>
        </div>
      </div>
    </div>
  `
}
