// Keeper Chat Panel — SSE streaming conversation with a keeper agent.
// Uses streamKeeperMessage() for real-time token-by-token responses.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { streamKeeperMessage, type KeeperChatStreamEvent } from '../api/keeper'
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
    <div class="keeper-chat">
      <div class="keeper-chat__header">
        <span class="keeper-chat__title">@${name} 대화</span>
        ${isStreaming ? html`
          <button class="control-btn ghost keeper-chat__cancel" onClick=${cancelStream}>중단</button>
        ` : null}
      </div>

      <div class="keeper-chat__messages" ref=${scrollRef}>
        ${messages.length === 0 && !isStreaming ? html`
          <div class="keeper-chat__empty">keeper에게 메시지를 보내세요</div>
        ` : null}

        ${messages.map((msg, idx) => html`
          <div key=${idx} class="keeper-chat__msg keeper-chat__msg--${msg.role}">
            <span class="keeper-chat__role">${msg.role === 'user' ? 'You' : name}</span>
            <div class="keeper-chat__text">${msg.content}</div>
          </div>
        `)}

        ${isStreaming && buffer ? html`
          <div class="keeper-chat__msg keeper-chat__msg--assistant keeper-chat__msg--streaming">
            <span class="keeper-chat__role">${name}</span>
            <div class="keeper-chat__text">${buffer}<span class="keeper-chat__cursor">|</span></div>
          </div>
        ` : isStreaming ? html`
          <div class="keeper-chat__msg keeper-chat__msg--assistant keeper-chat__msg--streaming">
            <span class="keeper-chat__role">${name}</span>
            <div class="keeper-chat__text keeper-chat__text--thinking">thinking...</div>
          </div>
        ` : null}
      </div>

      ${chatError.value ? html`<div class="keeper-chat__error">${chatError.value}</div>` : null}

      <div class="keeper-chat__input-row">
        <input
          class="control-input keeper-chat__input"
          type="text"
          placeholder="메시지 입력..."
          value=${chatInput.value}
          onInput=${(e: Event) => { chatInput.value = (e.target as HTMLInputElement).value }}
          onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter' && !e.shiftKey) void sendChat(name) }}
          disabled=${isStreaming}
        />
        <button
          class="control-btn keeper-chat__send"
          onClick=${() => { void sendChat(name) }}
          disabled=${isStreaming || chatInput.value.trim() === ''}
        >
          ${isStreaming ? '...' : '전송'}
        </button>
      </div>
    </div>
  `
}
