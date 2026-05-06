import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { AtSign, Braces, Megaphone, Send, UserRound } from 'lucide-preact'
import { currentDashboardActor, sendBroadcast } from '../../api'
import {
  dispatchOperatorAction,
  operatorActionBusy,
  operatorSnapshot,
} from '../../operator-store'
import { showToast } from '../common/toast'
import { ActionButton } from '../common/button'
import { Select } from '../common/select'
import { TextArea } from '../common/input'
import {
  ensureStateBlockDraft,
  stateBlockKeys,
  STATE_BLOCK_TEMPLATE,
} from '../ops/ops-state'

export type ComposerV2Mode = 'broadcast' | 'dm' | 'state-block'

interface ComposerV2Target {
  room_id?: string
  keeper_id?: string
}

interface StructuredStateBlock {
  kind: 'state-block'
  raw: string
  keys: string[]
}

export interface ComposerV2Request {
  compose: {
    mode: ComposerV2Mode
    target?: ComposerV2Target
    body: string | StructuredStateBlock
    attachments?: unknown[]
  }
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

const MODE_OPTIONS: Array<{ value: ComposerV2Mode; label: string; description: string }> = [
  { value: 'broadcast', label: 'Broadcast', description: 'Room broadcast' },
  { value: 'dm', label: 'DM', description: 'Keeper DM' },
  { value: 'state-block', label: 'State', description: 'State block' },
]

const MENTION_LISTBOX_ID = 'composer-v2-mention-listbox'

function normalizeRoomId(roomId: string | null | undefined): string {
  const normalized = roomId?.trim().replace(/^#+/, '')
  return normalized || 'default'
}

function normalizeStatus(value: unknown): string {
  return typeof value === 'string' ? value.trim().toLowerCase() : ''
}

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

function modeIcon(mode: ComposerV2Mode) {
  switch (mode) {
    case 'dm':
      return UserRound
    case 'state-block':
      return Braces
    case 'broadcast':
    default:
      return Megaphone
  }
}

function composeBodyText(body: ComposerV2Request['compose']['body']): string {
  return typeof body === 'string' ? body : body.raw
}

export function buildComposerV2Request(input: {
  mode: ComposerV2Mode
  roomId: string
  body: string
  keeperId?: string | null
}): ComposerV2Request {
  const body = input.body.trim()
  const target: ComposerV2Target = {}
  if (input.mode === 'dm') {
    if (input.keeperId) target.keeper_id = input.keeperId
  } else {
    target.room_id = normalizeRoomId(input.roomId)
  }
  const composeBody = input.mode === 'state-block'
    ? { kind: 'state-block' as const, raw: body, keys: stateBlockKeys(body) }
    : body
  return {
    compose: {
      mode: input.mode,
      target: Object.keys(target).length > 0 ? target : undefined,
      body: composeBody,
      attachments: [],
    },
  }
}

export function ComposerV2({ roomId }: { roomId?: string | null }) {
  const [mode, setMode] = useState<ComposerV2Mode>('broadcast')
  const [draft, setDraft] = useState('')
  const [keeperTarget, setKeeperTarget] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [activeMentionIndex, setActiveMentionIndex] = useState(0)
  const [dismissedMentionQuery, setDismissedMentionQuery] = useState<string | null>(null)
  const room = normalizeRoomId(roomId)
  const snapshot = operatorSnapshot.value
  const busy = submitting || operatorActionBusy.value
  const onlineKeepers = (snapshot?.keepers ?? [])
    .filter(keeper => normalizeStatus(keeper.status) !== 'offline')
    .map(keeper => ({ name: keeper.name, status: keeper.status }))
  const onlineKeeperNames = onlineKeepers.map(keeper => keeper.name).join('\0')
  const selectedKeeper = keeperNameFromTarget(keeperTarget)
  const selectedKeeperOnline = !!selectedKeeper && onlineKeepers.some(k => k.name === selectedKeeper)
  const mentionQuery = mode === 'dm' ? mentionQueryFromMessage(draft) : null
  const trailingMention = mode === 'dm' ? trailingMentionNameFromMessage(draft) : null
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
  const stateKeys = mode === 'state-block' ? stateBlockKeys(draft) : []
  const sendDisabled = busy
    || draft.trim() === ''
    || (mode === 'dm' && (!effectiveKeeperOnline || unresolvedTrailingMention))
    || (mode === 'state-block' && stateKeys.length === 0)

  useEffect(() => {
    setActiveMentionIndex(0)
    setDismissedMentionQuery(null)
  }, [mentionQuery, onlineKeeperNames])

  useEffect(() => {
    if (mode !== 'dm') return
    if (selectedKeeperOnline) return
    const firstKeeper = onlineKeepers[0]?.name
    setKeeperTarget(firstKeeper ? `keeper:${firstKeeper}` : '')
  }, [mode, onlineKeeperNames, selectedKeeperOnline])

  function chooseMode(nextMode: ComposerV2Mode): void {
    setMode(nextMode)
    setSubmitError(null)
    if (nextMode === 'state-block') {
      setDraft(current => ensureStateBlockDraft(current))
    }
  }

  function chooseMentionTarget(keeperName: string): void {
    setKeeperTarget(`keeper:${keeperName}`)
    setDraft(current => replaceTrailingMentionDraft(current, keeperName))
  }

  async function submit(): Promise<void> {
    const message = draft.trim()
    if (!message || sendDisabled) return
    const keeperId = mode === 'dm'
      ? trailingMentionTarget ?? keeperNameFromTarget(keeperTarget)
      : null
    const request = buildComposerV2Request({
      mode,
      roomId: room,
      body: message,
      keeperId,
    })
    setSubmitting(true)
    setSubmitError(null)
    try {
      if (mode === 'dm') {
        if (!keeperId) return
        await dispatchOperatorAction({
          actor: currentDashboardActor(),
          action_type: 'keeper_message',
          target_type: 'keeper',
          target_id: keeperId,
          payload: { message: composeBodyText(request.compose.body) },
        })
      } else {
        await sendBroadcast(currentDashboardActor(), composeBodyText(request.compose.body))
      }
      if (keeperId) setKeeperTarget(`keeper:${keeperId}`)
      setDraft('')
      showToast('Message sent.', 'success')
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Message send failed.'
      setSubmitError(message)
      showToast(message, 'error')
    } finally {
      setSubmitting(false)
    }
  }

  return html`
    <section class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] p-3" aria-label="Composer v2">
      <div class="flex flex-wrap items-center gap-2">
        <div class="inline-flex rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-0.5" role="group" aria-label="Composer v2 mode">
          ${MODE_OPTIONS.map(option => {
            const selected = mode === option.value
            const Icon = modeIcon(option.value)
            return html`
              <${ActionButton}
                variant="ghost"
                size="sm"
                pressed=${selected}
                ariaLabel=${`${option.label} mode`}
                title=${option.description}
                onClick=${() => { chooseMode(option.value) }}
                disabled=${busy}
                class="inline-flex items-center gap-1.5"
              >
                <${Icon} size=${13} aria-hidden="true" />
                ${option.label}
              <//>
            `
          })}
        </div>
        <span class="inline-flex items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-1 text-2xs font-medium text-[var(--color-fg-muted)]" aria-label=${`Target room: ${room}`}>
          #${room}
        </span>
        <span class="ml-auto text-2xs tabular-nums text-[var(--color-fg-muted)]" aria-live="polite">
          ${draft.length} chars · ${onlineKeepers.length} keepers
        </span>
      </div>

      <div class="mt-3 grid gap-2">
        ${mode === 'dm'
          ? html`
              <${Select}
                class="max-w-72"
                value=${selectedKeeperOnline ? keeperTarget : ''}
                placeholder="Keeper"
                ariaLabel="Composer v2 keeper target"
                options=${onlineKeepers.map(k => ({ value: `keeper:${k.name}`, label: k.name }))}
                onInput=${(value: string) => { setKeeperTarget(value) }}
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
                              <${AtSign} size=${12} aria-hidden="true" />
                              <span class="font-mono text-[var(--color-accent-fg)]">${candidate.name}</span>
                              <span class="ml-auto text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${candidate.status ?? 'online'}</span>
                            </button>
                          `)
                        : html`<div class="px-2 py-2 text-xs text-[var(--color-fg-muted)]">No online keeper matches @${mentionQuery}</div>`}
                    </div>
                  `
                : effectiveKeeperOnline
                ? html`
                    <div class="inline-flex w-fit items-center gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-1 text-2xs text-[var(--color-fg-muted)]" aria-label=${`Will mention: @${effectiveKeeper}`}>
                      <${AtSign} size=${12} aria-hidden="true" />
                      <span class="font-mono text-[var(--color-accent-fg)]">${effectiveKeeper}</span>
                    </div>
                  `
                : null}
            `
          : null}

        <${TextArea}
          class="min-h-24 border-[var(--color-border-default)] bg-[var(--color-bg-surface)] font-mono text-xs leading-[1.55]"
          rows=${mode === 'state-block' ? 6 : 4}
          placeholder=${mode === 'state-block' ? STATE_BLOCK_TEMPLATE : 'Message'}
          value=${draft}
          name="composer_v2_body"
          role=${mode === 'dm' ? 'combobox' : undefined}
          ariaAutocomplete=${mode === 'dm' ? 'list' : undefined}
          ariaControls=${mentionListOpen ? MENTION_LISTBOX_ID : undefined}
          ariaExpanded=${mode === 'dm' ? String(mentionListOpen) : undefined}
          ariaActiveDescendant=${activeMentionOptionId}
          ariaLabel=${mode === 'state-block' ? 'Composer v2 state block' : 'Composer v2 message'}
          onInput=${(event: Event) => {
            if (dismissedMentionQuery !== null) setDismissedMentionQuery(null)
            setDraft((event.target as HTMLTextAreaElement).value)
          }}
          onKeyDown=${(event: KeyboardEvent) => {
            if (mode === 'dm' && mentionListOpen && mentionMatches.length > 0) {
              if (event.key === 'ArrowDown') {
                event.preventDefault()
                setActiveMentionIndex(index => (index + 1) % mentionMatches.length)
                return
              }
              if (event.key === 'ArrowUp') {
                event.preventDefault()
                setActiveMentionIndex(index => (index - 1 + mentionMatches.length) % mentionMatches.length)
                return
              }
              if (event.key === 'Enter' && !(event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)) {
                event.preventDefault()
                chooseMentionTarget(mentionMatches[activeMentionIndex]?.name ?? mentionMatches[0]!.name)
                return
              }
            }
            if (mode === 'dm' && mentionListOpen && event.key === 'Escape') {
              event.preventDefault()
              setDismissedMentionQuery(mentionQuery ?? '')
              return
            }
            const shouldSubmit = event.key === 'Enter'
              && ((event.metaKey || event.ctrlKey) || (mode !== 'state-block' && !event.shiftKey && !event.altKey))
            if (!shouldSubmit) return
            event.preventDefault()
            void submit()
          }}
          disabled=${busy}
        />

        ${mode === 'state-block'
          ? html`
              <div class="flex flex-wrap items-center gap-2" aria-live="polite">
                ${stateKeys.length > 0
                  ? stateKeys.map(key => html`
                      <span class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5 text-2xs font-medium text-[var(--color-fg-secondary)]" key=${key}>${key}</span>
                    `)
                  : html`<span class="text-2xs text-[var(--color-status-warn)]">State block required</span>`}
                <${ActionButton}
                  variant="subtle"
                  size="sm"
                  onClick=${() => { setDraft(current => ensureStateBlockDraft(current)) }}
                  disabled=${busy}
                >
                  Insert state block
                <//>
              </div>
            `
          : null}

        ${submitError
          ? html`<div class="text-xs text-[var(--color-status-error)]" role="alert">${submitError}</div>`
          : null}

        <div class="flex justify-end">
          <${ActionButton}
            variant="primary"
            size="lg"
            onClick=${() => { void submit() }}
            disabled=${sendDisabled}
            ariaBusy=${busy}
            class="inline-flex items-center gap-2"
          >
            <${Send} size=${15} aria-hidden="true" />
            Send
          <//>
        </div>
      </div>
    </section>
  `
}
