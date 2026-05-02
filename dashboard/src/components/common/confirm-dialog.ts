import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { AlertTriangle, AlertCircle, Info } from 'lucide-preact'
import { ActionButton } from './button'
import { DialogOverlay } from './dialog'

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

  let iconColor = 'text-warn'
  let iconBg = 'bg-warn/10 border-warn/20'
  let confirmBtnClass = 'bg-[var(--color-status-warn)] text-[var(--color-bg-page)] hover:bg-[var(--color-status-warn)]/90'
  let IconComponent = AlertTriangle

  if (state.tone === 'danger') {
    iconColor = 'text-bad'
    iconBg = 'bg-bad/10 border-bad/20'
    confirmBtnClass = 'bg-[var(--color-status-err)] text-white hover:bg-[var(--color-status-err)]/90'
    IconComponent = AlertCircle
  } else if (state.tone === 'info') {
    iconColor = 'text-accent'
    iconBg = 'bg-[var(--accent-10)] border-accent/20'
    confirmBtnClass = 'bg-[var(--color-accent-fg)] text-[var(--color-bg-page)] hover:bg-[var(--color-accent-fg)]/90'
    IconComponent = Info
  }

  return html`
    <${DialogOverlay}
      labelledBy="confirm-dialog-title"
      onClose=${handleClose}
      overlayClass="fixed inset-0 z-[100] flex items-center justify-center p-4"
      panelClass="w-full max-w-100 bg-[var(--dialog-panel-bg)] rounded-md border border-[var(--dialog-panel-border)] shadow-[var(--shadow-raised)] overflow-hidden"
    >
      <div class="p-5">
        <div class="flex items-start gap-4">
          <div class="shrink-0 size-10 rounded-[var(--r-0)] border flex items-center justify-center ${iconBg} ${iconColor}">
            <${IconComponent} size=${20} />
          </div>
          <div class="flex-1 min-w-0 pt-0.5">
            <h2 id="confirm-dialog-title" class="text-lg font-semibold text-text-strong mb-1 leading-snug">${state.title}</h2>
            <p class="text-sm text-text-body leading-relaxed opacity-90 whitespace-pre-wrap">${state.message}</p>
          </div>
        </div>
        <div class="mt-6 flex items-center justify-end gap-2">
          <${ActionButton}
            variant="ghost"
            size="lg"
            onClick=${state.onCancel}
          >${state.cancelText}<//>
          <button type="button"
            class="px-4 py-2 rounded-[var(--r-1)] text-sm font-medium border border-transparent transition-colors cursor-pointer ${confirmBtnClass}"
            onClick=${state.onConfirm}
          >${state.confirmText}</button>
        </div>
      </div>
    <//>
  `
}
