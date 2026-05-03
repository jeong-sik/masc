// AgentMemory — AX molecule that visualizes short-term + long-term memory tiers.
//
// Kimi design system sec02 reference: 2.2.2 memory hierarchy with recency fade
// for short-term and cluster grouping for long-term.

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'

export interface MemoryEntry {
  id: string
  content: string
  type: 'short_term' | 'long_term'
  timestamp: number
  similarity?: number
  cluster?: string
}

interface AgentMemoryProps {
  entries: MemoryEntry[]
  testId?: string
}

function formatTime(ts: number): string {
  const d = new Date(ts)
  return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`
}

function groupByCluster(entries: MemoryEntry[]): Record<string, MemoryEntry[]> {
  const groups: Record<string, MemoryEntry[]> = {}
  for (const e of entries) {
    const key = e.cluster || '미분류'
    if (!groups[key]) groups[key] = []
    groups[key].push(e)
  }
  return groups
}

export function AgentMemory({ entries, testId }: AgentMemoryProps) {
  const shortTerm = useMemo(
    () =>
      entries
        .filter(e => e.type === 'short_term')
        .sort((a, b) => b.timestamp - a.timestamp)
        .slice(0, 10),
    [entries],
  )
  const longTerm = useMemo(() => entries.filter(e => e.type === 'long_term'), [entries])
  const clusters = useMemo(() => groupByCluster(longTerm), [longTerm])

  return html`
    <div
      class="flex gap-3 h-64"
      data-agent-memory
      data-testid=${testId}
    >
      <div class="flex-1 overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2">
        <h4 class="mb-2 text-3xs font-semibold uppercase tracking-wider text-[var(--color-fg-secondary)]">
          단기 기억 (최근 ${shortTerm.length}개)
        </h4>
        <div role="list" aria-label="단기 기억 목록">
          ${shortTerm.map(
            (e, i) => html`
              <div
                key=${e.id}
                class="flex items-center gap-2 py-1 text-sm"
                style=${{ opacity: `${Math.max(0.3, 1 - i * 0.08)}` }}
                role="listitem"
              >
                <span class="text-[var(--color-accent)]" aria-hidden="true">◆</span>
                <span class="flex-1 truncate text-[var(--color-fg-primary)]">${e.content}</span>
                <span class="text-3xs text-[var(--color-fg-secondary)]">${formatTime(e.timestamp)}</span>
              </div>
            `,
          )}
        </div>
      </div>

      <div class="flex-1 overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2">
        <h4 class="mb-2 text-3xs font-semibold uppercase tracking-wider text-[var(--color-fg-secondary)]">
          장기 기억 (${longTerm.length}개 클러스터)
        </h4>
        <div role="list" aria-label="장기 기억 클러스터 목록">
          ${Object.entries(clusters).map(
            ([cluster, items]) => html`
              <div key=${cluster} class="mb-2" role="listitem">
                <span class="text-3xs font-medium text-[var(--color-accent)]">${cluster}</span>
                <div class="mt-1 flex flex-wrap gap-1">
                  ${items.map(
                    item => html`
                      <span
                        key=${item.id}
                        class="inline-block rounded-full bg-[var(--color-bg-elevated)] px-1.5 py-0.5 text-3xs text-[var(--color-fg-secondary)]"
                        title=${item.similarity != null
                          ? `유사도: ${(item.similarity * 100).toFixed(1)}%`
                          : undefined}
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
  `
}
