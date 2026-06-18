import { html } from 'htm/preact'
import { useCallback, useEffect, useRef, useState } from 'preact/hooks'
import { AtSign, Braces, Megaphone, Mic, Paperclip, Send, Square, UserRound, X } from 'lucide-preact'
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
  ensureStateBlockDraft,
  stateBlockKeys,
  STATE_BLOCK_TEMPLATE,
} from '../ops/ops-state'
import {
  keeperNameFromTarget,
  replaceTrailingMentionDraft,
} from '../../lib/mention-utils'
import { useOperatorMentionContext } from '../common/use-operator-mention-context'

export type ComposerV2Mode = 'broadcast' | 'dm' | 'state-block'

interface ComposerV2Target {
  workspace_id?: string
  keeper_id?: string
}

interface StructuredStateBlock {
  kind: 'state-block'
  raw: string
  keys: string[]
}

export interface ComposerAttachmentDraft {
  id: string
  kind: 'image' | 'file'
  name: string
  size: string
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
    body: string | StructuredStateBlock
    attachments?: unknown[]
  }
}

const MODE_OPTIONS: Array<{ value: ComposerV2Mode; label: string; description: string }> = [
  { value: 'broadcast', label: 'Broadcast', description: 'Workspace broadcast' },
  { value: 'dm', label: 'DM', description: 'Keeper DM' },
  { value: 'state-block', label: 'State', description: 'State block' },
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
  const composeBody = input.mode === 'state-block'
    ? { kind: 'state-block' as const, raw: body, keys: stateBlockKeys(body) }
    : body
  return {
    compose: {
      mode: input.mode,
      target: Object.keys(target).length > 0 ? target : undefined,
      body: composeBody,
      attachments: input.attachments ?? [],
    },
  }
}

export function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

