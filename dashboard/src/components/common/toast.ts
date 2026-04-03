import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import type { ComponentChildren } from 'preact'
import { CheckCircle2, AlertTriangle, XCircle, X } from 'lucide-preact'

export type ToastType = 'success' | 'warning' | 'error'

export interface ToastAction {
  label: string
  onClick: () => void
}

interface Toast {
  id: number
  message: string
  type: ToastType
  action?: ToastAction
}

let _nextId = 0
const toasts = signal<Toast[]>([])

const BORDER_COLOR: Record<ToastType, string> = {
  success: 'border-l-[var(--ok)]',
  warning: 'border-l-[var(--warn)]',
  error: 'border-l-[var(--bad)]'
}

const ICON_COLOR: Record<ToastType, string> = {
  success: 'text-[var(--ok)]',
  warning: 'text-[var(--warn)]',
  error: 'text-[var(--bad)]'
}

const ICON: Record<ToastType, () => ComponentChildren> = {
  success: () => html`<${CheckCircle2} size=${14} />`,
  warning: () => html`<${AlertTriangle} size=${14} />`,
  error: () => html`<${XCircle} size=${14} />`
}

export function showToast(message: string, type: ToastType = 'success', durationMs = 4000) {
  const id = ++_nextId
  toasts.value = [...toasts.value, { id, message, type }]

  setTimeout(() => {
    toasts.value = toasts.value.filter(t => t.id !== id)
  }, durationMs)
}

export function showActionToast(message: string, action: ToastAction, type: ToastType = 'error', durationMs = 12000) {
  const id = ++_nextId
  toasts.value = [...toasts.value, { id, message, type, action }]

  setTimeout(() => {
    toasts.value = toasts.value.filter(t => t.id !== id)
  }, durationMs)
}

function dismissToast(id: number) {
  toasts.value = toasts.value.filter(t => t.id !== id)
}

export function ToastContainer() {
  const items = toasts.value
  if (items.length === 0) return null

  return html`
    <div
      class="fixed top-5 right-5 z-[var(--z-overlay-toast,3070)] flex flex-col gap-2 pointer-events-none"
      aria-live="polite"
      aria-atomic="true"
    >
      ${items.map(t => html`
        <div
          key=${t.id}
          role=${t.type === 'error' ? 'alert' : 'status'}
          class="pointer-events-auto flex items-center gap-2.5 py-2 px-3 min-w-[220px] max-w-[360px] rounded-md border-l-[3px] border-l-solid border border-solid border-[var(--card-border)] bg-[rgba(10,18,34,0.96)] shadow-lg animate-[slideInRight_0.2s_ease-out] ${BORDER_COLOR[t.type]}"
        >
          <span class="shrink-0 flex items-center ${ICON_COLOR[t.type]}">${ICON[t.type]()}</span>
          <span class="flex-1 text-[13px] text-[var(--text-body)] leading-[1.4]">${t.message}</span>
          ${t.action ? html`
            <button
              type="button"
              class="shrink-0 text-[11px] px-2 py-1 rounded border border-[var(--card-border)] bg-[var(--white-5)] text-[var(--accent)] hover:bg-[var(--white-10)] cursor-pointer transition-colors duration-150"
              onClick=${(e: Event) => {
                e.stopPropagation()
                t.action!.onClick()
                dismissToast(t.id)
              }}
            >
              ${t.action.label}
            </button>
          ` : null}
          <button
            type="button"
            class="shrink-0 text-[var(--text-muted)] hover:text-[var(--text-body)] cursor-pointer p-1 rounded hover:bg-[var(--white-5)] transition-colors duration-150 flex items-center justify-center"
            aria-label="닫기"
            title="닫기"
            onClick=${(e: Event) => {
              e.stopPropagation()
              dismissToast(t.id)
            }}
          >
            <${X} size=${14} />
          </button>
        </div>
      `)}
    </div>
  `
}
