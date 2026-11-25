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
import { useCallback, useEffect, useRef, useState } from 'preact/hooks'
import { formatObserved } from '../../core/resource-cache'
import { randomUuid } from '../../lib/uuid'
import {
  cancelQueuedChatOperation,
  fetchKeeperChatHistoryPageApi,
  fetchKeeperControlToken,
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
  saveChatBlockPrefs,
  shouldRenderChatEntry,
  summarizeCompact,
  thinkingModeLabel,
  toolsModeLabel,
  type ChatBlockPrefs,
} from './chat-blocks'
import type {
  BtwQueryState,
  ChatAttachmentDraft,
  ChatDeliveryState,
  ChatToolBlock,
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

  const fileInputRef = useRef<HTMLInputElement>(null)
  const voiceInputRef = useRef<HTMLInputElement>(null)
  const streamAbortRef = useRef<AbortController | null>(null)
  const btwAbortRef = useRef<AbortController | null>(null)
  const sendingRef = useRef(false)

  useEffect(() => {
    setControlToken(keeper.chat_control_token)
  }, [keeper.chat_control_token])

  const loadInitialHistory = useCallback(async () => {
    setLoadingHistory(true)
    setHistoryError(null)
    const [pageRes, opsRes] = await Promise.all([
      fetchKeeperChatHistoryPageApi(keeper.name, undefined, 40),
      fetchQueuedChatOperations(keeper.name),
    ])
    setLoadingHistory(false)
    if (!pageRes.ok) {
      setHistoryError(pageRes.error.message)
    } else {
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
    setLoadingHistory(true)
    const res = await fetchKeeperChatHistoryPageApi(keeper.name, nextCursor, 40)
    setLoadingHistory(false)
    if (!res.ok) {
      setHistoryError(res.error.message)
      return
    }
    setMessages((prev) => [...res.value.messages, ...prev])
    setHasMore(res.value.hasMore)
    setNextCursor(res.value.nextCursor)
  }

  const updateAssistantEntry = (
    assistantId: string,
    updater: (cur: ChatTranscriptEntry) => ChatTranscriptEntry,
  ) => {
    setMessages((prev) => prev.map((m) => (m.id === assistantId ? updater(m) : m)))
  }

  const handleRecoverCut = async (assistantId: string, operationId: string) => {
    updateAssistantEntry(assistantId, (m) => ({
      ...m,
      deliveryState: 'Confirming_delivery',
    }))
    const recovered = await recoverCutReplyFromJournal(keeper.name, operationId)
    if (!recovered.ok) {
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

    const operationId = `op-${randomUuid()}`
    const nowSec = Date.now() / 1000
    const userEntry: ChatTranscriptEntry = {
      id: `user-${operationId}`,
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
    sendingRef.current = true
    setMessages((prev) => [...prev, userEntry, assistantEntry])
    setDraft('')
    setAttachments([])
    setSending(true)

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
        const token = controlToken ?? (await fetchKeeperControlToken(keeper.name))
        if (token) {
          setControlToken(token)
          submitMode = { kind: 'steer', controlToken: token }
        }
      }

      streamAbortRef.current?.abort()
      abortController = new AbortController()
      streamAbortRef.current = abortController

      outcome = await streamKeeperChat({
        keeper: keeper.name,
        message: trimmed,
        operationId,
        mode: submitMode,
        attachments: currentAttachments,
        signal: abortController.signal,
        callbacks: {
          onAccepted: (info) => {
            if (info.controlToken) setControlToken(info.controlToken)
            const nextState: ChatDeliveryState =
              info.state === 'Queued'
                ? 'Queued'
                : info.state === 'Running'
                  ? 'Pending_processing'
                  : 'Delivered'
            updateAssistantEntry(assistantId, (m) => ({ ...m, deliveryState: nextState }))
          },
          onRunStarted: () => {
            updateAssistantEntry(assistantId, (m) => ({ ...m, deliveryState: 'Pending_processing' }))
          },
          onAttemptStarted: () => {
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              content: '',
              deliveryState: 'Streaming',
            }))
          },
          onTextDelta: (delta) => {
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              content: m.content + delta,
              deliveryState: 'Streaming',
            }))
          },
          onThinkingDelta: (delta) => {
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              thinking: (m.thinking ?? '') + delta,
            }))
          },
          onToolStart: (toolName, toolCallId) => {
            updateAssistantEntry(assistantId, (m) => {
              const nextTool: ChatToolBlock = { id: toolCallId, name: toolName, status: 'running' }
              return { ...m, toolCalls: [...(m.toolCalls ?? []), nextTool] }
            })
          },
          onToolArgsDelta: (toolCallId, delta) => {
            updateAssistantEntry(assistantId, (m) => {
              const list = [...(m.toolCalls ?? [])]
              const idx = toolCallId
                ? list.findIndex((t) => t.id === toolCallId)
                : list.length - 1
              if (idx < 0) return m
              const cur = list[idx]!
              list[idx] = { ...cur, args: (cur.args ?? '') + delta }
              return { ...m, toolCalls: list }
            })
          },
          onToolResult: (toolCallId, content) => {
            updateAssistantEntry(assistantId, (m) => {
              const list = [...(m.toolCalls ?? [])]
              const idx = toolCallId
                ? list.findIndex((t) => t.id === toolCallId)
                : list.length - 1
              if (idx < 0) {
                list.push({ id: toolCallId || undefined, name: 'tool', result: content, status: 'completed' })
              } else {
                const cur = list[idx]!
                list[idx] = { ...cur, result: content, status: 'completed' }
              }
              return { ...m, toolCalls: list }
            })
          },
          onReplyDetails: (reply, turnRef) => {
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              content: reply || m.content,
              turnRef: turnRef ?? m.turnRef,
            }))
          },
          onError: (msg) => {
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: 'Failed',
              errorDetail: msg,
            }))
          },
          onFinished: () => {
            updateAssistantEntry(assistantId, (m) => ({
              ...m,
              deliveryState: m.deliveryState === 'Failed' ? 'Failed' : 'Delivered',
            }))
          },
        },
      })
    } finally {
      sendingRef.current = false
      setSending(false)
    }

    // Mid-stream cut without RUN_FINISHED -> Confirming_delivery & journal recovery
    if (!outcome.terminal && !abortController?.signal.aborted) {
      updateAssistantEntry(assistantId, (m) => ({
        ...m,
        cutStream: true,
        deliveryState: 'Confirming_delivery',
      }))
      await handleRecoverCut(assistantId, operationId)
    }

    const opsRes = await fetchQueuedChatOperations(keeper.name)
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

  const recentSlice = messages.slice(-120)
  const parsedEntries = recentSlice.map((msg) => ({ msg, blocks: parseChatMessageBlocks(msg) }))
  const hiddenInternalCount = parsedEntries.filter(
    ({ blocks }) => blocks.isInternalOnly && blockPrefs.internal === 'hidden',
  ).length
  const visibleEntries = parsedEntries.filter(({ msg, blocks }) =>
    shouldRenderChatEntry(msg, blocks, blockPrefs),
  )

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

        <div class="kp-chat-list" role="log" aria-label="Keeper 대화 기록">
          ${loadingHistory && messages.length === 0
            ? html`<div class="kp-empty">대화 기록 불러오는 중…</div>`
            : visibleEntries.length === 0
              ? html`<div class="kp-empty">${messages.length > 0 ? '현재 블록 필터에 표시할 메시지가 없습니다.' : `${keeper.name}과(와) 대화를 시작하세요.`}</div>`
              : visibleEntries.map(({ msg, blocks }) => html`
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
                        ${blocks.toolBlocks.map((tb, idx) => html`
                          <details
                            key=${`${tb.id ?? tb.name}-${idx}:${blockPrefs.tools}`}
                            class="kp-block-card kp-block-card--tool"
                            data-testid="chat-tool-card"
                            open=${blockPrefs.tools === 'full' ? true : undefined}
                          >
                            <summary class="kp-block-summary">
                              <span class="kp-pill" data-tone=${tb.status === 'error' ? 'bad' : 'info'}>도구 · ${tb.name}</span>
                              <span class="kp-block-preview">
                                ${summarizeCompact(tb.args ?? tb.result ?? tb.status ?? '실행됨', 90)}
                              </span>
                            </summary>
                            <div class="kp-block-content">
                              ${tb.args && html`
                                <div class="kp-block-sublabel">입력 (Args)</div>
                                <pre class="kp-block-pre">${tb.args}</pre>
                              `}
                              ${tb.result && html`
                                <div class="kp-block-sublabel">결과 (Result)</div>
                                <pre class="kp-block-pre">${tb.result}</pre>
                              `}
                            </div>
                          </details>
                        `)}
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
                `)}
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
                  if (e.key === 'Enter') {
                    e.preventDefault()
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
