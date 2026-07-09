import { html } from 'htm/preact'
import { AgentFailure, failureTypeFromDiagnostic } from './common/agent-failure'
import { Markdown } from "./common/markdown"
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { keeperDirectChatAccess } from '../lib/keeper-chat-access'
import { isInFlightDelivery } from '../lib/keeper-delivery'
import { relativeTime, NO_TIME_INFO } from '../lib/format-time'
import { isAbortError } from '../lib/async-state'
import type {
  ChatBlock,
  ChatAttachBlock,
  Keeper,
  KeeperConversationAttachment,
  KeeperConversationEntry,
  KeeperDiagnostic,
} from '../types'
import {
  cancelActiveKeeperThreadMessage,
  hydrateKeeperStatus,
  hydrateKeeperChatHistory,
  loadFullKeeperHistory,
  interruptKeeperTurn,
  isKeeperThreadMessageSendInFlight,
  probeKeeperRuntime,
  recoverKeeperRuntime,
  resumePendingKeeperChatRequests,
  sendKeeperThreadMessage,
} from '../keeper-actions'
import {
  keeperActionErrors,
  keeperHydrating,
  keeperProbing,
  keeperRecovering,
  keeperSending,
  keeperStatusDetails,
  keeperStreamStartedAt,
  keeperStreamLastEventAt,
  keeperThreads,
  keeperStreamContract,
  setRecordValue,
} from '../keeper-state'
import { isDefaultVisibleConversationEntry } from '../keeper-state'
import {
  getKeeperLastSeen,
  advanceKeeperLastSeen,
  newestConversationEntryUnix,
} from '../keeper-last-seen'
import { refreshKeeperCatchupDigest } from '../keeper-digest-actions'
import { keeperCatchupDigests } from '../keeper-digest-signals'
import {
  KeeperCatchupDigestCard,
  shouldShowKeeperCatchupDigest,
} from './keeper-catchup-digest-card'
import {
  enqueueInput,
  clearInputQueue,
  getQueuedMessages,
  dequeueInput,
  markInputSent,
  requeueInputFront,
  hasQueuedInputClientAction,
  updateQueuedMessage,
  removeQueuedMessage,
  type QueuedMessage,
} from '../keeper-chat-store'
import { stableAttachmentId } from './chat/attachments'
import { AttachDraftChip, ChatComposer, ChatTranscript, STREAM_STALL_THRESHOLD_S, formatAttachmentSize, type ChatComposerCommand, type ChatComposerSendPayload } from './chat/primitives'
import { showToast } from './common/toast'
import { TextInput } from './common/input'
import { shellAuthSummary } from '../store'
import {
  toolCallOutputHydrationContract,
  toolCallOutputsCoveredSinceMs,
  toolCallOutputsCoveredThroughMs,
} from '../tool-call-output-store'
import { loadTools, toolsData, toolsLoading } from './tools/tool-state'
import { setupVisibleAutoRefresh } from '../lib/auto-refresh'
import { chatShowInternal, chatShowMetadata } from '../lib/chat-view-prefs'

// Mirrors `LANE_REFRESH_MS` in keeper-workspace/keeper-lane-strip.ts. That
// const is module-local there, so we keep the same 15 s cadence here rather
// than exporting it cross-file for a single consumer.
const BUSY_REFRESH_MS = 15_000


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

function cancelKeeperThreadFromUi(keeperName: string): void {
  void cancelActiveKeeperThreadMessage(keeperName)
    .then(cancelled => {
      if (!cancelled) {
        console.warn(`[keeper] no active keeper stream to cancel for ${keeperName}`)
      }
    })
    .catch(err => {
      console.error(
        `[keeper] failed to cancel active keeper stream for ${keeperName}`,
        err instanceof Error ? err.message : err,
      )
    })
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
    && isInFlightDelivery(entry.delivery)
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
    streamContract: keeperStreamContract('client_local_send', 'client_placeholder', {
      reason: 'UI-only placeholder while active stream entry mounts',
    }),
    details: null,
    error: null,
  }
}

