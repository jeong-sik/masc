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
  return { action_type: 'broadcast', target_type: 'root', label: 'All' }
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
    successMessage: `Message sent to ${target.label}`,
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
    <section class="${CARD_STANDARD} flex flex-col gap-3" aria-label="Quick intervention">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="text-sm font-semibold text-[var(--color-fg-secondary)]">Quick Intervention</h3>
          <p class="mt-1 text-xs leading-[1.45] text-[var(--color-fg-muted)]">Send a short note to the namespace or a keeper.</p>
        </div>
        <${ActionButton}
          variant="subtle"
          size="sm"
          onClick=${() => { setShowAdvanced(current => !current) }}
          disabled=${busy}
        >
          ${showAdvanced ? 'Close advanced' : 'Advanced'}
        <//>
      </div>

      <div class="flex gap-2 items-stretch flex-wrap">
        <${Select}
          class="shrink-0 px-3 py-2 text-sm min-w-30"
          value=${quickTarget.value}
          ariaLabel="Intervention target"
          options=${[
            { value: 'namespace', label: 'All' },
            ...onlineKeepers.map(k => ({ value: `keeper:${k.name}`, label: k.name })),
          ]}
          onInput=${(v: string) => { quickTarget.value = v }}
          disabled=${busy}
        />
        <${TextInput}
          class="min-w-50 flex-1 border-[var(--white-8)] bg-[var(--white-3)]"
          placeholder="Message"
          value=${quickMessage.value}
          name="quick_intervene_message"
          ariaLabel="Quick intervention message"
          autoComplete="off"
          onInput=${(e: Event) => { quickMessage.value = (e.target as HTMLInputElement).value }}
          onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') void submitQuickMessage() }}
          disabled=${busy}
        />
        <${ActionButton} variant="primary" size="lg" onClick=${() => { void submitQuickMessage() }} disabled=${busy || quickMessage.value.trim() === ''}>
          Send
        <//>
      </div>

      ${showAdvanced
        ? html`
            <div class="rounded border border-[var(--white-8)] bg-[var(--white-2)] p-3">
              <label class="block text-2xs font-medium uppercase tracking-1 text-[var(--color-fg-muted)]" for="quick-intervene-actor">
                Actor
              </label>
              <p class="mt-1 text-xs leading-[1.45] text-[var(--color-fg-muted)]">Interventions and approval requests are recorded with this name.</p>
              <${TextInput}
                class="mt-3 max-w-65 border-[var(--white-8)] bg-[var(--white-3)]"
                value=${actorName.value.trim() || 'dashboard'}
                name="quick_intervene_actor"
                ariaLabel="Intervention actor"
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
