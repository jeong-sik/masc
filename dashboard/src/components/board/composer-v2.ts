import { html } from 'htm/preact'
import { useCallback, useEffect, useRef, useState } from 'preact/hooks'
import { AtSign, Megaphone, Mic, Paperclip, Send, Square, UserRound, X } from 'lucide-preact'
import { currentDashboardActor, sendBroadcast } from '../../api'
import { keepers as dashboardKeepers, refreshExecution } from '../../store'
import {
  dispatchOperatorAction,
  operatorActionBusy,
} from '../../operator-store'
import { showToast } from '../common/toast'
import { ActionButton } from '../common/button'
import { Select } from '../common/select'
import { TextArea } from '../common/input'
import {
  keeperNameFromTarget,
  replaceTrailingMentionDraft,
} from '../../lib/mention-utils'
import { useOperatorMentionContext } from '../common/use-operator-mention-context'
import { stableAttachmentId } from '../chat/attachments'
import { useVoiceInput } from '../chat/voice-input'

export type ComposerV2Mode = 'broadcast' | 'dm'

interface ComposerV2Target {
  workspace_id?: string
  keeper_id?: string
}

export interface ComposerAttachmentDraft {
  id: string
  kind: 'image' | 'file'
  name: string
  size: string
  sizeBytes?: number | null
  mime?: string | null
  dims?: string | null
}

export interface ComposerVoiceDraft {
  secs: number
  size: string
  wave: number[]
  transcript: string
}

export interface ComposerV2Request {
  compose: {
    mode: ComposerV2Mode
    target?: ComposerV2Target
    body: string
    attachments?: unknown[]
  }
}

const MODE_OPTIONS: Array<{ value: ComposerV2Mode; label: string; description: string }> = [
  { value: 'broadcast', label: 'Broadcast', description: 'Workspace broadcast' },
  { value: 'dm', label: 'DM', description: 'Keeper DM' },
]

const MENTION_LISTBOX_ID = 'composer-v2-mention-listbox'

function normalizeWorkspaceId(workspaceId: string | null | undefined): string {
  const normalized = workspaceId?.trim().replace(/^#+/, '')
  return normalized || 'default'
}

function modeIcon(mode: ComposerV2Mode) {
  switch (mode) {
    case 'dm':
      return UserRound
    case 'broadcast':
    default:
      return Megaphone
  }
}

export function composerAttachmentTrayMeta(attachment: ComposerAttachmentDraft): string {
  return [attachment.size, attachment.mime, attachment.kind, attachment.dims].filter(Boolean).join(' · ')
}

function plural(count: number, singular: string, pluralLabel: string): string {
  return `${count} ${count === 1 ? singular : pluralLabel}`
}

export function composerAttachmentTransportUnavailable(attachments: ComposerAttachmentDraft[]): boolean {
  return attachments.length > 0
}

export function composerAttachmentDeliveryReason(attachments: ComposerAttachmentDraft[]): string | null {
  return composerAttachmentTransportUnavailable(attachments) ? 'attachment transport unavailable' : null
}

export function uniqueComposerAttachmentId(
  baseId: string,
  existing: ComposerAttachmentDraft[],
  pending: ComposerAttachmentDraft[],
): string {
  const used = new Set([...existing, ...pending].map(attachment => attachment.id))
  if (!used.has(baseId)) return baseId

  let suffix = 2
  while (used.has(`${baseId}-${suffix}`)) suffix += 1
  return `${baseId}-${suffix}`
}

export function buildComposerV2Request(input: {
  mode: ComposerV2Mode
  workspaceId: string
  body: string
  keeperId?: string | null
  attachments?: ComposerAttachmentDraft[]
}): ComposerV2Request {
  const body = input.body.trim()
  const target: ComposerV2Target = {}
  if (input.mode === 'dm') {
    if (input.keeperId) target.keeper_id = input.keeperId
  } else {
    target.workspace_id = normalizeWorkspaceId(input.workspaceId)
  }
  return {
    compose: {
      mode: input.mode,
      target: Object.keys(target).length > 0 ? target : undefined,
      body,
      attachments: input.attachments ?? [],
    },
  }
}

export function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}


