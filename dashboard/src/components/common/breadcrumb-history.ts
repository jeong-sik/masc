// BreadcrumbHistory — agent work-history timeline navigation
// Kimi design system sec02 2.4.3: breadcrumb + history timeline.
// Zero-dependency fallback.

import { html } from 'htm/preact'

export interface BreadcrumbItem {
  id: string
  label: string
  timestamp?: number
  active?: boolean
}

interface BreadcrumbHistoryProps {
  items: BreadcrumbItem[]
  onNavigate?: (id: string) => void
  testId?: string
}

function formatTime(ts?: number): string {
  if (!ts) return ''
  const d = new Date(ts)
  return d.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit' })
}

export function BreadcrumbHistory({ items, onNavigate, testId }: BreadcrumbHistoryProps) {
  if (items.length === 0) {
    return html`
      <nav
        data-testid=${testId}
        class="text-xs text-[var(--color-fg-muted)]"
        aria-label="작업 히스토리"
      >
        히스토리가 없습니다.
      </nav>
    `
  }

  return html`
    <nav data-testid=${testId} aria-label="작업 히스토리">
      <ol class="flex items-center gap-1 text-sm overflow-auto"
        role="list"
      >
        ${items.map((item, idx) => {
          const isLast = idx === items.length - 1
          const activeCls = item.active
            ? 'text-[var(--color-accent)] font-medium'
            : 'text-[var(--color-fg-secondary)] hover:text-[var(--color-fg-primary)]'
          return html`
            <li class="flex items-center gap-1 shrink-0" role="listitem">
              ${idx > 0
                ? html`<span class="text-[var(--color-fg-muted)] mx-0.5" aria-hidden="true">/</span>`
                : null}
              <button
                class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded hover:bg-[var(--color-bg-surface)] ${activeCls}"
                onClick=${() => onNavigate?.(item.id)}
                aria-current=${item.active ? 'page' : undefined}
                disabled=${!onNavigate}
              >
                <span>${item.label}</span>
                ${item.timestamp
                  ? html`<time class="text-3xs text-[var(--color-fg-muted)]">${formatTime(item.timestamp)}</time>`
                  : null}
              </button>
            </li>
          `
        })}
      </ol>
    </nav>
  `
}
