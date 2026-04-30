// Window — modal window with Alt+F4 close contract
// Kimi sec06 ARIA pattern: window. role="dialog" + Alt+F4 keyboard contract.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useCallback, useEffect, useRef } from 'preact/hooks'

interface WindowProps {
  children: ComponentChildren
  open: boolean
  onClose: () => void
  'aria-label': string
  class?: string
}

export function Window({ children, open, onClose, 'aria-label': ariaLabel, class: cx }: WindowProps) {
  const ref = useRef<HTMLDivElement>(null)

  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (e.key === 'Escape' || (e.key === 'F4' && e.altKey)) {
        e.preventDefault()
        onClose()
      }
    },
    [onClose],
  )

  useEffect(() => {
    if (!open) return
    const el = ref.current
    if (!el) return
    el.focus()
    document.addEventListener('keydown', handleKeyDown)
    return () => document.removeEventListener('keydown', handleKeyDown)
  }, [open, handleKeyDown])

  if (!open) return null

  return html`
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
      <div
        ref=${ref}
        role="dialog"
        aria-label=${ariaLabel}
        aria-modal="true"
        tabindex="-1"
        class=${`rounded border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] shadow-lg ${cx ?? ''}`}
        onKeyDown=${handleKeyDown}
      >
        ${children}
      </div>
    </div>
  `
}