export function appendVoiceTranscriptDraft(current: string, transcript: string): string {
  const text = transcript.trim()
  if (!text) return current
  const body = current.trim()
  return body ? `${body}\n\n${text}` : text
}

export function serializeComposerBody(input: {
  text: string
  attachments: ComposerAttachmentDraft[]
  voice: ComposerVoiceDraft | null
}): string {
  if (input.attachments.length > 0) {
    throw new Error('Composer attachments require block transport and must not be serialized into text body')
  }
  if (input.voice) {
    // G02 (multimodal parity) — voice must travel as a block, not be folded into
    // the text body. Chat and board share the ComposerBlocks transport; the text
    // path must refuse voice rather than silently serializing its transcript and
    // dropping the audio metadata. All current callers pass voice: null, so this
    // removes the dead serialization branch.
    throw new Error('Composer voice requires block transport and must not be serialized into text body')
  }
  return input.text.trim()
}

interface ComposerV2Props {
  workspaceId?: string | null
  mode?: ComposerV2Mode
  onModeChange?: (mode: ComposerV2Mode) => void
  showModeSelector?: boolean
  modeLabels?: Partial<Record<ComposerV2Mode, string>>
}

export function ComposerV2({
  workspaceId,
  mode: controlledMode,
  onModeChange,
  showModeSelector = true,
  modeLabels = {},
}: ComposerV2Props) {
  const [internalMode, setInternalMode] = useState<ComposerV2Mode>(controlledMode ?? 'broadcast')
  const mode = controlledMode ?? internalMode
  const setMode = useCallback((next: ComposerV2Mode) => {
    if (controlledMode === undefined) {
      setInternalMode(next)
    }
    onModeChange?.(next)
  }, [controlledMode, onModeChange])
  const [draft, setDraft] = useState('')
  const [keeperTarget, setKeeperTarget] = useState('')
  const [attachments, setAttachments] = useState<ComposerAttachmentDraft[]>([])
  const [submitting, setSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const workspace = normalizeWorkspaceId(workspaceId)
  const busy = submitting || operatorActionBusy.value
  const voice = useVoiceInput({
    onTranscribed: (text) => {
      setDraft(current => appendVoiceTranscriptDraft(current, text))
      showToast('Voice transcribed.', 'success')
    },
    onError: (message) => {
      showToast(message, 'error')
    },
  })
  const mention = useOperatorMentionContext({
    message: draft,
    target: keeperTarget,
    dmActive: mode === 'dm',
    listboxId: MENTION_LISTBOX_ID,
    fallbackKeepers: dashboardKeepers.value,
  })
  const {
    onlineKeepers,
    onlineKeeperNames,
    selectedKeeperOnline,
    mentionQuery,
    trailingMentionTarget,
    unresolvedTrailingMention,
    effectiveKeeper,
    effectiveKeeperOnline,
    mentionMatches,
    mentionListOpen,
    activeMentionOptionId,
    activeMentionIndex,
    setActiveMentionIndex,
    dismissedMentionQuery,
    setDismissedMentionQuery,
  } = mention
  const attachmentDeliveryReason = composerAttachmentDeliveryReason(attachments)
  const hasDraftContent = draft.trim() !== '' || attachments.length > 0
  const sendDisabled = busy
    || voice.state !== 'idle'
    || !hasDraftContent
    || attachmentDeliveryReason !== null
    || (mode === 'dm' && (!effectiveKeeperOnline || unresolvedTrailingMention))
  const targetLabel = mode === 'dm'
    ? effectiveKeeper
      ? `@${effectiveKeeper}`
      : 'keeper target required'
    : `#${workspace}`
  const mediaLabel = [
    attachments.length > 0 ? plural(attachments.length, 'file', 'files') : 'no files',
    voice.state !== 'idle' ? voice.state : null,
  ].filter(Boolean).join(' · ')
  const deliveryState = busy
    ? 'sending'
    : voice.state !== 'idle' || sendDisabled
      ? 'blocked'
      : 'ready'
  const deliveryReason = busy
    ? 'transport busy'
    : voice.state === 'recording'
      ? 'recording voice'
      : voice.state === 'transcribing'
        ? 'transcribing voice'
        : !hasDraftContent
          ? 'draft empty'
          : attachmentDeliveryReason
            ? attachmentDeliveryReason
            : mode === 'dm' && unresolvedTrailingMention
              ? 'resolve mention'
              : mode === 'dm' && !effectiveKeeperOnline
                ? 'keeper unavailable'
                : mode === 'dm'
                  ? 'keeper message'
                  : 'workspace broadcast'
  const deliveryToneClass = deliveryState === 'ready'
    ? 'border-[var(--color-status-ok)] text-[var(--color-status-ok)]'
    : deliveryState === 'sending'
      ? 'border-[var(--color-accent-fg)] text-[var(--color-accent-fg)]'
      : 'border-[var(--color-status-warn)] text-[var(--color-status-warn)]'

  useEffect(() => {
    if (mode !== 'dm') return
    if (selectedKeeperOnline) return
    const firstKeeper = onlineKeepers[0]?.name
    setKeeperTarget(firstKeeper ? `keeper:${firstKeeper}` : '')
  }, [mode, onlineKeeperNames, selectedKeeperOnline])

  useEffect(() => {
    if (mode !== 'dm') return
    if (onlineKeepers.length > 0) return
    void refreshExecution()
  }, [mode, onlineKeepers.length])

  function chooseMode(nextMode: ComposerV2Mode): void {
    setMode(nextMode)
    setSubmitError(null)
  }

  function chooseMentionTarget(keeperName: string): void {
    setKeeperTarget(`keeper:${keeperName}`)
    setDraft(current => replaceTrailingMentionDraft(current, keeperName))
  }

  function attachFiles(files: FileList | File[]): void {
    const nextFiles = Array.from(files).slice(0, 6)
    if (nextFiles.length === 0) return
    setAttachments(current => {
      const pending: ComposerAttachmentDraft[] = []
      for (const file of nextFiles) {
        const kind = file.type.startsWith('image/') ? 'image' : 'file'
        const baseId = stableAttachmentId({
          name: file.name,
          type: kind,
          mimeType: file.type || null,
          size: file.size,
        })
        pending.push({
          id: uniqueComposerAttachmentId(baseId, current, pending),
          kind,
          name: file.name,
          size: formatFileSize(file.size),
          sizeBytes: file.size,
          mime: file.type || null,
        })
      }
      return [...current, ...pending].slice(0, 6)
    })
  }

  function resetDraft(): void {
    setDraft('')
    setAttachments([])
  }

  async function submit(): Promise<void> {
    if (sendDisabled) return
    const message = serializeComposerBody({ text: draft, attachments: [], voice: null })
    if (!message) return
    const keeperId = mode === 'dm'
      ? trailingMentionTarget ?? keeperNameFromTarget(keeperTarget)
      : null
    const request = buildComposerV2Request({
      mode,
      workspaceId: workspace,
      body: message,
      keeperId,
      attachments,
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
          payload: { message: request.compose.body },
        })
      } else {
        await sendBroadcast(currentDashboardActor(), request.compose.body)
      }
      if (keeperId) setKeeperTarget(`keeper:${keeperId}`)
      resetDraft()
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
    <section class="v2-workspace-panel rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] p-3" aria-label="Composer v2">
      <div class="flex flex-wrap items-center gap-2">
        ${showModeSelector ? html`
          <div class="inline-flex rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-0.5" role="group" aria-label="Composer v2 mode">
            ${MODE_OPTIONS.map(option => {
              const selected = mode === option.value
              const Icon = modeIcon(option.value)
              const label = modeLabels[option.value] ?? option.label
              return html`
                <${ActionButton}
                  variant="ghost"
                  size="sm"
                  pressed=${selected}
                  ariaLabel=${`${label} mode`}
                  title=${option.description}
                  onClick=${() => { chooseMode(option.value) }}
                  disabled=${busy}
                  class="inline-flex items-center gap-1.5"
                >
                  <${Icon} size=${13} aria-hidden="true" />
                  ${label}
                <//>
              `
            })}
          </div>
        ` : null}
        <span class="inline-flex items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-1 text-2xs font-medium text-[var(--color-fg-muted)]" aria-label=${`Target workspace: ${workspace}`}>
          #${workspace}
        </span>
        <span class="ml-auto text-2xs tabular-nums text-[var(--color-fg-muted)]" aria-live="polite">
          ${draft.length} chars · ${mediaLabel} · ${onlineKeepers.length} keeper targets
        </span>
      </div>

      <div class="mt-3 grid gap-2">
        <div class="grid gap-2 sm:grid-cols-4" data-testid="composer-v2-command-rail" aria-label="Composer command envelope">
          <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-2" data-composer-command-group="mode">
            <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">mode</div>
            <div class="mt-1 truncate text-xs font-semibold text-[var(--color-fg-primary)]">${modeLabels[mode] ?? MODE_OPTIONS.find(option => option.value === mode)?.label ?? mode}</div>
          </div>
          <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-2" data-composer-command-group="target">
            <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">target</div>
            <div class="mt-1 break-words font-mono text-xs leading-snug text-[var(--color-fg-secondary)]" title=${targetLabel}>${targetLabel}</div>
          </div>
          <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-2" data-composer-command-group="media">
            <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">media</div>
            <div class="mt-1 truncate text-xs text-[var(--color-fg-secondary)]" title=${mediaLabel}>${mediaLabel}</div>
          </div>
          <div class=${`rounded-[var(--r-1)] border bg-[var(--color-bg-surface)] px-2.5 py-2 ${deliveryToneClass}`} data-composer-command-group="delivery">
            <div class="text-3xs uppercase tracking-[var(--track-caps)] opacity-70">delivery</div>
            <div class="mt-1 flex min-w-0 items-center gap-2">
              <span class="h-1.5 w-1.5 shrink-0 rounded-[var(--r-0)] bg-current"></span>
              <span class="break-words text-xs font-semibold leading-snug" title=${deliveryReason}>${deliveryState} · ${deliveryReason}</span>
            </div>
          </div>
        </div>

        ${attachments.length > 0
          ? html`
              <div class="composer-tray" data-testid="composer-v2-tray">
                ${attachments.map(attachment => html`
                  <div class="cdraft att" key=${attachment.id}>
                    <div class="cdraft-thumb">
                      <span class="cdraft-glyph">${attachment.kind === 'image' ? '▧' : '◫'}</span>
                    </div>
                    <div class="cdraft-meta">
                      <span class="cdraft-name mono">${attachment.name}</span>
                      <span class="cdraft-sub mono">${composerAttachmentTrayMeta(attachment)} · transport unavailable</span>
                    </div>
                    <button
                      type="button"
                      class="cdraft-x"
                      title="첨부 제거"
                      aria-label=${`Remove attachment ${attachment.name}`}
                      onClick=${() => { setAttachments(current => current.filter(item => item.id !== attachment.id)) }}
                      disabled=${busy}
                    >
                      <${X} size=${10} aria-hidden="true" />
                    </button>
                  </div>
                `)}
              </div>
            `
          : null}

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
                      class="v2-workspace-panel rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
                      role="listbox"
                      aria-label=${`Mention autocomplete (${mentionMatches.length} matches)`}
                    >
                      ${mentionMatches.length > 0
                        ? mentionMatches.map((candidate, index) => html`
                            <button
                              id=${`${MENTION_LISTBOX_ID}-option-${index}`}
                              type="button"
                              class="v2-workspace-action flex w-full items-center gap-2 border-0 border-l-2 border-solid ${candidate.selected || index === activeMentionIndex ? 'border-l-[var(--color-accent-fg)] bg-[var(--color-bg-elevated)]' : 'border-l-transparent bg-transparent'} px-2 py-1.5 text-left text-xs text-[var(--color-fg-secondary)] hover:bg-[var(--button-ghost-bg-hover)]"
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
                        : html`<div class="px-2 py-2 text-xs text-[var(--color-fg-muted)]">No keeper target matches @${mentionQuery}</div>`}
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

        ${voice.state !== 'idle'
          ? html`
              <div class="rec-bar" data-testid="composer-v2-recorder">
                <span class="rec-dot" aria-hidden="true"></span>
                <span class="rec-lbl">${voice.state === 'recording' ? '녹음 중' : '전사 중'}</span>
                <div class="rec-wave" aria-hidden="true">
                  ${[0.4, 0.8, 0.5, 0.9, 0.45, 0.75, 0.52, 0.84, 0.48, 0.7].map((height, index) => html`<span class="rbar" key=${index} style=${{ height: `${Math.round(3 + height * 20)}px` }} />`)}
                </div>
                <button type="button" class="rec-btn stop" onClick=${voice.stop} disabled=${busy || voice.state !== 'recording'}>
                  <${Square} size=${11} aria-hidden="true" />
                  완료
                </button>
              </div>
            `
          : null}

        <${TextArea}
          class="min-h-24 border-[var(--color-border-default)] bg-[var(--color-bg-surface)] font-mono text-xs leading-[1.55]"
          rows=${4}
          placeholder="Message"
          value=${draft}
          name="composer_v2_body"
          role=${mode === 'dm' ? 'combobox' : undefined}
          ariaAutocomplete=${mode === 'dm' ? 'list' : undefined}
          ariaControls=${mentionListOpen ? MENTION_LISTBOX_ID : undefined}
          ariaExpanded=${mode === 'dm' ? String(mentionListOpen) : undefined}
          ariaActiveDescendant=${activeMentionOptionId}
          ariaLabel="Composer v2 message"
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
              && ((event.metaKey || event.ctrlKey) || (!event.shiftKey && !event.altKey))
            if (!shouldSubmit) return
            event.preventDefault()
            void submit()
          }}
          disabled=${busy}
        />

        <div class="flex flex-wrap items-center justify-between gap-2">
          <div class="composer-tools" aria-label="Composer v2 multimodal tools">
            <input
              ref=${fileInputRef}
              type="file"
              accept="image/*,.pdf,.txt,.log,.json,.csv,.md"
              multiple
              hidden
              data-testid="composer-v2-file-input"
              onChange=${(event: Event) => {
                const input = event.target as HTMLInputElement
                if (input.files) attachFiles(input.files)
                input.value = ''
              }}
            />
            <button
              type="button"
              class="ctool"
              title="이미지·파일 첨부"
              aria-label="Attach file"
              onClick=${() => { fileInputRef.current?.click() }}
              disabled=${busy || attachments.length >= 6}
              data-testid="composer-v2-attach"
            >
              <${Paperclip} size=${15} aria-hidden="true" />
            </button>
            <button
              type="button"
              class="ctool"
              title="음성 입력"
              aria-label="Start voice input"
              onClick=${() => { void voice.start() }}
              disabled=${busy || voice.state !== 'idle' || !voice.supported}
              data-testid="composer-v2-voice"
            >
              <${Mic} size=${15} aria-hidden="true" />
            </button>
          </div>
          <span class="text-2xs text-[var(--color-fg-muted)]">⌘ ↵ 전송 · 파일/음성 포함</span>
        </div>

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
