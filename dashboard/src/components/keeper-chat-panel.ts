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
  type StreamAttachment,
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
  type Attachment,
  getChatMessageBuffer,
  appendChatMessage,
  mergeServerHistory,
  flushStreamBuffer,
  enqueueInput,
  dequeueInput,
  markInputSent,
  clearInputQueue,
  getQueueLength,
} from '../keeper-chat-store'

const ALLOWED_IMAGE_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp']
const ALLOWED_FILE_TYPES = ['text/plain', 'text/markdown', 'application/json', 'text/csv']
const MAX_IMAGE_SIZE = 5 * 1024 * 1024
const MAX_FILE_SIZE = 2 * 1024 * 1024
const MAX_TOTAL_PAYLOAD = 10 * 1024 * 1024
const MAX_ATTACHMENTS = 5

function validateFile(file: File): string | null {
  if (file.type.startsWith('image/')) {
    if (!ALLOWED_IMAGE_TYPES.includes(file.type)) return `지원하지 않는 이미지 형식: ${file.type}`
    if (file.size > MAX_IMAGE_SIZE) return '이미지 크기 초과 (최대 5MB)'
  } else {
    if (!ALLOWED_FILE_TYPES.includes(file.type)) return `지원하지 않는 파일 형식: ${file.type}`
    if (file.size > MAX_FILE_SIZE) return '파일 크기 초과 (최대 2MB)'
  }
  return null
}

function readFileAsDataURL(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result as string)
    reader.onerror = () => reject(new Error('파일 읽기 실패'))
    reader.readAsDataURL(file)
  })
}

