// @vitest-environment jsdom

import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { AttachmentRef } from '../../api/attachments'
import { currentSessionEpoch } from '../../core/auth'
import { dedupeHistoryToolRows, groupTranscriptEntries, parseChatMessageBlocks, shouldRenderChatEntry, DEFAULT_CHAT_BLOCK_PREFS } from './chat-blocks'
import { KeeperChatTab } from './keeper-chat-tab'
import {
  buildChatStreamRequestBody,
  decodeHistoryRow,
  streamKeeperChat,
} from './keepers-api'
import type { KeeperRosterItem } from './types'

const PNG_BYTES = Uint8Array.from(
  atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII='),
  (c) => c.charCodeAt(0),
)
const SHA_USER = '1'.repeat(64)
const ATT_USER: AttachmentRef = {
  id: `att_${SHA_USER}`,
  attachment_id: `att_${SHA_USER}`,
  sha256: SHA_USER,
  url: `/api/v1/attachments/att_${SHA_USER}`,
  mime_type: 'image/png',
  kind: 'image',
  bytes: 2048,
  width: 800,
  height: 600,
  filename: 'user-shot.png',
  origin: 'user_upload',
  created_at_unix: 1777100001.25,
  retention: 'durable',
}

const SHA_TOOL = '2'.repeat(64)
const ATT_TOOL: AttachmentRef = {
  id: `att_${SHA_TOOL}`,
  attachment_id: `att_${SHA_TOOL}`,
  sha256: SHA_TOOL,
  url: `/api/v1/attachments/att_${SHA_TOOL}`,
  mime_type: 'image/png',
  kind: 'image',
  bytes: 4096,
  width: 1280,
  height: 720,
  filename: 'browser-capture.png',
  origin: 'tool_capture',
  created_at_unix: 1777100002.5,
  retention: 'ephemeral',
}

const SHA_GEN = '3'.repeat(64)
const ATT_GEN: AttachmentRef = {
  id: `att_${SHA_GEN}`,
  attachment_id: `att_${SHA_GEN}`,
  sha256: SHA_GEN,
  url: `/api/v1/attachments/att_${SHA_GEN}`,
  mime_type: 'image/webp',
  kind: 'image',
  bytes: 8192,
  width: 1024,
  height: 1024,
  filename: 'generated.webp',
  origin: 'model_generated',
  created_at_unix: 1777100003.75,
  retention: 'durable',
}

function makeKeeper(): KeeperRosterItem {
  return {
    name: 'vision-keeper',
    status: 'online',
    phase: 'idle',
    health: 'healthy',
    paused: false,
    keepalive_running: true,
    activation_mode: 'active',
    runtime_id: 'openai.gpt-4o',
    sandbox_profile: null,
    company: 'core',
    context_ratio: 0.25,
    context_tokens: 32000,
    context_max: 128000,
    context_unavailable_reason: null,
    runtime_blocker_summary: null,
    last_failure: null,
    directory_issue: null,
    turns_24h: 4,
    candle_balance_milli: null,
    portrait_equipment: null,
    chat_control_token: null,
    active_turn: null,
  }
}

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

