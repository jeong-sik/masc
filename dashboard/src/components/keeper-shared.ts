import { html } from 'htm/preact'
import { AgentFailure, failureTypeFromDiagnostic } from './common/agent-failure'
import { Markdown } from "./common/markdown"
import { useEffect, useRef, useState } from 'preact/hooks'
import { keeperDirectChatAccess } from '../lib/keeper-chat-access'
import { relativeTime, NO_TIME_INFO } from '../lib/format-time'
import { isAbortError } from '../lib/async-state'
import type {
  Keeper,
  KeeperConversationAttachment,
  KeeperConversationEntry,
  KeeperDiagnostic,
} from '../types'
import {
  abortKeeperThreadMessage,
  hydrateKeeperStatus,
  hydrateKeeperChatHistory,
  loadFullKeeperHistory,
  keeperActionErrors,
  keeperHydrating,
  keeperProbing,
  keeperRecovering,
  keeperSending,
  keeperStatusDetails,
  keeperStreamStartedAt,
  keeperStreamLastEventAt,
  keeperThreads,
  probeKeeperRuntime,
  recoverKeeperRuntime,
  sendKeeperThreadMessage,
} from '../keeper-runtime'
import { isVisibleDirectConversationEntry } from '../keeper-state'
import {
  enqueueInput,
  dequeueInput,
  markInputSent,
  clearInputQueue,
  getQueueLength,
} from '../keeper-chat-store'
import { ChatComposer, ChatTranscript, STREAM_STALL_THRESHOLD_S } from './chat/primitives'
import { collectAttachments } from './chat/attachments'
import { showToast } from './common/toast'
import { TextInput } from './common/input'
import { shellAuthSummary } from '../store'


const KEEPER_CHAT_METADATA_VISIBLE_KEY = 'masc_keeper_chat_metadata_visible'
const KEEPER_CHAT_INTERNAL_VISIBLE_KEY = 'masc_keeper_chat_internal_visible'

function readKeeperChatMetadataVisible(): boolean {
  try {
    const stored = localStorage.getItem(KEEPER_CHAT_METADATA_VISIBLE_KEY)
    return stored === null ? false : stored === 'true'
  } catch {
    return false
  }
}

function writeKeeperChatMetadataVisible(value: boolean): void {
  try {
    localStorage.setItem(KEEPER_CHAT_METADATA_VISIBLE_KEY, value ? 'true' : 'false')
  } catch {}
}

function readKeeperChatInternalVisible(): boolean {
  try {
    const stored = localStorage.getItem(KEEPER_CHAT_INTERNAL_VISIBLE_KEY)
    return stored === null ? true : stored === 'true'
  } catch {
    return true
  }
}

function writeKeeperChatInternalVisible(value: boolean): void {
  try {
    localStorage.setItem(KEEPER_CHAT_INTERNAL_VISIBLE_KEY, value ? 'true' : 'false')
  } catch {}
}

function GhostButton({
  disabled,
  onClick,
  ariaExpanded,
  class: cx,
  children,
}: {
  disabled?: boolean
  onClick?: () => void
  ariaExpanded?: boolean
  class?: string
  children: unknown
}) {
  return html`
    <button
      type="button"
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-1.5 text-2xs text-[var(--color-fg-muted)] transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] ${cx ?? ''}"
      disabled=${disabled}
      onClick=${onClick}
      aria-expanded=${ariaExpanded}
    >
      ${children}
    </button>
  `
}

function quietReasonLabel(reason?: string | null): string {
  switch (reason) {
    case 'quiet_hours':
      return 'quiet hours'
    case 'min_gap':
      return 'cooldown gate'
    case 'no_recent_activity':
      return 'waiting for activity'
    case 'disabled':
      return 'runtime disabled'
    case 'startup':
      return 'warming up'
    case 'model_error':
      return 'model error'
    case 'graphql_error':
      return 'graphql error'
    case 'never_started':
      return 'never started'
    default:
      return 'unknown'
  }
}

