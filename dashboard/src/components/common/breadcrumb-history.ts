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

export interface BreadcrumbItemSummary {
  readonly id: string
  readonly label: string
  readonly index: number
  readonly active: boolean
  readonly first: boolean
  readonly last: boolean
  readonly timestamp: number | null
  readonly timeLabel: string
  readonly hasTimestamp: boolean
}

export interface BreadcrumbHistorySummary {
  readonly count: number
  readonly empty: boolean
  readonly activeId: string
  readonly activeIndex: number
  readonly hasActive: boolean
  readonly hasTimestamps: boolean
  readonly items: BreadcrumbItemSummary[]
}

interface BreadcrumbHistoryProps {
  items: BreadcrumbItem[]
  onNavigate?: (id: string) => void
  testId?: string
}

export function formatBreadcrumbTime(ts?: number): string {
  if (!ts) return ''
  const d = new Date(ts)
  return d.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit' })
}

export function summarizeBreadcrumbHistory(items: BreadcrumbItem[]): BreadcrumbHistorySummary {
  const activeIndex = items.findIndex((item) => item.active === true)
  const summaryItems = items.map((item, index) => {
    const timeLabel = formatBreadcrumbTime(item.timestamp)
    return {
      id: item.id,
      label: item.label,
      index,
      active: item.active === true,
      first: index === 0,
      last: index === items.length - 1,
      timestamp: item.timestamp ?? null,
      timeLabel,
      hasTimestamp: timeLabel.length > 0,
    }
  })

  return {
    count: items.length,
    empty: items.length === 0,
    activeId: activeIndex >= 0 ? items[activeIndex]!.id : '',
    activeIndex,
    hasActive: activeIndex >= 0,
    hasTimestamps: summaryItems.some((item) => item.hasTimestamp),
    items: summaryItems,
  }
}

export function BreadcrumbHistory({ items, onNavigate, testId }: BreadcrumbHistoryProps) {
  const summary = summarizeBreadcrumbHistory(items)
  const navigable = onNavigate != null

  if (summary.empty) {
    return html`
      <nav
        data-breadcrumb-history
        data-breadcrumb-count="0"
        data-breadcrumb-empty="true"
        data-breadcrumb-active-id=""
        data-breadcrumb-active-index="-1"
        data-breadcrumb-has-active="false"
        data-breadcrumb-has-timestamps="false"
        data-breadcrumb-navigable=${navigable}
        data-testid=${testId}
        class="text-xs text-[var(--color-fg-muted)]"
        aria-label="작업 히스토리"
      >
        히스토리가 없습니다.
      </nav>
    `
  }

  return html`
    <nav
      data-breadcrumb-history
      data-breadcrumb-count=${summary.count}
      data-breadcrumb-empty="false"
      data-breadcrumb-active-id=${summary.activeId}
      data-breadcrumb-active-index=${summary.activeIndex}
      data-breadcrumb-has-active=${summary.hasActive}
      data-breadcrumb-has-timestamps=${summary.hasTimestamps}
      data-breadcrumb-navigable=${navigable}
      data-testid=${testId}
      aria-label="작업 히스토리"
    >
      <ol class="flex max-w-full items-center gap-1 overflow-x-auto overflow-y-hidden text-sm"
        role="list"
      >
        ${summary.items.map((item) => {
          const activeCls = item.active
            ? 'text-[var(--color-accent-fg)] font-medium'
            : 'text-[var(--color-fg-secondary)] hover:text-[var(--color-fg-primary)]'
          return html`
            <li
              class="flex min-w-0 shrink-0 items-center gap-1"
              role="listitem"
              data-breadcrumb-item
              data-breadcrumb-item-id=${item.id}
              data-breadcrumb-item-index=${item.index}
              data-breadcrumb-item-active=${item.active}
              data-breadcrumb-item-first=${item.first}
              data-breadcrumb-item-last=${item.last}
              data-breadcrumb-item-has-timestamp=${item.hasTimestamp}
              data-breadcrumb-item-time-label=${item.timeLabel}
            >
              ${item.index > 0
                ? html`<span class="text-[var(--color-fg-muted)] mx-0.5" aria-hidden="true">/</span>`
                : null}
              <button
                class="inline-flex max-w-[14rem] items-center gap-1 rounded-[var(--r-1)] px-1.5 py-0.5 hover:bg-[var(--color-bg-surface)] ${activeCls}"
                onClick=${() => onNavigate?.(item.id)}
                aria-current=${item.active ? 'page' : undefined}
                disabled=${!navigable}
              >
                <span class="min-w-0 truncate">${item.label}</span>
                ${item.hasTimestamp
                  ? html`<time
                      class="shrink-0 text-3xs text-[var(--color-fg-muted)]"
                      datetime=${new Date(item.timestamp!).toISOString()}
                      title=${item.timeLabel}
                      >${item.timeLabel}</time
                    >`
                  : null}
              </button>
            </li>
          `
        })}
      </ol>
    </nav>
  `
}
