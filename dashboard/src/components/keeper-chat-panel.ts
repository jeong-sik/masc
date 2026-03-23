// Keeper Chat Panel — SSE streaming conversation with a keeper agent.
// Uses streamKeeperMessage() for real-time token-by-token responses.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { streamKeeperMessage, type KeeperChatStreamEvent } from '../api/keeper'
import { asString, isRecord } from './common/normalize'
import { showToast } from './common/toast'
import { ActionButton } from './common/button'
import { TextInput } from './common/input'

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

export function isKeeperTextContentEvent(event: KeeperChatStreamEvent): boolean {
  return event.type === 'TEXT_MESSAGE_CONTENT' || event.type === 'TEXT_DELTA'
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
  return 'Stream error'
}

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
        if (isKeeperTextContentEvent(event) && event.delta) {
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
      <div class="keeper-chat__header flex items-center justify-between py-2.5 px-3.5">
        <span class="keeper-chat__title">@${name} 대화</span>
        ${isStreaming ? html`
          <${ActionButton} variant="ghost" class="keeper-chat__cancel" onClick=${cancelStream}>중단<//>
        ` : null}
      </div>

      <div class="keeper-chat__messages flex-1 min-h-[200px] max-h-[400px] overflow-y-auto py-3 px-3.5 flex flex-col gap-3" ref=${scrollRef}>
        ${messages.length === 0 && !isStreaming ? html`
          <div class="text-[var(--white-20)] text-[var(--fs-base)] text-center py-10">keeper에게 메시지를 보내세요</div>
        ` : null}

        ${messages.map((msg, idx) => html`
          <div key=${idx} class="keeper-chat__msg flex flex-col gap-[3px] max-w-[85%] keeper-chat__msg--${msg.role} ${msg.role === 'user' ? 'self-end' : 'self-start'}">
            <span class="keeper-chat__role text-[var(--fs-2xs)] text-[var(--white-35)] uppercase tracking-[0.5px]">${msg.role === 'user' ? 'You' : name}</span>
            <div class="keeper-chat__text rounded-lg">${msg.content}</div>
          </div>
        `)}

        ${isStreaming && buffer ? html`
          <div class="keeper-chat__msg flex flex-col gap-[3px] max-w-[85%] keeper-chat__msg--assistant keeper-chat__msg--streaming self-start">
            <span class="keeper-chat__role text-[var(--fs-2xs)] text-[var(--white-35)] uppercase tracking-[0.5px]">${name}</span>
            <div class="keeper-chat__text rounded-lg">${buffer}<span class="keeper-chat__cursor">|</span></div>
          </div>
        ` : isStreaming ? html`
          <div class="keeper-chat__msg flex flex-col gap-[3px] max-w-[85%] keeper-chat__msg--assistant keeper-chat__msg--streaming self-start">
            <span class="keeper-chat__role text-[var(--fs-2xs)] text-[var(--white-35)] uppercase tracking-[0.5px]">${name}</span>
            <div class="keeper-chat__text rounded-lg keeper-chat__text--thinking">thinking...</div>
          </div>
        ` : null}
      </div>

      ${chatError.value ? html`<div class="keeper-chat__error">${chatError.value}</div>` : null}

      <div class="keeper-chat__input-row flex gap-2 py-2.5 px-3.5">
        <${TextInput}
          class="flex-1"
          placeholder="메시지 입력..."
          value=${chatInput.value}
          onInput=${(e: Event) => { chatInput.value = (e.target as HTMLInputElement).value }}
          onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter' && !e.shiftKey) void sendChat(name) }}
          disabled=${isStreaming}
        />
        <${ActionButton}
          class="shrink-0"
          onClick=${() => { void sendChat(name) }}
          disabled=${isStreaming || chatInput.value.trim() === ''}
        >
          ${isStreaming ? '...' : '전송'}
        <//>
      </div>
    </div>
  `
}
