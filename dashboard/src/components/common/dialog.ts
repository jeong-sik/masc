import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useEffect, useRef, useState } from 'preact/hooks'
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

// Animation tokens (#11747) wired through Tailwind arbitrary values.
// `data-state` toggles closed→open on the first animation frame after
// mount so the transition triggers on every open (otherwise dialogs
// mount as `open` and the transition fires zero times).
const OVERLAY_BASE =
  'transition-opacity duration-[var(--enter-duration)] ease-[var(--enter-easing)] ' +
  'data-[state=closed]:opacity-0 data-[state=open]:opacity-100'

const PANEL_BASE =
  'transition-[opacity,transform] duration-[var(--enter-duration)] ease-[var(--enter-easing)] ' +
  'data-[state=closed]:opacity-0 data-[state=closed]:scale-95 ' +
  'data-[state=open]:opacity-100 data-[state=open]:scale-100'

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

  // closed→open transition on mount. Without this dance the dialog
  // mounts at `open` and the consumer's transition has no `from` state.
  const [state, setState] = useState<'closed' | 'open'>('closed')
  useEffect(() => {
    const id = requestAnimationFrame(() => setState('open'))
    return () => cancelAnimationFrame(id)
  }, [])

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

  const overlayCls = `${OVERLAY_BASE}${overlayClass ? ` ${overlayClass}` : ''}`
  const panelCls = `${PANEL_BASE}${panelClass ? ` ${panelClass}` : ''}`

  return html`
    <div
      class=${overlayCls}
      data-state=${state}
      onClick=${(event: Event) => {
        if (event.target === event.currentTarget) {
          onClose()
        }
      }}
    >
      <div
        ref=${panelRef}
        class=${panelCls}
        role="dialog"
        aria-modal="true"
        aria-labelledby=${labelledBy}
        aria-describedby=${describedBy}
        tabIndex=${-1}
        data-state=${state}
      >
        ${children}
      </div>
    </div>
  `
}
