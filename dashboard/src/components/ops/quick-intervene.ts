// QuickIntervene — unified message input. Pick a target, type, send.
// Target selection determines action_type automatically:
//   'namespace' → broadcast, 'session:{id}' → team_note, 'keeper:{name}' → keeper_message

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { CARD_STANDARD } from '../common/card'
import { ActionButton } from '../common/button'
import { TextInput } from '../common/input'
import { Select } from '../common/select'
import {
  operatorActionBusy,
  operatorSnapshot,
} from '../../operator-store'
import { actorName, persistActorName, quickTarget, quickMessage } from './ops-state'
import { executeAction, normalizeStatus } from './helpers'

function parseTarget(value: string): {
  action_type: 'broadcast' | 'keeper_message'
  target_type: 'root' | 'keeper'
  target_id?: string
  label: string
} {
  if (value.startsWith('keeper:')) {
    const name = value.slice('keeper:'.length)
    return { action_type: 'keeper_message', target_type: 'keeper', target_id: name, label: name }
  }
  return { action_type: 'broadcast', target_type: 'root', label: '전체' }
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
  const [showAdvanced, setShowAdvanced] = useState(false)
  const snapshot = operatorSnapshot.value
  const keepers = snapshot?.keepers ?? []
  const busy = operatorActionBusy.value

  const onlineKeepers = keepers.filter(k => normalizeStatus(k.status) !== 'offline')

  return html`
    <section class="${CARD_STANDARD} flex flex-col gap-3" aria-label="빠른 개입">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="text-sm font-semibold text-[var(--color-fg-secondary)]">빠른 개입</h3>
          <p class="mt-1 text-xs leading-[1.45] text-[var(--color-fg-muted)]">메시지나 메모를 방 또는 키퍼에 바로 보냅니다.</p>
        </div>
        <${ActionButton}
          variant="subtle"
          size="sm"
          onClick=${() => { setShowAdvanced(current => !current) }}
          disabled=${busy}
        >
          ${showAdvanced ? '고급 닫기' : '고급 설정'}
        <//>
      </div>

      <div class="flex gap-2 items-stretch flex-wrap">
        <${Select}
          class="shrink-0 px-3 py-2 text-sm min-w-30"
          value=${quickTarget.value}
          ariaLabel="개입 대상"
          options=${[
            { value: 'namespace', label: '전체' },
            ...onlineKeepers.map(k => ({ value: `keeper:${k.name}`, label: k.name })),
          ]}
          onInput=${(v: string) => { quickTarget.value = v }}
          disabled=${busy}
        />
        <${TextInput}
          class="min-w-50 flex-1 border-[var(--white-8)] bg-[var(--white-3)]"
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
      </div>

      ${showAdvanced
        ? html`
            <div class="rounded border border-[var(--white-8)] bg-[var(--white-2)] p-3">
              <label class="block text-2xs font-medium uppercase tracking-1 text-[var(--color-fg-muted)]" for="quick-intervene-actor">
                기록 주체
              </label>
              <p class="mt-1 text-xs leading-[1.45] text-[var(--color-fg-muted)]">개입과 승인 요청은 이 이름으로 기록됩니다.</p>
              <${TextInput}
                class="mt-3 max-w-65 border-[var(--white-8)] bg-[var(--white-3)]"
                value=${actorName.value.trim() || 'dashboard'}
                name="quick_intervene_actor"
                ariaLabel="개입 기록 주체"
                autoComplete="off"
                onInput=${(event: Event) => { persistActorName((event.target as HTMLInputElement).value) }}
                disabled=${busy}
              />
            </div>
          `
        : null}
    </section>
  `
}