function nextActionLabel(path: string): string {
  switch (path) {
    case 'manual_social_sweep':
      return '대화 동기화'
    case 'probe':
      return 'probe'
    case 'recover':
      return 'recover'
    default:
      return 'message'
  }
}

function continuityStateLabel(state?: KeeperDiagnostic['continuity_state']): string | null {
  switch (state) {
    case 'healthy':
      return 'healthy'
    case 'recovering':
      return 'recovering'
    case 'disabled':
      return 'disabled'
    case 'not_running':
      return 'not running'
    case 'offline':
      return 'offline'
    default:
      return null
  }
}

// Delegated to lib/format-time (SSOT) — returns Korean relative time
function formatTime(timestamp?: string | null): string | null {
  if (!timestamp) return null
  const result = relativeTime(timestamp)
  return result === NO_TIME_INFO ? null : result
}

function formatEligible(seconds?: number | null): string | null {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds <= 0) return null
  if (seconds < 60) return `${Math.round(seconds)}s`
  return `${Math.ceil(seconds / 60)}m`
}

function conversationStateLabel(sending: boolean, hydrating: boolean, stalled: boolean): string {
  if (sending) return stalled ? '응답 지연' : '답변 중...'
  if (hydrating) return '불러오는 중...'
  return '대기 중'
}

function conversationStateClass(sending: boolean, hydrating: boolean, stalled: boolean): string {
  if (sending) {
    return stalled
      ? 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--color-status-warn)]'
      : 'border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--ok-20)]'
  }
  if (hydrating) {
    return 'border-[var(--accent-20)] bg-[var(--accent-10)] text-[var(--color-fg-secondary)]'
  }
  return 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-primary)]'
}

function isActiveAssistantEntry(entry: KeeperConversationEntry): boolean {
  return (
    entry.role === 'assistant'
    && entry.source === 'direct_assistant'
    && (entry.delivery === 'sending' || entry.delivery === 'streaming' || entry.delivery === 'queued')
  )
}

function liveAssistantPlaceholder(keeperName: string): KeeperConversationEntry {
  return {
    id: `live-assistant-placeholder-${keeperName}`,
    role: 'assistant',
    source: 'direct_assistant',
    label: keeperName,
    text: '',
    rawText: '',
    timestamp: null,
    delivery: 'streaming',
    streamState: 'streaming',
    details: null,
    error: null,
  }
}

function effectiveDiagnostic(keeper: Keeper | null | undefined): KeeperDiagnostic | null {
  if (!keeper) return null
  const detail = keeperStatusDetails.value[keeper.name]
  return detail?.diagnostic ?? keeper.diagnostic ?? null
}

/** Case-insensitive substring filter over entry text. Empty or
 *  whitespace-only queries return the input unchanged. Migrated from
 *  the former keeper-chat-panel.ts (filterChatMessages). */
export function filterConversationEntries(
  entries: KeeperConversationEntry[],
  query: string,
): KeeperConversationEntry[] {
  const q = query.trim().toLowerCase()
  if (!q) return entries
  return entries.filter(entry => entry.text.toLowerCase().includes(q))
}

// ── Composer attachments (shared by both panel layouts) ──

function AttachmentChips({
  attachments,
  onRemove,
}: {
  attachments: KeeperConversationAttachment[]
  onRemove: (id: string) => void
}) {
  if (attachments.length === 0) return null
  return html`
    <div class="mb-2 flex flex-wrap gap-2" data-chat-attachment-chips>
      ${attachments.map((att) => html`
        <div class="group relative inline-flex items-center gap-1.5 rounded-lg border border-[var(--color-border-default)] bg-[var(--color-bg-muted)] px-2 py-1 text-2xs" key=${att.id}>
          ${att.type === 'image'
            ? html`<img src=${att.data} class="h-6 w-6 rounded object-cover" alt="" />`
            : html`<span class="text-[var(--color-fg-muted)]">📄</span>`}
          <span class="max-w-32 truncate text-[var(--color-fg-secondary)]">${att.name}</span>
          <button
            type="button"
            class="ml-1 rounded-full p-0.5 text-[var(--color-fg-muted)] hover:bg-[var(--warn-20)] hover:text-[var(--warn-bright)]"
            onClick=${() => onRemove(att.id)}
            title="제거"
          >×</button>
        </div>`)}
    </div>
  `
}

