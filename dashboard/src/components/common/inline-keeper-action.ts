// InlineKeeperAction — send a keeper message directly from any card without navigating to the ops page.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { ActionButton } from './button'
import { showToast } from './toast'
import { dispatchOperatorAction } from '../../operator-actions'
import { actorName } from '../ops/ops-state'

interface InlineKeeperActionProps {
  keeperName: string
  disabled?: boolean
}

const expandedKeeper = signal<string | null>(null)
const messageText = signal('')
const sending = signal(false)

export function InlineKeeperAction({ keeperName, disabled }: InlineKeeperActionProps) {
  const isExpanded = expandedKeeper.value === keeperName
  const isBusy = sending.value || disabled

  const toggle = (e: Event) => {
    e.stopPropagation()
    if (isExpanded) {
      expandedKeeper.value = null
      messageText.value = ''
    } else {
      expandedKeeper.value = keeperName
      messageText.value = ''
    }
  }

  const send = async (e: Event) => {
    e.stopPropagation()
    const text = messageText.value.trim()
    if (!text) return
    sending.value = true
    try {
      const actor = actorName.value.trim() || 'dashboard'
      await dispatchOperatorAction({
        actor,
        action_type: 'keeper_message',
        target_type: 'keeper',
        target_id: keeperName,
        payload: { message: text },
      })
      showToast(`${keeperName}에게 메시지 전송 완료`, 'success')
      expandedKeeper.value = null
      messageText.value = ''
    } catch (err) {
      const msg = err instanceof Error ? err.message : '메시지 전송 실패'
      showToast(msg, 'error')
    } finally {
      sending.value = false
    }
  }

  if (!isExpanded) {
    return html`
      <${ActionButton} variant="ghost" size="lg" onClick=${toggle} disabled=${isBusy}>
        메시지
      <//>
    `
  }

  return html`
    <div class="flex flex-col gap-2 w-full" onClick=${(e: Event) => e.stopPropagation()}>
      <textarea
        class="w-full rounded-lg border border-[var(--white-8)] bg-[var(--white-3)] text-[13px] text-[var(--text-body)] px-3 py-2 outline-none focus:border-[var(--accent)] transition-colors resize-y min-h-[56px]"
        rows=${2}
        placeholder="${keeperName}에게 보낼 메시지"
        value=${messageText.value}
        onInput=${(e: Event) => { messageText.value = (e.target as HTMLTextAreaElement).value }}
        onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) void send(e) }}
        disabled=${isBusy}
      ></textarea>
      <div class="flex gap-2">
        <${ActionButton} variant="primary" size="lg" onClick=${send} disabled=${isBusy || messageText.value.trim() === ''}>
          ${sending.value ? '전송 중...' : '보내기'}
        <//>
        <${ActionButton} variant="ghost" size="lg" onClick=${toggle} disabled=${sending.value}>
          취소
        <//>
      </div>
    </div>
  `
}
