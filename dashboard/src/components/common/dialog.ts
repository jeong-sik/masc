import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useEffect, useRef } from 'preact/hooks'
import { useFocusScope } from '../../../design-system/headless-preact/use-focus-scope'

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

  // Focus trap + restore: delegated to headless-core via useFocusScope.
  // Replaces the inline FOCUSABLE_SELECTOR + focusableElements + trapFocus
  // helpers that lived here pre-migration (RFC 0002 Iter 1).
  useFocusScope({
    containerRef: panelRef,
    active: true,
    initialFocus: () => initialFocusRef?.current ?? panelRef.current,
  })

  // Scroll lock + ESC-to-close are out of scope for FocusScope (RFC 0001
  // §"out of scope" — only focus management). Kept inline in the
  // consumer so each dialog can opt in/out of body-overflow behavior
  // independently in the future.
  useEffect(() => {
    const previousOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        onClose()
      }
    }

    document.addEventListener('keydown', onKeyDown)

    return () => {
      document.removeEventListener('keydown', onKeyDown)
      document.body.style.overflow = previousOverflow
    }
  }, [onClose])

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
        data-state="open"
      >
        ${children}
      </div>
    </div>
  `
}