function AttachButton({
  disabled,
  onFiles,
}: {
  disabled: boolean
  onFiles: (files: FileList | null) => void
}) {
  const fileInputRef = useRef<HTMLInputElement | null>(null)
  return html`
    <button
      type="button"
      class="flex-shrink-0 rounded-lg border border-[var(--color-border-default)] px-2.5 py-2 text-sm hover:bg-[var(--color-bg-muted)] disabled:opacity-50"
      onClick=${() => fileInputRef.current?.click()}
      disabled=${disabled}
      title="파일 첨부"
      data-chat-attach-button
    >
      📎
    </button>
    <input
      type="file"
      ref=${fileInputRef}
      class="hidden"
      multiple
      accept="image/png,image/jpeg,image/gif,image/webp,text/plain,text/markdown,application/json,text/csv"
      onChange=${(e: Event) => {
        const target = e.target as HTMLInputElement
        onFiles(target.files)
        target.value = ''
      }}
    />
  `
}

// ── Diagnostic chip ──────────────────────────────────────

function DiagChip({ label }: { label: string }) {
  return html`
    <span class="inline-flex items-center py-0.5 px-2 rounded-[var(--r-0)] text-3xs font-medium bg-[var(--accent-12)] text-[var(--color-accent-fg)] border border-[var(--accent-30)]">${label}</span>
  `
}

// ── Diagnostic Summary ───────────────────────────────────

export function KeeperDiagnosticSummary({
  keeper,
  showRawStatus = false,
}: {
  keeper: Keeper | null | undefined
  showRawStatus?: boolean
}) {
  if (!keeper) {
    return html`<div class="text-xs text-[var(--color-fg-muted)] leading-relaxed py-2">키퍼를 선택하여 직접 응답 상태를 확인하세요.</div>`
  }

  const detail = keeperStatusDetails.value[keeper.name]
  const diagnostic = effectiveDiagnostic(keeper)
  const busy = keeperHydrating.value[keeper.name]
  const refreshStatus = async () => {
    try {
      await hydrateKeeperStatus(keeper.name, true)
    } catch (err) {
      const message = err instanceof Error ? err.message : `${keeper.name} 점검 실패`
      showToast(message, 'error')
    }
  }

  return html`
    <div class="py-3 px-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
      <div class="mb-3 flex items-center justify-between gap-3">
        <div class="text-2xs font-semibold uppercase tracking-4 text-[var(--color-fg-muted)]">명시적 상태 조회</div>
        <${GhostButton} disabled=${busy} onClick=${() => { void refreshStatus() }}>
          ${busy ? '불러오는 중...' : (detail ? '상태 새로고침' : '상태 불러오기')}
        <//>
      </div>
      <div class="flex flex-wrap gap-1.5 mb-2">
        ${continuityStateLabel(diagnostic?.continuity_state)
          ? html`<${DiagChip} label=${continuityStateLabel(diagnostic?.continuity_state)} />`
          : null}
        ${diagnostic?.health_state
          ? html`<${DiagChip} label=${diagnostic.health_state} />`
          : null}
        ${diagnostic?.quiet_reason
          ? html`<${DiagChip} label=${quietReasonLabel(diagnostic.quiet_reason)} />`
          : null}
        ${diagnostic?.next_action_path
          ? html`<${DiagChip} label=${'next: ' + nextActionLabel(diagnostic.next_action_path)} />`
          : null}
        ${busy ? html`<${DiagChip} label="refreshing" />` : null}
      </div>
      ${diagnostic?.continuity_summary || diagnostic?.summary
        ? html`<div class="text-xs text-[var(--color-fg-primary)] leading-relaxed">
            ${diagnostic.continuity_summary ?? diagnostic.summary}
          </div>`
        : null}
      <div class="text-xs text-[var(--color-fg-primary)] leading-relaxed mt-1">
        응답: ${diagnostic?.last_reply_status ?? '미조회'}
        ${diagnostic?.last_reply_at ? html` -- ${formatTime(diagnostic.last_reply_at)}` : null}
        ${diagnostic?.next_eligible_at_s ? html` -- 다음 응답 가능 ${formatEligible(diagnostic.next_eligible_at_s)}` : null}
      </div>
      ${diagnostic?.last_error
        ? html`<${AgentFailure}
            type=${failureTypeFromDiagnostic(diagnostic.last_error, diagnostic.recoverable)}
            message=${diagnostic.last_error}
          />`
        : null}
      ${showRawStatus
        ? html`<div class="mt-3 max-h-60 overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] custom-scrollbar"><${Markdown} text=${'```text\n' + (detail?.rawText ?? '키퍼 상태를 아직 불러오지 않았습니다.') + '\n```'} /></div>`
        : null}
    </div>
  `
}

