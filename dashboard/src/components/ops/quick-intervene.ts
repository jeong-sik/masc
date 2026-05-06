// QuickIntervene: operational composer for broadcast, keeper DM, and state blocks.

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
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

interface OnlineKeeper {
  name: string
  status?: string
}

interface MentionCandidate {
  name: string
  status?: string
  selected: boolean
}

const MODE_OPTIONS: Array<{ value: QuickComposerMode, label: string, description: string }> = [
  { value: 'broadcast', label: 'Broadcast', description: 'All keepers' },
  { value: 'dm', label: 'DM', description: 'One keeper' },
  { value: 'state', label: 'State', description: 'Structured' },
]

const MENTION_LISTBOX_ID = 'quick-intervene-mention-listbox'

function keeperNameFromTarget(value: string): string | null {
  if (!value.startsWith('keeper:')) return null
  const name = value.slice('keeper:'.length).trim()
  return name || null
}

function mentionQueryFromMessage(message: string): string | null {
  const match = message.match(/(?:^|\s)@([A-Za-z0-9_.-]*)$/)
  return match?.[1] ?? null
}

function trailingMentionNameFromMessage(message: string): string | null {
  const match = message.match(/(?:^|\s)@([A-Za-z0-9_.-]+)\s*$/)
  return match?.[1] ?? null
}

function onlineKeeperNameForMention(onlineKeepers: OnlineKeeper[], mentionName: string | null): string | null {
  if (!mentionName) return null
  const normalized = mentionName.toLowerCase()
  return onlineKeepers.find(keeper => keeper.name.toLowerCase() === normalized)?.name ?? null
}

function mentionCandidates(onlineKeepers: OnlineKeeper[], query: string | null, selectedKeeper: string | null): MentionCandidate[] {
  const normalizedQuery = query?.toLowerCase() ?? ''
  return onlineKeepers
    .filter(keeper => normalizedQuery === '' || keeper.name.toLowerCase().includes(normalizedQuery))
    .map(keeper => ({
      name: keeper.name,
      status: keeper.status,
      selected: keeper.name === selectedKeeper,
    }))
    .sort((a, b) => Number(b.selected) - Number(a.selected) || a.name.localeCompare(b.name))
    .slice(0, 5)
}

function replaceTrailingMentionDraft(message: string, keeperName: string): string {
  if (/(?:^|\s)@[A-Za-z0-9_.-]*$/.test(message)) {
    return message.replace(/(^|\s)@[A-Za-z0-9_.-]*$/, `$1@${keeperName} `)
  }
  const spacer = message.trimEnd().length > 0 ? ' ' : ''
  return `${message.trimEnd()}${spacer}@${keeperName} `
}

function chooseMentionTarget(keeperName: string): void {
  quickTarget.value = `keeper:${keeperName}`
  quickMessage.value = replaceTrailingMentionDraft(quickMessage.value, keeperName)
}

