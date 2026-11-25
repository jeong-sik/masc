/**
 * Entity Tab 1: `Chat` (`/keepers/:name/chat`)
 *
 * - `Origin_bare` live AG-UI SSE transcript (`POST /api/v1/keepers/chat/stream`),
 *   paginated history (`/keepers/:k/chat/history/page`), cut-reply journal recovery
 *   (`/keepers/:k/chat/events`), explicit delivery states
 *   (`Queued | Sending | Pending_processing | Confirming_delivery | Streaming | Delivered | Cut_recovered | Failed`).
 * - Hermes-style Composer Footer: Model/Lane pill, circular SVG Context Ring %,
 *   attachments + voice STT trigger, `Enter` Queue vs `⌘↵` Steer (own `operation_id`), `/btw` side-query.
 * - Opens the Debug Companion on demand (`⌘.`).
 */

import type { WorkspaceInspectPayload } from '../types'
import { html } from 'htm/preact'
import { ErrorBoundary } from '../../components/common/error-boundary'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { WorkspaceChatImage } from '../../components/chat/workspace-image'
import { lazy, Suspense } from 'preact/compat'
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks'
import { currentSessionEpoch, isEpochCurrent, sessionEpoch } from '../../core/auth'
import { formatObserved } from '../../core/resource-cache'
import { observerConnected, subscribeObserverFrames, subscribeObserverResync } from '../../core/observer'
import { randomUuid } from '../../lib/uuid'
import {
  cancelQueuedChatOperation,
  fetchKeeperChatHistoryPageApi,
  fetchKeeperControlToken,
  fetchKeeperToolResultApi,
  fetchKeeperWaitingInventoryApi,
  fetchQueuedChatOperations,
  formatContextDetail,
  moveQueuedChatOperationToEndApi,
  observeRosterContextPct,
  parseKeeperLiveObserverEvent,
  recoverCutReplyFromJournal,
  streamKeeperChat,
  transcribeVoiceAudio,
  type KeeperLiveToolPulse,
} from './keepers-api'
import {
  dedupeHistoryToolRows,
  extractDelegateCardInfo,
  findToolCallIndex,
  formatElapsedCompact,
  formatTurnActivityLabel,
  formatTurnLaneLabel,
  formatWaitingSourceLabel,
  groupTranscriptEntries,
  internalModeLabel,
  loadChatBlockPrefs,
  mergeLatestHistoryPage,
  nextInternalMode,
  nextThinkingMode,
  nextToolsMode,
  parseChatMessageBlocks,
  prettyFormatPayload,
  toolResultMarkdownPreview,
  saveChatBlockPrefs,
  shouldRenderChatEntry,
  summarizeCompact,
  summarizeToolHistogram,
  thinkingModeLabel,
  toolsModeLabel,
  toolStatusMeta,
  upsertStreamToolCall,
  type ChatBlockPrefs,
} from './chat-blocks'
import {
  TOOL_RESULT_MAX_PAGES_PER_BURST,
  TOOL_RESULT_PAGE_BYTES,
  applyToolResultError,
  applyToolResultPage,
  copyTextToClipboard,
  fetchToolResultContinuation,
  formatByteSize,
  formatToolResultProgress,
  isLongToolOutput,
  type ToolResultState,
} from './tool-result-state'
import type {
  BtwQueryState,
  ChatAttachmentDraft,
  ChatDeliveryState,
  ChatToolBlock,
  ChatTranscriptEntry,
  KeeperActiveTurnPreview,
  KeeperRosterItem,
  KeeperWaitingInventoryData,
  QueuedChatOperation,
} from './types'

const LazyKeeperDebugCompanion = lazy(async () => ({
  default: (await import('./keeper-debug-companion')).KeeperDebugCompanion,
}))

export interface KeeperChatTabProps {
  readonly keeper: KeeperRosterItem
  readonly onInspect: (payload: WorkspaceInspectPayload) => void
  readonly onSelectKeeper?: (name: string) => void
  readonly onMutated: () => void
}

const RING_CIRCUMFERENCE = 2 * Math.PI * 8.5
const BOTTOM_STICKY_THRESHOLD_PX = 72
const INITIAL_RENDER_WINDOW = 120
const MAX_RENDER_WINDOW = 1000

type ChatRead = 'history' | 'queue' | 'waiting'

type QueueRead = {
  readonly keeperName: string
  readonly epoch: number
  readonly operations: readonly QueuedChatOperation[]
} & (
  | { readonly kind: 'loading' | 'ready' }
  | { readonly kind: 'error'; readonly message: string }
)

function formatChatTime(ts: number): string | null {
  if (!Number.isFinite(ts) || ts <= 0) return null
  const ms = ts < 1_000_000_000_000 ? ts * 1000 : ts
  const d = new Date(ms)
  if (Number.isNaN(d.getTime())) return null
  const hh = String(d.getHours()).padStart(2, '0')
  const mm = String(d.getMinutes()).padStart(2, '0')
  return `${hh}:${mm}`
}

function formatChatSpeakerLabel(msg: ChatTranscriptEntry, keeperName: string, autonomousSummary: string | null, memoryOnly: boolean): string {
  if (msg.role === 'user') {
    const actor = msg.speakerName ?? msg.speakerId ?? null
    if (msg.speakerAuthority === 'keeper') {
      return `Keeper · ${actor ?? 'keeper'}`
    }
    if (msg.speakerAuthority === 'external') {
      return actor ? `${actor} (외부)` : '외부 발신자'
    }
    if (msg.speakerAuthority === 'owner') {
      return actor && actor.toLowerCase() !== 'operator' ? `Operator (${actor})` : 'Operator'
    }
    return actor ?? msg.speakerLabel ?? '사용자'
  }
  if (autonomousSummary !== null) return `${keeperName} · Autonomous Turn`
  if (memoryOnly) return `${keeperName} · Memory Recall`
  if (msg.toolName) return `Tool · ${msg.toolName}`
  return keeperName
}

function deliveryBadgeTone(state: ChatDeliveryState | undefined): 'ok' | 'warn' | 'bad' | 'info' | 'brass' | undefined {
  switch (state) {
    case 'Queued':
    case 'Pending_processing':
      return 'warn'
    case 'Sending':
    case 'Confirming_delivery':
      return 'info'
    case 'Streaming':
      return 'brass'
    case 'Delivered':
    case 'Cut_recovered':
      return 'ok'
    case 'Failed':
      return 'bad'
    default:
      return undefined
  }
}

const MAX_TOOL_RESULT_CACHE = 50
const MAX_AUTO_HYDRATE_TOOL_RESULTS = 8

function joinThinkingMap(map: Map<string, string>): string | undefined {
  const ordered = Array.from(map.values()).filter((v) => v.length > 0)
  return ordered.length > 0 ? ordered.join('\n\n') : undefined
}

function setBoundedToolResultCache(
  prev: Record<string, ToolResultState>,
  key: string,
  entry: ToolResultState,
): Record<string, ToolResultState> {
  const next: Record<string, ToolResultState> = { ...prev }
  delete next[key]
  next[key] = entry
  const keys = Object.keys(next)
  while (keys.length > MAX_TOOL_RESULT_CACHE) {
    const oldest = keys.shift()
    if (oldest) delete next[oldest]
  }
  return next
}

