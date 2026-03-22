// Toast notification system — signal-based, auto-dismiss
// Usage: showToast('Success message', 'success')
//        showToast('Warning', 'warning')
//        showToast('Error occurred', 'error')

import { html } from 'htm/preact'
import { signal } from '@preact/signals'

type ToastType = 'success' | 'warning' | 'error'

interface Toast {
  id: number
  message: string
  type: ToastType
}

let _nextId = 0
const toasts = signal<Toast[]>([])

const BORDER_COLOR: Record<ToastType, string> = {
  success: 'border-l-[var(--ok)]',
  warning: 'border-l-[var(--warn)]',
  error: 'border-l-[var(--bad)]',
}

const ICON: Record<ToastType, string> = {
  success: '✓',
  warning: '⚠',
  error: '✕',
}

const ICON_COLOR: Record<ToastType, string> = {
  success: 'text-[var(--ok)]',
  warning: 'text-[var(--warn)]',
  error: 'text-[var(--bad)]',
}

export function showToast(message: string, type: ToastType = 'success', durationMs = 4000): void {
  const id = ++_nextId
  toasts.value = [...toasts.value, { id, message, type }]
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
    <div class="fixed top-5 right-5 z-[var(--z-overlay-toast,3070)] flex flex-col gap-2.5">
      ${items.map(t => html`
        <div
          key=${t.id}
          class="flex items-center gap-2.5 py-2.5 px-3.5 min-w-[240px] max-w-[380px] rounded-lg border-l-[3px] border-l-solid border border-solid border-[var(--card-border)] bg-[rgba(10,18,34,0.95)] shadow-[0_8px_24px_rgba(0,0,0,0.35),0_2px_8px_rgba(0,0,0,0.2)] backdrop-blur-sm cursor-pointer transition-opacity duration-200 hover:opacity-90 animate-[slideInRight_0.25s_ease-out] ${BORDER_COLOR[t.type]}"
          onClick=${() => dismissToast(t.id)}
        >
          <span class="text-sm shrink-0 ${ICON_COLOR[t.type]}">${ICON[t.type]}</span>
          <span class="text-[12px] text-[var(--text-body)] leading-[1.4]">${t.message}</span>
        </div>
      `)}
    </div>
  `
}
