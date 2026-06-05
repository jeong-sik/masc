// Keeper Chat Panel — SSE streaming conversation with a keeper agent.
// Uses streamKeeperMessage() for real-time token-by-token responses.
//
// Messages are persisted via keeper-chat-store (sessionStorage) so they
// survive tab navigation and page refreshes.  The web dashboard is one
// connector among many (Discord, Slack, etc.).

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useMemo, useRef } from 'preact/hooks'
import {
  streamKeeperMessage,
  fetchKeeperChatHistory,
  type KeeperChatStreamEvent,
} from '../api/keeper'
import { asString, isRecord } from './common/normalize'
import { showToast } from './common/toast'
import { TextInput } from './common/input'
import { ChatComposer, ChatTranscript } from './chat/primitives'
import { Surf } from './surf'
import type { KeeperConversationEntry } from '../types'
import { shellAuthSummary } from '../store'
import { keeperDirectChatAccess } from '../lib/keeper-chat-access'
import { errorToString } from '../lib/format-string'
import {
  type ChatMessage,
  getChatMessageBuffer,
  appendChatMessage,
  mergeServerHistory,
  flushStreamBuffer,
} from '../keeper-chat-store'

/**
 * Pure filter: case-insensitive substring match over message content.
 * Empty or whitespace-only queries return the input unchanged.
 */
export function filterChatMessages(messages: ChatMessage[], query: string): ChatMessage[] {
  const q = query.trim().toLowerCase()
  if (!q) return messages
  return messages.filter((m) => m.content.toLowerCase().includes(q))
}

function toConversationEntry(
  keeperName: string,
  msg: ChatMessage,
  index: number,
): KeeperConversationEntry {
  const source = msg.role === 'user' ? 'direct_user' : 'direct_assistant'
  return {
    id: `${msg.role}-${msg.timestamp}-${index}`,
    role: msg.role,
    source,
    label: msg.role === 'user' ? '사용자' : keeperName,
    text: msg.content,
    rawText: msg.content,
    timestamp: new Date(msg.timestamp).toISOString(),
    delivery: 'delivered',
    streamState: null,
    details: null,
  }
}

export function isKeeperTextContentEvent(
  event: KeeperChatStreamEvent,
): event is KeeperChatStreamEvent & { delta: string } {
  return (
    event.type === 'TEXT_MESSAGE_CONTENT'
    && typeof event.delta === 'string'
    && event.delta.length > 0
  )
}

export function normalizeKeeperChatErrorValue(value: unknown): string {
  const direct = asString(value)
  if (direct) return direct
  if (isRecord(value)) {
    const nestedError = isRecord(value.error) ? value.error : null
    const message =
      asString(value.message)
      ?? asString(value.error)
      ?? asString(nestedError?.message)
      ?? asString(nestedError?.error)
    if (message) return message
  }
  return '스트림 오류'
}