// ── Conversation Panel ───────────────────────────────────

export function KeeperConversationPanel({
  keeperName,
  placeholder,
  layout = 'default',
}: {
  keeperName: string
  placeholder: string
  layout?: 'default' | 'primary'
}) {
  const [draft, setDraft] = useState('')
  const [showMetadata, setShowMetadata] = useState(readKeeperChatMetadataVisible())
  const [showInternal, setShowInternal] = useState(readKeeperChatInternalVisible())

  const toggleMetadata = () => {
    setShowMetadata(prev => {
      const next = !prev
      writeKeeperChatMetadataVisible(next)
      return next
    })
  }
  const toggleInternal = () => {
    setShowInternal(prev => {
      const next = !prev
      writeKeeperChatInternalVisible(next)
      return next
    })
  }

  const [historyExpanded, setHistoryExpanded] = useState(false)
  const [searchQuery, setSearchQuery] = useState('')
  const [selectedAttachments, setSelectedAttachments] = useState<KeeperConversationAttachment[]>([])
  // Bumped whenever the input queue mutates — the queue lives outside
  // the signal graph (keeper-chat-store), so re-renders must be forced.
  const [, setQueueVersion] = useState(0)
  const bumpQueue = () => setQueueVersion(v => v + 1)

  const addFiles = async (files: FileList | null) => {
    if (!files) return
    const { attachments, errors } = await collectAttachments(files, selectedAttachments)
    errors.forEach(message => showToast(message, 'error'))
    if (attachments.length > 0) {
      setSelectedAttachments(prev => [...prev, ...attachments])
    }
  }
  const removeAttachment = (id: string) => {
    setSelectedAttachments(prev => prev.filter(att => att.id !== id))
  }
  const handlePaste = (event: ClipboardEvent) => {
    const items = event.clipboardData?.items
    if (!items) return
    const imageFiles: File[] = []
    for (const item of Array.from(items)) {
      if (item.type.startsWith('image/')) {
        const file = item.getAsFile()
        if (file) imageFiles.push(file)
      }
    }
    if (imageFiles.length > 0) {
      event.preventDefault()
      const dt = new DataTransfer()
      for (const f of imageFiles) dt.items.add(f)
      void addFiles(dt.files)
    }
  }

  // External-system sync: merge the server-persisted transcript
  // (.masc/keeper_chat/<name>.jsonl) on mount so the conversation
  // survives full page reloads. Once-per-keeper inside the action.
  useEffect(() => {
    void hydrateKeeperChatHistory(keeperName)
  }, [keeperName])

  const rawThread = keeperThreads.value[keeperName] ?? []
  const thread = showInternal ? rawThread : rawThread.filter(isVisibleDirectConversationEntry)
  const hiddenCount = rawThread.length - thread.length
  const sending = keeperSending.value[keeperName] ?? false
  const visibleThread =
    sending && !thread.some(isActiveAssistantEntry)
      ? [...thread, liveAssistantPlaceholder(keeperName)]
      : thread
  const hasQuery = searchQuery.trim().length > 0
  const transcriptEntries = filterConversationEntries(visibleThread, searchQuery)
  const transcriptEmptyText =
    hasQuery && visibleThread.length > 0
      ? '검색어와 일치하는 메시지가 없습니다.'
      : '아직 표시할 대화가 없습니다. 내부 메시지와 도구 호출은 토글로 전환할 수 있습니다.'
  const hydrating = keeperHydrating.value[keeperName] ?? false
  const error = keeperActionErrors.value[keeperName]
  const chatAccess = keeperDirectChatAccess(shellAuthSummary.value)
  const composerDisabled = !keeperName || chatAccess.blocked
  const queueCount = getQueueLength(keeperName)

  // 1 s ticker while a stream is active so the stall badge can compare
  // against wall-clock time. External-system sync (timer), not data init.
  const [, setStallTick] = useState(0)
  useEffect(() => {
    if (!sending) return
    const id = setInterval(() => setStallTick(t => t + 1), 1000)
    return () => clearInterval(id)
  }, [sending, keeperName])

  const streamStartedAt = keeperStreamStartedAt.value[keeperName] ?? null
  // Before the first SSE event arrives, measure the stall from stream
  // start instead so a never-responding stream is also flagged.
  const lastSignalAt = keeperStreamLastEventAt.value[keeperName] ?? streamStartedAt
  const stalled =
    sending && lastSignalAt !== null && Date.now() - lastSignalAt >= STREAM_STALL_THRESHOLD_S * 1000

  const expandHistory = async () => {
    setHistoryExpanded(true)
    await loadFullKeeperHistory(keeperName)
  }

  const drainQueue = async () => {
    for (;;) {
      const next = dequeueInput(keeperName)
      if (!next) break
      bumpQueue()
      try {
        await sendKeeperThreadMessage(keeperName, next.content, { attachments: next.attachments })
      } catch (err) {
        markInputSent(keeperName)
        bumpQueue()
        if (isAbortError(err)) return
        const message = err instanceof Error ? err.message : `${keeperName} 메시지 전송 실패`
        showToast(message, 'error')
        return
      }
      markInputSent(keeperName)
      bumpQueue()
    }
  }

  const submit = async () => {
    const prompt = draft.trim()
    if (chatAccess.blocked) {
      showToast(chatAccess.message, 'error')
      return
    }
    if (!keeperName || !prompt) return
    const attachments = selectedAttachments
    setDraft('')
    setSelectedAttachments([])
    if (keeperSending.value[keeperName]) {
      enqueueInput(keeperName, prompt, attachments.length > 0 ? attachments : undefined)
      bumpQueue()
      return
    }
    try {
      await sendKeeperThreadMessage(keeperName, prompt, { attachments })
    } catch (err) {
      if (isAbortError(err)) return
      const message = err instanceof Error ? err.message : `${keeperName} 메시지 전송 실패`
      showToast(message, 'error')
      return
    }
    await drainQueue()
  }

  const cancelQueue = () => {
    clearInputQueue(keeperName)
    bumpQueue()
  }

  if (layout === 'primary') {
    return html`
      <div
        class="flex h-[clamp(30rem,calc(100svh-13rem),52rem)] min-h-0 flex-col gap-4 overflow-hidden rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4 shadow-none"
        data-keeper-chat-layout="primary"
        onPaste=${handlePaste}
      >
        <div class="shrink-0 flex flex-wrap items-center justify-between gap-3 border-b border-[var(--color-border-default)] pb-3">
          <div class="min-w-0">
            <div class="text-2xs font-semibold uppercase tracking-5 text-[var(--color-fg-muted)]">직접 대화</div>
            <div class="mt-1.5 flex flex-wrap items-center gap-2">
              <div class="text-lg font-semibold text-[var(--color-fg-primary)]">@${keeperName}</div>
              <span class=${`inline-flex items-center rounded-[var(--r-0)] border px-2.5 py-1 text-3xs font-medium uppercase tracking-2 ${conversationStateClass(sending, hydrating, stalled)}`}>
                ${conversationStateLabel(sending, hydrating, stalled)}
              </span>
            </div>
          </div>
          <div class="flex flex-wrap items-center justify-end gap-2">
            <${TextInput}
              class="max-w-45"
              name="keeper_chat_search"
              ariaLabel="대화 내용 검색"
              autoComplete="off"
              placeholder="대화 검색..."
              value=${searchQuery}
              onInput=${(e: Event) => { setSearchQuery((e.target as HTMLInputElement).value) }}
            />
            ${hasQuery
              ? html`<span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-2.5 py-1 text-2xs font-medium text-[var(--color-fg-secondary)]" data-chat-search-count>
                  ${transcriptEntries.length} / ${visibleThread.length}
                </span>`
              : null}
            <${GhostButton} onClick=${toggleMetadata} ariaExpanded=${showMetadata}>
              ${showMetadata ? '메타데이터 숨김' : '메타데이터 표시'}
            <//>
            <${GhostButton}
              onClick=${toggleInternal}
              ariaExpanded=${showInternal}
              class=${showInternal ? 'border-[var(--info-border)] text-[var(--info-fg)]' : ''}
            >
              ${showInternal ? '내부 메시지 숨김' : '내부 메시지 표시'}
            </${GhostButton}>
            ${!historyExpanded
              ? html`
                  <${GhostButton} disabled=${hydrating} onClick=${() => { void expandHistory() }}>
                    ${hydrating
                      ? '불러오는 중...'
                      : rawThread.length === 0
                        ? '이력 불러오기'
                        : `전체 이력 (${thread.length})`}
                  </button>
                `
              : null}
          </div>
        </div>

        ${chatAccess.message
          ? html`
              <div class="shrink-0 rounded-[var(--r-2)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2.5 text-xs leading-loose text-[var(--warn-bright)]">
                ${chatAccess.message}
              </div>
            `
          : null}

        <${ChatTranscript}
          entries=${transcriptEntries}
          emptyText=${transcriptEmptyText}
          showMetadata=${showMetadata}
          variant="messenger"
          size="primary"
        />

        ${!showInternal && hiddenCount > 0
          ? html`
              <div class="shrink-0 rounded-[var(--r-2)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs leading-paragraph text-[var(--warn-bright)]">
                ${hiddenCount}개의 내부 메시지가 숨겨져 있습니다. "내부 메시지 표시"로 볼 수 있습니다.
              </div>
            `
          : null}

        <div class="shrink-0 rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-4 py-4 shadow-none">
          ${queueCount > 0
            ? html`
                <div class="mb-2 flex items-center gap-2 text-2xs text-[var(--color-fg-muted)]" data-chat-queue-row>
                  <span>${queueCount}개 메시지 대기 중</span>
                  <button type="button" class="underline hover:text-[var(--color-fg-secondary)]" onClick=${cancelQueue}>모두 취소</button>
                </div>
              `
            : null}
          <${AttachmentChips} attachments=${selectedAttachments} onRemove=${removeAttachment} />
          <div class="flex items-end gap-2">
            <${AttachButton} disabled=${composerDisabled} onFiles=${(files: FileList | null) => { void addFiles(files) }} />
            <div class="min-w-0 flex-1">
              <${ChatComposer}
                draft=${draft}
                placeholder=${chatAccess.blocked
                  ? '현재 actor는 direct keeper chat 권한이 없습니다'
                  : sending
                    ? '응답 중 — 지금 보내면 대기열에 추가됩니다'
                    : placeholder}
                disabled=${composerDisabled}
                streaming=${sending}
                streamStartedAt=${streamStartedAt}
                lastEventAt=${lastSignalAt}
                queueEnabled=${true}
                queueCount=${queueCount}
                onDraftChange=${setDraft}
                onSend=${() => { void submit() }}
                onAbort=${() => { abortKeeperThreadMessage(keeperName) }}
                layout="primary"
              />
            </div>
          </div>
        </div>

        ${error ? html`<div class="shrink-0 text-xs text-[var(--bad-light)] leading-relaxed">${error}</div>` : null}
      </div>
    `
  }

  return html`
    <div class="flex flex-col gap-3" onPaste=${handlePaste}>
      <div class="overflow-hidden rounded-[var(--radius-xl)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] shadow-[var(--shadow-raised)]">
        <div class="flex flex-wrap items-start justify-between gap-3 border-b border-[var(--color-border-default)] px-4 py-4">
          <div class="min-w-55 flex-1">
            <div class="text-2xs font-semibold uppercase tracking-5 text-[var(--color-fg-muted)]">직접 대화</div>
            <div class="mt-2 flex flex-wrap items-center gap-2">
              <div class="text-md font-semibold text-[var(--color-fg-secondary)]">@${keeperName}</div>
              <span class=${`inline-flex items-center rounded-[var(--r-0)] border px-2.5 py-1 text-3xs font-medium uppercase tracking-2 ${conversationStateClass(sending, hydrating, stalled)}`}>
                ${conversationStateLabel(sending, hydrating, stalled)}
              </span>
            </div>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <${TextInput}
              class="max-w-45"
              name="keeper_chat_search"
              ariaLabel="대화 내용 검색"
              autoComplete="off"
              placeholder="대화 검색..."
              value=${searchQuery}
              onInput=${(e: Event) => { setSearchQuery((e.target as HTMLInputElement).value) }}
            />
            ${hasQuery
              ? html`<span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-2.5 py-1 text-2xs font-medium text-[var(--color-fg-secondary)]" data-chat-search-count>
                  ${transcriptEntries.length} / ${visibleThread.length}
                </span>`
              : null}
            <${GhostButton} onClick=${toggleMetadata} ariaExpanded=${showMetadata}>
              ${showMetadata ? '메타데이터 숨김' : '메타데이터 표시'}
            <//>
            <${GhostButton}
              onClick=${toggleInternal}
              ariaExpanded=${showInternal}
              class=${showInternal ? 'border-[var(--info-border)] text-[var(--info-fg)]' : ''}
            >
              ${showInternal ? '내부 메시지 숨김' : '내부 메시지 표시'}
            </${GhostButton}>
            ${!historyExpanded
              ? html`
                  <${GhostButton} disabled=${hydrating} onClick=${() => { void expandHistory() }}>
                    ${hydrating
                      ? '불러오는 중...'
                      : rawThread.length === 0
                        ? '대화 이력 불러오기'
                        : `전체 이력 불러오기 (직접 대화 ${thread.length}건 표시 중)`}
                  </button>
                `
              : null}
          </div>
        </div>

        <div class="px-4 py-4">
          ${chatAccess.message
            ? html`
                <div class="mb-4 rounded-[var(--r-5)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2.5 text-xs leading-loose text-[var(--warn-bright)]">
                  ${chatAccess.message}
                </div>
              `
            : null}
          <${ChatTranscript}
            entries=${transcriptEntries}
            emptyText=${transcriptEmptyText}
            showMetadata=${showMetadata}
            variant="messenger"
            size="default"
          />
        </div>

        ${!showInternal && hiddenCount > 0
          ? html`
              <div class="mx-4 mb-4 rounded-[var(--r-5)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs leading-paragraph text-[var(--warn-bright)]">
                ${hiddenCount}개의 내부 메시지가 숨겨져 있습니다. "내부 메시지 표시"로 볼 수 있습니다.
              </div>
            `
          : null}

        <div class="border-t border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-4 py-4">
          ${queueCount > 0
            ? html`
                <div class="mb-2 flex items-center gap-2 text-2xs text-[var(--color-fg-muted)]" data-chat-queue-row>
                  <span>${queueCount}개 메시지 대기 중</span>
                  <button type="button" class="underline hover:text-[var(--color-fg-secondary)]" onClick=${cancelQueue}>모두 취소</button>
                </div>
              `
            : null}
          <${AttachmentChips} attachments=${selectedAttachments} onRemove=${removeAttachment} />
          <div class="flex items-end gap-2">
            <${AttachButton} disabled=${composerDisabled} onFiles=${(files: FileList | null) => { void addFiles(files) }} />
            <div class="min-w-0 flex-1">
              <${ChatComposer}
                draft=${draft}
                placeholder=${chatAccess.blocked
                  ? '현재 actor는 direct keeper chat 권한이 없습니다'
                  : sending
                    ? '응답 중 — 지금 보내면 대기열에 추가됩니다'
                    : placeholder}
                disabled=${composerDisabled}
                streaming=${sending}
                streamStartedAt=${streamStartedAt}
                lastEventAt=${lastSignalAt}
                queueEnabled=${true}
                queueCount=${queueCount}
                onDraftChange=${setDraft}
                onSend=${() => { void submit() }}
                onAbort=${() => { abortKeeperThreadMessage(keeperName) }}
              />
            </div>
          </div>
        </div>
      </div>

      ${error ? html`<div class="text-xs text-[var(--bad-light)] leading-relaxed">${error}</div>` : null}
    </div>
  `
}