export function formatClock(seconds: number): string {
  const whole = Math.max(0, Math.round(seconds))
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`
}

export function createComposerVoiceDraft(): ComposerVoiceDraft {
  return {
    secs: 12,
    size: formatFileSize(12 * 3400),
    wave: [0.35, 0.72, 0.48, 0.9, 0.42, 0.66, 0.58, 0.8, 0.5, 0.7, 0.38, 0.62],
    transcript: '스케줄러 p99 스파이크와 compact 타이밍을 비교해서 결과만 알려줘.',
  }
}

export function serializeComposerBody(input: {
  text: string
  attachments: ComposerAttachmentDraft[]
  voice: ComposerVoiceDraft | null
}): string {
  const blocks: string[] = []
  if (input.attachments.length > 0) {
    blocks.push([
      'Attachments:',
      ...input.attachments.map(attachment => {
        const meta = [attachment.size, attachment.kind, attachment.dims].filter(Boolean).join(' · ')
        return `- ${attachment.name}${meta ? ` (${meta})` : ''}`
      }),
    ].join('\n'))
  }
  if (input.voice) {
    blocks.push([
      `Voice memo ${formatClock(input.voice.secs)} (${input.voice.size})`,
      input.voice.transcript,
    ].join('\n'))
  }
  const text = input.text.trim()
  if (text) blocks.push(text)
  return blocks.join('\n\n')
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
  const [voiceDraft, setVoiceDraft] = useState<ComposerVoiceDraft | null>(null)
  const [recording, setRecording] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const workspace = normalizeWorkspaceId(workspaceId)
  const busy = submitting || operatorActionBusy.value
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
  const stateKeys = mode === 'state-block' ? stateBlockKeys(draft) : []
  const hasDraftContent = draft.trim() !== '' || attachments.length > 0 || voiceDraft !== null
  const attachmentLabel = `${attachments.length} file${attachments.length === 1 ? '' : 's'}`
  const sendDisabled = busy
    || !hasDraftContent
    || (mode === 'dm' && (!effectiveKeeperOnline || unresolvedTrailingMention))
    || (mode === 'state-block' && stateKeys.length === 0)

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
    if (nextMode === 'state-block') {
      setDraft(current => ensureStateBlockDraft(current))
    }
  }

  function chooseMentionTarget(keeperName: string): void {
    setKeeperTarget(`keeper:${keeperName}`)
    setDraft(current => replaceTrailingMentionDraft(current, keeperName))
  }

  function attachFiles(files: FileList | File[]): void {
    const nextFiles = Array.from(files).slice(0, 6)
    if (nextFiles.length === 0) return
    setAttachments(current => [
      ...current,
      ...nextFiles.map((file, index): ComposerAttachmentDraft => ({
        id: `${Date.now()}-${index}-${file.name}`,
        kind: file.type.startsWith('image/') ? 'image' : 'file',
        name: file.name,
        size: formatFileSize(file.size),
      })),
    ].slice(0, 6))
  }

  function stopVoiceDraft(): void {
    setRecording(false)
    setVoiceDraft(createComposerVoiceDraft())
  }

  function resetDraft(): void {
    setDraft('')
    setAttachments([])
    setVoiceDraft(null)
    setRecording(false)
  }

  async function submit(): Promise<void> {
    const message = serializeComposerBody({ text: draft, attachments, voice: voiceDraft })
    if (!message || sendDisabled) return
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
          payload: { message: composeBodyText(request.compose.body) },
        })
      } else {
        await sendBroadcast(currentDashboardActor(), composeBodyText(request.compose.body))
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
          ${draft.length} chars · ${attachmentLabel}${voiceDraft ? ' · voice' : ''} · ${onlineKeepers.length} keeper targets
        </span>
      </div>

      <div class="mt-3 grid gap-2">
        ${attachments.length > 0 || voiceDraft
          ? html`
              <div class="composer-tray" data-testid="composer-v2-tray">
                ${attachments.map(attachment => html`
                  <div class="cdraft att" key=${attachment.id}>
                    <div class="cdraft-thumb">
                      <span class="cdraft-glyph">${attachment.kind === 'image' ? '▧' : '◫'}</span>
                    </div>
                    <div class="cdraft-meta">
                      <span class="cdraft-name mono">${attachment.name}</span>
                      <span class="cdraft-sub mono">${[attachment.size, attachment.kind, attachment.dims].filter(Boolean).join(' · ')}</span>
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
                ${voiceDraft
                  ? html`
                      <div class="cdraft voice">
                        <span class="cdraft-glyph mic">◌</span>
                        <div class="cdraft-wave" aria-hidden="true">
                          ${voiceDraft.wave.map((height, index) => html`<span class="vbar" key=${index} style=${{ height: `${Math.round(4 + height * 18)}px` }} />`)}
                        </div>
                        <span class="cdraft-dur mono">${formatClock(voiceDraft.secs)}</span>
                        <div class="cdraft-tx">
                          <span class="cdraft-tx-k">받아쓰기</span>
                          <span class="cdraft-tx-v">${voiceDraft.transcript}</span>
                        </div>
                        <button
                          type="button"
                          class="cdraft-x"
                          title="음성 제거"
                          aria-label="Remove voice draft"
                          onClick=${() => { setVoiceDraft(null) }}
                          disabled=${busy}
                        >
                          <${X} size=${10} aria-hidden="true" />
                        </button>
                      </div>
                    `
                  : null}
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

        ${recording
          ? html`
              <div class="rec-bar" data-testid="composer-v2-recorder">
                <span class="rec-dot" aria-hidden="true"></span>
                <span class="rec-lbl">녹음 중</span>
                <span class="rec-clock mono">0:12</span>
                <div class="rec-wave" aria-hidden="true">
                  ${[0.4, 0.8, 0.5, 0.9, 0.45, 0.75, 0.52, 0.84, 0.48, 0.7].map((height, index) => html`<span class="rbar" key=${index} style=${{ height: `${Math.round(3 + height * 20)}px` }} />`)}
                </div>
                <button type="button" class="rec-btn cancel" onClick=${() => { setRecording(false) }} disabled=${busy}>취소</button>
                <button type="button" class="rec-btn stop" onClick=${stopVoiceDraft} disabled=${busy}>
                  <${Square} size=${11} aria-hidden="true" />
                  완료
                </button>
              </div>
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
              aria-label="Start voice draft"
              onClick=${() => { setRecording(true) }}
              disabled=${busy || recording}
              data-testid="composer-v2-voice"
            >
              <${Mic} size=${15} aria-hidden="true" />
            </button>
          </div>
          <span class="text-2xs text-[var(--color-fg-muted)]">⌘ ↵ 전송 · 파일/음성 포함</span>
        </div>

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
