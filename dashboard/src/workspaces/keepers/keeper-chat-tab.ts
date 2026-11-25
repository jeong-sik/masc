/**
 * Entity Tab 1: `Chat` (`/keepers/:name/chat`)
 *
 * - `Origin_bare` live AG-UI SSE transcript (`POST /api/v1/keepers/chat/stream`),
 *   paginated history (`/keepers/:k/chat/history/page`), cut-reply journal recovery
 *   (`/keepers/:k/chat/events`), explicit delivery states
 *   (`Queued | Sending | Pending_processing | Confirming_delivery | Streaming | Delivered | Cut_recovered | Failed`).
 * - Hermes-style Composer Footer: Model/Lane pill, circular SVG Context Ring %,
 *   attachments + voice STT trigger, `Enter` Queue vs `⌘↵` Steer (own `operation_id`), `/btw` side-query.
 * - Opt-In Right Debug Companion Pane (`⌘.`, `380px`, default closed `<1280px`).
 */

import type { WorkspaceInspectPayload } from '../types'
import { html } from 'htm/preact'
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks'
import { currentSessionEpoch, isEpochCurrent, sessionEpoch } from '../../core/auth'
import { formatObserved } from '../../core/resource-cache'
import { randomUuid } from '../../lib/uuid'
import {
  cancelQueuedChatOperation,
  fetchKeeperChatHistoryPageApi,
  fetchKeeperControlToken,
  fetchKeeperToolResultApi,
  fetchQueuedChatOperations,
  moveQueuedChatOperationToEndApi,
  observeRosterContextPct,
  recoverCutReplyFromJournal,
  streamKeeperChat,
  transcribeVoiceAudio,
} from './keepers-api'
import {
  KeeperDebugCompanion,
  shouldDefaultOpenCompanion,
} from './keeper-debug-companion'
import {
  internalModeLabel,
  loadChatBlockPrefs,
  nextInternalMode,
  nextThinkingMode,
  nextToolsMode,
  parseChatMessageBlocks,
  prettyFormatPayload,
  saveChatBlockPrefs,
  shouldRenderChatEntry,
  summarizeCompact,
  thinkingModeLabel,
  toolsModeLabel,
  toolStatusMeta,
  upsertStreamToolCall,
  type ChatBlockPrefs,
} from './chat-blocks'
import type {
  BtwQueryState,
  ChatAttachmentDraft,
  ChatDeliveryState,
  ChatTranscriptEntry,
  KeeperRosterItem,
  QueuedChatOperation,
} from './types'

export interface KeeperChatTabProps {
  readonly keeper: KeeperRosterItem
  readonly onInspect: (payload: WorkspaceInspectPayload) => void
  readonly onMutated: () => void
}

const RING_CIRCUMFERENCE = 2 * Math.PI * 8.5
const BOTTOM_STICKY_THRESHOLD_PX = 72
const INITIAL_RENDER_WINDOW = 120
const MAX_RENDER_WINDOW = 1000

