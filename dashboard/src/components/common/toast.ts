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
    <div class="fixed top-5 right-5 z-[var(--z-overlay-toast,3070)] flex flex-col gap-2">
      ${items.map(t => html`
        <div key=${t.id} class="toast ${t.type}" onClick=${() => dismissToast(t.id)}>
          ${t.message}
        </div>
      `)}
    </div>
  `
}
