import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useEffect, useRef } from 'preact/hooks'

const FOCUSABLE_SELECTOR = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(',')

function focusableElements(root: HTMLElement): HTMLElement[] {
  return Array.from(root.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR))
    .filter(element => !element.hasAttribute('hidden') && element.getAttribute('aria-hidden') !== 'true')
}

function trapFocus(event: KeyboardEvent, root: HTMLElement): void {
  if (event.key !== 'Tab') return

  const elements = focusableElements(root)
  if (elements.length === 0) {
    event.preventDefault()
    root.focus()
    return
  }

  const first = elements[0]
  const last = elements[elements.length - 1]
  const active = document.activeElement as HTMLElement | null
  if (!first || !last) return

  if (event.shiftKey) {
    if (active === first || active === root) {
      event.preventDefault()
      last.focus()
    }
    return
  }

  if (active === last) {
    event.preventDefault()
    first.focus()
  }
}

interface DialogOverlayProps {
  labelledBy: string
  describedBy?: string
  onClose: () => void
  overlayClass?: string
  panelClass?: string
  initialFocusRef?: { current: HTMLElement | null }
  children: ComponentChildren
}

export function DialogOverlay({
  labelledBy,
  describedBy,
  onClose,
  overlayClass,
  panelClass,
  initialFocusRef,
  children,
}: DialogOverlayProps) {
  const panelRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const restoreTarget = document.activeElement instanceof HTMLElement ? document.activeElement : null
    const previousOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'

    const focusTarget = initialFocusRef?.current ?? panelRef.current
    window.requestAnimationFrame(() => {
      focusTarget?.focus()
    })

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        onClose()
        return
      }

      if (panelRef.current) {
        trapFocus(event, panelRef.current)
      }
    }

    document.addEventListener('keydown', onKeyDown)

    return () => {
      document.removeEventListener('keydown', onKeyDown)
      document.body.style.overflow = previousOverflow
      restoreTarget?.focus()
    }
  }, [initialFocusRef, onClose])

  return html`
    <div
      class=${overlayClass}
      onClick=${(event: Event) => {
        if (event.target === event.currentTarget) {
          onClose()
        }
      }}
    >
      <div
        ref=${panelRef}
        class=${panelClass}
        role="dialog"
        aria-modal="true"
        aria-labelledby=${labelledBy}
        aria-describedby=${describedBy}
        tabIndex=${-1}
      >
        ${children}
      </div>
    </div>
  `
}