export function KeeperChatPanel({ name }: { name: string }) {
  // Per-instance signals — each KeeperChatPanel has its own state.
  // Fixes: global signal sharing caused cross-keeper state clobbering
  // and effect re-initialization wiped messages on parent re-render.
  const chatMessages = useMemo(() => signal<ChatMessage[]>(getChatMessageBuffer(name)), [])
  const chatInput = useMemo(() => signal(''), [])
  const streaming = useMemo(() => signal(false), [])
  const streamBuffer = useMemo(() => signal(''), [])
  const streamStartedAt = useMemo(() => signal<number | null>(null), [])
  const chatError = useMemo(() => signal(''), [])
  const searchQuery = useMemo(() => signal(''), [])

  const activeAbortRef = useRef<AbortController | null>(null)

  function cancelStream(): void {
    if (activeAbortRef.current) activeAbortRef.current.abort()
    activeAbortRef.current = null
    streaming.value = false
    streamBuffer.value = ''
    streamStartedAt.value = null
  }

  async function sendChat(keeperName: string): Promise<void> {
    const text = chatInput.value.trim()
    if (!text || streaming.value) return

    chatInput.value = ''
    chatError.value = ''
    streamBuffer.value = ''
    streamStartedAt.value = Date.now()

    const userMsg: ChatMessage = { role: 'user', content: text, timestamp: Date.now(), source: 'dashboard' }
    appendChatMessage(keeperName, userMsg)
    chatMessages.value = [...chatMessages.value, userMsg]

    streaming.value = true
    activeAbortRef.current = new AbortController()

    try {
      await streamKeeperMessage(keeperName, text, {
        signal: activeAbortRef.current.signal,
        onEvent: (event: KeeperChatStreamEvent) => {
          if (isKeeperTextContentEvent(event) && typeof event.delta === 'string') {
            streamBuffer.value += event.delta
          } else if (event.type === 'RUN_FINISHED') {
            const finalText = streamBuffer.value.trim() || '(no response)'
            const assistantMsg: ChatMessage = { role: 'assistant', content: finalText, timestamp: Date.now(), source: 'dashboard' }
            appendChatMessage(keeperName, assistantMsg)
            chatMessages.value = [...chatMessages.value, assistantMsg]
            streamBuffer.value = ''
          } else if (event.type === 'RUN_ERROR') {
            chatError.value = normalizeKeeperChatErrorValue(event.value)
          }
        },
      })
    } catch (err) {
      if (err instanceof DOMException && err.name === 'AbortError') return
      const msg = err instanceof Error ? err.message : '채팅 실패'
      chatError.value = msg
      showToast(msg, 'error')
    } finally {
      streaming.value = false
      activeAbortRef.current = null
      streamStartedAt.value = null
    }
  }

  useEffect(() => {
    // Sync local buffer into the signal so the UI shows persisted messages
    // immediately (zero server round-trip).  Then merge server history
    // so external-connector messages (Discord, etc.) are incorporated.
    chatMessages.value = getChatMessageBuffer(name)

    let stale = false
    void fetchKeeperChatHistory(name)
      .then((history) => {
        if (stale) return
        if (history.length > 0) {
          const serverMsgs = history.map((m) => ({
            role: m.role === 'assistant' ? 'assistant' as const : 'user' as const,
            content: m.content,
            timestamp: m.ts * 1000,
            source: 'api' as const,
          }))
          mergeServerHistory(name, serverMsgs)
          chatMessages.value = getChatMessageBuffer(name)
        }
      })
      .catch((err: unknown) => {
        if (stale) return
        const msg = errorToString(err)
        chatError.value = `이전 대화 불러오기 실패: ${msg}`
      })
    return () => {
      stale = true
      // If a stream was in progress when the component unmounts
      // (tab change, route navigation), flush the partial buffer
      // into the store so the user does not lose the assistant's response.
      if (streaming.value && streamBuffer.value.trim()) {
        flushStreamBuffer(name, streamBuffer.value)
        chatMessages.value = getChatMessageBuffer(name)
      }
    }
  }, [name])

  const messages = chatMessages.value
  const buffer = streamBuffer.value
  const isStreaming = streaming.value
  const query = searchQuery.value
  const hasQuery = query.trim().length > 0
  const filteredMessages = filterChatMessages(messages, query)
  const entries = filteredMessages.map((msg, index) => toConversationEntry(name, msg, index))
  const chatAccess = keeperDirectChatAccess(shellAuthSummary.value)
  const transcriptEntries =
    isStreaming && buffer
      ? [
          ...entries,
          {
            id: `assistant-stream-${name}`,
            role: 'assistant',
            source: 'direct_assistant',
            label: name,
            text: buffer,
            rawText: buffer,
            timestamp: new Date().toISOString(),
            delivery: 'streaming',
            streamState: 'streaming',
            details: null,
          } satisfies KeeperConversationEntry,
        ]
      : entries

  return html`
    <div class="overflow-hidden rounded-[var(--radius-xl)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] shadow-[var(--shadow-raised)]">
      <div class="flex flex-wrap items-start justify-between gap-3 border-b border-[var(--color-border-default)] px-4 py-4">
        <div class="min-w-55 flex-1">
          <div class="text-2xs font-semibold uppercase tracking-5 text-[var(--color-fg-muted)]">직접 대화</div>
          <div class="mt-2 text-md font-semibold text-[var(--color-fg-secondary)]">@${name}</div>
          <div class="mt-1 text-sm leading-loose text-[var(--color-fg-secondary)]">
            이 키퍼와의 실시간 직접 대화입니다. 스트리밍 응답은 동일한 대화 레인에 표시됩니다.
          </div>
        </div>
        <div class="flex items-center gap-2">
          <${TextInput}
            class="max-w-55"
            name="keeper_chat_search"
            ariaLabel="대화 내용 검색"
            autoComplete="off"
            placeholder="대화 검색..."
            value=${query}
            onInput=${(e: Event) => { searchQuery.value = (e.target as HTMLInputElement).value }}
          />
          <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-2.5 py-1 text-2xs font-medium text-[var(--color-fg-secondary)]">
            ${hasQuery ? `${filteredMessages.length} / ${messages.length}개 메시지` : `${messages.length}개 메시지`}
          </span>
        </div>
      </div>

      <div class="px-4 py-4">
        ${chatAccess.message
          ? html`<div class="mb-4 rounded-card border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2.5 text-xs leading-loose text-[var(--warn-bright)]">${chatAccess.message}</div>`
          : null}
        <${ChatTranscript}
          entries=${transcriptEntries}
          emptyText=${hasQuery && messages.length > 0
            ? '검색어와 일치하는 메시지가 없습니다.'
            : '직접 프롬프트를 본내 키퍼 대화를 시작하세요.'}
          showMetadata=${false}
        />
      </div>

      ${chatError.value
        ? html`<${Surf} kind="err" role="alert" padding="tight" class="mx-4 mb-4 text-xs leading-loose">${chatError.value}<//>`
        : null}

      <div class="border-t border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-4 py-4">
        <${ChatComposer}
          draft=${chatInput.value}
          placeholder=${chatAccess.blocked ? '현재 actor는 direct keeper chat 권한이 없습니다' : '메시지 입력...'}
          disabled=${chatAccess.blocked}
          streaming=${isStreaming}
          streamStartedAt=${streamStartedAt.value}
          onDraftChange=${(value: string) => { chatInput.value = value }}
          onSend=${() => {
            if (chatAccess.blocked) {
              showToast(chatAccess.message, 'error')
              return
            }
            void sendChat(name)
          }}
          onAbort=${cancelStream}
        />
      </div>
    </div>
  `
}