async function resizeImage(file: File, maxWidth = 1920): Promise<File> {
  if (!file.type.startsWith('image/')) return file
  return new Promise((resolve) => {
    const img = new Image()
    const objectUrl = URL.createObjectURL(file)
    img.onload = () => {
      URL.revokeObjectURL(objectUrl)
      if (img.width <= maxWidth) { resolve(file); return }
      const canvas = document.createElement('canvas')
      const scale = maxWidth / img.width
      canvas.width = maxWidth
      canvas.height = Math.round(img.height * scale)
      const ctx = canvas.getContext('2d')
      if (!ctx) { resolve(file); return }
      ctx.drawImage(img, 0, 0, canvas.width, canvas.height)
      canvas.toBlob((blob) => {
        if (!blob) { resolve(file); return }
        resolve(new File([blob], file.name, { type: file.type }))
      }, file.type)
    }
    img.onerror = () => {
      URL.revokeObjectURL(objectUrl)
      resolve(file)
    }
    img.src = objectUrl
  })
}

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
    attachments: msg.attachments,
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
  const chatMessages = useMemo(() => signal<ChatMessage[]>(getChatMessageBuffer(name)), [name])
  const chatInput = useMemo(() => signal(''), [])
  const streaming = useMemo(() => signal(false), [])
  const streamBuffer = useMemo(() => signal(''), [])
  const streamStartedAt = useMemo(() => signal<number | null>(null), [])
  const chatError = useMemo(() => signal(''), [])
  const searchQuery = useMemo(() => signal(''), [])
  const historyLoaded = useMemo(() => signal(false), [])

  const activeAbortRef = useRef<AbortController | null>(null)
  const fileInputRef = useRef<HTMLInputElement | null>(null)
  const selectedAttachments = useMemo(() => signal<Attachment[]>([]), [])

  async function handleFileSelect(files: FileList | null): Promise<void> {
    if (!files) return
    const newAttachments: Attachment[] = []
    let totalSize = selectedAttachments.value.reduce((sum, a) => sum + a.size, 0)

    for (const file of Array.from(files).slice(0, MAX_ATTACHMENTS - selectedAttachments.value.length)) {
      const error = validateFile(file)
      if (error) { showToast(error, 'error'); continue }
      const resized = await resizeImage(file)
      const dataUrl = await readFileAsDataURL(resized)
      const base64Size = Math.ceil(dataUrl.length * 0.75)
      totalSize += base64Size
      if (totalSize > MAX_TOTAL_PAYLOAD) {
        showToast('총 첨부 크기가 10MB를 초과합니다.', 'error')
        break
      }
      newAttachments.push({
        id: `att-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
        type: resized.type.startsWith('image/') ? 'image' : 'file',
        name: resized.name,
        size: base64Size,
        mimeType: resized.type,
        data: dataUrl,
      })
    }
    selectedAttachments.value = [...selectedAttachments.value, ...newAttachments]
  }

  function removeAttachment(id: string): void {
    selectedAttachments.value = selectedAttachments.value.filter((a) => a.id !== id)
  }

  function handlePaste(event: ClipboardEvent): void {
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
      void handleFileSelect(dt.files)
    }
  }

  function cancelStream(): void {
    if (activeAbortRef.current) activeAbortRef.current.abort()
    activeAbortRef.current = null
    streaming.value = false
    streamBuffer.value = ''
    streamStartedAt.value = null
  }

  async function loadHistory(keeperName: string): Promise<void> {
    if (historyLoaded.value) return
    historyLoaded.value = true
    try {
      const history = await fetchKeeperChatHistory(keeperName)
      if (history.length > 0) {
        const serverMsgs = history.map((m) => ({
          role: m.role === 'assistant' ? 'assistant' as const : 'user' as const,
          content: m.content,
          timestamp: m.ts * 1000,
          source: 'api' as const,
        }))
        mergeServerHistory(keeperName, serverMsgs)
        chatMessages.value = getChatMessageBuffer(keeperName)
      }
    } catch (err: unknown) {
      const msg = errorToString(err)
      chatError.value = `이전 대화 불러오기 실패: ${msg}`
    }
  }

  async function sendChat(keeperName: string, queuedText?: string): Promise<void> {
    await loadHistory(keeperName)

    const text = queuedText ?? chatInput.value.trim()
    if (!text) return

    if (streaming.value && !queuedText) {
      chatInput.value = ''
      enqueueInput(keeperName, text)
      return
    }

    if (!queuedText) chatInput.value = ''
    chatError.value = ''
    streamBuffer.value = ''
    streamStartedAt.value = Date.now()

    const userMsg: ChatMessage = {
      role: 'user',
      content: text,
      timestamp: Date.now(),
      source: 'dashboard',
      attachments: selectedAttachments.value.length > 0 ? selectedAttachments.value : undefined,
    }
    appendChatMessage(keeperName, userMsg)
    chatMessages.value = getChatMessageBuffer(keeperName)
    selectedAttachments.value = []

    streaming.value = true
    activeAbortRef.current = new AbortController()

    const apiAttachments: StreamAttachment[] | undefined =
      userMsg.attachments?.map((att) => ({
        id: att.id,
        type: att.type,
        name: att.name,
        size: att.size,
        mimeType: att.mimeType,
        data: att.data,
      }))

    try {
      await streamKeeperMessage(keeperName, text, {
        signal: activeAbortRef.current.signal,
        attachments: apiAttachments,
        onEvent: (event: KeeperChatStreamEvent) => {
          if (isKeeperTextContentEvent(event) && typeof event.delta === 'string') {
            streamBuffer.value += event.delta
          } else if (event.type === 'RUN_FINISHED') {
            const finalText = streamBuffer.value.trim() || '(no response)'
            const assistantMsg: ChatMessage = { role: 'assistant', content: finalText, timestamp: Date.now(), source: 'dashboard' }
            appendChatMessage(keeperName, assistantMsg)
            chatMessages.value = getChatMessageBuffer(keeperName)
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

      markInputSent(keeperName)
      const next = dequeueInput(keeperName)
      if (next) {
        void sendChat(keeperName, next.content)
      }
    }
  }

  useEffect(() => {
    // External-system sync: flush an in-progress stream buffer into the
    // store when the component unmounts (tab change, route navigation).
    // No data init here — history is loaded lazily on first interaction.
    return () => {
      if (streaming.value && streamBuffer.value.trim()) {
        flushStreamBuffer(name, streamBuffer.value)
      }
    }
  }, [name])

  const messages = chatMessages.value
  const buffer = streamBuffer.value
  const isStreaming = streaming.value
  const query = searchQuery.value
  const hasQuery = query.trim().length > 0
  const queueCount = getQueueLength(name)
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
    <div class="overflow-hidden rounded-[var(--radius-xl)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] shadow-[var(--shadow-raised)]" onPaste=${handlePaste}>
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
        ${queueCount > 0
          ? html`<div class="mb-2 flex items-center gap-2 text-2xs text-[var(--color-fg-muted)]">
              <span class="inline-flex items-center rounded-full bg-[var(--accent-20)] px-2 py-0.5 font-medium text-[var(--color-fg-secondary)]">${queueCount}개 대기 중</span>
              <button class="underline hover:text-[var(--color-fg-secondary)]" onClick=${() => { clearInputQueue(name); chatMessages.value = [...getChatMessageBuffer(name)] }}>취소</button>
            </div>`
          : null}
        ${selectedAttachments.value.length > 0
          ? html`<div class="mb-2 flex flex-wrap gap-2">
              ${selectedAttachments.value.map((att) => html`
                <div class="group relative inline-flex items-center gap-1.5 rounded-lg border border-[var(--color-border-default)] bg-[var(--color-bg-muted)] px-2 py-1 text-2xs">
                  ${att.type === 'image'
                    ? html`<img src=${att.data} class="h-6 w-6 rounded object-cover" alt="" />`
                    : html`<span class="text-[var(--color-fg-muted)]">📄</span>`}
                  <span class="max-w-32 truncate text-[var(--color-fg-secondary)]">${att.name}</span>
                  <button
                    class="ml-1 rounded-full p-0.5 text-[var(--color-fg-muted)] hover:bg-[var(--warn-20)] hover:text-[var(--warn-bright)]"
                    onClick=${() => removeAttachment(att.id)}
                    title="제거"
                  >×</button>
                </div>`)}`
          : null}
        <div class="flex items-end gap-2">
          <button
            class="flex-shrink-0 rounded-lg border border-[var(--color-border-default)] px-2.5 py-2 text-sm hover:bg-[var(--color-bg-muted)] disabled:opacity-50"
            onClick=${() => fileInputRef.current?.click()}
            disabled=${chatAccess.blocked}
            title="파일 첨부"
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
              void handleFileSelect(target.files)
              target.value = ''
            }}
          />
          <div class="flex-1">
            <${ChatComposer}
              draft=${chatInput.value}
              placeholder=${isStreaming ? '답변 중... 메시지를 입력하면 대기열에 추가됩니다' : chatAccess.blocked ? '현재 actor는 direct keeper chat 권한이 없습니다' : '메시지 입력...'}
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
      </div>
    </div>
  `
}
