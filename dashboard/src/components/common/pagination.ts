// Pagination — numeric and cursor pagination primitives.
//
// Numeric pagination uses nav + list semantics and marks the current page with
// aria-current="page". Cursor pagination keeps previous/next batch controls
// explicit for event streams that do not expose page numbers.

import { html } from 'htm/preact'
import type { ComponentChild } from 'preact'
import { useCallback, useMemo, useState } from 'preact/hooks'
import { ChevronLeft, ChevronRight, MoreHorizontal } from 'lucide-preact'

type PageItem = number | 'ellipsis-start' | 'ellipsis-end'

export interface PaginationProps {
  page?: number
  defaultPage?: number
  totalPages: number
  onPageChange?: (page: number) => void
  siblingCount?: number
  boundaryCount?: number
  disabled?: boolean
  showSummary?: boolean
  ariaLabel?: string
  class?: string
  testId?: string
}

export interface CursorPaginationProps {
  cursor?: string
  hasPrevious?: boolean
  hasNext?: boolean
  onPrevious?: () => void
  onNext?: () => void
  previousLabel?: string
  nextLabel?: string
  ariaLabel?: string
  disabled?: boolean
  class?: string
  testId?: string
}

const NAV_CLS = 'inline-flex items-center gap-2'
const LIST_CLS = 'inline-flex items-center gap-1'
const PAGE_BUTTON_CLS = [
  'inline-flex h-6 min-w-6 items-center justify-center rounded-sm border px-2',
  'border-[var(--color-border-default)] bg-[var(--color-bg-surface)]',
  'font-mono text-2xs tabular-nums text-[var(--color-fg-secondary)]',
  'transition-colors duration-[var(--t-fast)]',
  'hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]',
  'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-45)]',
  'disabled:cursor-not-allowed disabled:text-[var(--color-fg-disabled)] disabled:hover:bg-[var(--color-bg-surface)]',
  'aria-current:bg-[var(--button-primary-bg)] aria-current:border-[var(--button-primary-border)]',
  'aria-current:text-[var(--button-primary-fg)]',
].join(' ')
const CURSOR_NAV_CLS = [
  'inline-flex items-center gap-2 rounded border border-[var(--color-border-default)]',
  'bg-[var(--color-bg-surface)] px-3 py-2 font-mono',
].join(' ')
const CURSOR_BUTTON_CLS = [
  'inline-flex h-6 items-center gap-1 rounded-sm border border-[var(--color-border-default)] px-2',
  'text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-secondary)]',
  'transition-colors duration-[var(--t-fast)]',
  'hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]',
  'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-45)]',
  'disabled:cursor-not-allowed disabled:text-[var(--color-fg-disabled)] disabled:hover:bg-transparent',
].join(' ')

function clampPage(page: number, totalPages: number): number {
  const total = Math.max(1, Math.trunc(totalPages))
  if (!Number.isFinite(page)) return 1
  return Math.min(total, Math.max(1, Math.trunc(page)))
}

function range(start: number, end: number): number[] {
  const out: number[] = []
  for (let n = start; n <= end; n += 1) out.push(n)
  return out
}

export function paginationItems({
  page,
  totalPages,
  siblingCount = 1,
  boundaryCount = 1,
}: {
  page: number
  totalPages: number
  siblingCount?: number
  boundaryCount?: number
}): PageItem[] {
  const total = Math.max(1, Math.trunc(totalPages))
  const current = clampPage(page, total)
  const siblings = Math.max(0, Math.trunc(siblingCount))
  const boundaries = Math.max(1, Math.trunc(boundaryCount))
  const visibleWithoutEllipsis = boundaries * 2 + siblings * 2 + 3

  if (total <= visibleWithoutEllipsis) return range(1, total)

  const startPages = range(1, Math.min(boundaries, total))
  const endPages = range(Math.max(total - boundaries + 1, boundaries + 1), total)
  const siblingStart = Math.max(
    Math.min(current - siblings, total - boundaries - siblings * 2 - 1),
    boundaries + 2,
  )
  const siblingEnd = Math.min(
    Math.max(current + siblings, boundaries + siblings * 2 + 2),
    total - boundaries - 1,
  )

  const items: PageItem[] = [...startPages]
  if (siblingStart > boundaries + 2) {
    items.push('ellipsis-start')
  } else {
    items.push(...range(boundaries + 1, siblingStart - 1))
  }
  items.push(...range(siblingStart, siblingEnd))
  if (siblingEnd < total - boundaries - 1) {
    items.push('ellipsis-end')
  } else {
    items.push(...range(siblingEnd + 1, total - boundaries))
  }
  items.push(...endPages)
  return items
}

function icon(child: ComponentChild) {
  return html`<span aria-hidden="true" class="inline-flex items-center">${child}</span>`
}

