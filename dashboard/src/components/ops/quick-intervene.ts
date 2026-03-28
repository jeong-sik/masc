// QuickIntervene — unified message input. Pick a target, type, send.
// Target selection determines action_type automatically:
//   'room' → broadcast, 'session:{id}' → team_note, 'keeper:{name}' → keeper_message

import { html } from 'htm/preact'
import { CARD_STANDARD } from '../common/card'
import { ActionButton } from '../common/button'
import { TextInput } from '../common/input'
import {
  operatorActionBusy,
  operatorSnapshot,
} from '../../operator-store'
import { quickTarget, quickMessage } from './ops-state'
import { executeAction, normalizeStatus, submitPause, submitResume } from './helpers'

function parseTarget(value: string): {
  action_type: 'broadcast' | 'team_note' | 'keeper_message'
  target_type: 'room' | 'team_session' | 'keeper'
  target_id?: string
  label: string
} {
  if (value.startsWith('session:')) {
    const id = value.slice('session:'.length)
    return { action_type: 'team_note', target_type: 'team_session', target_id: id, label: id }
  }
  if (value.startsWith('keeper:')) {
    const name = value.slice('keeper:'.length)
    return { action_type: 'keeper_message', target_type: 'keeper', target_id: name, label: name }
  }
  return { action_type: 'broadcast', target_type: 'room', label: '전체' }
}

async function submitQuickMessage() {
  const message = quickMessage.value.trim()
  if (!message) return
  const target = parseTarget(quickTarget.value)
  const result = await executeAction({
    action_type: target.action_type,
    target_type: target.target_type,
    target_id: target.target_id,
    payload: { message },
    successMessage: `${target.label}에 메시지를 보냈습니다`,
  })
  if (result) quickMessage.value = ''
}

export function QuickIntervene() {
  const snapshot = operatorSnapshot.value
  const sessions = snapshot?.sessions ?? []
  const keepers = snapshot?.keepers ?? []
  const room = snapshot?.room ?? {}
  const busy = operatorActionBusy.value

  const runningSessions = sessions.filter(s => { const st = normalizeStatus(s.status); return st === 'running' || st === 'active' })
  const onlineKeepers = keepers.filter(k => normalizeStatus(k.status) !== 'offline')

  return html`
    <section class="${CARD_STANDARD} flex flex-col gap-3">
      <div class="flex gap-2 items-stretch flex-wrap">
        <select
          class="shrink-0 rounded-lg border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2 text-[13px] text-[var(--text-body)] transition-colors cursor-pointer min-w-[120px] focus-visible:outline-none focus-visible:border-[rgba(71,184,255,0.5)] focus-visible:ring-1 focus-visible:ring-[rgba(71,184,255,0.35)]"
          value=${quickTarget.value}
          aria-label="개입 대상"
          onChange=${(e: Event) => { quickTarget.value = (e.target as HTMLSelectElement).value }}
          disabled=${busy}
        >
          <option value="room">전체</option>
          ${runningSessions.map(s => html`
            <option key=${s.session_id} value=${`session:${s.session_id}`}>
              세션 ${s.session_id.slice(0, 8)}
            </option>
          `)}
          ${onlineKeepers.map(k => html`
            <option key=${k.name} value=${`keeper:${k.name}`}>
              ${k.name}
            </option>
          `)}
        </select>
        <${TextInput}
          class="min-w-[200px] flex-1 border-[var(--white-8)] bg-[var(--white-3)]"
          placeholder="메시지"
          value=${quickMessage.value}
          name="quick_intervene_message"
          ariaLabel="빠른 개입 메시지"
          autoComplete="off"
          onInput=${(e: Event) => { quickMessage.value = (e.target as HTMLInputElement).value }}
          onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') void submitQuickMessage() }}
          disabled=${busy}
        />
        <${ActionButton} variant="primary" size="lg" onClick=${() => { void submitQuickMessage() }} disabled=${busy || quickMessage.value.trim() === ''}>
          보내기
        <//>
        <div class="flex gap-1 ml-auto">
          ${room.paused
            ? html`<${ActionButton} variant="ghost" size="lg" onClick=${() => { void submitResume() }} disabled=${busy}>재개<//>`
            : html`<${ActionButton} variant="ghost" size="lg" onClick=${() => { void submitPause() }} disabled=${busy}>일시정지<//>`
          }
        </div>
      </div>
    </section>
  `
}
