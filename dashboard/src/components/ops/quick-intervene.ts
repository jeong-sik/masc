// QuickIntervene: operational composer for broadcast, keeper DM, and state blocks.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { CARD_STANDARD } from '../common/card'
import { ActionButton } from '../common/button'
import { TextArea, TextInput } from '../common/input'
import { Select } from '../common/select'
import {
  operatorActionBusy,
  operatorSnapshot,
} from '../../operator-store'
import { route } from '../../router'
import {
  actorName,
  composerModeForFocus,
  ensureStateBlockDraft,
  hasStateBlock,
  persistActorName,
  quickComposerMode,
  quickTarget,
  quickMessage,
  stateBlockKeys,
  STATE_BLOCK_TEMPLATE,
  type QuickComposerMode,
} from './ops-state'
import { executeAction, normalizeStatus } from './helpers'

interface ComposerTarget {
  action_type: 'broadcast' | 'keeper_message'
  target_type: 'root' | 'keeper'
  target_id?: string
  label: string
}

const MODE_OPTIONS: Array<{ value: QuickComposerMode, label: string, description: string }> = [
  { value: 'broadcast', label: 'Broadcast', description: 'All keepers' },
  { value: 'dm', label: 'DM', description: 'One keeper' },
  { value: 'state', label: 'State', description: 'Structured' },
]

function keeperNameFromTarget(value: string): string | null {
  if (!value.startsWith('keeper:')) return null
  const name = value.slice('keeper:'.length).trim()
  return name || null
}

function selectComposerMode(mode: QuickComposerMode, onlineKeepers: Array<{ name: string }>): void {
  quickComposerMode.value = mode
  if (mode === 'dm') {
    const selected = keeperNameFromTarget(quickTarget.value)
    const selectedOnline = selected && onlineKeepers.some(k => k.name === selected)
    if (!selectedOnline) {
      const firstKeeper = onlineKeepers[0]?.name
      quickTarget.value = firstKeeper ? `keeper:${firstKeeper}` : ''
    }
    return
  }

  quickTarget.value = 'namespace'
  if (mode === 'state') quickMessage.value = ensureStateBlockDraft(quickMessage.value)
}

function parseComposerTarget(mode: QuickComposerMode): ComposerTarget | null {
  if (mode === 'dm') {
    const name = keeperNameFromTarget(quickTarget.value)
    return name
      ? { action_type: 'keeper_message', target_type: 'keeper', target_id: name, label: name }
      : null
  }
  return { action_type: 'broadcast', target_type: 'root', label: mode === 'state' ? 'State block' : 'All' }
}

async function submitQuickMessage() {
  const message = quickMessage.value.trim()
  if (!message) return
  const mode = quickComposerMode.value
  if (mode === 'state' && !hasStateBlock(message)) return
  const target = parseComposerTarget(mode)
  if (!target) return

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
  const currentRoute = route.value

  const onlineKeepers = keepers.filter(k => normalizeStatus(k.status) !== 'offline')
  const onlineKeeperKey = onlineKeepers.map(k => k.name).join('\u0000')
  const mode = quickComposerMode.value
  const stateKeys = mode === 'state' ? stateBlockKeys(quickMessage.value) : []
  const selectedKeeper = keeperNameFromTarget(quickTarget.value)
  const selectedKeeperOnline = !!selectedKeeper && onlineKeepers.some(k => k.name === selectedKeeper)
  const sendDisabled = busy
    || quickMessage.value.trim() === ''
    || (mode === 'dm' && !selectedKeeperOnline)
    || (mode === 'state' && !hasStateBlock(quickMessage.value))

  useEffect(() => {
    const nextMode = composerModeForFocus(currentRoute.params.focus)
    if (nextMode) selectComposerMode(nextMode, onlineKeepers)
  }, [currentRoute, onlineKeeperKey])

  return html`
    <section class="${CARD_STANDARD} flex flex-col gap-3" aria-label="Quick intervention">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="text-sm font-semibold text-[var(--color-fg-secondary)]">Quick Intervention</h3>
          <p class="mt-1 text-xs leading-[1.45] text-[var(--color-fg-muted)]">Send a broadcast, keeper DM, or structured state block.</p>
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

      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="inline-flex rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-0.5" role="group" aria-label="Composer mode">
          ${MODE_OPTIONS.map(option => {
            const selected = mode === option.value
            return html`
              <${ActionButton}
                variant="ghost"
                size="sm"
                pressed=${selected}
                ariaLabel=${`${option.label} mode`}
                title=${option.description}
                onClick=${() => { selectComposerMode(option.value, onlineKeepers) }}
                disabled=${busy}
              >
                ${option.label}
              <//>
            `
          })}
        </div>
        <div class="text-2xs text-[var(--color-fg-muted)]" aria-live="polite">
          ${quickMessage.value.length} chars / ${onlineKeepers.length} keepers online
        </div>
      </div>

      <div class="flex flex-col gap-2">
        ${mode === 'dm'
          ? html`
              <${Select}
                class="max-w-70"
                value=${selectedKeeperOnline ? quickTarget.value : ''}
                placeholder="Keeper"
                ariaLabel="Keeper message target"
                options=${onlineKeepers.map(k => ({ value: `keeper:${k.name}`, label: k.name }))}
                onInput=${(v: string) => { quickTarget.value = v }}
                disabled=${busy || onlineKeepers.length === 0}
              />
            `
          : html`
              <div class="inline-flex w-fit items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-1 text-2xs text-[var(--color-fg-muted)]">
                Target: ${mode === 'state' ? 'Namespace state stream' : 'All keepers'}
              </div>
            `}

        <${TextArea}
          class="min-h-26 border-[var(--color-border-default)] bg-[var(--color-bg-surface)] font-mono text-xs leading-[1.55]"
          rows=${mode === 'state' ? 6 : 4}
          placeholder=${mode === 'state' ? STATE_BLOCK_TEMPLATE : 'Message'}
          value=${quickMessage.value}
          name="quick_intervene_message"
          ariaLabel=${mode === 'state' ? 'Structured state block message' : 'Quick intervention message'}
          onInput=${(e: Event) => { quickMessage.value = (e.target as HTMLTextAreaElement).value }}
          onKeyDown=${(e: KeyboardEvent) => {
            if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') void submitQuickMessage()
          }}
          disabled=${busy}
        />

        ${mode === 'state'
          ? html`
              <div class="flex flex-wrap items-center gap-2" aria-live="polite">
                ${stateKeys.length > 0
                  ? stateKeys.map(key => html`
                      <span class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5 text-2xs font-medium text-[var(--color-fg-secondary)]">${key}</span>
                    `)
                  : html`<span class="text-2xs text-[var(--color-status-warn)]">State block required</span>`}
                <${ActionButton}
                  variant="subtle"
                  size="sm"
                  onClick=${() => { quickMessage.value = ensureStateBlockDraft(quickMessage.value) }}
                  disabled=${busy}
                >
                  Insert state block
                <//>
              </div>
            `
          : null}

        <div class="flex justify-end">
          <${ActionButton} variant="primary" size="lg" onClick=${() => { void submitQuickMessage() }} disabled=${sendDisabled}>
            Send
          <//>
        </div>
      </div>

      ${showAdvanced
        ? html`
            <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
              <label class="block text-2xs font-medium uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]" for="quick-intervene-actor">
                Actor
              </label>
              <p class="mt-1 text-xs leading-[1.45] text-[var(--color-fg-muted)]">Interventions and approval requests are recorded with this name.</p>
              <${TextInput}
                class="mt-3 max-w-65 border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
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
