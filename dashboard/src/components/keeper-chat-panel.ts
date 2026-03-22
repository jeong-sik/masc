// Keeper Chat Panel — SSE streaming conversation with a keeper agent.
// Uses streamKeeperMessage() for real-time token-by-token responses.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { streamKeeperMessage, type KeeperChatStreamEvent } from '../api/keeper'
import { ActionButton } from './common/button'
import { TextInput } from './common/input'
import { EmptyState } from './common/feedback-state'
import { showToast } from './common/toast'

interface ChatMessage {
  role: 'user' | 'assistant'
  content: string
  timestamp: number
}

const chatMessages = signal<ChatMessage[]>([])
const chatInput = signal('')
const streaming = signal(false)
const streamBuffer = signal('')
const chatError = signal('')

let activeAbort: AbortController | null = null

function cancelStream(): void {
  if (activeAbort) {
    activeAbort.abort()
    activeAbort = null
    streaming.value = false
  }
}

async function sendChat(keeperName: string): Promise<void> {
  const text = chatInput.value.trim()
  if (!text || streaming.value) return

  chatInput.value = ''
  chatError.value = ''
  streamBuffer.value = ''

  chatMessages.value = [
    ...chatMessages.value,
    { role: 'user', content: text, timestamp: Date.now() },
  ]

  streaming.value = true
  activeAbort = new AbortController()

  try {
    await streamKeeperMessage(keeperName, text, undefined, {
      signal: activeAbort.signal,
      onEvent: (event: KeeperChatStreamEvent) => {
        if (event.type === 'TEXT_DELTA' && event.delta) {
          streamBuffer.value += event.delta
        } else if (event.type === 'RUN_FINISHED') {
          const finalText = streamBuffer.value.trim() || '(no response)'
          chatMessages.value = [
            ...chatMessages.value,
            { role: 'assistant', content: finalText, timestamp: Date.now() },
          ]
          streamBuffer.value = ''
        } else if (event.type === 'RUN_ERROR') {
          chatError.value = String(event.value ?? 'Stream error')
        }
      },
    })
  } catch (err) {
    if (err instanceof DOMException && err.name === 'AbortError') return
    const msg = err instanceof Error ? err.message : 'Chat failed'
    chatError.value = msg
    showToast(msg, 'error')
  } finally {
    streaming.value = false
    activeAbort = null
  }
}

function msgBubble(role: string): string {
  return role === 'user'
    ? 'bg-[var(--accent-12)] border border-[var(--accent-20)] text-[var(--text-body)]'
    : 'bg-[var(--white-6)] border border-[var(--card-border)] text-[var(--text-body)]'
}

export function KeeperChatPanel({ name }: { name: string }) {
  const scrollRef = useRef<HTMLDivElement>(null)
  const messages = chatMessages.value
  const buffer = streamBuffer.value
  const isStreaming = streaming.value

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight
    }
  }, [messages.length, buffer])

  return html`
    <div class="flex flex-col rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] overflow-hidden">
      <div class="flex items-center justify-between py-2.5 px-3.5 border-b border-[var(--card-border)]">
        <span class="text-xs font-medium text-[var(--text-strong)]">@${name} 대화</span>
        ${isStreaming ? html`
          <${ActionButton} variant="ghost" size="sm" onClick=${cancelStream}>중단<//>
        ` : null}
      </div>

      <div class="flex-1 min-h-[200px] max-h-[400px] overflow-y-auto py-3 px-3.5 flex flex-col gap-2.5" ref=${scrollRef}>
        ${messages.length === 0 && !isStreaming ? html`
          <${EmptyState} class="py-10">keeper에게 메시지를 보내세요<//>
        ` : null}

        ${messages.map((msg, idx) => html`
          <div key=${idx} class="flex flex-col gap-[3px] max-w-[85%] ${msg.role === 'user' ? 'self-end' : 'self-start'}">
            <span class="text-[10px] text-[var(--text-dim)] uppercase tracking-wider ${msg.role === 'user' ? 'text-right' : ''}">${msg.role === 'user' ? 'You' : name}</span>
            <div class="rounded-lg py-2 px-3 text-[13px] leading-relaxed ${msgBubble(msg.role)}">${msg.content}</div>
          </div>
        `)}

        ${isStreaming && buffer ? html`
          <div class="flex flex-col gap-[3px] max-w-[85%] self-start">
            <span class="text-[10px] text-[var(--text-dim)] uppercase tracking-wider">${name}</span>
            <div class="rounded-lg py-2 px-3 text-[13px] leading-relaxed ${msgBubble('assistant')} border-[var(--accent)]">${buffer}<span class="animate-pulse text-[var(--accent)]">|</span></div>
          </div>
        ` : isStreaming ? html`
          <div class="flex flex-col gap-[3px] max-w-[85%] self-start">
            <span class="text-[10px] text-[var(--text-dim)] uppercase tracking-wider">${name}</span>
            <div class="rounded-lg py-2 px-3 text-[13px] leading-relaxed ${msgBubble('assistant')} animate-pulse">thinking...</div>
          </div>
        ` : null}
      </div>

      ${chatError.value ? html`<div class="mx-3.5 mb-2 p-2 rounded-lg bg-[rgba(239,68,68,0.08)] border border-[rgba(239,68,68,0.2)] text-xs text-[#fda4af]">${chatError.value}</div>` : null}

      <div class="flex gap-2 py-2.5 px-3.5 border-t border-[var(--card-border)]">
        <${TextInput}
          class="flex-1"
          placeholder="메시지 입력..."
          value=${chatInput.value}
          onInput=${(e: Event) => { chatInput.value = (e.target as HTMLInputElement).value }}
          onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter' && !e.shiftKey) void sendChat(name) }}
          disabled=${isStreaming}
        />
        <${ActionButton}
          variant="primary"
          onClick=${() => { void sendChat(name) }}
          disabled=${isStreaming || chatInput.value.trim() === ''}
        >
          ${isStreaming ? '...' : '전송'}
        <//>
      </div>
    </div>
  `
}