describe('Keeper Chat upload-first request body, history decoding, and live KEEPER_ATTACHMENT SSE', () => {
  it('builds upload-first user_blocks + lightweight attachments without inline base64', () => {
    const withText = buildChatStreamRequestBody({
      keeper: 'vision-keeper',
      message: '이 화면을 분석해줘',
      operationId: 'op-att-1',
      mode: { kind: 'queue' },
      attachments: [ATT_USER],
    })
    expect(withText.user_blocks).toEqual([
      { type: 'text', text: '이 화면을 분석해줘' },
      { type: 'attachment', attachment_id: ATT_USER.attachment_id },
    ])
    expect(withText.attachments).toEqual([
      {
        attachment_id: ATT_USER.attachment_id,
        id: ATT_USER.id,
        url: ATT_USER.url,
        mime_type: 'image/png',
        kind: 'image',
        bytes: 2048,
        width: 800,
        height: 600,
        filename: 'user-shot.png',
      },
    ])
    expect(JSON.stringify(withText)).not.toContain('"data":')

    // Attachment-only send omits empty text block
    const attOnly = buildChatStreamRequestBody({
      keeper: 'vision-keeper',
      message: '   ',
      operationId: 'op-att-2',
      mode: { kind: 'queue' },
      attachments: [ATT_USER],
    })
    expect(attOnly.user_blocks).toEqual([
      { type: 'attachment', attachment_id: ATT_USER.attachment_id },
    ])
  })

  it('decodes and deduplicates user, tool, and assistant attachments from history rows and preserves tool screenshots across dedupeHistoryToolRows', () => {
    const userRow = decodeHistoryRow({
      id: 'row-u1',
      role: 'user',
      content: '',
      ts: 100,
      attachments: [ATT_USER],
      blocks: [{ t: 'attachment', attachment_id: ATT_USER.attachment_id, url: ATT_USER.url, mime_type: 'image/png', kind: 'image' }],
    })!
    expect(userRow.attachments).toHaveLength(1)
    expect(userRow.attachments?.[0]?.filename).toBe('user-shot.png')
    // Attachment-only user row must render even with empty content
    expect(shouldRenderChatEntry(userRow, parseChatMessageBlocks(userRow), DEFAULT_CHAT_BLOCK_PREFS)).toBe(true)

    const toolRow = decodeHistoryRow({
      id: 'row-t1',
      role: 'tool',
      content: '{"url":"https://example.com"}',
      tool_call_name: 'masc_browser_screenshot',
      execution_id: 'exec-shot-1',
      ts: 101,
      attachments: [ATT_TOOL],
    })!
    const assistantRow = decodeHistoryRow({
      id: 'row-a1',
      role: 'assistant',
      content: '화면을 확인했습니다.',
      ts: 102,
      blocks: [
        { t: 'trace', trace: [{ kind: 'tool', name: 'masc_browser_screenshot', execution_id: 'exec-shot-1', status: 'ok' }] },
        { t: 'attachment', ...ATT_GEN },
      ],
    })!

    const deduped = dedupeHistoryToolRows([userRow, toolRow, assistantRow])
    expect(deduped).toHaveLength(2)
    const enrichedAssistant = deduped[1]!
    expect(enrichedAssistant.attachments?.map((a) => a.attachment_id)).toEqual([
      ATT_GEN.attachment_id,
      ATT_TOOL.attachment_id,
    ])
    expect(enrichedAssistant.toolCalls?.[0]?.attachments?.map((a) => a.attachment_id)).toEqual([
      ATT_TOOL.attachment_id,
    ])

    // Standalone tool row with attachment is never collapsed into a text-only tool_group
    const standaloneTool = decodeHistoryRow({
      id: 'row-t2',
      role: 'tool',
      content: '{"ok":true}',
      tool_call_name: 'keeper_generate_image',
      execution_id: 'exec-standalone',
      ts: 103,
      attachments: [ATT_TOOL],
    })!
    const grouped = groupTranscriptEntries([{ msg: standaloneTool, blocks: parseChatMessageBlocks(standaloneTool) }])
    expect(grouped[0]?.kind).toBe('message')
  })

  it('dispatches canonical KEEPER_ATTACHMENT events (user, tool, assistant) with response ownership and compat KEEPER_MEDIA_DELTA', async () => {
    const legacyMedia = `/api/v1/media/${'f'.repeat(64)}`
    const events = [
      { type: 'CUSTOM', name: 'KEEPER_ATTACHMENT', value: { ...ATT_USER, role: 'user' } },
      { type: 'CUSTOM', name: 'KEEPER_ATTACHMENT', value: { ...ATT_TOOL, role: 'tool', tool_call_id: 'tc-1' } },
      {
        type: 'CUSTOM',
        name: 'KEEPER_ATTACHMENT',
        value: { ...ATT_GEN, role: 'assistant', block_index: 0, response: { content_generation: 2, stream_scope: 1 } },
      },
      // Stale response generation must be ignored
      {
        type: 'CUSTOM',
        name: 'KEEPER_ATTACHMENT',
        value: {
          attachment_id: `att_${'9'.repeat(64)}`,
          url: `/api/v1/attachments/att_${'9'.repeat(64)}`,
          mime_type: 'image/png',
          kind: 'image',
          role: 'assistant',
          response: { content_generation: 1, stream_scope: 1 },
        },
      },
      {
        type: 'CUSTOM',
        name: 'KEEPER_MEDIA_DELTA',
        value: {
          index: 0,
          media_type: 'image/png',
          source_type: 'base64',
          media_ref: legacyMedia,
          response: { content_generation: 2, stream_scope: 1 },
        },
      },
      { type: 'RUN_FINISHED' },
    ]

    const onAttachment = vi.fn()
    const onRetainedImages = vi.fn()
    await streamKeeperChat({
      keeper: 'vision-keeper',
      message: 'check',
      operationId: 'op-sse-att',
      mode: { kind: 'queue' },
      fetchImpl: vi.fn(async () => new Response(
        events.map((e) => `data: ${JSON.stringify(e)}\n\n`).join(''),
        { headers: { 'Content-Type': 'text/event-stream' } },
      )),
      callbacks: { onAttachment, onRetainedImages },
    })

    expect(onAttachment).toHaveBeenCalledTimes(3)
    expect(onAttachment.mock.calls.map(([ev]) => [ev.role, ev.attachment.attachment_id, ev.toolCallId])).toEqual([
      ['user', ATT_USER.attachment_id, undefined],
      ['tool', ATT_TOOL.attachment_id, 'tc-1'],
      ['assistant', ATT_GEN.attachment_id, undefined],
    ])
    expect(onRetainedImages).toHaveBeenCalledWith([
      { path: legacyMedia, workspaceEpoch: currentSessionEpoch() },
    ])
  })

  it('uploads pasted image, sends user_blocks + attachments, renders optimistic user image and live KEEPER_ATTACHMENT in KeeperChatTab', async () => {
    vi.stubGlobal('IntersectionObserver', undefined)
    let chatPostBody: Record<string, unknown> | null = null
    const mockFetch = vi.fn<typeof fetch>(async (input, init) => {
      const url = new URL(String(input), window.location.origin)
      if (url.pathname === '/api/v1/attachments' && init?.method === 'POST') {
        return new Response(JSON.stringify({ ok: true, data: ATT_USER }), {
          status: 201,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.pathname.startsWith('/api/v1/attachments/')) {
        return new Response(PNG_BYTES, { status: 200, headers: { 'Content-Type': 'image/png' } })
      }
      if (url.pathname === '/api/v1/keepers/chat/stream' && init?.method === 'POST') {
        chatPostBody = JSON.parse(String(init.body)) as Record<string, unknown>
        const sseEvents = [
          { type: 'CUSTOM', name: 'KEEPER_CHAT_OPERATION_ACCEPTED', value: { operation_id: chatPostBody.request_id, state: 'Running', queued_count: 0 } },
          { type: 'TEXT_MESSAGE_CONTENT', delta: '이미지를 생성했습니다.', response: { content_generation: 1, stream_scope: 0 } },
          { type: 'CUSTOM', name: 'KEEPER_ATTACHMENT', value: { ...ATT_GEN, role: 'assistant', response: { content_generation: 1, stream_scope: 0 } } },
          { type: 'RUN_FINISHED' },
        ]
        return new Response(
          sseEvents.map((e) => `data: ${JSON.stringify(e)}\n\n`).join(''),
          { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
        )
      }
      if (url.pathname.includes('/chat/history/page')) {
        return new Response(JSON.stringify({
          messages: chatPostBody
            ? [
                { id: 'persisted-u', role: 'user', content: '봐줘', ts: 100, attachments: [ATT_USER] },
                { id: 'persisted-a', role: 'assistant', content: '이미지를 생성했습니다.', ts: 101, attachments: [ATT_GEN] },
              ]
            : [],
          has_more: false,
          next_cursor: null,
        }), { headers: { 'Content-Type': 'application/json' } })
      }
      if (url.pathname.includes('/chat/operations')) {
        return new Response(JSON.stringify({ schema: 'masc.keeper_chat_operations_page.v1', operations: [], next_cursor: null }), {
          headers: { 'Content-Type': 'application/json' },
        })
      }
      return new Response(JSON.stringify({ rows: [] }), { headers: { 'Content-Type': 'application/json' } })
    })
    vi.stubGlobal('fetch', mockFetch)

    const view = render(html`<${KeeperChatTab} keeper=${makeKeeper()} onInspect=${vi.fn()} onMutated=${vi.fn()} />`)

    // Paste an image into the composer
    const pasted = new File([PNG_BYTES], 'user-shot.png', { type: 'image/png' })
    fireEvent.paste(view.getByTestId('attachment-composer'), {
      clipboardData: {
        items: [{ kind: 'file', getAsFile: () => pasted }],
        files: [pasted],
      },
    })
    await view.findByText('user-shot.png')
    await waitFor(() => {
      expect(view.getByTestId('attachment-chip').getAttribute('data-status')).toBe('ready')
    })

    // Type text and submit
    const textarea = view.getByLabelText('Keeper 채팅 입력') as HTMLTextAreaElement
    fireEvent.input(textarea, { target: { value: '봐줘' } })
    fireEvent.click(view.getByRole('button', { name: 'Queue ↵' }))

    await waitFor(() => {
      expect(chatPostBody).not.toBeNull()
    })
    expect(chatPostBody!.user_blocks).toEqual([
      { type: 'text', text: '봐줘' },
      { type: 'attachment', attachment_id: ATT_USER.attachment_id },
    ])
    expect(chatPostBody!.attachments).toHaveLength(1)
    expect(JSON.stringify(chatPostBody)).not.toContain('"data":')

    // Both user attachment and assistant generated image render via AttachmentGallery
    await waitFor(() => {
      const galleries = view.container.querySelectorAll('[data-testid="attachment-gallery"]')
      expect(galleries.length).toBeGreaterThanOrEqual(2)
    })
    expect(view.container.querySelector(`[data-attachment-id="${ATT_USER.attachment_id}"]`)).not.toBeNull()
    expect(view.container.querySelector(`[data-attachment-id="${ATT_GEN.attachment_id}"]`)).not.toBeNull()
  })
})
