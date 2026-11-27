import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { createPortal } from 'preact/compat'
import { useEffect, useRef } from 'preact/hooks'
import { useFocusScope } from '../../../design-system/headless-preact/use-focus-scope'
import { isDismissEscape } from '../../lib/keyboard'

export function ChatPreviewModal({
  title,
  subtitle,
  actions,
  footer,
  onClose,
  children,
}: {
  title: string
  subtitle?: string
  actions?: ComponentChildren
  footer?: ComponentChildren
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
        class="relative flex max-h-[92vh] max-w-[92vw] flex-col overflow-hidden rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4 shadow-[var(--shadow-raised)]"
        onClick=${(e: Event) => e.stopPropagation()}
      >
        <div class="mb-3 flex flex-wrap items-center justify-between gap-3">
          <div class="min-w-0 flex-1">
            <div class="truncate text-sm font-semibold text-[var(--color-fg-primary)]">${title}</div>
            ${subtitle && html`
              <div class="mono truncate text-xs text-[var(--color-fg-secondary)]">${subtitle}</div>
            `}
          </div>
          <div class="flex shrink-0 items-center gap-2">
            ${actions}
            <button
              type="button"
              class="rounded-[var(--r-0)] px-2 py-1 text-xs text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]"
              onClick=${onClose}
              aria-label="닫기"
            >
              ✕
            </button>
          </div>
        </div>
        <div class="chat-preview-modal-body min-h-0 flex-1 overflow-auto">${children}</div>
        ${footer && html`
          <div class="chat-preview-modal-footer mt-3 flex flex-wrap items-center justify-between gap-2 border-t border-[var(--line-1)] pt-2 text-xs text-[var(--fg-2)]">
            ${footer}
          </div>
        `}
      </div>
    </div>
  `, document.body)
}
