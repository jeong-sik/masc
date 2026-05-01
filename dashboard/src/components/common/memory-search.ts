// MemorySearch — AX molecule for vector-based semantic memory search.
//
// Kimi design system sec03 reference: 3.1.2 vector similarity search UX.

import { html } from 'htm/preact'
import type { FunctionComponent } from 'preact'
import { useState } from 'preact/hooks'

export interface MemorySearchResult {
  id: string
  content: string
  similarity: number
  cluster: string
}

interface MemorySearchProps {
  query?: string
  results?: MemorySearchResult[]
  loading?: boolean
  onQueryChange?: (query: string) => void
  testId?: string
}

export const MemorySearch: FunctionComponent<MemorySearchProps> = ({
  query = '',
  results = [],
  loading = false,
  onQueryChange,
  testId,
}) => {
  const [localQuery, setLocalQuery] = useState(query)

  const handleInput = (e: InputEvent) => {
    const v = (e.currentTarget as HTMLInputElement).value
    setLocalQuery(v)
    onQueryChange?.(v)
  }

  return html`
    <div class="w-full" data-memory-search data-testid=${testId}>
      <input
        type="text"
        value=${localQuery}
        onInput=${handleInput}
        class="w-full rounded border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-sm text-[var(--color-fg-primary)] outline-none focus:ring-1 focus:ring-[var(--color-accent)]"
        placeholder="기억 검색 (의미적 유사도)..."
        aria-label="메모리 검색"
      />
      ${loading
        ? html`<div class="mt-2 animate-pulse text-3xs text-[var(--color-fg-secondary)]">검색 중...</div>`
        : null}
      <div class="mt-2 space-y-1" role="list" aria-label="검색 결과">
        ${results.map(
          r => html`
            <div
              key=${r.id}
              class="group flex cursor-pointer items-center gap-3 rounded px-3 py-2 hover:bg-[var(--white-6)]"
              role="listitem"
            >
              <div class="h-1 w-12 overflow-hidden rounded-full bg-[var(--white-4)]">
                <div
                  class="h-full rounded-full"
                  style=${{
                    width: `${Math.round(r.similarity * 100)}%`,
                    background: 'var(--color-accent)',
                  }}
                  aria-hidden="true"
                ></div>
              </div>
              <span class="w-12 text-3xs text-[var(--color-fg-secondary)]"
                >${(r.similarity * 100).toFixed(0)}%</span
              >
              <span class="flex-1 truncate text-sm text-[var(--color-fg-primary)]"
                >${r.content}</span
              >
              <span
                class="text-3xs text-[var(--color-accent)] opacity-0 transition-opacity group-hover:opacity-100"
                >${r.cluster}</span
              >
            </div>
          `,
        )}
      </div>
    </div>
  `
}
