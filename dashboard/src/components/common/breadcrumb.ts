// Breadcrumb — shared path navigation primitive.
//
// Matches the design-system G5 contract: nav[aria-label] > ol > li,
// decorative separators, and the terminal crumb marked aria-current="page".

import { html } from 'htm/preact'

export interface BreadcrumbItem {
  label: string
  href?: string
  current?: boolean
  onClick?: (event: MouseEvent) => void
}

interface BreadcrumbProps {
  items: BreadcrumbItem[]
  ariaLabel?: string
  class?: string
  itemClass?: string
  currentClass?: string
  separator?: string
  testId?: string
  dataSurfaceBreadcrumb?: boolean
}

const NAV_CLASS = [
  'flex items-center gap-1 font-mono text-3xs uppercase',
  'tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]',
].join(' ')

const LIST_CLASS = 'flex min-w-0 items-center gap-1'
const ITEM_CLASS = 'inline-flex min-w-0 items-center gap-1'
const CRUMB_CLASS = [
  'min-w-0 rounded-[var(--r-1)] px-1 py-0.5',
  'text-[var(--color-fg-disabled)]',
].join(' ')
const INTERACTIVE_CLASS = [
  CRUMB_CLASS,
  'cursor-pointer hover:bg-[var(--color-bg-elevated)] hover:text-[var(--color-fg-primary)]',
  'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-45)]',
].join(' ')
const CURRENT_CLASS = `${CRUMB_CLASS} text-[var(--color-fg-primary)]`
const SEPARATOR_CLASS = 'text-[var(--color-fg-disabled)]'

function itemKey(item: BreadcrumbItem, index: number): string {
  return `${index}:${item.label}`
}

function renderCrumb(
  item: BreadcrumbItem,
  itemClass?: string,
  currentClass?: string,
) {
  const current = item.current === true
  if (current) {
    return html`
      <span
        class=${currentClass ? `${CURRENT_CLASS} ${currentClass}` : CURRENT_CLASS}
        aria-current="page"
      >${item.label}</span>
    `
  }
  if (item.href) {
    return html`
      <a
        href=${item.href}
        class=${itemClass ? `${INTERACTIVE_CLASS} ${itemClass}` : INTERACTIVE_CLASS}
        onClick=${item.onClick}
      >${item.label}</a>
    `
  }
  if (item.onClick) {
    return html`
      <button
        type="button"
        class=${itemClass ? `${INTERACTIVE_CLASS} bg-transparent border-0 ${itemClass}` : `${INTERACTIVE_CLASS} bg-transparent border-0`}
        onClick=${item.onClick}
      >${item.label}</button>
    `
  }
  return html`<span class=${itemClass ? `${CRUMB_CLASS} ${itemClass}` : CRUMB_CLASS}>${item.label}</span>`
}

export function Breadcrumb({
  items,
  ariaLabel = 'Breadcrumb',
  class: cx,
  itemClass,
  currentClass,
  separator = '›',
  testId,
  dataSurfaceBreadcrumb = false,
}: BreadcrumbProps) {
  if (items.length === 0) return null

  const hasExplicitCurrent = items.some((item) => item.current === true)

  return html`
    <nav
      aria-label=${ariaLabel}
      data-testid=${testId}
      data-surface-breadcrumb=${dataSurfaceBreadcrumb ? 'true' : undefined}
      class=${cx ? `${NAV_CLASS} ${cx}` : NAV_CLASS}
    >
      <ol class=${LIST_CLASS}>
        ${items.map((item, index) => {
          const isLast = index === items.length - 1
          const current = hasExplicitCurrent ? item.current === true : isLast
          return html`
            <li key=${itemKey(item, index)} class=${ITEM_CLASS}>
              ${renderCrumb({ ...item, current }, itemClass, currentClass)}
              ${!isLast
                ? html`<span aria-hidden="true" class=${SEPARATOR_CLASS}>${separator}</span>`
                : null}
            </li>
          `
        })}
      </ol>
    </nav>
  `
}
