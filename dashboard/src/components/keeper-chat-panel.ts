// Keeper Chat Panel — SSE streaming conversation with a keeper agent.
// Uses streamKeeperMessage() for real-time token-by-token responses.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import {
  streamKeeperMessage,
  fetchKeeperChatHistory,
  type KeeperChatStreamEvent,
} from '../api/keeper'
import { asString, isRecord } from './common/normalize'
import { showToast } from './common/toast'
import { TextInput } from './common/input'
import { ChatComposer, ChatTranscript } from './chat/primitives'
import type { KeeperConversationEntry } from '../types'
import { shellAuthSummary } from '../store'
import { keeperDirectChatAccess } from '../lib/keeper-chat-access'

export interface ChatMessage {
  role: 'user' | 'assistant'
  content: string
  timestamp: number
}

const chatMessages = signal<ChatMessage[]>([])
const chatInput = signal('')
const streaming = signal(false)
const streamBuffer = signal('')
const streamStartedAt = signal<number | null>(null)
const chatError = signal('')
const searchQuery = signal('')

/**
 * Pure filter: case-insensitive substring match over message content.
 * Empty or whitespace-only queries return the input unchanged.
 */
export function filterChatMessages(messages: ChatMessage[], query: string): ChatMessage[] {
  const q = query.trim().toLowerCase()
  if (!q) return messages
  return messages.filter((m) => m.content.toLowerCase().includes(q))
}

let activeAbort: AbortController | null = null

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
    (event.type === 'TEXT_MESSAGE_CONTENT' || event.type === 'TEXT_DELTA')
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

function cancelStream(): void {
  if (activeAbort) activeAbort.abort()
  activeAbort = null
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

  chatMessages.value = [
    ...chatMessages.value,
    { role: 'user', content: text, timestamp: Date.now() },
  ]

  streaming.value = true
  activeAbort = new AbortController()

  try {
    await streamKeeperMessage(keeperName, text, {
      signal: activeAbort.signal,
      onEvent: (event: KeeperChatStreamEvent) => {
        if (isKeeperTextContentEvent(event) && typeof event.delta === 'string') {
          streamBuffer.value += event.delta
        } else if (event.type === 'RUN_FINISHED') {
          const finalText = streamBuffer.value.trim() || '(no response)'
          chatMessages.value = [
            ...chatMessages.value,
            { role: 'assistant', content: finalText, timestamp: Date.now() },
          ]
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
    activeAbort = null
    streamStartedAt.value = null
  }
}

export function KeeperChatPanel({ name }: { name: string }) {
  useEffect(() => {
    cancelStream()
    chatInput.value = ''
    streamBuffer.value = ''
    streamStartedAt.value = null
    chatError.value = ''
    chatMessages.value = []
    searchQuery.value = ''
    let stale = false
    void fetchKeeperChatHistory(name).then((history) => {
      if (stale) return
      if (history.length > 0) {
        chatMessages.value = history.map((m) => ({
          role: m.role === 'assistant' ? 'assistant' as const : 'user' as const,
          content: m.content,
          timestamp: m.ts * 1000,
        }))
      }
    })
    return () => { stale = true }
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
    <div class="overflow-hidden rounded-[var(--radius-xl)] border border-[var(--card-border)] bg-[linear-gradient(180deg,rgba(11,18,34,0.95),rgba(6,11,22,0.92))] shadow-[0_24px_56px_rgba(0,0,0,0.24)]">
      <div class="flex flex-wrap items-start justify-between gap-3 border-b border-[var(--slate-gray-12)] px-4 py-4">
        <div class="min-w-[220px] flex-1">
          <div class="text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">직접 대화</div>
          <div class="mt-2 text-[15px] font-semibold text-[var(--text-strong)]">@${name}</div>
          <div class="mt-1 text-[13px] leading-[1.65] text-[var(--text-secondary)]">
            이 키퍼와의 실시간 직접 대화입니다. 스트리밍 응답은 동일한 대화 레인에 표시됩니다.
          </div>
        </div>
        <div class="flex items-center gap-2">
          <${TextInput}
            class="max-w-[220px]"
            name="keeper_chat_search"
            ariaLabel="대화 내용 검색"
            autoComplete="off"
            placeholder="대화 검색..."
            value=${query}
            onInput=${(e: Event) => { searchQuery.value = (e.target as HTMLInputElement).value }}
          />
          <span class="inline-flex items-center rounded-sm border border-[var(--accent-20)] bg-[var(--accent-10)] px-2.5 py-1 text-[11px] font-medium text-[var(--text-strong)]">
            ${hasQuery ? `${filteredMessages.length} / ${messages.length}개 메시지` : `${messages.length}개 메시지`}
          </span>
        </div>
      </div>

      <div class="px-4 py-4">
        ${chatAccess.message
          ? html`<div class="mb-4 rounded-card border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2.5 text-[12px] leading-[1.6] text-[var(--warn-bright)]">${chatAccess.message}</div>`
          : null}
        <${ChatTranscript}
          entries=${transcriptEntries}
          emptyText=${hasQuery && messages.length > 0
            ? '검색어와 일치하는 메시지가 없습니다.'
            : '직접 프롬프트를 보내 키퍼 대화를 시작하세요.'}
          showMetadata=${false}
        />
      </div>

      ${chatError.value
        ? html`<div class="mx-4 mb-4 rounded-card border border-[rgba(239,68,68,0.24)] bg-[rgba(127,29,29,0.24)] px-3 py-2.5 text-[12px] leading-[1.6] text-[var(--bad-light)]">${chatError.value}</div>`
        : null}

      <div class="border-t border-[var(--slate-gray-12)] bg-[var(--white-3)] px-4 py-4">
        <${ChatComposer}
          draft=${chatInput.value}
          placeholder=${chatAccess.blocked ? '현재 actor는 direct keeper chat 권한이 없습니다' : '메시지 입력...'}
          disabled=${chatAccess.blocked}
          streaming=${isStreaming}
          streamStartedAt=${streamStartedAt.value}
          onDraftChange=${(value: string) => { chatInput.value = value }}
          onSend=${() => {
            if (chatAccess.blocked) {
              showToast(chatAccess.message ?? '직접 통신 권한이 없습니다.', 'error')
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
