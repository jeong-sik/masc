// AlertDialog — ARIA alertdialog primitive
// Kimi sec06 6.1.1: alertdialog는 인터럽트가 불가능한 중요 정보를 전달.
// ConfirmDialog와 다르게 backdrop 클릭으로 닫히지 않으며, 반드시
// 하나 이상의 포커스 가능한 컨트롤을 포함해야 한다.
//
// Usage:
//   <${AlertDialog}
//     open=${true}
//     title="인증 실패"
//     onClose=${handleClose}
//   >
//     <p>API 키가 유효하지 않습니다.</p>
//     <${ActionButton} onClick=${handleClose}>확인<//>
//   <//>

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useEffect, useRef, useState } from 'preact/hooks'

interface AlertDialogProps {
  open: boolean
  title: string
  description?: string
  onClose: () => void
  /** When true, ESC closes the dialog. Default false for critical alerts. */
  allowEsc?: boolean
  children: ComponentChildren
}

export function AlertDialog({
  open,
  title,
  description,
  onClose,
  allowEsc = false,
  children,
}: AlertDialogProps) {
  const panelRef = useRef<HTMLDivElement>(null)
  const previouslyFocused = useRef<HTMLElement | null>(null)

  // closed→open transition
  const [state, setState] = useState<'closed' | 'open'>('closed')
  useEffect(() => {
    if (!open) {
      setState('closed')
      return
    }
    const id = requestAnimationFrame(() => setState('open'))
    return () => cancelAnimationFrame(id)
  }, [open])

  // Focus trap + restore
  useEffect(() => {
    if (!open) {
      previouslyFocused.current?.focus()
      return
    }
    previouslyFocused.current = document.activeElement as HTMLElement

    const panel = panelRef.current
    if (!panel) return

    // Move focus to first focusable element inside panel
    const focusable = panel.querySelector<HTMLElement>(
      'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])',
    )
    focusable?.focus()

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Tab') {
        const elements = Array.from(
          panel.querySelectorAll<HTMLElement>(
            'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])',
          ),
        ).filter((el) => !el.hasAttribute('disabled'))
        if (elements.length === 0) return
        const first = elements[0]
        const last = elements[elements.length - 1]
        if (!first || !last) return
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault()
          last.focus()
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault()
          first.focus()
        }
      }
      if (allowEsc && event.key === 'Escape') {
        event.preventDefault()
        onClose()
      }
    }

    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [open, allowEsc, onClose])

  if (!open && state === 'closed') return null

  return html`
    <div
      class=${
        'fixed inset-0 z-[100] flex items-center justify-center p-4 ' +
        'transition-opacity duration-[var(--enter-duration)] ease-[var(--enter-easing)] ' +
        'data-[state=closed]:opacity-0 data-[state=open]:opacity-100'
      }
      data-state=${state}
    >
      <div class="absolute inset-0 bg-black/50" />
      <div
        ref=${panelRef}
        class=${
          'relative w-full max-w-100 bg-[var(--dialog-panel-bg)] rounded-[var(--r-2)] ' +
          'border border-[var(--dialog-panel-border)] ' +
          'shadow-[var(--shadow-raised)] overflow-hidden ' +
          'transition-[opacity,transform] duration-[var(--enter-duration)] ease-[var(--enter-easing)] ' +
          'data-[state=closed]:opacity-0 data-[state=closed]:scale-95 ' +
          'data-[state=open]:opacity-100 data-[state=open]:scale-100'
        }
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="alert-dialog-title"
        aria-describedby=${description ? 'alert-dialog-desc' : undefined}
        data-state=${state}
        tabIndex=${-1}
      >
        <div class="p-5">
          <h2
            id="alert-dialog-title"
            class="text-lg font-semibold text-text-strong mb-1 leading-snug"
          >
            ${title}
          </h2>
          ${description
            ? html`<p
                id="alert-dialog-desc"
                class="text-sm text-text-body leading-relaxed opacity-90"
              >
                ${description}
              </p>`
            : null}
          <div class="mt-6 flex items-center justify-end gap-2">
            ${children}
          </div>
        </div>
      </div>
    </div>
  `
}
