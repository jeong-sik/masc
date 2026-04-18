import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { AlertTriangle, AlertCircle, Info } from 'lucide-preact'

type ConfirmTone = 'danger' | 'warning' | 'info'

interface ConfirmState {
  isOpen: boolean
  title: string
  message: string
  confirmText: string
  cancelText: string
  tone: ConfirmTone
  onConfirm: () => void
  onCancel: () => void
}

const confirmState = signal<ConfirmState>({
  isOpen: false,
  title: '',
  message: '',
  confirmText: '확인',
  cancelText: '취소',
  tone: 'warning',
  onConfirm: () => {},
  onCancel: () => {}
})

export function requestConfirm({
  title,
  message,
  confirmText = '확인',
  cancelText = '취소',
  tone = 'warning'
}: {
  title: string
  message: string
  confirmText?: string
  cancelText?: string
  tone?: ConfirmTone
}): Promise<boolean> {
  return new Promise((resolve) => {
    confirmState.value = {
      isOpen: true,
      title,
      message,
      confirmText,
      cancelText,
      tone,
      onConfirm: () => {
        confirmState.value = { ...confirmState.value, isOpen: false }
        resolve(true)
      },
      onCancel: () => {
        confirmState.value = { ...confirmState.value, isOpen: false }
        resolve(false)
      }
    }
  })
}

export function ConfirmDialogOverlay() {
  const state = confirmState.value
  if (!state.isOpen) return null

  const handleClose = () => state.onCancel()
  
  // Prevent clicks inside the modal from bubbling to the overlay backdrop
  const stopPropagation = (e: Event) => e.stopPropagation()

  let iconColor = 'text-warn'
  let iconBg = 'bg-warn/10 border-warn/20'
  let confirmBtnClass = 'bg-[var(--warn)] text-[var(--bg-0)] hover:bg-[var(--warn)]/90'
  let IconComponent = AlertTriangle

  if (state.tone === 'danger') {
    iconColor = 'text-bad'
    iconBg = 'bg-bad/10 border-bad/20'
    confirmBtnClass = 'bg-[var(--bad)] text-white hover:bg-[var(--bad)]/90'
    IconComponent = AlertCircle
  } else if (state.tone === 'info') {
    iconColor = 'text-accent'
    iconBg = 'bg-[var(--accent-10)] border-accent/20'
    confirmBtnClass = 'bg-[var(--accent)] text-[var(--bg-0)] hover:bg-[var(--accent)]/90'
    IconComponent = Info
  }

  return html`
    <div class="fixed inset-0 z-[100] bg-[var(--white-5)]/60 backdrop-blur-sm isolate flex items-center justify-center p-4 animate-in fade-in duration-200" onClick=${handleClose}>
      <div class="w-full max-w-[400px] bg-[rgba(13,21,38,0.98)] rounded-md border border-[var(--card-border)] shadow-[0_24px_64px_rgba(0,0,0,0.6)] overflow-hidden" onClick=${stopPropagation} role="dialog" aria-modal="true" aria-labelledby="confirm-dialog-title">
        <div class="p-5">
          <div class="flex items-start gap-4">
            <div class="shrink-0 size-10 rounded-sm border flex items-center justify-center ${iconBg} ${iconColor}">
              <${IconComponent} size=${20} />
            </div>
            <div class="flex-1 min-w-0 pt-0.5">
              <h2 id="confirm-dialog-title" class="text-[16px] font-semibold text-text-strong mb-1 leading-snug">${state.title}</h2>
              <p class="text-[13px] text-text-body leading-relaxed opacity-90 whitespace-pre-wrap">${state.message}</p>
            </div>
          </div>
          <div class="mt-6 flex items-center justify-end gap-2">
            <button type="button"
              class="px-4 py-2 rounded text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] text-text-body hover:bg-[var(--white-8)] transition-colors cursor-pointer"
              onClick=${state.onCancel}
            >${state.cancelText}</button>
            <button type="button"
              class="px-4 py-2 rounded text-[13px] font-medium border border-transparent transition-colors cursor-pointer ${confirmBtnClass}"
              onClick=${state.onConfirm}
            >${state.confirmText}</button>
          </div>
        </div>
      </div>
    </div>
  `
}