function formatChatTime(ts: number): string | null {
  if (!Number.isFinite(ts) || ts <= 0) return null
  const ms = ts < 1_000_000_000_000 ? ts * 1000 : ts
  const d = new Date(ms)
  if (Number.isNaN(d.getTime())) return null
  const hh = String(d.getHours()).padStart(2, '0')
  const mm = String(d.getMinutes()).padStart(2, '0')
  return `${hh}:${mm}`
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

interface ToolResultCacheEntry {
  readonly status: 'loading' | 'loaded' | 'pending' | 'unavailable' | 'error'
  readonly content?: string
  readonly isError?: boolean
  readonly detail?: string
  readonly truncated?: boolean
}

const MAX_TOOL_RESULT_CACHE = 50

function joinThinkingMap(map: Map<string, string>): string | undefined {
  const ordered = Array.from(map.values()).filter((v) => v.length > 0)
  return ordered.length > 0 ? ordered.join('\n\n') : undefined
}

function setBoundedToolResultCache(
  prev: Record<string, ToolResultCacheEntry>,
  key: string,
  entry: ToolResultCacheEntry,
): Record<string, ToolResultCacheEntry> {
  const next: Record<string, ToolResultCacheEntry> = { ...prev }
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

  const [queuedOps, setQueuedOps] = useState<readonly QueuedChatOperation[]>([])
  const [draft, setDraft] = useState('')
  const [attachments, setAttachments] = useState<readonly ChatAttachmentDraft[]>([])
  const [sending, setSending] = useState(false)
  const [voiceBusy, setVoiceBusy] = useState(false)
  const [controlToken, setControlToken] = useState<string | null>(keeper.chat_control_token)
  const [companionOpen, setCompanionOpen] = useState<boolean>(() => shouldDefaultOpenCompanion())
  const [blockPrefs, setBlockPrefs] = useState<ChatBlockPrefs>(() => loadChatBlockPrefs())

  const updateBlockPrefs = useCallback((updater: (cur: ChatBlockPrefs) => ChatBlockPrefs) => {
    setBlockPrefs((cur) => {
      const next = updater(cur)
      saveChatBlockPrefs(next)
      return next
    })
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
  const [toolResultCache, setToolResultCache] = useState<Record<string, ToolResultCacheEntry>>({})

  const chatListRef = useRef<HTMLDivElement>(null)
  const composerRef = useRef<HTMLTextAreaElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const voiceInputRef = useRef<HTMLInputElement>(null)
  const streamAbortRef = useRef<AbortController | null>(null)
  const btwAbortRef = useRef<AbortController | null>(null)
  const sendingRef = useRef(false)
  const stickToBottomRef = useRef(true)
  const forceScrollBottomRef = useRef(true)
  const pendingPrependAnchorRef = useRef<{ readonly prevScrollHeight: number; readonly prevScrollTop: number } | null>(null)
  const prevTailSigRef = useRef('')
  const mountedRef = useRef(true)
  const activeKeeperRef = useRef(keeper.name)
  const requestedExecIdsRef = useRef<Set<string>>(new Set())
  const toolFetchControllersRef = useRef<Set<AbortController>>(new Set())

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
    for (const ctrl of toolFetchControllersRef.current) {
      ctrl.abort()
    }
    toolFetchControllersRef.current.clear()
  }, [])

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      abortAllToolFetches()
    }
  }, [abortAllToolFetches])

  useEffect(() => {
    activeKeeperRef.current = keeper.name
    stickToBottomRef.current = true
    forceScrollBottomRef.current = true
    pendingPrependAnchorRef.current = null
    setRenderWindow(INITIAL_RENDER_WINDOW)
    setIsNearBottom(true)
    setUnseenBelowCount(0)
    abortAllToolFetches()
    requestedExecIdsRef.current.clear()
    setToolResultCache({})
  }, [keeper.name, abortAllToolFetches])

  useEffect(() => {
    let lastEpoch = currentSessionEpoch()
    return sessionEpoch.subscribe((ep) => {
      if (ep !== lastEpoch) {
        lastEpoch = ep
        streamAbortRef.current?.abort('session_epoch_changed')
        btwAbortRef.current?.abort('session_epoch_changed')
        abortAllToolFetches()
        requestedExecIdsRef.current.clear()
        setToolResultCache({})
      }
    })
  }, [abortAllToolFetches])

  const requestToolResult = useCallback(async (executionId: string, force = false) => {
    const trimmed = executionId.trim()
    if (!trimmed) return
    if (!force && requestedExecIdsRef.current.has(trimmed)) return
    requestedExecIdsRef.current.add(trimmed)
    const targetKeeper = keeper.name
    const startEpoch = currentSessionEpoch()
    const ctrl = new AbortController()
    toolFetchControllersRef.current.add(ctrl)
    setToolResultCache((prev) => setBoundedToolResultCache(prev, trimmed, { status: 'loading' }))
    try {
      const res = await fetchKeeperToolResultApi(targetKeeper, trimmed, 16_384, ctrl.signal)
      if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch)) {
        requestedExecIdsRef.current.delete(trimmed)
        return
      }
      if (!res.ok) {
        requestedExecIdsRef.current.delete(trimmed)
        if (res.error.kind === 'epoch_stale' || res.error.kind === 'aborted') return
        setToolResultCache((prev) =>
          setBoundedToolResultCache(prev, trimmed, { status: 'error', detail: res.error.message }),
        )
        return
      }
      const payload = res.value
      if (payload.state === 'pending') {
        requestedExecIdsRef.current.delete(trimmed)
        setToolResultCache((prev) => setBoundedToolResultCache(prev, trimmed, { status: 'pending' }))
        return
      }
      if (payload.state === 'unavailable') {
        setToolResultCache((prev) =>
          setBoundedToolResultCache(prev, trimmed, { status: 'unavailable', detail: payload.reason }),
        )
        return
      }
      setToolResultCache((prev) =>
        setBoundedToolResultCache(prev, trimmed, {
          status: 'loaded',
          content: prettyFormatPayload(payload.content),
          isError: payload.isError,
          truncated: !payload.eof,
        }),
      )
    } finally {
      toolFetchControllersRef.current.delete(ctrl)
    }
  }, [keeper.name])

  useEffect(() => {
    setControlToken(keeper.chat_control_token)
  }, [keeper.chat_control_token])

  const loadInitialHistory = useCallback(async () => {
    const targetKeeper = keeper.name
    const startEpoch = currentSessionEpoch()
    setLoadingHistory(true)
    setHistoryError(null)
    const [pageRes, opsRes] = await Promise.all([
      fetchKeeperChatHistoryPageApi(targetKeeper, undefined, 40),
      fetchQueuedChatOperations(targetKeeper),
    ])
    if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch)) return
    setLoadingHistory(false)
    if (!pageRes.ok) {
      if (pageRes.error.kind !== 'epoch_stale' && pageRes.error.kind !== 'aborted') {
        setHistoryError(pageRes.error.message)
      }
    } else {
      forceScrollBottomRef.current = true
      setMessages((prev) => {
        const loadedIds = new Set(pageRes.value.messages.map((m) => m.id))
        const optimistic = prev.filter((m) => !loadedIds.has(m.id))
        return [...pageRes.value.messages, ...optimistic]
      })
      setHasMore(pageRes.value.hasMore)
      setNextCursor(pageRes.value.nextCursor)
    }
    if (opsRes.ok) {
      setQueuedOps(opsRes.value)
    }
  }, [keeper.name])

  useEffect(() => {
    void loadInitialHistory()
    return () => {
      streamAbortRef.current?.abort()
      btwAbortRef.current?.abort()
    }
  }, [loadInitialHistory])

  // Global shortcuts: ⌘. / Ctrl+. (Debug Companion) and Alt+T (Thinking block visibility)
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.isComposing || e.keyCode === 229) return
      if ((e.metaKey || e.ctrlKey) && e.key === '.') {
        e.preventDefault()
        setCompanionOpen((prev) => !prev)
        return
      }
      if (e.altKey && !e.metaKey && !e.ctrlKey && e.key.toLowerCase() === 't') {
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
    setLoadingHistory(true)
    const res = await fetchKeeperChatHistoryPageApi(targetKeeper, nextCursor, 40)
    if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch)) return
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
    setMessages((prev) => {
      const existingIds = new Set(prev.map((m) => m.id))
      const fresh = res.value.messages.filter((m) => !existingIds.has(m.id))
      return [...fresh, ...prev]
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
      deliveryState: recovered.value.error ? 'Failed' : 'Cut_recovered',
      cutStream: false,
      errorDetail: recovered.value.error ?? undefined,
    }))
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
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: promoteStreaming(m.deliveryState),
              toolCalls: upsertStreamToolCall(
                m.toolCalls,
                { toolCallId, streamKey },
                (cur) => ({
                  ...cur,
                  id: toolCallId ?? cur.id,
                  streamKey: streamKey ?? cur.streamKey,
                  name: toolName || cur.name,
                  status: 'running',
                }),
                () => ({
                  id: toolCallId,
                  streamKey,
                  name: toolName,
                  status: 'running',
                }),
              ),
            }))
          },
          onToolAdmitted: (toolName, toolCallId, streamKey) => {
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              toolCalls: upsertStreamToolCall(
                m.toolCalls,
                { toolCallId, streamKey },
                (cur) => ({
                  ...cur,
                  id: toolCallId ?? cur.id,
                  streamKey: streamKey ?? cur.streamKey,
                  name: toolName,
                }),
              ),
            }))
          },
          onToolArgsDelta: (toolCallId, delta, streamKey) => {
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: promoteStreaming(m.deliveryState),
              toolCalls: upsertStreamToolCall(
                m.toolCalls,
                { toolCallId, streamKey },
                (cur) => ({ ...cur, args: (cur.args ?? '') + delta }),
              ),
            }))
          },
          onToolArgsSnapshot: (toolCallId, snapshot, streamKey) => {
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: promoteStreaming(m.deliveryState),
              toolCalls: upsertStreamToolCall(
                m.toolCalls,
                { toolCallId, streamKey },
                (cur) => ({ ...cur, args: snapshot }),
              ),
            }))
          },
          onToolEnd: (toolCallId, streamKey) => {
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              toolCalls: upsertStreamToolCall(
                m.toolCalls,
                { toolCallId, streamKey },
                (cur) => ({
                  ...cur,
                  status: cur.status === 'running' ? 'awaiting_result' : cur.status,
                }),
              ),
            }))
          },
          onToolResultReady: ({ executionId, toolCallId, streamKey }) => {
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              toolCalls: upsertStreamToolCall(
                m.toolCalls,
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
              ),
            }))
          },
          onToolResult: (toolCallId, content, streamKey) => {
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              toolCalls: upsertStreamToolCall(
                m.toolCalls,
                { toolCallId, streamKey },
                (cur) => ({ ...cur, result: content, status: 'completed' }),
                () => ({
                  id: toolCallId || undefined,
                  streamKey,
                  name: 'tool',
                  result: content,
                  status: 'completed',
                }),
              ),
            }))
          },
          onNativeToolProgress: ({ toolName, toolCallId, streamKey, progressLabel }) => {
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: promoteStreaming(m.deliveryState),
              toolCalls: upsertStreamToolCall(
                m.toolCalls,
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
              ),
            }))
          },
          onNativeToolEnd: ({ toolName, toolCallId, streamKey, status, summary }) => {
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              toolCalls: upsertStreamToolCall(
                m.toolCalls,
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
              ),
            }))
          },
          onToolApprovalRequested: ({ toolCallId, toolName, args, question, because }) => {
            const label = question ?? because ?? '운영자 승인 대기 중'
            const trimmedId = toolCallId.trim()
            const matchRef = trimmedId
              ? { toolCallId: trimmedId }
              : { streamKey: `approval:${randomUuid()}` }
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: promoteStreaming(m.deliveryState),
              toolCalls: upsertStreamToolCall(
                m.toolCalls,
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
              ),
            }))
          },
          onToolApprovalSettled: ({ toolCallId, outcome: approvalOutcome }) => {
            const approved = /^approv/i.test(approvalOutcome.trim())
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              toolCalls: upsertStreamToolCall(
                m.toolCalls,
                { toolCallId },
                (cur) => ({
                  ...cur,
                  status: approved ? 'running' : 'error',
                  progressLabel: approvalOutcome,
                }),
              ),
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
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: m.deliveryState === 'Failed' ? 'Failed' : 'Delivered',
              toolCalls: m.toolCalls?.map((tc) =>
                tc.status === 'running' || tc.status === 'awaiting_result'
                  ? { ...tc, status: 'completed' }
                  : tc,
              ),
            }))
          },
        },
      })
    } finally {
      sendingRef.current = false
      if (mountedRef.current) setSending(false)
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

    const opsRes = await fetchQueuedChatOperations(targetKeeper)
    if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch)) {
      return
    }
    if (opsRes.ok) setQueuedOps(opsRes.value)
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

  const lastVisible = visibleEntries[visibleEntries.length - 1]?.msg
  const tailSig = lastVisible
    ? `${visibleEntries.length}:${lastVisible.id}:${lastVisible.content.length}:${lastVisible.thinking?.length ?? 0}:${lastVisible.toolCalls?.length ?? 0}:${lastVisible.deliveryState ?? ''}:${lastVisible.errorDetail ?? ''}`
    : `${visibleEntries.length}:empty`

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
            ${loadingHistory && messages.length === 0
              ? html`<div class="kp-empty">대화 기록 불러오는 중…</div>`
              : visibleEntries.length === 0
                ? html`<div class="kp-empty">${messages.length > 0 ? '현재 블록 필터에 표시할 메시지가 없습니다.' : `${keeper.name}과(와) 대화를 시작하세요.`}</div>`
                : visibleEntries.map(({ msg, blocks }) => {
                    const timeLabel = formatChatTime(msg.ts)
                    return html`
                    <article key=${msg.id} class="kp-msg" data-role=${msg.role}>
                      <div class="kp-msg-head">
                        <span>
                          ${msg.role === 'user'
                            ? (msg.speakerLabel ?? '사용자')
                            : blocks.autonomousSummary !== null
                              ? `${keeper.name} · Autonomous Turn`
                              : blocks.memoryItems.length > 0 && blocks.bodyText.length === 0
                                ? `${keeper.name} · Memory Recall`
                                : msg.toolName
                                  ? `Tool · ${msg.toolName}`
                                  : keeper.name}
                        </span>
                        <div class="kp-pill-row">
                          ${timeLabel && html`<time class="kp-msg-time tnum">${timeLabel}</time>`}
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

                    ${blocks.thinkingText && blockPrefs.thinking !== 'hidden' && html`
                      <details
                        key=${`think:${blockPrefs.thinking}`}
                        class="kp-block-card kp-msg-thinking"
                        data-testid="chat-thinking-card"
                        open=${blockPrefs.thinking === 'expanded' ? true : undefined}
                      >
                        <summary class="kp-block-summary">
                          <span>추론 (Thinking)</span>
                          <span class="kp-block-preview">${summarizeCompact(blocks.thinkingText, 80)}</span>
                        </summary>
                        <div class="kp-block-content">${blocks.thinkingText}</div>
                      </details>
                    `}

                    ${blocks.toolBlocks.length > 0 && blockPrefs.tools !== 'hidden' && html`
                      <div class="kp-block-stack">
                        ${blocks.toolBlocks.map((tb, idx) => {
                          const cachedRes = tb.executionId ? toolResultCache[tb.executionId] : undefined
                          const displayArgs = tb.args ? prettyFormatPayload(tb.args) : undefined
                          const displayResult = tb.result
                            ? prettyFormatPayload(tb.result)
                            : cachedRes?.status === 'loaded'
                              ? cachedRes.content
                              : undefined
                          const effectiveStatus =
                            cachedRes?.status === 'loaded' && cachedRes.isError ? 'error' : tb.status
                          const statusMeta = toolStatusMeta(effectiveStatus)
                          const previewText = summarizeCompact(
                            displayArgs ?? displayResult ?? tb.progressLabel ?? statusMeta.label,
                            90,
                          )
                          return html`
                            <details
                              key=${`${tb.streamKey ?? tb.id ?? tb.executionId ?? tb.name}-${idx}:${blockPrefs.tools}`}
                              class="kp-block-card kp-block-card--tool"
                              data-testid="chat-tool-card"
                              open=${blockPrefs.tools === 'full' ? true : undefined}
                              onToggle=${(e: Event) => {
                                const el = e.currentTarget as HTMLDetailsElement
                                if (
                                  el.open
                                  && tb.executionId
                                  && !displayResult
                                  && (!cachedRes || cachedRes.status === 'pending' || cachedRes.status === 'error')
                                ) {
                                  void requestToolResult(tb.executionId, cachedRes?.status === 'pending' || cachedRes?.status === 'error')
                                }
                              }}
                            >
                              <summary class="kp-block-summary">
                                <span class="kp-pill" data-tone=${statusMeta.tone}>도구 · ${tb.name}</span>
                                <span class="kp-pill" data-tone=${statusMeta.tone}>
                                  ${tb.progressLabel ?? statusMeta.label}${tb.duration ? ` · ${tb.duration}` : ''}
                                </span>
                                <span class="kp-block-preview">${previewText}</span>
                              </summary>
                              <div class="kp-block-content">
                                ${displayArgs && html`
                                  <div class="kp-block-sublabel">입력 (Args)</div>
                                  <pre class="kp-block-pre">${displayArgs}</pre>
                                `}
                                ${displayResult && html`
                                  <div class="kp-block-sublabel">
                                    결과 (Result)${cachedRes?.truncated ? ' · 일부 표시' : ''}
                                  </div>
                                  <pre class="kp-block-pre">${displayResult}</pre>
                                `}
                                ${!displayResult && cachedRes?.status === 'loading' && html`
                                  <div class="kp-block-status">결과 불러오는 중…</div>
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
                                        다시 시도
                                      </button>
                                    `}
                                  </div>
                                `}
                                ${!displayResult && !cachedRes && tb.executionId && html`
                                  <div class="kp-block-status">
                                    <button
                                      type="button"
                                      class="btn-ghost kp-toggle-btn"
                                      onClick=${() => void requestToolResult(tb.executionId!)}
                                    >
                                      실행 결과 불러오기
                                    </button>
                                  </div>
                                `}
                                ${!displayArgs && !displayResult && !cachedRes && !tb.executionId && html`
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
                              </div>
                            </details>
                          `
                        })}
                      </div>
                    `}

                    ${blocks.memoryItems.length > 0 && blockPrefs.internal === 'shown' && html`
                      <details class="kp-block-card kp-block-card--memory" data-testid="chat-memory-card">
                        <summary class="kp-block-summary">
                          <span class="kp-pill" data-tone="brass">메모리 회상 (${blocks.memoryItems.length})</span>
                          <span class="kp-block-preview">${summarizeCompact(blocks.memoryItems[0], 90)}</span>
                        </summary>
                        <ul class="kp-block-list">
                          ${blocks.memoryItems.map((item, idx) => html`<li key=${idx}>${item}</li>`)}
                        </ul>
                      </details>
                    `}

                    ${blocks.autonomousSummary !== null && blockPrefs.internal === 'shown' && html`
                      <details class="kp-block-card kp-block-card--auto" data-testid="chat-autonomous-card">
                        <summary class="kp-block-summary">
                          <span class="kp-pill" data-tone="warn">자율 턴 (Autonomous)</span>
                          <span class="kp-block-preview">${blocks.autonomousSummary}</span>
                        </summary>
                        ${blocks.autonomousDetails && html`
                          <pre class="kp-block-pre">${blocks.autonomousDetails}</pre>
                        `}
                      </details>
                    `}

                      ${(blocks.bodyText || msg.deliveryState === 'Streaming') && html`
                        <div class="kp-msg-body">${blocks.bodyText || '응답 생성 중…'}</div>
                      `}
                      ${msg.errorDetail && html`<div class="ap-error">${msg.errorDetail}</div>`}
                    </article>
                  `
                  })}
          </div>
          ${!isNearBottom && visibleEntries.length > 0 && html`
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

        ${queuedOps.length > 0 && html`
          <div class="kp-queue-strip" aria-label="대기 중인 큐 작업">
            <span class="kp-kv-k">Queued Operations (${queuedOps.length})</span>
            ${queuedOps.map((op) => html`
              <div key=${op.operationId} class="kp-queue-row">
                <span class="kp-roster-name">${op.message || op.operationId}</span>
                <div class="kp-pill-row">
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${async () => {
                      await moveQueuedChatOperationToEndApi(keeper.name, op.operationId)
                      const next = await fetchQueuedChatOperations(keeper.name)
                      if (next.ok) setQueuedOps(next.value)
                    }}
                  >
                    뒤로
                  </button>
                  <button
                    type="button"
                    class="kp-btn-danger"
                    onClick=${async () => {
                      await cancelQueuedChatOperation(keeper.name, op.operationId)
                      const next = await fetchQueuedChatOperations(keeper.name)
                      if (next.ok) setQueuedOps(next.value)
                    }}
                  >
                    취소
                  </button>
                </div>
              </div>
            `)}
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
                <strong>Q:</strong> ${btw.prompt}
                <div>${btw.reply || (btw.status === 'streaming' ? '응답 수신 중…' : '')}</div>
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
              <span class="kp-ctx-ring" title="컨텍스트 점유율">
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
                <span>Ctx ${formatObserved(ctxObs, (v) => `${v}%`)}</span>
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
        <${KeeperDebugCompanion}
          keeperName=${keeper.name}
          onClose=${() => setCompanionOpen(false)}
          onInspect=${props.onInspect}
          onMutated=${props.onMutated}
        />
      `}
    </div>
  `
}