function queuedInputToConversationEntry(msg: QueuedMessage): KeeperConversationEntry {
  const hasText = msg.content.trim().length > 0
  const attachmentCount = msg.attachments?.length ?? 0
  const attachmentText = attachmentCount > 0 ? `첨부 ${attachmentCount}개 대기 중` : ''
  return {
    id: `queued-user-${msg.id}`,
    role: 'user',
    source: 'direct_user',
    label: 'You',
    text: hasText ? msg.content : attachmentText,
    rawText: msg.content,
    timestamp: queuedTimestampIso(msg.timestamp),
    delivery: 'queued',
    streamState: undefined,
    streamContract: keeperStreamContract('client_local_send', 'client_placeholder', {
      deliveryReceipt: 'no_delivery_receipt',
      reason: 'client-side composer queue item; not yet submitted to keeper runtime',
    }),
    queueSeq: msg.sequence,
    queueClientActionId: msg.clientActionId ?? null,
    attachments: msg.attachments,
    blocks: msg.blocks,
    details: null,
    error: null,
  }
}

function queuedTimestampIso(timestampMs: number): string | null {
  if (!Number.isFinite(timestampMs)) return null
  try {
    return new Date(timestampMs).toISOString()
  } catch {
    return null
  }
}

function effectiveDiagnostic(keeper: Keeper | null | undefined): KeeperDiagnostic | null {
  if (!keeper) return null
  const detail = keeperStatusDetails.value[keeper.name]
  return detail?.diagnostic ?? keeper.diagnostic ?? null
}

/** Case-insensitive substring filter over entry text. Tool rows also match on
 *  the tool label because their visible name often is not present in `{}` args.
 *  Empty or
 *  whitespace-only queries return the input unchanged. Migrated from
 *  the former keeper-chat-panel.ts (filterChatMessages). */
export function filterConversationEntries(
  entries: KeeperConversationEntry[],
  query: string,
): KeeperConversationEntry[] {
  const q = query.trim().toLowerCase()
  if (!q) return entries
  return entries.filter(entry => {
    if (entry.text.toLowerCase().includes(q)) return true
    if ((entry.rawText ?? '').toLowerCase().includes(q)) return true
    return entry.role === 'tool' && entry.label.toLowerCase().includes(q)
  })
}

function blocksToAttachments(blocks: ChatBlock[]): KeeperConversationAttachment[] {
  const generatedCounts = new Map<string, number>()
  return blocks
    .filter((b): b is ChatAttachBlock => b.t === 'attach')
    .map((b) => {
      const baseId = stableAttachmentId({
        name: b.name,
        type: b.kind === 'image' || b.src?.startsWith('data:image/') ? 'image' : 'file',
        kind: b.kind,
        mimeType: b.mimeType,
        size: b.sizeBytes,
        dims: b.dims,
        data: b.data ?? b.svg ?? b.ph,
        src: b.src,
      })
      const count = generatedCounts.get(baseId) ?? 0
      generatedCounts.set(baseId, count + 1)
      return {
        id: b.id ?? (count === 0 ? baseId : `${baseId}-${count + 1}`),
        type: b.kind === 'image' || b.src?.startsWith('data:image/') ? 'image' : 'file',
        name: b.name,
        size: b.sizeBytes ?? 0,
        mimeType: b.mimeType ?? 'application/octet-stream',
        data: b.data ?? b.src ?? '',
        dims: b.dims,
      }
    })
}