// ── Runtime Actions ──────────────────────────────────────

export function KeeperRuntimeActions({
  actor,
  keeper,
  onSocialSweep,
}: {
  actor: string
  keeper: Keeper | null | undefined
  onSocialSweep: () => void
}) {
  if (!keeper) return null
  const diagnostic = effectiveDiagnostic(keeper)
  const probing = keeperProbing.value[keeper.name] ?? false
  const recovering = keeperRecovering.value[keeper.name] ?? false
  const recommended = diagnostic?.next_action_path ?? null
  const canRecover = diagnostic?.recoverable === true

  const btnBase = 'py-1.5 px-4 rounded-[var(--r-1)] text-xs font-medium cursor-pointer transition-colors border'
  const ghostBtn = `${btnBase} border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]`
  const activeGhostBtn = `${btnBase} border-[var(--info-border)] bg-[var(--accent-12)] text-[var(--color-accent-fg)] hover:bg-[var(--accent-20)]`
  const secondaryBtn = `${btnBase} border-[var(--warn-border)] bg-[var(--warn-10)] text-[var(--color-status-warn)] hover:bg-[var(--warn-soft)]`
  const activeSecondaryBtn = `${btnBase} border-[var(--warn-border)] bg-[var(--warn-soft)] text-[var(--color-status-warn)] hover:bg-[var(--warn-20)]`

  return html`
    <div class="flex flex-wrap gap-2">
      <button type="button"
        class=${recommended === 'probe' ? activeGhostBtn : ghostBtn}
        onClick=${() => {
          void probeKeeperRuntime(keeper.name, actor).catch(err => {
            const message = err instanceof Error ? err.message : `${keeper.name} 점검 실패`
            showToast(message, 'error')
          })
        }}
        disabled=${probing || !actor.trim()}
      >
        ${probing ? '점검 중...' : '점검'}
      </button>
      <button type="button"
        class=${recommended === 'recover' ? activeSecondaryBtn : secondaryBtn}
        onClick=${() => {
          void recoverKeeperRuntime(keeper.name, actor).catch(err => {
            const message = err instanceof Error ? err.message : `${keeper.name} 복구 실패`
            showToast(message, 'error')
          })
        }}
        disabled=${recovering || !canRecover || !actor.trim()}
      >
        ${recovering ? '복구 중...' : '복구'}
      </button>
      <button type="button"
        class=${recommended === 'manual_social_sweep' ? activeGhostBtn : ghostBtn}
        onClick=${onSocialSweep}
      >
        Social sweep
      </button>
    </div>
  `
}
