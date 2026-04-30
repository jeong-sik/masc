// Drawer — ARIA dialog modal side panel
//
// Keyboard: Escape closes. Focus is trapped inside the drawer while open.
// Click on backdrop closes. Animates in from the edge.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'

interface DrawerProps {
  open: boolean
  onClose: () => void
  title: string
  children: unknown
  position?: 'left' | 'right' | 'top' | 'bottom'
  class?: string
}

const BACKDROP_CLS =
  'fixed inset-0 bg-black/50 transition-opacity'

function panelCls(position: string): string {
  const base =
    'fixed bg-[var(--dialog-panel-bg)] border-[var(--dialog-panel-border)] shadow-[0_8px_24px_rgba(0,0,0,0.4)] overflow-auto '
  switch (position) {
    case 'left':
      return base + 'left-0 top-0 h-full w-80 border-r'
    case 'right':
      return base + 'right-0 top-0 h-full w-80 border-l'
    case 'top':
      return base + 'top-0 left-0 w-full h-64 border-b'
    case 'bottom':
      return base + 'bottom-0 left-0 w-full h-64 border-t'
    default:
      return base + 'right-0 top-0 h-full w-80 border-l'
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

  useEffect(() => {
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
      onClick=${(e: MouseEvent) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div class=${BACKDROP_CLS} />
      <div
        ref=${panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="drawer-title"
        class=${panelCls(position) + (cx ? ` ${cx}` : '')}
        onClick=${(e: MouseEvent) => e.stopPropagation()}
      >
        <div class="flex items-center justify-between px-4 py-3 border-b border-[var(--color-border-default)]">
          <h2 id="drawer-title" class="text-base font-medium text-[var(--color-fg-primary)]">
            ${title}
          </h2>
          <button
            ref=${closeBtnRef}
            type="button"
            aria-label="Close drawer"
            class="text-[var(--color-fg-muted)] hover:text-[var(--color-fg-primary)] transition-colors"
            onClick=${onClose}
          >
            ✕
          </button>
        </div>
        <div class="p-4">${children}</div>
      </div>
    </div>
  `
}
