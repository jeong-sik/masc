import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { createPortal } from 'preact/compat'
import { useEffect, useRef } from 'preact/hooks'
import { useFocusScope } from '../../../design-system/headless-preact/use-focus-scope'
import { isDismissEscape } from '../../lib/keyboard'

export function ChatPreviewModal({
  title,
  onClose,
  children,
}: {
  title: string
  onClose: () => void
  children: ComponentChildren
}) {
  const modalRef = useRef<HTMLDivElement>(null)
  const onCloseRef = useRef(onClose)
  onCloseRef.current = onClose

  useFocusScope({ containerRef: modalRef, active: true })

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (isDismissEscape(e)) {
        e.preventDefault()
        e.stopPropagation()
        onCloseRef.current()
      }
    }
    window.addEventListener('keydown', handler, true)
    return () => window.removeEventListener('keydown', handler, true)
  }, [])

  // Keep the fixed overlay relative to the viewport, outside transcript row
  // layout/paint containment and the transcript scroll clip.
  return createPortal(html`
    <div
      ref=${modalRef}
      class="fixed inset-0 z-[var(--z-modal)] flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm"
      onClick=${onClose}
      role="dialog"
      aria-modal="true"
      aria-label=${title}
    >
      <div
        class="relative max-h-[90vh] max-w-[90vw] overflow-auto rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4 shadow-[var(--shadow-raised)]"
        onClick=${(e: Event) => e.stopPropagation()}
      >
        <div class="mb-3 flex items-center justify-between gap-4">
          <span class="truncate text-sm font-semibold text-[var(--color-fg-primary)]">${title}</span>
          <button
            type="button"
            class="rounded-[var(--r-0)] px-2 py-1 text-xs text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]"
            onClick=${onClose}
            aria-label="닫기"
          >
            ✕
          </button>
        </div>
        <div class="chat-preview-modal-body">${children}</div>
      </div>
    </div>
  `, document.body)
}