function blocksToDisplayBlocks(blocks: ChatBlock[]): ChatBlock[] | undefined {
  const displayBlocks = blocks.filter((block) => block.t !== 'attach')
  return displayBlocks.length > 0 ? displayBlocks : undefined
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
    <div class="py-3 px-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] v2-monitoring-panel">
      <div class="mb-3 flex items-center justify-between gap-3">
        <div class="text-2xs font-semibold uppercase tracking-4 text-[var(--color-fg-muted)]">명시적 상태 조회</div>
        <${GhostButton} disabled=${busy} onClick=${() => { void refreshStatus() }}>
          ${busy ? '불러오는 중...' : (detail ? '상태 새로고침' : '상태 불러오기')}
        <//>
      </div>
      <div class="flex flex-wrap gap-1.5 mb-2 v2-monitoring-row">
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
      <div class="text-xs text-[var(--color-fg-primary)] leading-relaxed mt-1 v2-monitoring-row">
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
        ? html`<div class="mt-3 max-h-60 overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] custom-scrollbar v2-monitoring-panel"><${Markdown} text=${'```text\n' + (detail?.rawText ?? '키퍼 상태를 아직 불러오지 않았습니다.') + '\n```'} /></div>`
        : null}
    </div>
  `
}

// ── Queued message editor (rendered inside the conversation panel) ──

interface QueueItemCardProps {
  keeperName: string
  msg: QueuedMessage
  onMutate: () => void
}

function QueueItemCard({ keeperName, msg, onMutate }: QueueItemCardProps) {
  const [editing, setEditing] = useState(false)
  const [text, setText] = useState(msg.content)
  const [attachments, setAttachments] = useState(msg.attachments ?? [])

  const save = () => {
    updateQueuedMessage(keeperName, msg.id, {
      content: text.trim(),
      attachments: attachments.length > 0 ? attachments : undefined,
    })
    setEditing(false)
    onMutate()
  }

  const cancel = () => {
    setText(msg.content)
    setAttachments(msg.attachments ?? [])
    setEditing(false)
  }

  const removeAttachment = (id: string) => {
    setAttachments(prev => prev.filter(a => a.id !== id))
  }

  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2.5"
      data-chat-queue-item=${msg.id}
      data-chat-queue-seq=${msg.sequence}
      data-chat-queue-client-action-id=${msg.clientActionId ?? undefined}
    >
      ${editing
        ? html`
            <textarea
              class="w-full min-h-[3.5rem] rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2.5 py-2 text-sm leading-relaxed text-[var(--color-fg-primary)] outline-none focus:border-[var(--color-accent-fg-dim)]"
              value=${text}
              onInput=${(e: Event) => { setText((e.target as HTMLTextAreaElement).value) }}
            />
            ${attachments.length > 0
              ? html`
                  <div class="mt-2 flex flex-wrap gap-2">
                    ${attachments.map(att => html`
                      <${AttachDraftChip}
                        key=${att.id}
                        attachment=${att}
                        onRemove=${() => { removeAttachment(att.id) }}
                      />
                    `)}
                  </div>
                `
              : null}
            <div class="mt-2 flex items-center justify-end gap-2">
              <button type="button" class="text-2xs text-[var(--color-fg-secondary)] hover:text-[var(--color-fg-primary)]" onClick=${cancel}>취소</button>
              <button type="button" class="rounded-[var(--r-0)] bg-[var(--color-accent-fg)] px-2.5 py-1 text-2xs font-semibold text-[var(--color-bg-page)]" onClick=${save}>저장</button>
            </div>
          `
        : html`
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0 flex-1">
                <div class="text-sm text-[var(--color-fg-primary)] whitespace-pre-wrap break-words">${msg.content}</div>
                ${attachments.length > 0
                  ? html`<div class="mt-1.5 flex flex-wrap gap-1.5">
                      ${attachments.map(att => html`
                        <span class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-1.5 py-0.5 text-2xs text-[var(--color-fg-secondary)]">
                          <span>${att.type === 'image' ? '▣' : '◫'}</span>
                          <span class="truncate max-w-[12rem]">${att.name}</span>
                          <span class="tabular-nums">${formatAttachmentSize(att.size)}</span>
                        </span>
                      `)}
                    </div>`
                  : null}
              </div>
              <div class="flex items-center gap-1.5 flex-none">
                <button type="button" class="text-2xs text-[var(--color-fg-secondary)] hover:text-[var(--color-fg-primary)]" onClick=${() => { setEditing(true) }}>수정</button>
                <button type="button" class="text-2xs text-[var(--color-status-err)] hover:text-[var(--color-status-err)]" onClick=${() => { removeQueuedMessage(keeperName, msg.id); onMutate() }}>삭제</button>
              </div>
            </div>
          `}
    </div>
  `
}

// ── Busy toolbar (turn-interrupt affordance) ─────────────

function BusyToolbar({
  keeperName,
  onInterrupt,
}: {
  keeperName: string
  onInterrupt: () => void
}) {
  return html`
    <div
      class="mb-2 flex items-center justify-between gap-2 text-2xs v2-monitoring-row"
      data-keeper-name=${keeperName}
    >
      <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-2 py-0.5 font-medium text-[var(--color-status-warn)]">
        busy
      </span>
      <${GhostButton} onClick=${onInterrupt}>현재 턴 중단<//>
    </div>
  `
}

// ── Conversation Panel ───────────────────────────────────