function selectComposerMode(mode: QuickComposerMode, onlineKeepers: OnlineKeeper[]): void {
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

function parseComposerTarget(mode: QuickComposerMode, onlineKeepers: OnlineKeeper[]): ComposerTarget | null {
  if (mode === 'dm') {
    const typedMention = trailingMentionNameFromMessage(quickMessage.value)
    const typedMentionTarget = onlineKeeperNameForMention(onlineKeepers, typedMention)
    if (typedMention && !typedMentionTarget) return null
    const name = typedMentionTarget ?? keeperNameFromTarget(quickTarget.value)
    return name
      ? { action_type: 'keeper_message', target_type: 'keeper', target_id: name, label: name }
      : null
  }
  return { action_type: 'broadcast', target_type: 'root', label: mode === 'state' ? 'State block' : 'All' }
}

async function submitQuickMessage(onlineKeepers: OnlineKeeper[]) {
  const message = quickMessage.value.trim()
  if (!message) return
  const mode = quickComposerMode.value
  const submitStateKeys = mode === 'state' ? stateBlockKeys(message) : []
  if (mode === 'state' && submitStateKeys.length === 0) return
  const target = parseComposerTarget(mode, onlineKeepers)
  if (!target) return

  const result = await executeAction({
    action_type: target.action_type,
    target_type: target.target_type,
    target_id: target.target_id,
    payload: { message },
    successMessage: `Message sent to ${target.label}`,
  })
  if (result) {
    if (target.target_type === 'keeper' && target.target_id) {
      quickTarget.value = `keeper:${target.target_id}`
    }
    quickMessage.value = ''
  }
}

export function QuickIntervene() {
  const [showAdvanced, setShowAdvanced] = useState(false)
  const [activeMentionIndex, setActiveMentionIndex] = useState(0)
  const [dismissedMentionQuery, setDismissedMentionQuery] = useState<string | null>(null)
  const appliedRouteFocus = useRef<string | null>(null)
  const snapshot = operatorSnapshot.value
  const keepers = snapshot?.keepers ?? []
  const busy = operatorActionBusy.value
  const currentRoute = route.value

  const onlineKeepers = keepers.filter(k => normalizeStatus(k.status) !== 'offline')
  const onlineKeeperNames = onlineKeepers.map(keeper => keeper.name).join('\0')
  const mode = quickComposerMode.value
  const stateKeys = mode === 'state' ? stateBlockKeys(quickMessage.value) : []
  const selectedKeeper = keeperNameFromTarget(quickTarget.value)
  const selectedKeeperOnline = !!selectedKeeper && onlineKeepers.some(k => k.name === selectedKeeper)
  const mentionQuery = mode === 'dm' ? mentionQueryFromMessage(quickMessage.value) : null
  const trailingMention = mode === 'dm' ? trailingMentionNameFromMessage(quickMessage.value) : null
  const trailingMentionTarget = mode === 'dm' ? onlineKeeperNameForMention(onlineKeepers, trailingMention) : null
  const unresolvedTrailingMention = mode === 'dm' && !!trailingMention && !trailingMentionTarget
  const effectiveKeeper = trailingMentionTarget ?? selectedKeeper
  const effectiveKeeperOnline = !!trailingMentionTarget || selectedKeeperOnline
  const mentionMatches = mode === 'dm' ? mentionCandidates(onlineKeepers, mentionQuery, effectiveKeeper) : []
  const mentionListOpen = mentionQuery !== null && dismissedMentionQuery !== mentionQuery
  const activeMention = mentionListOpen ? mentionMatches[activeMentionIndex] ?? mentionMatches[0] : null
  const activeMentionOptionId = activeMention
    ? `${MENTION_LISTBOX_ID}-option-${Math.max(mentionMatches.indexOf(activeMention), 0)}`
    : undefined
  const sendDisabled = busy
    || quickMessage.value.trim() === ''
    || (mode === 'dm' && (!effectiveKeeperOnline || unresolvedTrailingMention))
    || (mode === 'state' && stateKeys.length === 0)

  useEffect(() => {
    setActiveMentionIndex(0)
    setDismissedMentionQuery(null)
  }, [mentionQuery, onlineKeeperNames])

  useEffect(() => {
    const focus = currentRoute.params.focus ?? null
    const nextMode = composerModeForFocus(focus)
    if (!nextMode) {
      appliedRouteFocus.current = focus
      return
    }
    const focusChanged = focus !== appliedRouteFocus.current
    const needsLoadedDmTarget = nextMode === 'dm'
      && mode === 'dm'
      && onlineKeepers.length > 0
      && !selectedKeeperOnline
    if (!focusChanged && !needsLoadedDmTarget) return
    appliedRouteFocus.current = focus
    if (nextMode) selectComposerMode(nextMode, onlineKeepers)
  }, [currentRoute.params.focus, mode, onlineKeeperNames, selectedKeeperOnline])

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
              ${mentionListOpen
                ? html`
                    <div
                      id=${MENTION_LISTBOX_ID}
                      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
                      role="listbox"
                      aria-label=${`Mention autocomplete (${mentionMatches.length} matches)`}
                    >
                      <div class="border-b border-[var(--color-border-default)] px-2 py-1 text-2xs font-medium uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
                        Match @${mentionQuery}
                      </div>
                      ${mentionMatches.length > 0
                        ? mentionMatches.map((candidate, index) => html`
                            <button
                              id=${`${MENTION_LISTBOX_ID}-option-${index}`}
                              type="button"
                              class="flex w-full items-center gap-2 border-0 border-l-2 border-solid ${candidate.selected || index === activeMentionIndex ? 'border-l-[var(--color-accent-fg)] bg-[var(--color-bg-elevated)]' : 'border-l-transparent bg-transparent'} px-2 py-1.5 text-left text-xs text-[var(--color-fg-secondary)] hover:bg-[var(--button-ghost-bg-hover)]"
                              role="option"
                              aria-selected=${candidate.selected || index === activeMentionIndex ? 'true' : 'false'}
                              onClick=${() => { chooseMentionTarget(candidate.name) }}
                              disabled=${busy}
                            >
                              <span class="font-mono text-[var(--color-accent-fg)]">@${candidate.name}</span>
                              <span class="ml-auto text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${candidate.status ?? 'online'}</span>
                            </button>
                          `)
                        : html`<div class="px-2 py-2 text-xs text-[var(--color-fg-muted)]">No online keeper matches @${mentionQuery}</div>`}
                    </div>
                  `
                  : effectiveKeeperOnline
                  ? html`
                      <div class="flex flex-wrap items-center gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-1 text-2xs text-[var(--color-fg-muted)]" aria-label=${`Will mention: @${effectiveKeeper}`}>
                        <span>Will mention:</span>
                        <button
                          type="button"
                          class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5 font-mono text-[var(--color-accent-fg)]"
                          onClick=${() => { if (effectiveKeeper) chooseMentionTarget(effectiveKeeper) }}
                          disabled=${busy}
                        >
                          @${effectiveKeeper}
                        </button>
                        <span class="ml-auto text-[var(--color-fg-muted)]">type @ to filter targets</span>
                      </div>
                    `
                  : null}
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
          role=${mode === 'dm' ? 'combobox' : undefined}
          ariaAutocomplete=${mode === 'dm' ? 'list' : undefined}
          ariaControls=${mentionListOpen ? MENTION_LISTBOX_ID : undefined}
          ariaExpanded=${mode === 'dm' ? String(mentionListOpen) : undefined}
          ariaActiveDescendant=${activeMentionOptionId}
          ariaLabel=${mode === 'state' ? 'Structured state block message' : 'Quick intervention message'}
          onInput=${(e: Event) => {
            if (dismissedMentionQuery !== null) setDismissedMentionQuery(null)
            quickMessage.value = (e.target as HTMLTextAreaElement).value
          }}
          onKeyDown=${(e: KeyboardEvent) => {
            if (mode === 'dm' && mentionListOpen && mentionMatches.length > 0) {
              if (e.key === 'ArrowDown') {
                e.preventDefault()
                setActiveMentionIndex(index => (index + 1) % mentionMatches.length)
                return
              }
              if (e.key === 'ArrowUp') {
                e.preventDefault()
                setActiveMentionIndex(index => (index - 1 + mentionMatches.length) % mentionMatches.length)
                return
              }
              if (e.key === 'Enter' && !(e.metaKey || e.ctrlKey || e.shiftKey || e.altKey)) {
                e.preventDefault()
                chooseMentionTarget(mentionMatches[activeMentionIndex]?.name ?? mentionMatches[0]!.name)
                return
              }
            }
            if (mode === 'dm' && mentionListOpen && e.key === 'Escape') {
              e.preventDefault()
              setDismissedMentionQuery(mentionQuery ?? '')
              return
            }
            const shouldSubmit = e.key === 'Enter'
              && ((e.metaKey || e.ctrlKey) || (mode !== 'state' && !e.shiftKey && !e.altKey))
            if (!shouldSubmit) return
            e.preventDefault()
            void submitQuickMessage(onlineKeepers)
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
          <${ActionButton} variant="primary" size="lg" onClick=${() => { void submitQuickMessage(onlineKeepers) }} disabled=${sendDisabled}>
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