export function Pagination({
  page: controlledPage,
  defaultPage = 1,
  totalPages,
  onPageChange,
  siblingCount = 1,
  boundaryCount = 1,
  disabled = false,
  showSummary = true,
  ariaLabel = 'Pagination',
  class: cx,
  testId,
}: PaginationProps) {
  const total = Math.max(1, Math.trunc(totalPages))
  const [uncontrolledPage, setUncontrolledPage] = useState(() =>
    clampPage(defaultPage, total),
  )
  const isControlled = controlledPage !== undefined
  const page = clampPage(isControlled ? controlledPage! : uncontrolledPage, total)
  const items = useMemo(
    () => paginationItems({ page, totalPages: total, siblingCount, boundaryCount }),
    [page, total, siblingCount, boundaryCount],
  )

  const setPage = useCallback(
    (next: number) => {
      const clamped = clampPage(next, total)
      if (!isControlled) setUncontrolledPage(clamped)
      if (clamped !== page) onPageChange?.(clamped)
    },
    [isControlled, onPageChange, page, total],
  )

  const button = (target: number, label: string, child: ComponentChild) => {
    const current = target === page
    return html`
      <button
        type="button"
        class=${PAGE_BUTTON_CLS}
        aria-label=${current ? `${label}, current page` : label}
        aria-current=${current ? 'page' : undefined}
        disabled=${disabled || current}
        onClick=${() => setPage(target)}
      >${child}</button>
    `
  }

  return html`
    <nav
      aria-label=${ariaLabel}
      data-testid=${testId}
      class=${cx ? `${NAV_CLS} ${cx}` : NAV_CLS}
    >
      <ul class=${LIST_CLS}>
        <li>
          <button
            type="button"
            class=${PAGE_BUTTON_CLS}
            aria-label="Previous page"
            disabled=${disabled || page <= 1}
            onClick=${() => setPage(page - 1)}
          >${icon(html`<${ChevronLeft} size=${14} focusable="false" />`)}</button>
        </li>
        ${items.map((item) =>
          typeof item === 'number'
            ? html`<li key=${`page-${item}`}>${button(item, `Page ${item}`, item)}</li>`
            : html`
                <li key=${item}>
                  <span
                    aria-hidden="true"
                    class="inline-flex h-6 min-w-6 items-center justify-center text-[var(--color-fg-disabled)]"
                  >${icon(html`<${MoreHorizontal} size=${14} focusable="false" />`)}</span>
                </li>
              `,
        )}
        <li>
          <button
            type="button"
            class=${PAGE_BUTTON_CLS}
            aria-label="Next page"
            disabled=${disabled || page >= total}
            onClick=${() => setPage(page + 1)}
          >${icon(html`<${ChevronRight} size=${14} focusable="false" />`)}</button>
        </li>
      </ul>
      ${showSummary
        ? html`
            <span
              aria-hidden="true"
              class="font-mono text-3xs uppercase tracking-wider text-[var(--color-fg-muted)]"
            >page ${page} / ${total}</span>
          `
        : null}
    </nav>
  `
}

export function CursorPagination({
  cursor,
  hasPrevious = true,
  hasNext = true,
  onPrevious,
  onNext,
  previousLabel = 'Older',
  nextLabel = 'Newer',
  ariaLabel = 'Cursor pagination',
  disabled = false,
  class: cx,
  testId,
}: CursorPaginationProps) {
  const previousDisabled = disabled || !hasPrevious
  const nextDisabled = disabled || !hasNext

  return html`
    <nav
      aria-label=${ariaLabel}
      data-testid=${testId}
      class=${cx ? `${CURSOR_NAV_CLS} ${cx}` : CURSOR_NAV_CLS}
    >
      <button
        type="button"
        class=${CURSOR_BUTTON_CLS}
        aria-label=${previousLabel}
        aria-disabled=${previousDisabled ? 'true' : undefined}
        disabled=${previousDisabled}
        onClick=${() => {
          if (!previousDisabled) onPrevious?.()
        }}
      >
        ${icon(html`<${ChevronLeft} size=${14} focusable="false" />`)}
        <span>${previousLabel}</span>
      </button>
      ${cursor
        ? html`
            <span
              class="min-w-0 flex-1 truncate px-2 text-center text-3xs uppercase tracking-wider text-[var(--color-fg-muted)]"
            >
              cursor · <span class="text-[var(--color-accent-fg)]">${cursor}</span>
            </span>
          `
        : null}
      <button
        type="button"
        class=${CURSOR_BUTTON_CLS}
        aria-label=${nextLabel}
        aria-disabled=${nextDisabled ? 'true' : undefined}
        disabled=${nextDisabled}
        onClick=${() => {
          if (!nextDisabled) onNext?.()
        }}
      >
        <span>${nextLabel}</span>
        ${icon(html`<${ChevronRight} size=${14} focusable="false" />`)}
      </button>
    </nav>
  `
}
