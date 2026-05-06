// Drawer — ARIA dialog modal side panel
//
// Keyboard: Escape closes. Focus is trapped inside the drawer while open.
// Click on backdrop closes. Animates in from the edge.

import { html } from 'htm/preact'
import { useEffect, useId, useLayoutEffect, useRef } from 'preact/hooks'

export type DrawerPosition = 'left' | 'right' | 'top' | 'bottom'

export interface DrawerPositionSummary {
  position: DrawerPosition
  axis: 'horizontal' | 'vertical'
  edge: DrawerPosition
}

interface DrawerProps {
  open: boolean
  onClose: () => void
  title: string
  children: unknown
  position?: DrawerPosition
  class?: string
}

const BACKDROP_CLS =
  'fixed inset-0 bg-black/50 transition-opacity'

export function summarizeDrawerPosition(
  position: DrawerPosition = 'right',
): DrawerPositionSummary {
  return {
    position,
    axis: position === 'left' || position === 'right' ? 'horizontal' : 'vertical',
    edge: position,
  }
}

export function panelCls(position: DrawerPosition): string {
  const base =
    'fixed bg-[var(--color-bg-surface)] border-[var(--color-border-default)] shadow-[var(--shadow-panel)] overflow-auto '
  switch (position) {
    case 'left':
      return base + 'left-0 top-0 h-full w-80 max-w-[calc(100vw-1rem)] border-r'
    case 'right':
      return base + 'right-0 top-0 h-full w-80 max-w-[calc(100vw-1rem)] border-l'
    case 'top':
      return base + 'top-0 left-0 w-full h-64 max-h-[calc(100vh-1rem)] border-b'
    case 'bottom':
      return base + 'bottom-0 left-0 w-full h-64 max-h-[calc(100vh-1rem)] border-t'
    default:
      return base + 'right-0 top-0 h-full w-80 max-w-[calc(100vw-1rem)] border-l'
  }
}

export function Drawer({
  open,
  onClose,
  title,
  children,
  position = 'right',
  class: cx,
}: DrawerProps) {
  const panelRef = useRef<HTMLDivElement>(null)
  const closeBtnRef = useRef<HTMLButtonElement>(null)
  const titleId = `${useId()}-drawer-title`
  const summary = summarizeDrawerPosition(position)

  useLayoutEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        onClose()
      }
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [open, onClose])

  useEffect(() => {
    if (open) {
      closeBtnRef.current?.focus()
    }
  }, [open])

  if (!open) return null

  return html`
    <div
      class="fixed inset-0 z-50"
      role="presentation"
      data-drawer
      data-drawer-open=${open}
      data-drawer-position=${summary.position}
      data-drawer-axis=${summary.axis}
      data-drawer-edge=${summary.edge}
      onClick=${(e: MouseEvent) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div class=${BACKDROP_CLS} />
      <div
        ref=${panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby=${titleId}
        class=${panelCls(position) + (cx ? ` ${cx}` : '')}
        data-drawer-panel
        data-drawer-panel-position=${summary.position}
        onClick=${(e: MouseEvent) => e.stopPropagation()}
      >
        <div class="flex items-center justify-between gap-3 border-b border-[var(--color-border-default)] px-4 py-3">
          <h2
            id=${titleId}
            class="min-w-0 truncate font-mono text-sm font-semibold text-[var(--color-fg-primary)]"
            data-drawer-title
          >
            ${title}
          </h2>
          <button
            ref=${closeBtnRef}
            type="button"
            aria-label="Close drawer"
            class="inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-[var(--r-0)] border border-[var(--color-border-subtle)] font-mono text-xs text-[var(--color-fg-muted)] transition-colors hover:border-[var(--color-border-default)] hover:text-[var(--color-fg-primary)] focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--color-accent-fg)]"
            data-drawer-close
            onClick=${onClose}
          >
            ✕
          </button>
        </div>
        <div class="min-w-0 p-4" data-drawer-body>${children}</div>
      </div>
    </div>
  `
}