export function KeeperConversationPanel({
  keeperName,
  placeholder,
  layout = 'default',
  composerCommands = [],
  onInspectTurn,
}: {
  keeperName: string
  placeholder: string
  layout?: 'default' | 'primary' | 'workspace'
  composerCommands?: ChatComposerCommand[]
  onInspectTurn?: (entry: KeeperConversationEntry) => void
}) {
  // Global view prefs (Tweaks panel owns the switches). Reading .value here
  // subscribes this component, so a Tweaks flip re-renders every mounted panel.
  const showMetadata = chatShowMetadata.value
  const showInternal = chatShowInternal.value

  const [historyExpanded, setHistoryExpanded] = useState(false)
  const [searchQuery, setSearchQuery] = useState('')
  // Bumped whenever the input queue mutates — the queue lives outside
  // the signal graph (keeper-chat-store), so re-renders must be forced.
  const [queueVersion, setQueueVersion] = useState(0)
  const bumpQueue = () => setQueueVersion(v => v + 1)
  const isDrainingRef = useRef(false)

  // Keep the shared keeper waiting inventory live on surfaces that do NOT
  // render KeeperLaneSection (which is what normally polls it every 15 s).
  // Mirror the lane strip's visibility-aware auto-refresh: pause while the tab
  // is hidden, refresh immediately on focus/return, and return the cleanup so
  // the busy chip / interrupt button cannot freeze on a stale snapshot.
  useEffect(() => {
    if (!toolsData.value && !toolsLoading.value) void loadTools()
    return setupVisibleAutoRefresh(() => {
      void loadTools()
    }, BUSY_REFRESH_MS)
  }, [])

  const inventoryEntry = useMemo(() => {
    const inv = toolsData.value?.keeper_waiting_inventory
    if (!inv) return null
    return inv.keepers.find(k => k.keeper_name === keeperName) ?? null
  }, [keeperName, toolsData.value])

  // External-system sync: merge the server-persisted transcript
  // (.masc/keeper_chat/<name>.jsonl) on mount so the conversation
  // survives full page reloads. Once-per-keeper inside the action.
  useEffect(() => {
    // Capture the last-seen cursor BEFORE anything advances it, and fetch the
    // since-last-seen digest against that frozen baseline. The card and the
    // unread divider anchor on the server's echoed since_unix, not the live
    // cursor, so the advance below does not move them mid-visit.
    const baseline = getKeeperLastSeen(keeperName)
    if (baseline !== null) void refreshKeeperCatchupDigest(keeperName, baseline)
    void (async () => {
      await hydrateKeeperChatHistory(keeperName)
      // The server transcript is now merged: mark the newest merged entry as
      // seen so the NEXT visit's baseline is current. First-ever visits (no
      // prior cursor) also land here, seeding the cursor without a card.
      const newest = newestConversationEntryUnix(keeperThreads.value[keeperName] ?? [])
      if (newest !== null) advanceKeeperLastSeen(keeperName, newest)
    })()
    void resumePendingKeeperChatRequests(keeperName)
  }, [keeperName])

  const rawThread = keeperThreads.value[keeperName] ?? []
  // thread / visibleThread / transcriptEntries form a derivation chain over
  // rawThread + UI state (showInternal toggle, sending flag, searchQuery
  // keystrokes). The parent re-renders on every search keystroke and other
  // unrelated signals; memoizing each stage on its stable upstream skips the
  // refilter when rawThread and the relevant UI flag are unchanged.
  const thread = useMemo(
    () => showInternal ? rawThread : rawThread.filter(isDefaultVisibleConversationEntry),
    [rawThread, showInternal],
  )
  const hiddenCount = rawThread.length - thread.length
  const sending = keeperSending.value[keeperName] ?? false
  const isKeeperBusy = Boolean(inventoryEntry?.state === 'busy' && !sending)
  const visibleThread = useMemo(
    () =>
      sending && !thread.some(isActiveAssistantEntry)
        ? [...thread, liveAssistantPlaceholder(keeperName)]
        : thread,
    [thread, sending, keeperName],
  )
  const queuedMessages = useMemo(
    () => getQueuedMessages(keeperName),
    [keeperName, queueVersion],
  )
  const queueCount = queuedMessages.length
  const visibleThreadWithQueue = useMemo(
    () =>
      queuedMessages.length > 0
        ? [...visibleThread, ...queuedMessages.map(queuedInputToConversationEntry)]
        : visibleThread,
    [visibleThread, queuedMessages],
  )
  const hasQuery = searchQuery.trim().length > 0
  const transcriptEntries = useMemo(
    () => filterConversationEntries(visibleThreadWithQueue, searchQuery),
    [visibleThreadWithQueue, searchQuery],
  )
  // Since-last-seen digest (fetched once on mount against the frozen baseline).
  // Reading the signal here subscribes the panel so the card appears when the
  // fetch resolves. Card + divider anchor on digest.since_unix, not the cursor.
  const catchupDigest = keeperCatchupDigests.value[keeperName] ?? null
  const digestCard = shouldShowKeeperCatchupDigest(catchupDigest)
    ? html`<${KeeperCatchupDigestCard} digest=${catchupDigest} />`
    : null
  const unreadAfterTs = catchupDigest?.since_unix ?? null
  const newestEntryTsUnix = useMemo(
    () => newestConversationEntryUnix(transcriptEntries),
    [transcriptEntries],
  )
  // Advance the cursor to the newest visible entry once the operator has caught
  // up (ChatTranscript calls this when pinned to bottom / tab visible). Monotonic
  // and localStorage-guarded, so repeated pinned calls are cheap.
  const markTranscriptSeen = () => {
    if (newestEntryTsUnix !== null) advanceKeeperLastSeen(keeperName, newestEntryTsUnix)
  }
  // Stable action object so the memoized ChatMessageBubble's shallow prop
  // compare can skip unchanged messages — an inline `{ ...onClick }` literal
  // would be a new reference each render and defeat the memo.
  const inspectAction = useMemo(
    () =>
      onInspectTurn
        ? { label: '턴 상세', title: '이 메시지 턴 상세 열기', onClick: onInspectTurn }
        : undefined,
    [onInspectTurn],
  )
  const transcriptEmptyText =
    hasQuery && visibleThreadWithQueue.length > 0
      ? '검색어와 일치하는 메시지가 없습니다.'
      : '아직 표시할 대화가 없습니다. 내부 메시지는 Tweaks의 "내부 메시지"로 볼 수 있습니다.'
  const hydrating = keeperHydrating.value[keeperName] ?? false
  const error = keeperActionErrors.value[keeperName]
  const renderError = (extraClass = 'mt-2') => {
    if (!error) return null
    return html`
      <div class="${extraClass} flex items-start justify-between gap-2 rounded border border-[var(--err-border)] bg-[var(--bad-10)] px-3 py-2 text-xs text-[var(--bad-light)] leading-relaxed v2-monitoring-panel" role="alert">
        <span class="flex-1">${error}</span>
        <button
          type="button"
          aria-label="에러 메시지 닫기"
          class="shrink-0 text-[var(--bad-light)] opacity-70 hover:opacity-100 transition-opacity ml-1 cursor-pointer font-bold select-none"
          title="에러 메시지 닫기"
          onClick=${() => setRecordValue(keeperActionErrors, keeperName, null)}
        >
          ✕
        </button>
      </div>
    `
  }
  const chatAccess = keeperDirectChatAccess(shellAuthSummary.value)
  const composerDisabled = !keeperName || chatAccess.blocked
  const composerPlaceholder = chatAccess.blocked
    ? '현재 actor는 direct keeper chat 권한이 없습니다'
    : isKeeperBusy
      ? '현재 턴 실행 중 — 지금 보낸 메시지는 현재 턴 종료 후 대기열에서 처리됩니다'
      : sending
        ? '응답 중 — 지금 보낸 메시지는 대기열에 추가됩니다'
        : placeholder

  // 1 s ticker while a stream is active so the stall badge can compare
  // against wall-clock time. External-system sync (timer), not data init.
  const [, setStallTick] = useState(0)
  useEffect(() => {
    if (!sending) return
    const id = setInterval(() => setStallTick(t => t + 1), 1000)
    return () => clearInterval(id)
  }, [sending, keeperName])

  // Reactively drain the queued inputs when the keeper finishes sending
  useEffect(() => {
    if (!sending && keeperName) {
      void drainQueue()
    }
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
    if (isDrainingRef.current) return
    isDrainingRef.current = true
    try {
      for (;;) {
        const queued = dequeueInput(keeperName)
        if (!queued) return
        bumpQueue()

        const content = queued.content.trim()
        const attachments = queued.attachments && queued.attachments.length > 0 ? queued.attachments : undefined
        if (!content && !attachments) {
          markInputSent(keeperName)
          bumpQueue()
          continue
        }

        try {
          await sendKeeperThreadMessage(keeperName, content, {
            attachments,
            blocks: queued.blocks,
            clientActionId: queued.clientActionId,
            userBlocks: queued.userBlocks,
          })
          markInputSent(keeperName)
          bumpQueue()
        } catch (err) {
          if (isAbortError(err)) {
            markInputSent(keeperName)
            bumpQueue()
            return
          }
          requeueInputFront(keeperName, queued)
          bumpQueue()
          const message = err instanceof Error ? err.message : `${keeperName} 메시지 전송 실패`
          showToast(message, 'error')
          return
        }
      }
    } finally {
      isDrainingRef.current = false
    }
  }

  const submit = async ({ blocks, userBlocks, clientActionId, text }: ChatComposerSendPayload) => {
    const prompt = text
    if (chatAccess.blocked) {
      showToast(chatAccess.message, 'error')
      return
    }
    if (!keeperName || (!prompt && blocks.length === 0)) return
    const attachments = blocksToAttachments(blocks)
    const displayBlocks = blocksToDisplayBlocks(blocks)
    if (keeperSending.value[keeperName]) {
      if (
        isKeeperThreadMessageSendInFlight(keeperName, clientActionId)
        || hasQueuedInputClientAction(keeperName, clientActionId)
      ) {
        return
      }
      enqueueInput(
        keeperName,
        prompt,
        attachments.length > 0 ? attachments : undefined,
        clientActionId,
        displayBlocks,
        userBlocks,
      )
      bumpQueue()
      return
    }
    try {
      await sendKeeperThreadMessage(keeperName, prompt, {
        attachments,
        blocks: displayBlocks,
        clientActionId,
        userBlocks,
      })
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

  // Busy/interrupt affordance shared by all three composer layouts. Defined
  // here (not as a module-level helper) so it closes over keeperName/showToast/
  // interruptKeeperTurn and the workspace/primary/default branches cannot drift
  // apart again — the default branch previously dropped this entirely.
  const renderBusyToolbar = () => html`
    <${BusyToolbar}
      keeperName=${keeperName}
      onInterrupt=${() => {
        void interruptKeeperTurn(keeperName)
          .then(cancelled => {
            showToast(
              cancelled ? '현재 턴을 중단했습니다' : '중단할 실행 중인 턴이 없습니다',
              cancelled ? 'success' : 'warning',
            )
          })
          .catch(() => {
            showToast('현재 턴 중단에 실패했습니다', 'error')
          })
      }}
    />
  `

  if (layout === 'workspace') {
    // 3-pane workspace: identity + lifecycle live in the ChatHeader above
    // this panel, so the workspace layout drops the panel's own header and
    // renders just the spacious thread + composer. All chat state/handlers
    // (draft, queue, attachments, streaming, search, toggles) are reused
    // unchanged — only the chrome differs. Spacing comes from keeper-workspace.css.
    return html`
      <div
        class="flex min-h-0 flex-1 flex-col v2-monitoring-surface"
        data-keeper-chat-layout="workspace"
      >
        <div class="kw-chat-toolbar v2-monitoring-toolbar">
          <${TextInput}
            class="max-w-50"
            name="keeper_chat_search"
            ariaLabel="대화 내용 검색"
            autoComplete="off"
            placeholder="대화 검색..."
            value=${searchQuery}
            onInput=${(e: Event) => { setSearchQuery((e.target as HTMLInputElement).value) }}
          />
          ${hasQuery
            ? html`<span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-2 py-0.5 text-2xs font-medium text-[var(--color-fg-secondary)] v2-monitoring-row" data-chat-search-count>
                ${transcriptEntries.length} / ${visibleThreadWithQueue.length}
              </span>`
            : null}
          <span class="spacer"></span>
          ${!historyExpanded
            ? html`
                <${GhostButton} disabled=${hydrating} onClick=${() => { void expandHistory() }}>
                  ${hydrating
                    ? '불러오는 중...'
                    : rawThread.length === 0
                      ? '이력 불러오기'
                      : `전체 이력 (${thread.length})`}
                <//>
              `
            : null}
        </div>

        ${chatAccess.message
          ? html`
              <div class="mx-10 mt-3 rounded-[var(--r-2)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2.5 text-xs leading-loose text-[var(--warn-bright)] v2-monitoring-panel">
                ${chatAccess.message}
              </div>
            `
          : null}

        ${digestCard ? html`<div class="mx-10 mt-3">${digestCard}</div>` : null}

        <div class="kw-thread v2-monitoring-panel">
          <div class="kw-thread-inner v2-monitoring-panel">
            <${ChatTranscript}
              entries=${transcriptEntries}
              emptyText=${transcriptEmptyText}
              showMetadata=${showMetadata}
              variant="messenger"
              size="primary"
              showDayDividers=${true}
              groupToolCalls=${true}
              showSourceBadge=${true}
              toolOutputsCoveredSinceMs=${toolCallOutputsCoveredSinceMs(keeperName)}
              toolOutputsCoveredThroughMs=${toolCallOutputsCoveredThroughMs(keeperName)}
              toolOutputHydrationContract=${toolCallOutputHydrationContract(keeperName)}
              unreadAfterTs=${unreadAfterTs}
              onSeenBottom=${markTranscriptSeen}
              action=${inspectAction}
            />
          </div>
        </div>

        ${!showInternal && hiddenCount > 0
          ? html`
              <div class="mx-10 mb-2 rounded-[var(--r-2)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs leading-paragraph text-[var(--warn-bright)] v2-monitoring-panel">
                ${hiddenCount}개의 내부 메시지가 숨겨져 있습니다.
                <button
                  type="button"
                  class="ml-1 cursor-pointer border-0 bg-transparent p-0 text-2xs font-semibold text-[var(--warn-bright)] underline"
                  onClick=${() => { chatShowInternal.value = true }}
                >바로 표시</button>
              </div>
            `
          : null}

        <div class="kw-composer-wrap v2-monitoring-panel">
          <div class="kw-composer-inner v2-monitoring-panel">
            ${queueCount > 0
              ? html`
                  <div class="mb-3 flex flex-col gap-2" data-chat-queue-list>
                    <div class="flex items-center justify-between gap-2 text-2xs text-[var(--color-fg-muted)] v2-monitoring-row" data-chat-queue-row>
                      <span>${queueCount}개 메시지 대기 중</span>
                      <button type="button" class="underline hover:text-[var(--color-fg-secondary)]" onClick=${cancelQueue}>모두 취소</button>
                    </div>
                    ${queuedMessages.map(msg => html`
                      <${QueueItemCard}
                        key=${msg.id}
                        keeperName=${keeperName}
                        msg=${msg}
                        onMutate=${bumpQueue}
                      />
                    `)}
                  </div>
                `
              : null}
            ${isKeeperBusy ? renderBusyToolbar() : null}
            <${ChatComposer}
              key=${keeperName}
              draftPersistKey=${keeperName}
              keeperLabel=${keeperName}
              placeholder=${composerPlaceholder}
              disabled=${composerDisabled}
              streaming=${sending}
              streamStartedAt=${streamStartedAt}
              lastEventAt=${lastSignalAt}
              queueEnabled=${true}
              queueCount=${queueCount}
              commands=${composerCommands}
              onSend=${(payload: ChatComposerSendPayload) => { void submit(payload) }}
              onAbort=${() => { cancelKeeperThreadFromUi(keeperName) }}
              layout="primary"
            />
            ${renderError()}
          </div>
        </div>
      </div>
    `
  }

  if (layout === 'primary') {
    return html`
      <div
        class="flex h-[clamp(30rem,calc(100svh-13rem),52rem)] min-h-0 flex-col gap-4 overflow-hidden rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4 shadow-none v2-monitoring-surface"
        data-keeper-chat-layout="primary"
      >
        <div class="shrink-0 flex flex-wrap items-center justify-between gap-3 border-b border-[var(--color-border-default)] pb-3 v2-monitoring-toolbar">
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
                  ${transcriptEntries.length} / ${visibleThreadWithQueue.length}
                </span>`
              : null}
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
              <div class="shrink-0 rounded-[var(--r-2)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2.5 text-xs leading-loose text-[var(--warn-bright)] v2-monitoring-panel">
                ${chatAccess.message}
              </div>
            `
          : null}

        ${digestCard ? html`<div class="shrink-0">${digestCard}</div>` : null}

        <${ChatTranscript}
          entries=${transcriptEntries}
          emptyText=${transcriptEmptyText}
          showMetadata=${showMetadata}
          variant="messenger"
          size="primary"
          groupToolCalls=${true}
          toolOutputsCoveredSinceMs=${toolCallOutputsCoveredSinceMs(keeperName)}
          toolOutputsCoveredThroughMs=${toolCallOutputsCoveredThroughMs(keeperName)}
          toolOutputHydrationContract=${toolCallOutputHydrationContract(keeperName)}
          unreadAfterTs=${unreadAfterTs}
          onSeenBottom=${markTranscriptSeen}
          action=${inspectAction}
        />

        ${!showInternal && hiddenCount > 0
          ? html`
              <div class="shrink-0 rounded-[var(--r-2)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs leading-paragraph text-[var(--warn-bright)] v2-monitoring-panel">
                ${hiddenCount}개의 내부 메시지가 숨겨져 있습니다.
                <button
                  type="button"
                  class="ml-1 cursor-pointer border-0 bg-transparent p-0 text-2xs font-semibold text-[var(--warn-bright)] underline"
                  onClick=${() => { chatShowInternal.value = true }}
                >바로 표시</button>
              </div>
            `
          : null}

        <div class="shrink-0 rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-4 py-4 shadow-none v2-monitoring-panel">
          ${queueCount > 0
            ? html`
                <div class="mb-2 flex items-center gap-2 text-2xs text-[var(--color-fg-muted)] v2-monitoring-row" data-chat-queue-row>
                  <span>${queueCount}개 메시지 대기 중</span>
                  <button type="button" class="underline hover:text-[var(--color-fg-secondary)]" onClick=${cancelQueue}>모두 취소</button>
                </div>
              `
            : null}
          ${isKeeperBusy ? renderBusyToolbar() : null}
          <${ChatComposer}
            key=${keeperName}
            draftPersistKey=${keeperName}
            keeperLabel=${keeperName}
            placeholder=${composerPlaceholder}
            disabled=${composerDisabled}
            streaming=${sending}
            streamStartedAt=${streamStartedAt}
            lastEventAt=${lastSignalAt}
            queueEnabled=${true}
            queueCount=${queueCount}
            commands=${composerCommands}
            onSend=${(payload: ChatComposerSendPayload) => { void submit(payload) }}
            onAbort=${() => { cancelKeeperThreadFromUi(keeperName) }}
            layout="primary"
          />
        </div>

        ${renderError('shrink-0')}
      </div>
    `
  }

  return html`
    <div class="flex flex-col gap-3 v2-monitoring-surface">
      <div class="overflow-hidden rounded-[var(--radius-xl)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] shadow-[var(--shadow-raised)] v2-monitoring-panel">
        <div class="flex flex-wrap items-start justify-between gap-3 border-b border-[var(--color-border-default)] px-4 py-4 v2-monitoring-toolbar">
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
                  ${transcriptEntries.length} / ${visibleThreadWithQueue.length}
                </span>`
              : null}
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
                <div class="mb-4 rounded-[var(--r-5)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2.5 text-xs leading-loose text-[var(--warn-bright)] v2-monitoring-panel">
                  ${chatAccess.message}
                </div>
              `
            : null}
          ${digestCard ? html`<div class="mb-4">${digestCard}</div>` : null}
          <${ChatTranscript}
            entries=${transcriptEntries}
            emptyText=${transcriptEmptyText}
            showMetadata=${showMetadata}
            variant="messenger"
            size="default"
            groupToolCalls=${true}
            toolOutputsCoveredSinceMs=${toolCallOutputsCoveredSinceMs(keeperName)}
            toolOutputsCoveredThroughMs=${toolCallOutputsCoveredThroughMs(keeperName)}
            toolOutputHydrationContract=${toolCallOutputHydrationContract(keeperName)}
            unreadAfterTs=${unreadAfterTs}
            onSeenBottom=${markTranscriptSeen}
            action=${inspectAction}
          />
        </div>

        ${!showInternal && hiddenCount > 0
          ? html`
              <div class="mx-4 mb-4 rounded-[var(--r-5)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs leading-paragraph text-[var(--warn-bright)] v2-monitoring-panel">
                ${hiddenCount}개의 내부 메시지가 숨겨져 있습니다.
                <button
                  type="button"
                  class="ml-1 cursor-pointer border-0 bg-transparent p-0 text-2xs font-semibold text-[var(--warn-bright)] underline"
                  onClick=${() => { chatShowInternal.value = true }}
                >바로 표시</button>
              </div>
            `
          : null}

        <div class="border-t border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-4 py-4 v2-monitoring-panel">
          ${queueCount > 0
            ? html`
                <div class="mb-2 flex items-center gap-2 text-2xs text-[var(--color-fg-muted)] v2-monitoring-row" data-chat-queue-row>
                  <span>${queueCount}개 메시지 대기 중</span>
                  <button type="button" class="underline hover:text-[var(--color-fg-secondary)]" onClick=${cancelQueue}>모두 취소</button>
                </div>
              `
            : null}
          ${isKeeperBusy ? renderBusyToolbar() : null}
          <${ChatComposer}
            key=${keeperName}
            draftPersistKey=${keeperName}
            keeperLabel=${keeperName}
            placeholder=${composerPlaceholder}
            disabled=${composerDisabled}
            streaming=${sending}
            streamStartedAt=${streamStartedAt}
            lastEventAt=${lastSignalAt}
            queueEnabled=${true}
            queueCount=${queueCount}
            commands=${composerCommands}
            onSend=${(payload: ChatComposerSendPayload) => { void submit(payload) }}
            onAbort=${() => { cancelKeeperThreadFromUi(keeperName) }}
          />
        </div>
      </div>

      ${renderError()}
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
    <div class="flex flex-wrap gap-2 v2-monitoring-toolbar">
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