export function KeeperChatTab(props: KeeperChatTabProps) {
  const { keeper } = props
  const [messages, setMessages] = useState<readonly ChatTranscriptEntry[]>([])
  const [nextCursor, setNextCursor] = useState<string | null>(null)
  const [hasMore, setHasMore] = useState(false)
  const [loadingHistory, setLoadingHistory] = useState(true)
  const [historyError, setHistoryError] = useState<string | null>(null)

  const [queueRead, setQueueRead] = useState<QueueRead | null>(null)
  const queue = queueRead?.keeperName === keeper.name && isEpochCurrent(queueRead.epoch)
    ? queueRead
    : null
  const queuedOps = queue?.operations ?? []
  const [draft, setDraft] = useState('')
  const [attachments, setAttachments] = useState<readonly ChatAttachmentDraft[]>([])
  const [sending, setSending] = useState(false)
  const [voiceBusy, setVoiceBusy] = useState(false)
  const [controlToken, setControlToken] = useState<string | null>(keeper.chat_control_token)
  const [companionOpen, setCompanionOpen] = useState(false)
  const [blockPrefs, setBlockPrefs] = useState<ChatBlockPrefs>(() => loadChatBlockPrefs())

  const updateBlockPrefs = useCallback((updater: (cur: ChatBlockPrefs) => ChatBlockPrefs) => {
    const cur = blockPrefsRef.current
    const next = updater(cur)
    blockPrefsRef.current = next
    saveChatBlockPrefs(next)
    setBlockPrefs(next)
    if (next.tools !== cur.tools) {
      autoOpenedGroupsRef.current.clear()
      expandedCardKeysRef.current = {}
      renderedOpenRef.current.clear()
      setExpandedCardKeys({})
    }
    if (next.thinking !== cur.thinking) {
      setExpandedThinkingKeys({})
    }
  }, [])

  const [btw, setBtw] = useState<BtwQueryState>({
    status: 'idle',
    prompt: '',
    reply: '',
    error: null,
  })
  const [btwOpen, setBtwOpen] = useState(false)
  const [btwInput, setBtwInput] = useState('')
  const [renderWindow, setRenderWindow] = useState(INITIAL_RENDER_WINDOW)
  const [isNearBottom, setIsNearBottom] = useState(true)
  const [unseenBelowCount, setUnseenBelowCount] = useState(0)
  const [toolResultCache, setToolResultCache] = useState<Record<string, ToolResultState>>({})
  const [expandedCardKeys, setExpandedCardKeys] = useState<Record<string, boolean>>({})
  const [expandedThinkingKeys, setExpandedThinkingKeys] = useState<Record<string, boolean>>({})
  const [expandedPreKeys, setExpandedPreKeys] = useState<Record<string, boolean>>({})
  const [copiedPreKey, setCopiedPreKey] = useState<string | null>(null)
  const [waitingInventory, setWaitingInventory] = useState<KeeperWaitingInventoryData | null>(null)
  const [livePreview, setLivePreview] = useState<{
    readonly ownerKey: string | null
    readonly preview: KeeperActiveTurnPreview
  } | null>(null)
  const [liveToolPulse, setLiveToolPulse] = useState<KeeperLiveToolPulse | null>(null)

  const chatListRef = useRef<HTMLDivElement>(null)
  const chatFeedRef = useRef<HTMLDivElement>(null)
  const composerRef = useRef<HTMLTextAreaElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const voiceInputRef = useRef<HTMLInputElement>(null)
  const streamAbortRef = useRef<AbortController | null>(null)
  const btwAbortRef = useRef<AbortController | null>(null)
  const sendingRef = useRef(false)
  const sendingOperationRef = useRef<{ operationId: string; executionId: string } | null>(null)
  const refreshChatRef = useRef<(...reads: ChatRead[]) => void>(() => {})
  const retryQueueRef = useRef<() => void>(() => {})
  const stickToBottomRef = useRef(true)
  const forceScrollBottomRef = useRef(true)
  const pendingPrependAnchorRef = useRef<{ readonly prevScrollHeight: number; readonly prevScrollTop: number } | null>(null)
  const prevTailSigRef = useRef('')
  const mountedRef = useRef(true)
  const activeKeeperRef = useRef(keeper.name)
  const hasLoadedEarlierRef = useRef(false)
  const earlierAbortRef = useRef<AbortController | null>(null)
  const earlierGenRef = useRef(0)
  const requestedExecIdsRef = useRef<Set<string>>(new Set())
  const toolFetchControllersRef = useRef<Map<string, AbortController>>(new Map())
  const toolResultCacheRef = useRef<Record<string, ToolResultState>>(toolResultCache)
  toolResultCacheRef.current = toolResultCache
  const expandedCardKeysRef = useRef<Record<string, boolean>>(expandedCardKeys)
  expandedCardKeysRef.current = expandedCardKeys
  const blockPrefsRef = useRef<ChatBlockPrefs>(blockPrefs)
  blockPrefsRef.current = blockPrefs
  const autoOpenedGroupsRef = useRef<Set<string>>(new Set())
  const renderedOpenRef = useRef<Map<string, boolean>>(new Map())
  const copyTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // NOTE: Intentionally keep evicted keys in `requestedExecIdsRef` so auto-hydration
  // never thrash-fetches in an infinite loop when >MAX_TOOL_RESULT_CACHE cards stay open.
  // Explicit user clicks ("실행 결과 불러오기") and manual re-toggles pass `force = true`.
  const updateToolResultCache = useCallback((key: string, entry: ToolResultState) => {
    toolResultCacheRef.current = setBoundedToolResultCache(toolResultCacheRef.current, key, entry)
    setToolResultCache((prev) => {
      const next = setBoundedToolResultCache(prev, key, entry)
      toolResultCacheRef.current = next
      return next
    })
  }, [])

  const resetToolResultCache = useCallback(() => {
    toolResultCacheRef.current = {}
    setToolResultCache({})
  }, [])

  const resetExpandUiState = useCallback(() => {
    autoOpenedGroupsRef.current.clear()
    renderedOpenRef.current.clear()
    expandedCardKeysRef.current = {}
    setExpandedCardKeys({})
    setExpandedThinkingKeys({})
    setExpandedPreKeys({})
    setCopiedPreKey(null)
    if (copyTimerRef.current) {
      clearTimeout(copyTimerRef.current)
      copyTimerRef.current = null
    }
  }, [])

  const setCardExpanded = useCallback((cardKey: string, open: boolean, executionId?: string) => {
    const trimmedExec = executionId?.trim() || ''
    const execKey = trimmedExec ? `exec:${trimmedExec}` : ''
    const curRef = expandedCardKeysRef.current
    if (curRef[cardKey] !== open || (execKey && curRef[execKey] !== open)) {
      const syncNext: Record<string, boolean> = { ...curRef, [cardKey]: open }
      if (execKey) syncNext[execKey] = open
      expandedCardKeysRef.current = syncNext
    }
    setExpandedCardKeys((prev) => {
      if (prev[cardKey] === open && (!execKey || prev[execKey] === open)) {
        return prev
      }
      const next: Record<string, boolean> = { ...prev, [cardKey]: open }
      if (execKey) next[execKey] = open
      expandedCardKeysRef.current = next
      return next
    })
  }, [])

  const handleCopyPre = useCallback(async (preKey: string, text: string) => {
    const ok = await copyTextToClipboard(text)
    if (!ok || !mountedRef.current) return
    setCopiedPreKey(preKey)
    if (copyTimerRef.current) clearTimeout(copyTimerRef.current)
    copyTimerRef.current = setTimeout(() => {
      copyTimerRef.current = null
      if (mountedRef.current) setCopiedPreKey(null)
    }, 1500)
  }, [])

  const scrollToBottom = useCallback((behavior: ScrollBehavior = 'auto') => {
    const el = chatListRef.current
    if (!el) return
    stickToBottomRef.current = true
    setIsNearBottom(true)
    setUnseenBelowCount(0)
    if (behavior === 'auto' || typeof el.scrollTo !== 'function') {
      el.scrollTop = el.scrollHeight
    } else {
      el.scrollTo({ top: el.scrollHeight, behavior })
    }
  }, [])

  useEffect(() => {
    const feed = chatFeedRef.current
    if (!feed || typeof ResizeObserver === 'undefined') return
    const observer = new ResizeObserver(() => {
      if (stickToBottomRef.current) scrollToBottom()
    })
    observer.observe(feed)
    return () => observer.disconnect()
  }, [scrollToBottom])

  const handleChatScroll = useCallback(() => {
    const el = chatListRef.current
    if (!el) return
    const distanceFromBottom = el.scrollHeight - el.scrollTop - el.clientHeight
    const near = distanceFromBottom <= BOTTOM_STICKY_THRESHOLD_PX
    stickToBottomRef.current = near
    setIsNearBottom(near)
    if (near) setUnseenBelowCount(0)
  }, [])

  const abortAllToolFetches = useCallback(() => {
    for (const ctrl of toolFetchControllersRef.current.values()) {
      ctrl.abort()
    }
    toolFetchControllersRef.current.clear()
  }, [])

  const invalidateEarlierReads = useCallback(() => {
    earlierGenRef.current += 1
    earlierAbortRef.current?.abort()
    earlierAbortRef.current = null
  }, [])

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      invalidateEarlierReads()
      abortAllToolFetches()
      if (copyTimerRef.current) {
        clearTimeout(copyTimerRef.current)
        copyTimerRef.current = null
      }
    }
  }, [abortAllToolFetches, invalidateEarlierReads])

  useEffect(() => {
    const switchedKeeper = activeKeeperRef.current !== keeper.name
    activeKeeperRef.current = keeper.name
    stickToBottomRef.current = true
    forceScrollBottomRef.current = true
    pendingPrependAnchorRef.current = null
    setRenderWindow(INITIAL_RENDER_WINDOW)
    setIsNearBottom(true)
    setUnseenBelowCount(0)
    hasLoadedEarlierRef.current = false
    invalidateEarlierReads()
    abortAllToolFetches()
    requestedExecIdsRef.current.clear()
    resetToolResultCache()
    resetExpandUiState()
    setWaitingInventory(null)
    setLivePreview(null)
    setLiveToolPulse(null)
    if (switchedKeeper) {
      setMessages([])
      setHasMore(false)
      setNextCursor(null)
      setQueueRead(null)
    }
  }, [keeper.name, abortAllToolFetches, invalidateEarlierReads, resetToolResultCache, resetExpandUiState])

  useEffect(() => {
    let lastEpoch = currentSessionEpoch()
    return sessionEpoch.subscribe((ep) => {
      if (ep !== lastEpoch) {
        lastEpoch = ep
        hasLoadedEarlierRef.current = false
        invalidateEarlierReads()
        streamAbortRef.current?.abort('session_epoch_changed')
        btwAbortRef.current?.abort('session_epoch_changed')
        abortAllToolFetches()
        requestedExecIdsRef.current.clear()
        resetToolResultCache()
        resetExpandUiState()
      }
    })
  }, [abortAllToolFetches, invalidateEarlierReads, resetToolResultCache, resetExpandUiState])

  useEffect(() => {
    if (!keeper.active_turn) {
      setLivePreview(null)
      setLiveToolPulse(null)
    }
  }, [keeper.active_turn])

  const requestToolResult = useCallback(async (executionId: string, force = false) => {
    const trimmed = executionId.trim()
    if (!trimmed) return
    if (!force && (requestedExecIdsRef.current.has(trimmed) || toolFetchControllersRef.current.has(trimmed))) {
      return
    }
    if (force) {
      toolFetchControllersRef.current.get(trimmed)?.abort()
      toolFetchControllersRef.current.delete(trimmed)
    }
    requestedExecIdsRef.current.add(trimmed)
    const targetKeeper = keeper.name
    const startEpoch = currentSessionEpoch()
    const ctrl = new AbortController()
    toolFetchControllersRef.current.set(trimmed, ctrl)
    updateToolResultCache(trimmed, { status: 'loading' })
    try {
      const res = await fetchKeeperToolResultApi(targetKeeper, trimmed, TOOL_RESULT_PAGE_BYTES, ctrl.signal)
      if (
        !mountedRef.current
        || activeKeeperRef.current !== targetKeeper
        || !isEpochCurrent(startEpoch)
        || toolFetchControllersRef.current.get(trimmed) !== ctrl
        || ctrl.signal.aborted
      ) {
        if (toolFetchControllersRef.current.get(trimmed) === ctrl) {
          requestedExecIdsRef.current.delete(trimmed)
        }
        return
      }
      if (!res.ok) {
        requestedExecIdsRef.current.delete(trimmed)
        if (res.error.kind === 'epoch_stale' || res.error.kind === 'aborted') return
        updateToolResultCache(trimmed, applyToolResultError(undefined, res.error))
        return
      }
      const payload = res.value
      if (payload.state === 'pending') {
        requestedExecIdsRef.current.delete(trimmed)
      }
      updateToolResultCache(trimmed, applyToolResultPage(undefined, payload))
    } finally {
      if (toolFetchControllersRef.current.get(trimmed) === ctrl) {
        toolFetchControllersRef.current.delete(trimmed)
      }
    }
  }, [keeper.name, updateToolResultCache])

  const loadMoreToolResult = useCallback(async (executionId: string, maxPages: number) => {
    const trimmed = executionId.trim()
    if (!trimmed) return
    if (toolFetchControllersRef.current.has(trimmed)) return
    const current = toolResultCacheRef.current[trimmed]
    if (!current || current.status !== 'loaded' || current.eof || current.isBinary) return
    const targetKeeper = keeper.name
    const startEpoch = currentSessionEpoch()
    const ctrl = new AbortController()
    toolFetchControllersRef.current.set(trimmed, ctrl)
    const isCurrent = () =>
      mountedRef.current
      && activeKeeperRef.current === targetKeeper
      && isEpochCurrent(startEpoch)
      && toolFetchControllersRef.current.get(trimmed) === ctrl
      && !ctrl.signal.aborted
    try {
      await fetchToolResultContinuation({
        keeperName: targetKeeper,
        executionId: trimmed,
        initialState: current,
        maxPages,
        signal: ctrl.signal,
        isCurrent,
        onUpdate: (next) => {
          if (isCurrent()) updateToolResultCache(trimmed, next)
        },
      })
    } finally {
      if (toolFetchControllersRef.current.get(trimmed) === ctrl) {
        toolFetchControllersRef.current.delete(trimmed)
      }
    }
  }, [keeper.name, updateToolResultCache])

  useEffect(() => {
    setControlToken(keeper.chat_control_token)
  }, [keeper.chat_control_token])

  useEffect(() => {
    let stopped = false
    let drainScheduled = false
    const pending = new Set<ChatRead>()
    const running = new Map<ChatRead, AbortController>()

    const abortReads = () => {
      for (const controller of running.values()) controller.abort()
      running.clear()
      pending.clear()
    }

    const refresh = (...reads: ChatRead[]) => {
      if (stopped) return
      for (const read of reads) pending.add(read)
      if (reads.includes('queue')) {
        const epoch = currentSessionEpoch()
        setQueueRead((previous) => ({
          keeperName: keeper.name,
          epoch,
          kind: 'loading',
          operations: previous?.keeperName === keeper.name && previous.epoch === epoch
            ? previous.operations
            : [],
        }))
      }
      if (drainScheduled) return
      drainScheduled = true
      queueMicrotask(() => {
        drainScheduled = false
        if (stopped) return
        for (const read of pending) {
          if (running.has(read)) continue
          pending.delete(read)
          const controller = new AbortController()
          running.set(read, controller)
          const signal = controller.signal
          const epoch = currentSessionEpoch()
          const current = () => !signal.aborted
            && activeKeeperRef.current === keeper.name && isEpochCurrent(epoch)
          void readChat(read, signal, epoch, current).finally(() => {
            if (!current()) return
            running.delete(read)
            if (pending.has(read)) refresh()
          })
        }
      })
    }

    const readChat = async (read: ChatRead, signal: AbortSignal, epoch: number, current: () => boolean) => {
      switch (read) {
        case 'history': {
          const result = await fetchKeeperChatHistoryPageApi(keeper.name, undefined, 40, signal)
          if (!current()) return
          setLoadingHistory(false)
          setHistoryError(result.ok ? null : result.error.message)
          if (result.ok) {
            const authoritativeEmpty = result.value.messages.length === 0
            if (authoritativeEmpty) {
              invalidateEarlierReads()
              hasLoadedEarlierRef.current = false
            }
            setMessages((previous) => mergeLatestHistoryPage(
              previous, result.value.messages, sendingOperationRef.current,
            ))
            if (authoritativeEmpty || !hasLoadedEarlierRef.current) {
              setHasMore(authoritativeEmpty ? false : result.value.hasMore)
              setNextCursor(authoritativeEmpty ? null : result.value.nextCursor)
            }
          }
          return
        }
        case 'queue': {
          const result = await fetchQueuedChatOperations(keeper.name, signal)
          if (!current()) return
          const anotherReadPending = pending.has('queue')
          if (result.ok) {
            setQueueRead({
              keeperName: keeper.name,
              epoch,
              kind: anotherReadPending ? 'loading' : 'ready',
              operations: result.value,
            })
          } else {
            const { kind, message } = result.error
            const clear = kind === 'unauthorized' || kind === 'forbidden' || kind === 'epoch_stale'
            setQueueRead((previous) => {
              const operations = !clear && previous?.keeperName === keeper.name && previous.epoch === epoch
                ? previous.operations
                : []
              const scope = { keeperName: keeper.name, epoch, operations }
              return anotherReadPending ? { ...scope, kind: 'loading' } : { ...scope, kind: 'error', message }
            })
          }
          return
        }
        case 'waiting': {
          const result = await fetchKeeperWaitingInventoryApi(keeper.name, signal)
          if (current() && result.ok) setWaitingInventory(result.value)
          return
        }
      }
    }

    const recover = () => {
      // The preceding connection's reads cannot settle this observation.
      abortReads()
      invalidateEarlierReads()
      setLivePreview(null)
      setLiveToolPulse(null)
      refresh('history', 'queue', 'waiting')
    }

    refreshChatRef.current = refresh
    retryQueueRef.current = () => {
      running.get('queue')?.abort()
      running.delete('queue')
      refresh('queue')
    }
    const unsubscribeFrames = subscribeObserverFrames((frame) => {
      const event = parseKeeperLiveObserverEvent(frame.event, frame.data, keeper.name)
      switch (event?.kind) {
        case 'turn_preview':
          setLivePreview((prev) => {
            if (prev !== null && prev.ownerKey === event.ownerKey
                && prev.preview.revision !== null && event.preview.revision !== null
                && event.preview.revision < prev.preview.revision) return prev
            return { ownerKey: event.ownerKey, preview: event.preview }
          })
          break
        case 'turn_ended':
          setLivePreview(null)
          setLiveToolPulse(null)
          break
        case 'tool_pulse':
          setLiveToolPulse(event.pulse)
          break
        case 'chat_appended':
          refresh('history')
          break
        case 'waiting_changed':
          refresh('waiting')
          if (event.queueChanged) refresh('queue')
          break
        case undefined:
          break
      }
    })
    const unsubscribeResync = subscribeObserverResync(recover)
    let wasConnected = observerConnected.peek()
    const unsubscribeConnection = observerConnected.subscribe((connected) => {
      if (connected && !wasConnected) recover()
      wasConnected = connected
    })
    let epoch = currentSessionEpoch()
    const unsubscribeEpoch = sessionEpoch.subscribe((nextEpoch) => {
      if (nextEpoch === epoch) return
      epoch = nextEpoch
      setMessages([])
      setQueueRead(null)
      setHasMore(false)
      setNextCursor(null)
      setWaitingInventory(null)
      setHistoryError(null)
      setLoadingHistory(true)
      recover()
    })
    setLoadingHistory(true)
    setHistoryError(null)
    refresh('history', 'queue', 'waiting')
    return () => {
      stopped = true
      abortReads()
      invalidateEarlierReads()
      unsubscribeFrames()
      unsubscribeResync()
      unsubscribeConnection()
      unsubscribeEpoch()
      refreshChatRef.current = () => {}
      retryQueueRef.current = () => {}
      streamAbortRef.current?.abort()
      btwAbortRef.current?.abort()
    }
  }, [keeper.name, invalidateEarlierReads])

  const updateQueueOperation = async (
    operationId: string,
    action: typeof moveQueuedChatOperationToEndApi,
  ) => {
    if (queue?.kind !== 'ready' || !isEpochCurrent(queue.epoch) || activeKeeperRef.current !== keeper.name) return
    await action(keeper.name, operationId)
    if (mountedRef.current && activeKeeperRef.current === keeper.name && isEpochCurrent(queue.epoch)) {
      refreshChatRef.current('queue', 'waiting')
    }
  }

  // Global shortcuts: ⌘. / Ctrl+. (Debug Companion) and Alt+T (Thinking block visibility)
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.isComposing || e.keyCode === 229) return
      if (typeof document !== 'undefined' && document.querySelector('[role="dialog"][aria-modal="true"]')) return
      if ((e.metaKey || e.ctrlKey) && !e.altKey && e.key === '.') {
        e.preventDefault()
        setCompanionOpen((prev) => !prev)
        return
      }
      if (e.altKey && !e.metaKey && !e.ctrlKey && !e.shiftKey && (e.code === 'KeyT' || e.key.toLowerCase() === 't')) {
        e.preventDefault()
        updateBlockPrefs((cur) => ({ ...cur, thinking: nextThinkingMode(cur.thinking) }))
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [updateBlockPrefs])

  const handleLoadEarlier = async () => {
    if (!nextCursor || loadingHistory) return
    const targetKeeper = keeper.name
    const startEpoch = currentSessionEpoch()
    earlierAbortRef.current?.abort()
    const ctrl = new AbortController()
    earlierAbortRef.current = ctrl
    const reqGen = ++earlierGenRef.current
    setLoadingHistory(true)
    const res = await fetchKeeperChatHistoryPageApi(targetKeeper, nextCursor, 40, ctrl.signal)
    if (
      !mountedRef.current
      || activeKeeperRef.current !== targetKeeper
      || !isEpochCurrent(startEpoch)
      || ctrl.signal.aborted
      || reqGen !== earlierGenRef.current
    ) {
      return
    }
    if (earlierAbortRef.current === ctrl) {
      earlierAbortRef.current = null
    }
    setLoadingHistory(false)
    if (!res.ok) {
      if (res.error.kind !== 'epoch_stale' && res.error.kind !== 'aborted') {
        setHistoryError(res.error.message)
      }
      return
    }
    const el = chatListRef.current
    if (el) {
      pendingPrependAnchorRef.current = {
        prevScrollHeight: el.scrollHeight,
        prevScrollTop: el.scrollTop,
      }
    }
    setRenderWindow((cur) => Math.min(MAX_RENDER_WINDOW, cur + res.value.messages.length))
    hasLoadedEarlierRef.current = true
    setMessages((prev) => {
      const existingIds = new Set(prev.map((m) => m.id))
      const fresh = res.value.messages.filter((m) => !existingIds.has(m.id))
      return [...dedupeHistoryToolRows([...fresh, ...prev])]
    })
    setHasMore(res.value.hasMore)
    setNextCursor(res.value.nextCursor)
  }

  const updateEntryById = (
    entryId: string,
    updater: (cur: ChatTranscriptEntry) => ChatTranscriptEntry,
  ) => {
    setMessages((prev) => prev.map((m) => (m.id === entryId ? updater(m) : m)))
  }

  const updateAssistantEntry = updateEntryById

  const handleRecoverCut = async (assistantId: string, operationId: string) => {
    const targetKeeper = keeper.name
    const startEpoch = currentSessionEpoch()
    updateAssistantEntry(assistantId, (m) => ({
      ...m,
      deliveryState: 'Confirming_delivery',
    }))
    const recovered = await recoverCutReplyFromJournal(targetKeeper, operationId)
    if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch)) return
    if (!recovered.ok) {
      if (recovered.error.kind === 'epoch_stale' || recovered.error.kind === 'aborted') return
      updateAssistantEntry(assistantId, (m) => ({
        ...m,
        deliveryState: 'Failed',
        errorDetail: `저널 복구 실패: ${recovered.error.message}`,
      }))
      return
    }
    updateAssistantEntry(assistantId, (m) => ({
      ...m,
      content: recovered.value.text || m.content,
      replyOperationId: recovered.value.executionId ?? m.replyOperationId,
      deliveryState: recovered.value.error ? 'Failed' : 'Cut_recovered',
      cutStream: false,
      errorDetail: recovered.value.error ?? undefined,
    }))
    refreshChatRef.current('history')
  }

  const runBtwQuery = async (promptText: string) => {
    const trimmed = promptText.trim()
    if (!trimmed) return
    btwAbortRef.current?.abort()
    const btwController = new AbortController()
    btwAbortRef.current = btwController
    setBtwOpen(true)
    setBtw({ status: 'streaming', prompt: trimmed, reply: '', error: null })
    const operationId = `btw-${randomUuid()}`
    const outcome = await streamKeeperChat({
      keeper: keeper.name,
      message: trimmed,
      operationId,
      mode: { kind: 'btw' },
      signal: btwController.signal,
      callbacks: {
        onTextDelta: (delta) => {
          setBtw((cur) => ({ ...cur, reply: cur.reply + delta }))
        },
        onReplyDetails: (reply) => {
          setBtw((cur) => ({ ...cur, reply: reply || cur.reply }))
        },
        onError: (msg) => {
          setBtw((cur) => ({ ...cur, status: 'error', error: msg }))
        },
        onFinished: () => {
          setBtw((cur) => ({ ...cur, status: cur.status === 'error' ? 'error' : 'done' }))
        },
      },
    })
    if (!outcome.terminal && !outcome.error && !btwController.signal.aborted) {
      const rec = await recoverCutReplyFromJournal(keeper.name, operationId)
      if (rec.ok && !btwController.signal.aborted) {
        setBtw((cur) => ({
          ...cur,
          status: rec.value.error ? 'error' : 'done',
          reply: rec.value.text || cur.reply,
          error: rec.value.error,
        }))
      }
    }
  }

  const submitMessage = async (intent: 'queue' | 'steer') => {
    if (sendingRef.current || sending) return
    const trimmed = draft.trim()
    if (!trimmed && attachments.length === 0) return

    // `/btw <question>` shortcut inside main composer
    if (trimmed.startsWith('/btw ')) {
      const sidePrompt = trimmed.slice(5).trim()
      setDraft('')
      await runBtwQuery(sidePrompt)
      return
    }

    const targetKeeper = keeper.name
    const startEpoch = currentSessionEpoch()
    const operationId = `op-${randomUuid()}`
    const nowSec = Date.now() / 1000
    const userId = `user-${operationId}`
    const userEntry: ChatTranscriptEntry = {
      id: userId,
      role: 'user',
      speakerLabel: 'Operator',
      content: trimmed,
      ts: nowSec,
      operationId,
      deliveryState: 'Sending',
    }
    const assistantId = `asst-${operationId}`
    const assistantEntry: ChatTranscriptEntry = {
      id: assistantId,
      role: 'assistant',
      content: '',
      ts: nowSec,
      operationId,
      deliveryState: 'Sending',
    }

    const currentAttachments = [...attachments]
    let acceptedByServer = false
    sendingRef.current = true
    sendingOperationRef.current = { operationId, executionId: operationId }
    forceScrollBottomRef.current = true
    setMessages((prev) => [...prev, userEntry, assistantEntry])
    setDraft('')
    setAttachments([])
    setSending(true)
    queueMicrotask(() => composerRef.current?.focus())

    let abortController: AbortController | null = null
    let outcome: { readonly terminal: boolean; readonly error: string | null } = {
      terminal: false,
      error: null,
    }
    try {
      let submitMode: { readonly kind: 'queue' } | { readonly kind: 'steer'; readonly controlToken: string } = {
        kind: 'queue',
      }
      if (intent === 'steer') {
        const token = controlToken ?? (await fetchKeeperControlToken(targetKeeper))
        if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch)) {
          return
        }
        if (token) {
          setControlToken(token)
          submitMode = { kind: 'steer', controlToken: token }
        }
      }

      if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch)) {
        return
      }

      streamAbortRef.current?.abort()
      abortController = new AbortController()
      streamAbortRef.current = abortController

      const thinkingByBlock = new Map<string, string>()
      let liveTools: readonly ChatToolBlock[] = []
      const promoteStreaming = (cur: ChatDeliveryState | undefined): ChatDeliveryState =>
        cur === 'Failed' || cur === 'Delivered' ? cur : 'Streaming'
      const markUserDelivered = () => {
        acceptedByServer = true
        updateEntryById(userId, (m) =>
          m.deliveryState === 'Delivered' ? m : { ...m, deliveryState: 'Delivered' },
        )
      }

      outcome = await streamKeeperChat({
        keeper: targetKeeper,
        message: trimmed,
        operationId,
        mode: submitMode,
        attachments: currentAttachments,
        signal: abortController.signal,
        callbacks: {
          onBatchBound: (memberId, executionId) => {
            if (memberId !== operationId) return
            sendingOperationRef.current = { operationId, executionId }
            updateAssistantEntry(assistantId, (entry) => ({ ...entry, replyOperationId: executionId }))
          },
          onAccepted: (info) => {
            acceptedByServer = true
            if (info.controlToken) setControlToken(info.controlToken)
            const nextState: ChatDeliveryState =
              info.state === 'Queued'
                ? 'Queued'
                : info.state === 'Running'
                  ? 'Pending_processing'
                  : 'Delivered'
            updateEntryById(userId, (m) => ({
              ...m,
              deliveryState: info.state === 'Queued' ? 'Queued' : 'Delivered',
            }))
            updateAssistantEntry(assistantId, (m) => ({ ...m, deliveryState: nextState }))
          },
          onRunStarted: () => {
            markUserDelivered()
            updateAssistantEntry(assistantId, (m) => ({ ...m, deliveryState: 'Pending_processing' }))
          },
          onAttemptStarted: () => {
            markUserDelivered()
            thinkingByBlock.clear()
            liveTools = []
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              content: '',
              thinking: undefined,
              toolCalls: undefined,
              deliveryState: 'Streaming',
            }))
          },
          onModelActivity: () => {
            markUserDelivered()
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: promoteStreaming(m.deliveryState),
            }))
          },
          onTextDelta: (delta) => {
            markUserDelivered()
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              content: m.content + delta,
              deliveryState: 'Streaming',
            }))
          },
          onThinkingDelta: (delta, blockKey = '0:0:0') => {
            markUserDelivered()
            thinkingByBlock.set(blockKey, (thinkingByBlock.get(blockKey) ?? '') + delta)
            const combined = joinThinkingMap(thinkingByBlock)
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              thinking: combined,
              deliveryState: promoteStreaming(m.deliveryState),
            }))
          },
          onRetainedImages: (retainedImages) => {
            if (retainedImages.length > 0) markUserDelivered()
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              retainedImages,
              deliveryState: retainedImages.length > 0 ? promoteStreaming(m.deliveryState) : m.deliveryState,
            }))
          },
          onThinkingSnapshot: (snapshot, blockKey = '0:0:0') => {
            markUserDelivered()
            thinkingByBlock.set(blockKey, snapshot)
            const combined = joinThinkingMap(thinkingByBlock)
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              thinking: combined,
              deliveryState: promoteStreaming(m.deliveryState),
            }))
          },
          onToolStart: (toolName, toolCallId, streamKey) => {
            liveTools = upsertStreamToolCall(
              liveTools,
              { toolCallId, streamKey },
              (cur) => ({
                ...cur,
                id: toolCallId ?? cur.id,
                streamKey: cur.streamKey ?? streamKey,
                name: toolName || cur.name,
                status: 'running',
              }),
              () => ({
                id: toolCallId,
                streamKey,
                name: toolName,
                status: 'running',
              }),
            )
            const snapshotTools = liveTools
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: promoteStreaming(m.deliveryState),
              toolCalls: snapshotTools,
            }))
          },
          onToolAdmitted: (toolName, toolCallId, streamKey) => {
            const prevIdx = findToolCallIndex(liveTools, { toolCallId, streamKey })
            const prevStreamKey = prevIdx >= 0 ? liveTools[prevIdx]!.streamKey : undefined
            liveTools = upsertStreamToolCall(
              liveTools,
              { toolCallId, streamKey },
              (cur) => ({
                ...cur,
                id: toolCallId ?? cur.id,
                streamKey: cur.streamKey ?? streamKey,
                name: toolName,
              }),
            )
            if (prevIdx >= 0 && !prevStreamKey && streamKey) {
              const oldKey = `${assistantId}:tool:${prevIdx}`
              const newKey = `${assistantId}:tool:${streamKey}`
              const prevOpen = expandedCardKeysRef.current[oldKey]
              if (prevOpen !== undefined) {
                setCardExpanded(newKey, prevOpen)
              }
            }
            const snapshotTools = liveTools
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              toolCalls: snapshotTools,
            }))
          },
          onToolArgsDelta: (toolCallId, delta, streamKey) => {
            liveTools = upsertStreamToolCall(
              liveTools,
              { toolCallId, streamKey },
              (cur) => ({ ...cur, args: (cur.args ?? '') + delta }),
            )
            const snapshotTools = liveTools
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: promoteStreaming(m.deliveryState),
              toolCalls: snapshotTools,
            }))
          },
          onToolArgsSnapshot: (toolCallId, snapshot, streamKey) => {
            liveTools = upsertStreamToolCall(
              liveTools,
              { toolCallId, streamKey },
              (cur) => ({ ...cur, args: snapshot }),
            )
            const snapshotTools = liveTools
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: promoteStreaming(m.deliveryState),
              toolCalls: snapshotTools,
            }))
          },
          onToolEnd: (toolCallId, streamKey) => {
            liveTools = upsertStreamToolCall(
              liveTools,
              { toolCallId, streamKey },
              (cur) => ({
                ...cur,
                status: cur.status === 'running' ? 'awaiting_result' : cur.status,
              }),
            )
            const snapshotTools = liveTools
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              toolCalls: snapshotTools,
            }))
          },
          onToolResultReady: ({ executionId, toolCallId, streamKey }) => {
            liveTools = upsertStreamToolCall(
              liveTools,
              { toolCallId, streamKey },
              (cur) => ({
                ...cur,
                executionId,
                status: cur.status === 'error' ? 'error' : 'completed',
              }),
              () => ({
                id: toolCallId,
                streamKey,
                executionId,
                name: 'tool',
                status: 'completed',
              }),
            )
            const matchedIdx = findToolCallIndex(liveTools, { toolCallId, streamKey })
            const slotIdx = matchedIdx >= 0 ? matchedIdx : Math.max(0, liveTools.length - 1)
            const matchedBlock = liveTools[slotIdx]
            const cardKey = `${assistantId}:tool:${matchedBlock?.streamKey ?? slotIdx}`
            const explicitOpen = expandedCardKeysRef.current[cardKey]
            const isCardOpen = explicitOpen !== undefined
              ? explicitOpen
              : blockPrefsRef.current.tools === 'full'
            if (explicitOpen !== undefined) {
              setCardExpanded(cardKey, explicitOpen, executionId)
            }
            const snapshotTools = liveTools
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              toolCalls: snapshotTools,
            }))
            if (blockPrefsRef.current.tools !== 'hidden' && isCardOpen && !matchedBlock?.result) {
              void requestToolResult(executionId)
            }
          },
          onToolResult: (toolCallId, content, streamKey) => {
            liveTools = upsertStreamToolCall(
              liveTools,
              { toolCallId, streamKey },
              (cur) => ({ ...cur, result: content, status: 'completed' }),
              () => ({
                id: toolCallId || undefined,
                streamKey,
                name: 'tool',
                result: content,
                status: 'completed',
              }),
            )
            const snapshotTools = liveTools
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              toolCalls: snapshotTools,
            }))
          },
          onNativeToolProgress: ({ toolName, toolCallId, streamKey, progressLabel }) => {
            liveTools = upsertStreamToolCall(
              liveTools,
              { toolCallId, streamKey },
              (cur) => ({
                ...cur,
                name: toolName ?? cur.name,
                progressLabel,
              }),
              () => ({
                id: toolCallId,
                streamKey,
                name: toolName ?? 'native_tool',
                status: 'running',
                progressLabel,
              }),
            )
            const snapshotTools = liveTools
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: promoteStreaming(m.deliveryState),
              toolCalls: snapshotTools,
            }))
          },
          onNativeToolEnd: ({ toolName, toolCallId, streamKey, status, summary }) => {
            liveTools = upsertStreamToolCall(
              liveTools,
              { toolCallId, streamKey },
              (cur) => ({
                ...cur,
                name: toolName ?? cur.name,
                status,
                progressLabel: summary ?? cur.progressLabel,
              }),
              () => ({
                id: toolCallId,
                streamKey,
                name: toolName ?? 'native_tool',
                status,
                progressLabel: summary,
              }),
            )
            const snapshotTools = liveTools
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              toolCalls: snapshotTools,
            }))
          },
          onToolApprovalRequested: ({ toolCallId, toolName, args, question, because }) => {
            const label = question ?? because ?? '운영자 승인 대기 중'
            const trimmedId = toolCallId.trim()
            const matchRef = trimmedId
              ? { toolCallId: trimmedId }
              : { streamKey: `approval:${randomUuid()}` }
            liveTools = upsertStreamToolCall(
              liveTools,
              matchRef,
              (cur) => ({
                ...cur,
                name: toolName || cur.name,
                args: args ?? cur.args,
                status: 'awaiting_approval',
                progressLabel: label,
              }),
              () => ({
                id: trimmedId || undefined,
                streamKey: matchRef.streamKey,
                name: toolName,
                args,
                status: 'awaiting_approval',
                progressLabel: label,
              }),
            )
            const snapshotTools = liveTools
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: promoteStreaming(m.deliveryState),
              toolCalls: snapshotTools,
            }))
          },
          onToolApprovalSettled: ({ toolCallId, toolName, outcome: approvalOutcome }) => {
            const normalizedOutcome = approvalOutcome.trim().toLowerCase()
            const approved =
              normalizedOutcome === 'approve' || normalizedOutcome === 'remembered_approve'
            const trimmedId = toolCallId.trim()
            if (trimmedId) {
              liveTools = upsertStreamToolCall(
                liveTools,
                { toolCallId: trimmedId },
                (cur) => ({
                  ...cur,
                  status: approved ? 'running' : 'error',
                  progressLabel: approvalOutcome,
                }),
              )
            } else {
              const list = [...liveTools]
              let targetIdx = -1
              for (let i = list.length - 1; i >= 0; i -= 1) {
                const cur = list[i]!
                if (cur.status !== 'awaiting_approval') continue
                if (!toolName || cur.name === toolName) {
                  targetIdx = i
                  break
                }
                if (targetIdx < 0) targetIdx = i
              }
              if (targetIdx >= 0) {
                list[targetIdx] = {
                  ...list[targetIdx]!,
                  status: approved ? 'running' : 'error',
                  progressLabel: approvalOutcome,
                }
                liveTools = list
              }
            }
            const snapshotTools = liveTools
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              toolCalls: snapshotTools.length > 0 ? snapshotTools : m.toolCalls,
            }))
          },
          onReplyDetails: (reply, turnRef) => {
            acceptedByServer = true
            updateEntryById(userId, (m) => (m.deliveryState === 'Delivered' ? m : { ...m, deliveryState: 'Delivered' }))
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              content: reply || m.content,
              turnRef: turnRef ?? m.turnRef,
            }))
          },
          onError: (msg) => {
            updateEntryById(userId, (m) => ({
              ...m,
              deliveryState: acceptedByServer ? 'Delivered' : 'Failed',
            }))
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: 'Failed',
              errorDetail: msg,
            }))
          },
          onFinished: () => {
            markUserDelivered()
            liveTools = liveTools.map((tc) =>
              tc.status === 'running' || tc.status === 'awaiting_result' || tc.status === 'awaiting_approval'
                ? { ...tc, status: 'completed' }
                : tc,
            )
            const snapshotTools = liveTools.length > 0 ? liveTools : undefined
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: m.deliveryState === 'Failed' ? 'Failed' : 'Delivered',
              toolCalls: snapshotTools ?? m.toolCalls?.map((tc) =>
                tc.status === 'running' || tc.status === 'awaiting_result' || tc.status === 'awaiting_approval'
                  ? { ...tc, status: 'completed' }
                  : tc,
              ),
            }))
          },
        },
      })
    } finally {
      sendingRef.current = false
      sendingOperationRef.current = null
      if (mountedRef.current) {
        setSending(false)
      }
    }

    if (
      !mountedRef.current
      || activeKeeperRef.current !== targetKeeper
      || !isEpochCurrent(startEpoch)
      || outcome.error === 'session_epoch_changed'
      || outcome.error === 'aborted'
    ) {
      return
    }

    // Mid-stream cut without RUN_FINISHED -> Confirming_delivery & journal recovery
    if (!outcome.terminal && !abortController?.signal.aborted) {
      updateEntryById(userId, (m) => (m.deliveryState === 'Sending' ? { ...m, deliveryState: 'Delivered' } : m))
      updateAssistantEntry(assistantId, (m) => ({
        ...m,
        cutStream: true,
        deliveryState: 'Confirming_delivery',
      }))
      await handleRecoverCut(assistantId, operationId)
    }

    if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch)) {
      return
    }

    refreshChatRef.current('history', 'queue', 'waiting')
    props.onMutated()
  }

  const handleComposerKeyDown = (e: KeyboardEvent) => {
    // Guard Korean/CJK IME composition & prevent double-submit while streaming
    if (e.isComposing || e.keyCode === 229) return
    if (e.key !== 'Enter') return
    if (e.shiftKey) return
    e.preventDefault()
    if (sendingRef.current || sending) return
    if (e.metaKey || e.ctrlKey) {
      void submitMessage('steer')
    } else {
      void submitMessage('queue')
    }
  }

  const handleAttachmentSelect = async (e: Event) => {
    const input = e.currentTarget as HTMLInputElement
    const files = input.files
    if (!files || files.length === 0) return
    const next: ChatAttachmentDraft[] = []
    for (const file of Array.from(files)) {
      const buf = await file.arrayBuffer()
      const bytes = new Uint8Array(buf)
      let bin = ''
      for (const b of bytes) bin += String.fromCharCode(b)
      const base64 = typeof btoa === 'function' ? btoa(bin) : ''
      next.push({
        id: randomUuid(),
        type: file.type.startsWith('image/') ? 'image' : 'file',
        name: file.name,
        size: file.size,
        mimeType: file.type || 'application/octet-stream',
        data: base64,
      })
    }
    setAttachments((prev) => [...prev, ...next])
    input.value = ''
  }

  const handleVoiceFile = async (e: Event) => {
    const input = e.currentTarget as HTMLInputElement
    const file = input.files?.[0]
    if (!file) return
    setVoiceBusy(true)
    try {
      const buf = await file.arrayBuffer()
      const res = await transcribeVoiceAudio(buf, file.type || 'audio/webm')
      if (res.ok && res.value.trim()) {
        setDraft((cur) => (cur.trim() ? `${cur.trim()} ${res.value.trim()}` : res.value.trim()))
      }
    } finally {
      setVoiceBusy(false)
      input.value = ''
    }
  }

  const ctxObs = observeRosterContextPct(keeper)
  const ctxPct = ctxObs.kind === 'value' ? ctxObs.data : null
  const ringOffset = ctxPct !== null
    ? RING_CIRCUMFERENCE * (1 - ctxPct / 100)
    : RING_CIRCUMFERENCE
  const ringTone = ctxPct === null ? 'absent' : ctxPct >= 85 ? 'bad' : ctxPct >= 65 ? 'warn' : 'ok'

  const recentSlice = messages.slice(-renderWindow)
  const parsedEntries = recentSlice.map((msg) => ({ msg, blocks: parseChatMessageBlocks(msg) }))
  const hiddenInternalCount = parsedEntries.filter(
    ({ blocks }) => blocks.isInternalOnly && blockPrefs.internal === 'hidden',
  ).length
  const visibleEntries = parsedEntries.filter(({ msg, blocks }) =>
    shouldRenderChatEntry(msg, blocks, blockPrefs),
  )
  const displayItems = groupTranscriptEntries(visibleEntries)

  // Bounded auto-hydration for `Tools: full` (latest 8 visible cards) plus
  // immediate hydration for explicitly user-opened cards once `executionId` attaches.
  const explicitExpandedExecIds: string[] = []
  const fullModeVisibleExecIds: string[] = []
  if (blockPrefs.tools !== 'hidden') {
    const collectHydrationTarget = (
      tb: ChatToolBlock,
      idx: number,
      keyPrefix: string,
      parentOpen: boolean,
    ) => {
      const eid = tb.executionId?.trim()
      if (!eid || tb.result) return
      const cardKey = `${keyPrefix}:tool:${tb.streamKey ?? idx}`
      const explicit = expandedCardKeys[cardKey] ?? expandedCardKeys[`exec:${eid}`]
      if (explicit === true) {
        explicitExpandedExecIds.push(eid)
      } else if (blockPrefs.tools === 'full' && explicit !== false && parentOpen) {
        fullModeVisibleExecIds.push(eid)
      }
    }

    for (const item of displayItems) {
      if (item.kind === 'tool_group') {
        if (item.toolBlocks.length === 1) {
          const singleEntry = item.entries[0]!
          collectHydrationTarget(singleEntry.blocks.toolBlocks[0]!, 0, singleEntry.msg.id, true)
        } else {
          const groupOpen = expandedCardKeys[item.id] ?? (blockPrefs.tools === 'full')
          for (const entry of item.entries) {
            entry.blocks.toolBlocks.forEach((tb, tbIdx) => {
              collectHydrationTarget(tb, tbIdx, entry.msg.id, groupOpen)
            })
          }
        }
      } else {
        const { msg, blocks } = item.entry
        if (blocks.toolBlocks.length === 1) {
          collectHydrationTarget(blocks.toolBlocks[0]!, 0, msg.id, true)
        } else if (blocks.toolBlocks.length > 1) {
          const turnGroupKey = `turn-tools:${msg.id}`
          const hasInFlight = blocks.toolBlocks.some(
            (tb) => tb.status === 'running' || tb.status === 'awaiting_result' || tb.status === 'awaiting_approval',
          )
          if (hasInFlight) autoOpenedGroupsRef.current.add(turnGroupKey)
          const groupOpen =
            expandedCardKeys[turnGroupKey]
            ?? (blockPrefs.tools === 'full' || autoOpenedGroupsRef.current.has(turnGroupKey))
          blocks.toolBlocks.forEach((tb, tbIdx) => {
            collectHydrationTarget(tb, tbIdx, msg.id, groupOpen)
          })
        }
      }
    }
  }
  const boundedFullExecIds = fullModeVisibleExecIds.slice(-MAX_AUTO_HYDRATE_TOOL_RESULTS)
  const autoHydrateTargets = Array.from(new Set([...explicitExpandedExecIds, ...boundedFullExecIds]))
  const autoHydrateKey = autoHydrateTargets.join('\0')

  useEffect(() => {
    if (!autoHydrateKey) return
    const targets = autoHydrateKey.split('\0').filter(Boolean)
    for (const eid of targets) {
      if (!toolResultCacheRef.current[eid] && !requestedExecIdsRef.current.has(eid)) {
        void requestToolResult(eid)
      }
    }
  }, [autoHydrateKey, keeper.name, blockPrefs.tools, requestToolResult])

  // Live autonomous / delegated / external turn status from roster + SSE preview override
  const activeTurn = keeper.active_turn
  const effectivePreview: KeeperActiveTurnPreview | null = livePreview?.preview ?? activeTurn?.preview ?? null
  const browserRequestQueued = sending && messages.some((entry) => entry.role === 'assistant'
    && entry.operationId === sendingOperationRef.current?.operationId && entry.deliveryState === 'Queued')
  const showLiveTurnCard = (!sending || browserRequestQueued) && (activeTurn !== null || effectivePreview !== null)
  const liveTurnActivity = formatTurnActivityLabel(effectivePreview?.activity)
  const liveTurnLaneLabel = activeTurn ? formatTurnLaneLabel(activeTurn.lane) : 'Keeper 턴'
  const lastObserved = effectivePreview ? formatChatTime(effectivePreview.updated_at_unix) : null
  const liveTurnElapsedSec = activeTurn
    ? (activeTurn.elapsed_ms !== null && activeTurn.elapsed_ms !== undefined
        ? Math.floor(activeTurn.elapsed_ms / 1000)
        : activeTurn.started_at_unix > 0
          ? Math.max(0, Math.floor(Date.now() / 1000 - activeTurn.started_at_unix))
          : null)
    : null
  const liveToolName =
    activeTurn?.tool_in_flight
    ?? liveToolPulse?.toolName
    ?? effectivePreview?.last_tool
    ?? null
  const isLiveToolInFlight = Boolean(
    activeTurn?.tool_in_flight
    || effectivePreview?.activity === 'tool'
    || effectivePreview?.activity === 'tool_observed',
  )

  const renderToolPreSection = (
    label: string,
    text: string,
    preKey: string,
    opts?: {
      readonly cachedRes?: ToolResultState
      readonly executionId?: string
    },
  ) => {
    const cachedRes = opts?.cachedRes
    const executionId = opts?.executionId
    const progressText = formatToolResultProgress(cachedRes)
    const isExpandedPre = expandedPreKeys[preKey] === true
    const isLong = isLongToolOutput(text)
    const markdown = opts && (cachedRes?.status !== 'loaded' || (cachedRes.eof && !cachedRes.isBinary))
      ? toolResultMarkdownPreview(text) : null
    const raw = html`<pre class=${isExpandedPre ? 'kp-block-pre kp-block-pre--expanded' : 'kp-block-pre'}>${text}</pre>`
    const showPager = Boolean(
      executionId
      && cachedRes?.status === 'loaded'
      && !cachedRes.eof
      && !cachedRes.isBinary,
    )
    return html`
      <div class="kp-block-subbar">
        <div class="kp-pill-row">
          <span class="kp-block-sublabel">
            ${label}${cachedRes?.status === 'loaded' && cachedRes.eof === false ? ' · 일부 표시' : ''}
          </span>
          ${progressText && html`
            <span class="kp-pill" data-tone=${cachedRes?.eof === false ? 'warn' : 'default'}>
              ${progressText}
            </span>
          `}
          ${cachedRes?.status === 'loaded' && cachedRes.isBinary && html`
            <span class="kp-pill">바이너리 · ${formatByteSize(cachedRes.totalBytes ?? cachedRes.recordedBytes ?? 0)}</span>
          `}
        </div>
        <div class="kp-block-subactions">
          <button
            type="button"
            class="btn-ghost kp-toggle-btn"
            onClick=${() => void handleCopyPre(preKey, text)}
          >
            ${copiedPreKey === preKey ? '복사됨' : '복사'}
          </button>
          ${isLong && html`
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              onClick=${() => setExpandedPreKeys((prev) => ({ ...prev, [preKey]: !prev[preKey] }))}
            >
              ${isExpandedPre ? '축소' : '전체 높이'}
            </button>
          `}
        </div>
      </div>
      ${markdown === null ? raw : html`
        <${MarkdownContent} text=${markdown} />
        <details open=${isExpandedPre || undefined}>
          <summary>저장 참조</summary>
          ${raw}
        </details>
      `}
      ${showPager && html`
        <div class="kp-tool-result-pager" data-testid="tool-result-pager">
          <span class="kp-pill" data-tone="warn">
            ${cachedRes?.loadingMore
              ? `불러오는 중… (${progressText ?? ''})`
              : progressText ?? '일부 표시'}
          </span>
          <div class="kp-block-subactions">
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              disabled=${cachedRes?.loadingMore === true}
              onClick=${() => void loadMoreToolResult(executionId!, 1)}
            >
              더 불러오기 (+16KB)
            </button>
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              disabled=${cachedRes?.loadingMore === true}
              onClick=${() => void loadMoreToolResult(executionId!, TOOL_RESULT_MAX_PAGES_PER_BURST)}
            >
              끝까지 불러오기
            </button>
          </div>
        </div>
      `}
      ${executionId && cachedRes?.status === 'loaded' && cachedRes.loadMoreError && html`
        <div class="kp-tool-result-error" role="status" data-testid="tool-result-load-more-error">
          <span>${cachedRes.loadMoreError}</span>
          <div class="kp-block-subactions">
            ${cachedRes.loadMoreConflict
              ? html`
                  <button
                    type="button"
                    class="btn-ghost kp-toggle-btn"
                    onClick=${() => void requestToolResult(executionId, true)}
                  >
                    처음부터 다시 불러오기
                  </button>
                `
              : html`
                  <button
                    type="button"
                    class="btn-ghost kp-toggle-btn"
                    onClick=${() => void loadMoreToolResult(executionId, 1)}
                  >
                    다시 시도
                  </button>
                  <button
                    type="button"
                    class="btn-ghost kp-toggle-btn"
                    onClick=${() => void requestToolResult(executionId, true)}
                  >
                    처음부터 다시 불러오기
                  </button>
                `}
          </div>
        </div>
      `}
    `
  }

  const renderToolResultStatus = (
    tb: ChatToolBlock,
    cachedRes: ToolResultState | undefined,
    displayArgs: string | undefined,
    displayResult: string | undefined,
    effectiveStatus: string | undefined,
    loadingLabel: string,
    hasInlineSummary: boolean,
  ) => html`
    ${!displayResult && cachedRes?.status === 'loaded' && html`
      <div class="kp-block-status">(빈 출력 · 0 B)</div>
    `}
    ${!displayResult && cachedRes?.status === 'loading' && html`
      <div class="kp-block-status">${loadingLabel}</div>
    `}
    ${!displayResult && cachedRes?.status === 'pending' && html`
      <div class="kp-block-status">
        도구 실행 중 — 결과 준비 대기 중…
        ${tb.executionId && html`
          ${' '}
          <button
            type="button"
            class="btn-ghost kp-toggle-btn"
            onClick=${() => void requestToolResult(tb.executionId!, true)}
          >
            다시 확인
          </button>
        `}
      </div>
    `}
    ${!displayResult && cachedRes?.status === 'unavailable' && html`
      <div class="kp-block-status">저장된 결과 없음 (${cachedRes.detail ?? 'unavailable'})</div>
    `}
    ${!displayResult && cachedRes?.status === 'error' && html`
      <div class="kp-block-status">
        결과 조회 실패 (${cachedRes.detail ?? 'error'})
        ${tb.executionId && html`
          ${' '}
          <button
            type="button"
            class="btn-ghost kp-toggle-btn"
            onClick=${() => void requestToolResult(tb.executionId!, true)}
          >
            ${cachedRes.sourceChanged ? '처음부터 다시 불러오기' : '다시 시도'}
          </button>
        `}
      </div>
    `}
    ${!displayResult && !cachedRes && tb.executionId && html`
      <div class="kp-block-status">
        <button
          type="button"
          class="btn-ghost kp-toggle-btn"
          onClick=${() => void requestToolResult(tb.executionId!, true)}
        >
          실행 결과 불러오기
        </button>
      </div>
    `}
    ${!hasInlineSummary && !displayArgs && !displayResult && !cachedRes && !tb.executionId && html`
      <div class="kp-block-status">
        ${tb.progressLabel
          ?? (effectiveStatus === 'running'
            ? '도구 실행 중…'
            : effectiveStatus === 'awaiting_result'
              ? '도구 호출 완료 — 결과 대기 중…'
              : effectiveStatus === 'awaiting_approval'
                ? '운영자 승인 대기 중…'
                : '기록된 입력·결과가 없습니다.')}
      </div>
    `}
  `

  const renderToolCard = (tb: ChatToolBlock, idx: number, keyPrefix: string) => {
    const cachedRes = tb.executionId ? toolResultCache[tb.executionId] : undefined
    const displayArgs = tb.args ? prettyFormatPayload(tb.args) : undefined
    const displayResult = tb.result ?? (cachedRes?.status === 'loaded' ? cachedRes.displayContent : undefined)
    const effectiveStatus =
      cachedRes?.status === 'loaded' && cachedRes.isError ? 'error' : tb.status
    const statusMeta = toolStatusMeta(effectiveStatus)
    const delegateInfo = extractDelegateCardInfo({
      ...tb,
      args: displayArgs ?? tb.args,
      result: displayResult ?? tb.result,
    })
    const cardKey = `${keyPrefix}:tool:${tb.streamKey ?? idx}`
    const isExpanded =
      expandedCardKeys[cardKey]
      ?? (tb.executionId ? expandedCardKeys[`exec:${tb.executionId}`] : undefined)
      ?? (blockPrefs.tools === 'full')
    renderedOpenRef.current.set(cardKey, isExpanded)

    const handleToggle = (e: Event) => {
      const el = e.currentTarget as HTMLDetailsElement
      // Ignore programmatic `open` attribute sync events (sync in happy-dom / async in browsers)
      // so switching `Tools: summary -> full` never triggers an unbounded fetch storm.
      if (el.open === renderedOpenRef.current.get(cardKey)) return
      renderedOpenRef.current.set(cardKey, el.open)
      setCardExpanded(cardKey, el.open, tb.executionId)
      if (
        el.open
        && tb.executionId
        && !displayResult
        && (!cachedRes || cachedRes.status === 'pending' || cachedRes.status === 'error')
      ) {
        void requestToolResult(tb.executionId, true)
      }
    }

    if (delegateInfo) {
      const actionTitle =
        delegateInfo.kind === 'delegate'
          ? '위임'
          : delegateInfo.kind === 'delegate_status'
            ? '위임 조회'
            : '위임 취소'
      const targetSuffix =
        delegateInfo.targetKeepers.length > 1
          ? ` → @${delegateInfo.targetKeepers[0]} 외 ${delegateInfo.targetKeepers.length - 1}명`
          : delegateInfo.targetKeeper
            ? ` → @${delegateInfo.targetKeeper}`
            : ''
      const delStatus = delegateInfo.delegateState ?? tb.progressLabel ?? statusMeta.label
      const rawDelegatePreview =
        delegateInfo.prompt
        ?? (delegateInfo.operationCount > 1 ? `대상 ${delegateInfo.operationCount}건` : null)
        ?? delegateInfo.operationId
        ?? delStatus
      const preview = summarizeCompact(
        typeof rawDelegatePreview === 'string' && rawDelegatePreview.length > 512
          ? rawDelegatePreview.slice(0, 512)
          : rawDelegatePreview,
        90,
      )
      const hasInlineSummary = Boolean(delegateInfo.prompt || delegateInfo.operationId || delegateInfo.operationCount > 0)
      const rawKey = `${cardKey}:raw`
      const isRawExpanded = expandedCardKeys[rawKey] === true
      renderedOpenRef.current.set(rawKey, isRawExpanded)
      return html`
        <div
          key=${cardKey}
          class="kp-collapsible-shell kp-block-card kp-block-card--delegate"
          data-testid="chat-delegate-card"
        >
          <details
            class="kp-collapsible-details"
            open=${isExpanded}
            onToggle=${handleToggle}
          >
            <summary class="kp-block-summary">
              <span class="kp-pill" data-tone="brass">
                ${actionTitle}${targetSuffix}
              </span>
              <span class="kp-pill" data-tone=${statusMeta.tone}>
                ${delStatus}${tb.duration ? ` · ${tb.duration}` : ''}
              </span>
              <span class="kp-block-preview">${preview}</span>
            </summary>
            <div class="kp-block-content">
              ${delegateInfo.prompt && html`
                <div class="kp-block-sublabel">위임 요청 내용</div>
                <div class="kp-delegate-prompt">${delegateInfo.prompt}</div>
              `}
              <div class="kp-pill-row">
                ${delegateInfo.operationCount > 1 && html`
                  <span class="kp-pill">조회 대상 ${delegateInfo.operationCount}건</span>
                `}
                ${delegateInfo.operationId && html`
                  <span class="kp-pill">op: ${delegateInfo.operationId}</span>
                `}
                ${delegateInfo.artifactCount > 0 && html`
                  <span class="kp-pill">아티팩트 ${delegateInfo.artifactCount}개</span>
                `}
                ${delegateInfo.targetTurnAgeSec !== null && html`
                  <span class="kp-pill" data-tone="warn">상대 턴 경과 ${formatElapsedCompact(delegateInfo.targetTurnAgeSec)}</span>
                `}
              </div>
              ${(displayArgs || displayResult) && html`
                <details
                  key=${rawKey}
                  class="kp-sub-details"
                  open=${isRawExpanded}
                  onToggle=${(e: Event) => {
                    const nextOpen = (e.currentTarget as HTMLDetailsElement).open
                    if (nextOpen === renderedOpenRef.current.get(rawKey)) return
                    renderedOpenRef.current.set(rawKey, nextOpen)
                    setCardExpanded(rawKey, nextOpen)
                  }}
                >
                  <summary class="kp-sub-summary">원본 입출력 (JSON)</summary>
                  <div class="kp-block-content">
                    ${displayArgs && renderToolPreSection('입력 (Args)', displayArgs, `${cardKey}:args`)}
                    ${displayResult && renderToolPreSection('결과 (Result)', displayResult, `${cardKey}:result`, {
                      cachedRes,
                      executionId: tb.executionId,
                    })}
                  </div>
                </details>
              `}
              ${renderToolResultStatus(
                tb,
                cachedRes,
                displayArgs,
                displayResult,
                effectiveStatus,
                '위임 응답 불러오는 중…',
                hasInlineSummary,
              )}
            </div>
          </details>
          ${delegateInfo.targetKeepers.length > 0 && props.onSelectKeeper && html`
            <div class="kp-collapsible-actions">
              ${delegateInfo.targetKeepers.map((target) => html`
                <button
                  key=${target}
                  type="button"
                  class="btn-ghost kp-toggle-btn kp-delegate-jump"
                  aria-label=${`${target} Keeper 대화로 이동`}
                  onClick=${() => props.onSelectKeeper?.(target)}
                >
                  @${target} ↗
                </button>
              `)}
            </div>
          `}
        </div>
      `
    }

    const rawPreviewSource = displayArgs ?? displayResult ?? tb.progressLabel ?? statusMeta.label
    const previewText = summarizeCompact(
      typeof rawPreviewSource === 'string' && rawPreviewSource.length > 512
        ? rawPreviewSource.slice(0, 512)
        : rawPreviewSource,
      90,
    )
    return html`
      <details
        key=${cardKey}
        class="kp-block-card kp-block-card--tool"
        data-testid="chat-tool-card"
        open=${isExpanded}
        onToggle=${handleToggle}
      >
        <summary class="kp-block-summary">
          <span class="kp-pill" data-tone=${statusMeta.tone}>도구 · ${tb.name}</span>
          <span class="kp-pill" data-tone=${statusMeta.tone}>
            ${tb.progressLabel ?? statusMeta.label}${tb.duration ? ` · ${tb.duration}` : ''}
          </span>
          <span class="kp-block-preview">${previewText}</span>
        </summary>
        <div class="kp-block-content">
          ${displayArgs && renderToolPreSection('입력 (Args)', displayArgs, `${cardKey}:args`)}
          ${displayResult && renderToolPreSection('결과 (Result)', displayResult, `${cardKey}:result`, {
            cachedRes,
            executionId: tb.executionId,
          })}
          ${renderToolResultStatus(
            tb,
            cachedRes,
            displayArgs,
            displayResult,
            effectiveStatus,
            '결과 불러오는 중…',
            false,
          )}
        </div>
      </details>
    `
  }

  const lastVisible = visibleEntries[visibleEntries.length - 1]?.msg
  const liveSig = showLiveTurnCard
    ? `live:${effectivePreview?.revision ?? 0}:${effectivePreview?.text_tail.length ?? 0}:${liveToolName ?? ''}`
    : ''
  const mediaSig = lastVisible?.retainedImages?.map(image => image.path).join(',') ?? ''
  const tailSig = lastVisible
    ? `${visibleEntries.length}:${lastVisible.id}:${lastVisible.content.length}:${lastVisible.thinking?.length ?? 0}:${lastVisible.toolCalls?.length ?? 0}:${lastVisible.deliveryState ?? ''}:${lastVisible.errorDetail ?? ''}:${mediaSig}:${liveSig}`
    : `${visibleEntries.length}:empty:${liveSig}`

  useLayoutEffect(() => {
    const el = chatListRef.current
    if (!el) return

    // Preserve exact viewport anchor when older history pages are prepended
    const anchor = pendingPrependAnchorRef.current
    if (anchor) {
      pendingPrependAnchorRef.current = null
      const delta = el.scrollHeight - anchor.prevScrollHeight
      el.scrollTop = anchor.prevScrollTop + Math.max(0, delta)
      prevTailSigRef.current = tailSig
      return
    }

    const tailChanged = tailSig !== prevTailSigRef.current
    prevTailSigRef.current = tailSig

    if (forceScrollBottomRef.current) {
      if (visibleEntries.length > 0 || !loadingHistory) {
        forceScrollBottomRef.current = false
        scrollToBottom('auto')
      }
      return
    }

    if (!tailChanged) return

    if (stickToBottomRef.current) {
      scrollToBottom('auto')
    } else if (visibleEntries.length > 0) {
      setUnseenBelowCount((c) => c + 1)
    }
  }, [tailSig, loadingHistory, visibleEntries.length, scrollToBottom])

  return html`
    <div class="kp-chat-shell" data-companion-open=${companionOpen ? 'true' : 'false'}>
      <div class="kp-chat-main">
        <div class="kp-chat-toolbar">
          <div class="kp-pill-row kp-chat-toggles">
            <span class="kp-pill" data-tone="info">Origin_bare · AG-UI SSE</span>
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              data-testid="chat-toggle-thinking"
              data-active=${blockPrefs.thinking !== 'hidden' ? 'true' : 'false'}
              title="추론 블록 표시 모드 전환 (Alt+T)"
              onClick=${() => updateBlockPrefs((cur) => ({ ...cur, thinking: nextThinkingMode(cur.thinking) }))}
            >
              추론: ${thinkingModeLabel(blockPrefs.thinking)} (Alt+T)
            </button>
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              data-testid="chat-toggle-tools"
              data-active=${blockPrefs.tools !== 'hidden' ? 'true' : 'false'}
              onClick=${() => updateBlockPrefs((cur) => ({ ...cur, tools: nextToolsMode(cur.tools) }))}
            >
              도구: ${toolsModeLabel(blockPrefs.tools)}
            </button>
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              data-testid="chat-toggle-internal"
              data-active=${blockPrefs.internal === 'shown' ? 'true' : 'false'}
              onClick=${() => updateBlockPrefs((cur) => ({ ...cur, internal: nextInternalMode(cur.internal) }))}
            >
              메모리·내부: ${internalModeLabel(blockPrefs.internal)}${hiddenInternalCount > 0 ? ` (${hiddenInternalCount})` : ''}
            </button>
            ${hasMore && html`
              <button type="button" class="btn-ghost" disabled=${loadingHistory} onClick=${() => void handleLoadEarlier()}>
                이전 대화 불러오기
              </button>
            `}
          </div>
          <div class="kp-pill-row">
            <button
              type="button"
              class="btn-ghost"
              aria-pressed=${btwOpen ? 'true' : 'false'}
              onClick=${() => setBtwOpen((v) => !v)}
            >
              /btw 사이드 질의
            </button>
            <button
              type="button"
              class="btn-ghost"
              aria-pressed=${companionOpen ? 'true' : 'false'}
              onClick=${() => setCompanionOpen((v) => !v)}
            >
              ${companionOpen ? 'Debug 닫기 (⌘.)' : 'Debug 열기 (⌘.)'}
            </button>
          </div>
        </div>

        ${historyError && html`<div class="ap-error" role="alert">${historyError}</div>`}

        <div class="kp-chat-stage">
          <div
            ref=${chatListRef}
            class="kp-chat-list"
            role="log"
            aria-label="Keeper 대화 기록"
            onScroll=${handleChatScroll}
          >
            <div class="kp-chat-feed" ref=${chatFeedRef}>
            ${loadingHistory && messages.length === 0
              ? html`<div class="kp-empty">대화 기록 불러오는 중…</div>`
              : displayItems.length === 0 && !showLiveTurnCard
                ? html`<div class="kp-empty">${messages.length > 0 ? '현재 블록 필터에 표시할 메시지가 없습니다.' : `${keeper.name}과(와) 대화를 시작하세요.`}</div>`
                : displayItems.map((item) => {
                    if (item.kind === 'tool_group') {
                      if (item.toolBlocks.length === 1) {
                        const singleEntry = item.entries[0]!
                        return html`
                          <div key=${item.id} class="kp-activity-single" data-testid="chat-tool-single">
                            ${renderToolCard(singleEntry.blocks.toolBlocks[0]!, 0, singleEntry.msg.id)}
                          </div>
                        `
                      }
                      const isGroupExpanded = expandedCardKeys[item.id] ?? (blockPrefs.tools === 'full')
                      renderedOpenRef.current.set(item.id, isGroupExpanded)
                      return html`
                        <div
                          key=${item.id}
                          class="kp-collapsible-shell kp-activity-group"
                          data-testid="chat-tool-group"
                        >
                          <details
                            class="kp-collapsible-details"
                            open=${isGroupExpanded}
                            onToggle=${(e: Event) => {
                              const nextOpen = (e.currentTarget as HTMLDetailsElement).open
                              if (nextOpen === renderedOpenRef.current.get(item.id)) return
                              renderedOpenRef.current.set(item.id, nextOpen)
                              setCardExpanded(item.id, nextOpen)
                            }}
                          >
                            <summary class="kp-activity-group-summary">
                              <span class="kp-pill" data-tone="info">도구 활동 · ${item.toolBlocks.length}건</span>
                              <span class="kp-block-preview">${item.toolSummary}</span>
                            </summary>
                            <div class="kp-hierarchy-rail">
                              ${item.entries.flatMap((entry) =>
                                entry.blocks.toolBlocks.map((tb, tbIdx) => renderToolCard(tb, tbIdx, entry.msg.id)),
                              )}
                            </div>
                          </details>
                          ${item.delegateTargets.length > 0 && props.onSelectKeeper && html`
                            <div class="kp-collapsible-actions">
                              ${item.delegateTargets.map((target) => html`
                                <button
                                  key=${target}
                                  type="button"
                                  class="btn-ghost kp-toggle-btn kp-delegate-jump"
                                  aria-label=${`${target} Keeper 대화로 이동`}
                                  onClick=${() => props.onSelectKeeper?.(target)}
                                >
                                  @${target} ↗
                                </button>
                              `)}
                            </div>
                          `}
                        </div>
                      `
                    }

                    const { msg, blocks } = item.entry
                    const timeLabel = formatChatTime(msg.ts)
                    const showThinking = Boolean(blocks.thinkingText && blockPrefs.thinking !== 'hidden')
                    const showTools = blocks.toolBlocks.length > 0 && blockPrefs.tools !== 'hidden'
                    const showMemory = blocks.memoryItems.length > 0 && blockPrefs.internal === 'shown'
                    const showAutonomous = blocks.autonomousSummary !== null && blockPrefs.internal === 'shown'
                    const hasTraceRail = showThinking || showTools || showMemory || showAutonomous
                    const hasInFlightTool = blocks.toolBlocks.some(
                      (tb) => tb.status === 'running' || tb.status === 'awaiting_result' || tb.status === 'awaiting_approval',
                    )
                    const thinkingKey = `${msg.id}:thinking`
                    const isThinkingOpen = expandedThinkingKeys[thinkingKey] ?? (blockPrefs.thinking === 'expanded')
                    renderedOpenRef.current.set(thinkingKey, isThinkingOpen)
                    const turnGroupKey = `turn-tools:${msg.id}`
                    if (hasInFlightTool) autoOpenedGroupsRef.current.add(turnGroupKey)
                    const isTurnGroupOpen =
                      expandedCardKeys[turnGroupKey]
                      ?? (blockPrefs.tools === 'full' || autoOpenedGroupsRef.current.has(turnGroupKey))
                    renderedOpenRef.current.set(turnGroupKey, isTurnGroupOpen)

                    return html`
                      <article key=${msg.id} class="kp-msg" data-role=${msg.role}>
                        <div class="kp-msg-head">
                          <span>
                            ${formatChatSpeakerLabel(
                              msg,
                              keeper.name,
                              blocks.autonomousSummary,
                              blocks.memoryItems.length > 0 && blocks.bodyText.length === 0,
                            )}
                          </span>
                          <div class="kp-pill-row">
                            ${timeLabel && html`<time class="kp-msg-time tnum">${timeLabel}</time>`}
                            ${msg.surface && msg.surface !== 'chat' && msg.surface !== 'dashboard' && html`
                              <span class="kp-pill" data-tone="info">${msg.surface}</span>
                            `}
                            ${msg.deliveryState && html`
                              <span class="kp-pill" data-tone=${deliveryBadgeTone(msg.deliveryState)}>
                                ${msg.deliveryState}
                              </span>
                            `}
                            ${msg.cutStream && msg.operationId && html`
                              <button
                                type="button"
                                class="btn-ghost"
                                onClick=${() => void handleRecoverCut(msg.id, msg.operationId!)}
                              >
                                저널 복구
                              </button>
                            `}
                          </div>
                        </div>

                        ${hasTraceRail && html`
                          <div class="kp-turn-trace" data-testid="chat-turn-trace">
                            ${showThinking && html`
                              <details
                                key=${thinkingKey}
                                class="kp-block-card kp-msg-thinking"
                                data-testid="chat-thinking-card"
                                open=${isThinkingOpen}
                                onToggle=${(e: Event) => {
                                  const nextOpen = (e.currentTarget as HTMLDetailsElement).open
                                  if (nextOpen === renderedOpenRef.current.get(thinkingKey)) return
                                  renderedOpenRef.current.set(thinkingKey, nextOpen)
                                  setExpandedThinkingKeys((prev) =>
                                    prev[thinkingKey] === nextOpen ? prev : { ...prev, [thinkingKey]: nextOpen },
                                  )
                                }}
                              >
                                <summary class="kp-block-summary">
                                  <span>추론 (Thinking)</span>
                                  <span class="kp-block-preview">${summarizeCompact(blocks.thinkingText, 80)}</span>
                                </summary>
                                <${MarkdownContent} class="kp-block-content" text=${blocks.thinkingText} streaming=${msg.deliveryState === 'Streaming'} />
                              </details>
                            `}

                            ${showTools && (blocks.toolBlocks.length === 1
                              ? html`
                                  <div class="kp-block-stack">
                                    ${renderToolCard(blocks.toolBlocks[0]!, 0, msg.id)}
                                  </div>
                                `
                              : html`
                                  <details
                                    key=${turnGroupKey}
                                    class="kp-tool-subgroup"
                                    data-testid="chat-turn-tool-group"
                                    open=${isTurnGroupOpen}
                                    onToggle=${(e: Event) => {
                                      const nextOpen = (e.currentTarget as HTMLDetailsElement).open
                                      if (nextOpen === renderedOpenRef.current.get(turnGroupKey)) return
                                      renderedOpenRef.current.set(turnGroupKey, nextOpen)
                                      setCardExpanded(turnGroupKey, nextOpen)
                                    }}
                                  >
                                    <summary class="kp-block-summary">
                                      <span class="kp-pill" data-tone=${hasInFlightTool ? 'brass' : 'info'}>
                                        도구 실행 · ${blocks.toolBlocks.length}건
                                      </span>
                                      ${hasInFlightTool && html`
                                        <span class="kp-pill" data-tone="brass">진행 중</span>
                                      `}
                                      <span class="kp-block-preview">${summarizeToolHistogram(blocks.toolBlocks)}</span>
                                    </summary>
                                    <div class="kp-hierarchy-rail">
                                      ${blocks.toolBlocks.map((tb, idx) => renderToolCard(tb, idx, msg.id))}
                                    </div>
                                  </details>
                                `)}

                            ${showMemory && html`
                              <details key=${`${msg.id}:memory`} class="kp-block-card kp-block-card--memory" data-testid="chat-memory-card">
                                <summary class="kp-block-summary">
                                  <span class="kp-pill" data-tone="brass">메모리 회상 (${blocks.memoryItems.length})</span>
                                  <span class="kp-block-preview">${summarizeCompact(blocks.memoryItems[0], 90)}</span>
                                </summary>
                                <ul class="kp-block-list">
                                  ${blocks.memoryItems.map((item, idx) => html`<li key=${idx}><${MarkdownContent} text=${item} /></li>`)}
                                </ul>
                              </details>
                            `}

                            ${showAutonomous && html`
                              <details key=${`${msg.id}:autonomous`} class="kp-block-card kp-block-card--auto" data-testid="chat-autonomous-card">
                                <summary class="kp-block-summary">
                                  <span class="kp-pill" data-tone="warn">자율 턴 (Autonomous)</span>
                                  <span class="kp-block-preview">${blocks.autonomousSummary}</span>
                                </summary>
                                ${blocks.autonomousDetails && html`
                                  <pre class="kp-block-pre">${blocks.autonomousDetails}</pre>
                                `}
                              </details>
                            `}
                          </div>
                        `}

                        ${(blocks.bodyText || msg.deliveryState === 'Streaming') && html`
                          ${blocks.bodyText
                            ? html`<${MarkdownContent} class="kp-msg-body" text=${blocks.bodyText} streaming=${msg.deliveryState === 'Streaming'} />`
                            : html`<div class="kp-msg-body">응답 생성 중…</div>`}
                        `}
                        ${msg.retainedImages?.map((image, index) => html`
                          <${WorkspaceChatImage} key=${`${index}:${image.path}`}
                            path=${image.path} caption=${image.caption} workspaceEpoch=${image.workspaceEpoch} />
                        `)}
                        ${msg.errorDetail && html`<div class="ap-error">${msg.errorDetail}</div>`}
                      </article>
                    `
                  })}

            ${showLiveTurnCard && html`
              <section class="kp-live-turn-card" data-testid="chat-live-turn-card">
                <div class="kp-msg-head">
                  <div class="kp-pill-row">
                    <span class="kp-live-dot" aria-hidden="true"></span>
                    <span class="kp-pill" data-tone="brass">${liveTurnLaneLabel}</span>
                    <span class="kp-pill" data-tone=${liveTurnActivity.tone}>${liveTurnActivity.label}</span>
                    ${activeTurn?.turn_ref && html`<span class="kp-pill">${activeTurn.turn_ref}</span>`}
                  </div>
                  <div class="kp-pill-row">
                    ${liveTurnElapsedSec !== null && html`
                      <span class="kp-pill">${formatElapsedCompact(liveTurnElapsedSec)}</span>
                    `}
                    ${lastObserved && html`<span class="kp-pill">마지막 진행 ${lastObserved}</span>`}
                  </div>
                </div>
                <div class="kp-hierarchy-rail">
                  ${liveToolName && html`
                    <div class="kp-pill-row">
                      <span class="kp-pill" data-tone="info">
                        ${isLiveToolInFlight ? '실행 중' : '최근 도구'} · ${liveToolName}
                      </span>
                      ${liveToolPulse?.executionMode === 'concurrent' && html`
                        <span class="kp-pill" data-tone="brass">
                          병렬${liveToolPulse.batchSize ? ` ${liveToolPulse.batchSize}건` : ''}
                        </span>
                      `}
                    </div>
                  `}
                  ${effectivePreview?.status_text && html`
                    <div class="kp-live-turn-status">${effectivePreview.status_text}</div>
                  `}
                  ${effectivePreview?.text_tail && html`
                    <div class="kp-live-turn-tail">… ${effectivePreview.text_tail}</div>
                  `}
                </div>
              </section>
            `}
            </div>
          </div>
          ${!isNearBottom && (visibleEntries.length > 0 || showLiveTurnCard) && html`
            <button
              type="button"
              class="kp-scroll-bottom-btn"
              data-testid="chat-scroll-bottom"
              data-has-unseen=${unseenBelowCount > 0 ? 'true' : 'false'}
              onClick=${() => scrollToBottom('smooth')}
            >
              ${unseenBelowCount > 0 ? '↓ 새 응답 보기' : '↓ 맨 아래로'}
            </button>
          `}
        </div>

        ${waitingInventory && waitingInventory.rows.length > 0 && (() => {
          const shownRows = waitingInventory.rows.slice(0, 12)
          const hiddenWaitingCount = Math.max(
            waitingInventory.rows.length - shownRows.length,
            waitingInventory.total_row_count - shownRows.length,
          )
          return html`
            <details class="kp-waiting-strip" data-testid="chat-waiting-strip">
              <summary class="kp-activity-group-summary">
                <span class="kp-pill" data-tone="warn">대기 · 위임 현황 (${waitingInventory.total_row_count || waitingInventory.rows.length}건)</span>
                ${waitingInventory.oldest_age_seconds !== null && html`
                  <span class="kp-pill">최장 ${formatElapsedCompact(waitingInventory.oldest_age_seconds)}</span>
                `}
                <span class="kp-block-preview">
                  ${summarizeCompact(
                    `${waitingInventory.rows[0]!.waiting_on} — ${waitingInventory.rows[0]!.what}`,
                    90,
                  )}
                </span>
              </summary>
              <div class="kp-hierarchy-rail">
                ${shownRows.map((row, idx) => html`
                  <div key=${`${row.source}-${row.waiting_on}-${idx}`} class="kp-waiting-row">
                    <div class="kp-pill-row">
                      <span class="kp-pill" data-tone="brass">${formatWaitingSourceLabel(row.source)}</span>
                      <span class="kp-roster-name">${row.waiting_on}</span>
                    </div>
                    ${row.what && html`<div class="kp-waiting-what">${row.what}</div>`}
                    ${row.next_action && html`<div class="kp-block-status">다음 동작: ${row.next_action}</div>`}
                  </div>
                `)}
                ${hiddenWaitingCount > 0 && html`
                  <div class="kp-block-status">+ ${hiddenWaitingCount}건 더 있음</div>
                `}
              </div>
            </details>
          `
        })()}

        ${(queuedOps.length > 0 || queue?.kind !== 'ready') && html`
          <div class="kp-queue-strip" aria-label="대기 중인 큐 작업">
            <div class="kp-queue-row">
              <span class="kp-kv-k">${queuedOps.length ? `대기열 (${queuedOps.length})` : '대기열'}</span>
              <button type="button" class="btn-ghost" aria-label="대기열 새로고침"
                onClick=${() => retryQueueRef.current()}>새로고침</button>
            </div>
            ${(!queue || queue.kind === 'loading') && html`<div role="status">대기열 조회 중…</div>`}
            ${queue?.kind === 'error' && html`
              <div role="status" title=${queue.message}>
                ${queuedOps.length > 0 ? '이전에 조회한 대기열입니다.' : '대기열을 불러오지 못했습니다.'}
              </div>
            `}
            <div class="kp-queue-rows">
              ${queuedOps.map((op) => html`
                <div key=${op.operationId} class="kp-queue-row">
                  <span class="kp-roster-name">${op.message || op.operationId}</span>
                  <div class="kp-pill-row">
                    <button type="button" class="btn-ghost" disabled=${queue?.kind !== 'ready'}
                      onClick=${() => void updateQueueOperation(op.operationId, moveQueuedChatOperationToEndApi)}>
                      뒤로
                    </button>
                    <button type="button" class="kp-btn-danger" disabled=${queue?.kind !== 'ready'}
                      onClick=${() => void updateQueueOperation(op.operationId, cancelQueuedChatOperation)}>
                      취소
                    </button>
                  </div>
                </div>
              `)}
            </div>
          </div>
        `}

        ${btwOpen && html`
          <section class="kp-btw-box" aria-label="/btw 사이드 질의">
            <div class="kp-card-head">
              <h3>/btw Ephemeral Side-Query</h3>
              <button type="button" class="btn-ghost" onClick=${() => setBtwOpen(false)}>닫기</button>
            </div>
            <div class="kp-lifecycle-bar">
              <input
                type="text"
                class="kp-input"
                placeholder="임시 사이드 질문을 입력하세요…"
                value=${btwInput}
                onInput=${(e: Event) => setBtwInput((e.currentTarget as HTMLInputElement).value)}
                onKeyDown=${(e: KeyboardEvent) => {
                  if (e.isComposing || e.keyCode === 229) return
                  if (e.key === 'Escape') {
                    e.preventDefault()
                    e.stopPropagation()
                    setBtwOpen(false)
                    return
                  }
                  if (e.key === 'Enter') {
                    e.preventDefault()
                    if (btw.status === 'streaming' || !btwInput.trim()) return
                    const q = btwInput
                    setBtwInput('')
                    void runBtwQuery(q)
                  }
                }}
              />
              <button
                type="button"
                class="btn-primary"
                disabled=${btw.status === 'streaming'}
                onClick=${() => {
                  const q = btwInput
                  setBtwInput('')
                  void runBtwQuery(q)
                }}
              >
                질의
              </button>
            </div>
            ${btw.status !== 'idle' && html`
              <div class="kp-msg-body">
                <strong>Q:</strong>
                <${MarkdownContent} text=${btw.prompt} />
                ${btw.reply
                  ? html`<${MarkdownContent} text=${btw.reply} streaming=${btw.status === 'streaming'} />`
                  : btw.status === 'streaming' && html`<div>응답 수신 중…</div>`}
                ${btw.error && html`<div class="ap-error">${btw.error}</div>`}
              </div>
            `}
          </section>
        `}

        <!-- Hermes-style Composer Footer -->
        <div class="kp-composer">
          ${attachments.length > 0 && html`
            <div class="kp-pill-row">
              ${attachments.map((att) => html`
                <span key=${att.id} class="kp-pill">
                  📎 ${att.name} (${Math.max(1, Math.round(att.size / 1024))}KB)
                  <button
                    type="button"
                    class="btn-ghost"
                    aria-label="첨부 제거"
                    onClick=${() => setAttachments((prev) => prev.filter((x) => x.id !== att.id))}
                  >
                    ×
                  </button>
                </span>
              `)}
            </div>
          `}

          <textarea
            ref=${composerRef}
            class="kp-textarea"
            rows=${3}
            placeholder=${`${keeper.name}에게 메시지 전송 (Enter: Queue · ⌘↵: Steer · /btw <질문>)`}
            aria-label="Keeper 채팅 입력"
            value=${draft}
            onInput=${(e: Event) => setDraft((e.currentTarget as HTMLTextAreaElement).value)}
            onKeyDown=${handleComposerKeyDown}
          />

          <input
            ref=${fileInputRef}
            type="file"
            multiple
            class="kp-hidden-input"
            onChange=${(e: Event) => void handleAttachmentSelect(e)}
          />
          <input
            ref=${voiceInputRef}
            type="file"
            accept="audio/*"
            class="kp-hidden-input"
            onChange=${(e: Event) => void handleVoiceFile(e)}
          />

          <div class="kp-composer-footer">
            <div class="kp-composer-meta">
              <span class="kp-pill" data-tone="info">
                ${keeper.runtime_id}${keeper.active_turn ? ` · ${keeper.active_turn.lane}` : ''}
              </span>

              <!-- Circular SVG Context Ring % (zero inline HTML style) -->
              <span class="kp-ctx-ring" title=${formatContextDetail(keeper).tooltip}>
                <svg class="kp-ring-svg" viewBox="0 0 22 22" aria-hidden="true">
                  <circle class="kp-ring-track" cx="11" cy="11" r="8.5" />
                  <circle
                    class="kp-ring-fill"
                    data-tone=${ringTone}
                    cx="11"
                    cy="11"
                    r="8.5"
                    stroke-dasharray=${RING_CIRCUMFERENCE.toFixed(2)}
                    stroke-dashoffset=${ringOffset.toFixed(2)}
                  />
                </svg>
                <span>Ctx ${ctxObs.kind === 'value' ? formatContextDetail(keeper).label : formatObserved(ctxObs, (v) => `${v}%`)}</span>
              </span>

              <button
                type="button"
                class="btn-ghost"
                onClick=${() => fileInputRef.current?.click()}
              >
                첨부
              </button>
              <button
                type="button"
                class="btn-ghost"
                disabled=${voiceBusy}
                onClick=${() => voiceInputRef.current?.click()}
              >
                ${voiceBusy ? 'STT 인식 중…' : '음성 STT'}
              </button>
            </div>

            <div class="kp-composer-actions">
              <button
                type="button"
                class="btn-ghost"
                disabled=${sending}
                onClick=${() => void submitMessage('queue')}
              >
                Queue ↵
              </button>
              <button
                type="button"
                class="btn-primary"
                disabled=${sending}
                onClick=${() => void submitMessage('steer')}
              >
                Steer ⌘↵
              </button>
            </div>
          </div>
        </div>
      </div>

      ${companionOpen && html`
        <${ErrorBoundary} label="Keeper Debug" fallback=${() => html`
          <aside class="kp-companion" aria-label="Debug Companion (⌘.)">
            <div class="kp-companion-head">
              <span role="alert">Debug 패널을 불러오지 못했습니다.</span>
              <button type="button" class="btn-ghost" onClick=${() => setCompanionOpen(false)}>닫기</button>
            </div>
          </aside>
        `}>
          <${Suspense} fallback=${html`
            <aside class="kp-companion" role="status">
              <div class="kp-companion-head">Debug 불러오는 중…</div>
            </aside>
          `}>
            <${LazyKeeperDebugCompanion}
              keeperName=${keeper.name}
              onClose=${() => setCompanionOpen(false)}
              onInspect=${props.onInspect}
              onMutated=${props.onMutated}
            />
          </${Suspense}>
        </${ErrorBoundary}>
      `}
    </div>
  `
}
