// @vitest-environment jsdom

import { html } from 'htm/preact'
import { render, options } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ChatBlock, KeeperConversationAttachment, KeeperConversationEntry } from '../../types'
import type { ToolCallEntry } from '../../api/dashboard'
import {
  CHAT_COMPOSER_COMMAND_HEADER_SUFFIX,
  CHAT_COMPOSER_DROP_PLACEHOLDER,
  ChatComposer,
  ChatTranscript,
  THINKING_TRACE_PREVIEW_CHARS,
  type ChatComposerSendPayload,
} from './primitives'
import { _resetChatStoreForTests, readKeeperDraft } from '../../keeper-chat-store'
import { collectAttachments } from './attachments'
import { recordToolCallOutputs, resetToolCallOutputs } from '../../tool-call-output-store'
import { fetchBoardPost } from '../../api/board'

vi.mock('./attachments', () => ({
  collectAttachments: vi.fn(),
}))

vi.mock('../../api/board', () => ({
  fetchBoardPost: vi.fn(),
}))

export let mockTranscribeCallback: ((text: string) => void) | null = null
vi.mock('./voice-input', () => ({
  voiceInputSupported: () => true,
  useVoiceInput: ({ onTranscribed }: any) => {
    mockTranscribeCallback = onTranscribed
    return {
      state: 'idle',
      supported: true,
      start: vi.fn(),
      stop: vi.fn(),
    }
  },
}))

const flushUi = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 30))

function makeFileList(files: File[]): FileList {
  const list = [...files] as unknown as FileList
  Object.defineProperties(list, {
    length: { value: files.length },
    item: { value: (index: number) => files[index] ?? null },
  })
  return list
}

function setInputFiles(input: HTMLInputElement, files: File[]): void {
  Object.defineProperty(input, 'files', {
    configurable: true,
    value: makeFileList(files),
  })
}

function dataTransferWith(files: File[]): DataTransfer {
  return { files: makeFileList(files) } as DataTransfer
}

function toolEntry(
  overrides: Partial<KeeperConversationEntry> & Pick<KeeperConversationEntry, 'id'>,
): KeeperConversationEntry {
  return {
    role: 'tool',
    source: 'tool_result',
    label: 'keeper_context_status',
    text: '{}',
    rawText: '{}',
    timestamp: '2026-03-24T00:00:00.000Z',
    delivery: 'history',
    streamState: null,
    details: null,
    error: null,
    ...overrides,
  }
}

function toolCallOutput(overrides: Partial<ToolCallEntry> & Pick<ToolCallEntry, 'tool_use_id'>): ToolCallEntry {
  return {
    ts: 0,
    keeper: 'sangsu',
    tool: 'keeper_context_status',
    input: {},
    output: 'context window ok',
    success: true,
    duration_ms: 12,
    ...overrides,
  }
}

function entry(
  overrides: Partial<KeeperConversationEntry> & Pick<KeeperConversationEntry, 'id' | 'text'>,
): KeeperConversationEntry {
  const { id, text, ...rest } = overrides
  return {
    id,
    role: 'user',
    source: 'direct_user',
    label: '사용자',
    text,
    rawText: rest.rawText ?? text,
    timestamp: '2026-03-24T00:00:00.000Z',
    delivery: 'history',
    streamState: null,
    details: null,
    error: null,
    ...rest,
  }
}

describe('ChatTranscript', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resetToolCallOutputs()
  })

  it('surfaces tool output joined by tool_use_id in the collapsed preview', () => {
    recordToolCallOutputs([toolCallOutput({ tool_use_id: 'toolu_x', output: 'context window 42%' })])
    render(
      html`<${ChatTranscript}
        entries=${[toolEntry({ id: 'tool-toolu_x' })]}
        emptyText="empty"
      />`,
      container,
    )

    const bubble = container.querySelector('[data-chat-variant="tool-call"]')
    expect(bubble).not.toBeNull()
    // No-argument tool (`{}`): the collapsed glance shows the result, not args.
    expect(bubble?.textContent).toContain('context window 42%')
    // Success status marker is rendered in the header.
    expect(bubble?.textContent).toContain('✓')
  })

  it('preserves structured failure messages as preformatted text', () => {
    const text = 'Keeper request failed: Internal error: [masc_oas_error] {"kind":"accept_rejected","scope":"ollama_cloud.deepseek-v4-flash","reason_kind":"no_usable_progress","last_tool_effect":"mutating"}'
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'err-1',
            role: 'assistant',
            source: 'direct_assistant',
            label: 'sangsu',
            text,
            rawText: text,
            delivery: 'error',
            error: text,
          }),
        ]}
        emptyText="empty"
        variant="messenger"
      />`,
      container,
    )

    const pre = container.querySelector('[data-chat-structured-error]')
    expect(pre?.tagName).toBe('PRE')
    expect(pre?.classList.contains('chat-error-text')).toBe(true)
    expect(pre?.classList.contains('break-words')).toBe(false)
    expect(pre?.textContent).toContain('ollama_cloud.deepseek-v4-flash')
    expect(Array.from(pre?.querySelectorAll('.chat-error-token') ?? []).some(node =>
      node.textContent?.includes('ollama_cloud.deepseek-v4-flash'),
    )).toBe(true)
    expect(container.querySelector('[data-chat-blocks]')).toBeNull()
  })

  it('exposes entry provenance as rendered attributes and surface links', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'discord-1',
            role: 'assistant',
            source: 'direct_assistant',
            label: 'sangsu',
            text: 'channel reply',
            rawText: 'channel reply',
            turnRef: 'trace-ui#9',
            surface: {
              kind: 'discord',
              guild_id: 'guild-1',
              channel_id: 'channel-1',
              thread_id: 'thread-1',
            },
          }),
        ]}
        emptyText="empty"
        variant="messenger"
        showSourceBadge=${true}
      />`,
      container,
    )

    const bubble = container.querySelector('[data-chat-entry-id="discord-1"]') as HTMLElement
    expect(bubble).not.toBeNull()
    expect(bubble.getAttribute('data-chat-source')).toBe('direct_assistant')
    expect(bubble.getAttribute('data-chat-surface-kind')).toBe('discord')
    expect(bubble.getAttribute('data-chat-turn-ref')).toBe('trace-ui#9')
    expect(bubble.getAttribute('data-chat-stream-state')).toBe('complete')
    const surfaceLink = bubble.querySelector('a[href="https://discord.com/channels/guild-1/thread-1"]')
    expect(surfaceLink?.textContent).toContain('Discord Thread')
  })

  it('exposes tool-call transcript provenance as rendered attributes', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          toolEntry({
            id: 'tool-toolu_prov',
            label: 'keeper_context_status',
            turnRef: 'trace-tool#3',
            delivery: 'history',
          }),
        ]}
        emptyText="empty"
        groupToolCalls=${false}
      />`,
      container,
    )

    const bubble = container.querySelector('[data-chat-variant="tool-call"]') as HTMLElement
    expect(bubble).not.toBeNull()
    expect(bubble.getAttribute('data-chat-entry-id')).toBe('tool-toolu_prov')
    expect(bubble.getAttribute('data-chat-role')).toBe('tool')
    expect(bubble.getAttribute('data-chat-source')).toBe('tool_result')
    expect(bubble.getAttribute('data-chat-delivery-state')).toBe('history')
    expect(bubble.getAttribute('data-chat-stream-state')).toBe('complete')
    expect(bubble.getAttribute('data-chat-turn-ref')).toBe('trace-tool#3')
    expect(bubble.getAttribute('data-chat-tool-call-id')).toBe('toolu_prov')
  })

  it('marks a failed tool call with the error status glyph', () => {
    recordToolCallOutputs([
      toolCallOutput({ tool_use_id: 'toolu_y', success: false, output: 'boom' }),
    ])
    render(
      html`<${ChatTranscript}
        entries=${[toolEntry({ id: 'tool-toolu_y' })]}
        emptyText="empty"
      />`,
      container,
    )

    const bubble = container.querySelector('[data-chat-variant="tool-call"]')
    expect(bubble?.textContent).toContain('✗')
  })

  it('falls back to arguments and shows no status until output arrives', () => {
    render(
      html`<${ChatTranscript}
        entries=${[toolEntry({ id: 'tool-toolu_pending', text: '{"path":"a.ml"}' })]}
        emptyText="empty"
      />`,
      container,
    )

    const bubble = container.querySelector('[data-chat-variant="tool-call"]')
    expect(bubble?.textContent).toContain('a.ml')
    expect(bubble?.textContent).not.toContain('✓')
    expect(bubble?.textContent).not.toContain('✗')
  })

  it('renders args and output in labelled sections when expanded', async () => {
    recordToolCallOutputs([toolCallOutput({ tool_use_id: 'toolu_z', output: 'EXPANDED OUTPUT' })])
    render(
      html`<${ChatTranscript}
        entries=${[toolEntry({ id: 'tool-toolu_z', text: '{"k":"v"}' })]}
        emptyText="empty"
      />`,
      container,
    )

    const toggle = container.querySelector('[data-chat-variant="tool-call"] button') as HTMLButtonElement
    toggle.click()
    await flushUi()

    const bubble = container.querySelector('[data-chat-variant="tool-call"]')
    expect(bubble?.textContent).toContain('arguments')
    expect(bubble?.textContent).toContain('output')
    expect(bubble?.textContent).toContain('EXPANDED OUTPUT')
  })

  it('shows a waiting hint for a no-arg tool whose output has not landed, when expanded', async () => {
    render(
      html`<${ChatTranscript}
        entries=${[toolEntry({ id: 'tool-toolu_wait' })]}
        emptyText="empty"
      />`,
      container,
    )

    const toggle = container.querySelector('[data-chat-variant="tool-call"] button') as HTMLButtonElement
    toggle.click()
    await flushUi()

    const bubble = container.querySelector('[data-chat-variant="tool-call"]')
    expect(bubble?.textContent).toContain('출력 대기 중')
  })

  it('re-renders to show output when it arrives after the bubble mounted', async () => {
    // Real-world path: the bubble renders before the tool-call hydration
    // lands (output is always late). Reading the store signal during render
    // subscribes the bubble, so a later record() must update it.
    render(
      html`<${ChatTranscript}
        entries=${[toolEntry({ id: 'tool-toolu_late' })]}
        emptyText="empty"
      />`,
      container,
    )
    let bubble = container.querySelector('[data-chat-variant="tool-call"]')
    expect(bubble?.textContent).not.toContain('late output here')

    recordToolCallOutputs([toolCallOutput({ tool_use_id: 'toolu_late', output: 'late output here' })])
    await flushUi()

    bubble = container.querySelector('[data-chat-variant="tool-call"]')
    expect(bubble?.textContent).toContain('late output here')
    expect(bubble?.textContent).toContain('✓')
  })

  it('keeps saved delivery badges in the default transcript', () => {
    render(
      html`<${ChatTranscript}
        entries=${[entry({ id: 'u1', text: 'ping' })]}
        emptyText="empty"
      />`,
      container,
    )

    expect(container.querySelector('[data-chat-delivery="saved"]')).not.toBeNull()
  })

  it('renders no-argument tool call (args "{}") as "입력 없음", not a bare {}', () => {
    // Regression: keeper_tools_list streams args `{}` (no params). The old
    // ToolCallBubble rendered `T keeper_tools_list ▸ {}`, which read as an
    // empty RESULT. The fix labels args as "입력" and renders `{}` as
    // "입력 없음" so operators do not mistake a no-arg call for a no-result call.
    render(
      html`<${ChatTranscript}
        entries=${[entry({
          id: 'tool-1',
          role: 'tool',
          source: 'tool_result',
          label: 'keeper_tools_list',
          text: '{}',
        })]}
        emptyText="empty"
      />`,
      container,
    )
    expect(container.textContent).toContain('keeper_tools_list')
    expect(container.textContent).toContain('입력')
    expect(container.textContent).toContain('입력 없음')
  })

  it('labels tool-call arguments as "입력" and shows the arg JSON', () => {
    render(
      html`<${ChatTranscript}
        entries=${[entry({
          id: 'tool-2',
          role: 'tool',
          source: 'tool_result',
          label: 'keeper_board_post',
          text: '{"title":"hi"}',
        })]}
        emptyText="empty"
      />`,
      container,
    )
    expect(container.textContent).toContain('입력')
    expect(container.textContent).toContain('keeper_board_post')
    expect(container.textContent).toContain('"title"')
  })

  it('hides saved badges in messenger mode but keeps live state badges', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({ id: 'u1', text: 'ping' }),
          entry({
            id: 'a1',
            role: 'assistant',
            source: 'direct_assistant',
            label: 'sangsu',
            text: 'pong',
            delivery: 'streaming',
            streamState: 'streaming',
          }),
        ]}
        emptyText="empty"
        variant="messenger"
      />`,
      container,
    )

    expect(container.querySelector('[data-chat-variant="messenger"]')).not.toBeNull()
    expect(container.querySelector('[data-chat-delivery="saved"]')).toBeNull()
    expect(container.querySelector('[data-chat-delivery="live"]')).not.toBeNull()
  })

  it('renders a live placeholder for empty streaming text', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({ id: 'u1', text: 'ping' }),
          entry({
            id: 'a1',
            role: 'assistant',
            source: 'direct_assistant',
            label: 'sangsu',
            text: '',
            delivery: 'streaming',
            streamState: 'streaming',
          }),
        ]}
        emptyText="empty"
        variant="messenger"
      />`,
      container,
    )

    const placeholder = container.querySelector('[data-chat-stream-placeholder]')
    expect(placeholder).not.toBeNull()
    expect(placeholder?.textContent).toContain('응답 작성 중...')
    expect(container.querySelector('[data-chat-delivery="live"]')).not.toBeNull()
  })

  it('renders an optional message action and passes the clicked entry', () => {
    const onClick = vi.fn()
    const target = entry({
      id: 'a1',
      role: 'assistant',
      source: 'direct_assistant',
      label: 'sangsu',
      text: '검사할 응답',
    })

    render(
      html`<${ChatTranscript}
        entries=${[target]}
        emptyText="empty"
        variant="messenger"
        action=${{ label: '턴 상세', title: '이 메시지 턴 상세 열기', onClick }}
      />`,
      container,
    )

    const action = container.querySelector('[data-testid="chat-message-action"]') as HTMLButtonElement
    expect(action).not.toBeNull()
    expect(action.textContent).toBe('턴 상세')

    fireEvent.click(action)

    expect(onClick).toHaveBeenCalledTimes(1)
    expect(onClick.mock.calls[0]?.[0].id).toBe('a1')
  })

  it('copies the message text from an assistant message copy button', () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.assign(globalThis.navigator, { clipboard: { writeText } })
    const target = entry({
      id: 'a1',
      role: 'assistant',
      source: 'direct_assistant',
      label: 'sangsu',
      text: '복사할 응답 본문',
    })

    render(
      html`<${ChatTranscript} entries=${[target]} emptyText="empty" variant="messenger" />`,
      container,
    )

    const copy = container.querySelector('[data-testid="chat-message-copy"]') as HTMLButtonElement
    expect(copy).not.toBeNull()
    fireEvent.click(copy)
    expect(writeText).toHaveBeenCalledWith('복사할 응답 본문')
  })

  it('does not render a copy button on user messages', () => {
    const target = entry({ id: 'u1', role: 'user', text: '내 질문' })
    render(
      html`<${ChatTranscript} entries=${[target]} emptyText="empty" variant="messenger" />`,
      container,
    )
    expect(container.querySelector('[data-testid="chat-message-copy"]')).toBeNull()
  })

  it('renders a thinking placeholder when the model is reasoning', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({ id: 'u1', text: 'ping' }),
          entry({
            id: 'a1',
            role: 'assistant',
            source: 'direct_assistant',
            label: 'sangsu',
            text: '',
            delivery: 'streaming',
            streamState: 'thinking',
          }),
        ]}
        emptyText="empty"
        variant="messenger"
      />`,
      container,
    )

    const placeholder = container.querySelector('[data-chat-stream-placeholder]')
    expect(placeholder).not.toBeNull()
    expect(placeholder?.textContent).toContain('생각 중...')
    expect(container.querySelector('[data-chat-delivery="thinking"]')).not.toBeNull()
  })

  it('shows a streaming cursor while content is streaming', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({ id: 'u1', text: 'ping' }),
          entry({
            id: 'a1',
            role: 'assistant',
            source: 'direct_assistant',
            label: 'sangsu',
            text: '안녕하세요',
            delivery: 'streaming',
            streamState: 'streaming',
          }),
        ]}
        emptyText="empty"
        variant="messenger"
      />`,
      container,
    )

    expect(container.textContent).toContain('안녕하세요')
    const cursor = container.querySelector('.animate-pulse')
    expect(cursor).not.toBeNull()
  })

  it('hides the streaming cursor when delivery is not streaming', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'a1',
            role: 'assistant',
            source: 'direct_assistant',
            label: 'sangsu',
            text: '완료된 응답',
            delivery: 'delivered',
          }),
        ]}
        emptyText="empty"
      />`,
      container,
    )

    const cursor = container.querySelector('.animate-pulse')
    expect(cursor).toBeNull()
  })

  it('uses a parent-bounded flexible transcript in primary mode', () => {
    render(
      html`<${ChatTranscript}
        entries=${[entry({ id: 'u1', text: 'ping' })]}
        emptyText="empty"
        variant="messenger"
        size="primary"
      />`,
      container,
    )

    const transcript = container.querySelector('[data-chat-variant="messenger"]')
    expect(transcript?.getAttribute('data-chat-size')).toBe('primary')
    expect(transcript?.classList.contains('min-h-0')).toBe(true)
    expect(transcript?.classList.contains('flex-1')).toBe(true)
    expect(transcript?.classList.contains('max-h-[42vh]')).toBe(false)
    expect(transcript?.classList.contains('chat-transcript-airy')).toBe(true)
  })

  it('renders attachments even when metadata is hidden', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'u1',
            text: '첨부 확인',
            attachments: [
              {
                id: 'att-1',
                type: 'image',
                name: 'screenshot.png',
                size: 1024,
                mimeType: 'image/png',
                data: 'data:image/png;base64,abc123',
              },
              {
                id: 'att-2',
                type: 'file',
                name: 'log.txt',
                size: 512,
                mimeType: 'text/plain',
                data: 'data:text/plain;base64,bG9n',
              },
            ],
          }),
        ]}
        emptyText="empty"
        showMetadata=${false}
      />`,
      container,
    )

    expect(container.querySelector('img[alt="screenshot.png"]')).not.toBeNull()
    expect(container.textContent).toContain('log.txt')
    expect(container.textContent).not.toContain('상세 보기')
  })

  it('does not show streaming ellipsis before elapsed time starts', () => {
    render(
      html`<${ChatComposer}
        draft="안녕"
        placeholder="메시지 입력..."
        disabled=${false}
        streaming=${true}
        onDraftChange=${() => {}}
        onSend=${() => {}}
      />`,
      container,
    )

    const buttons = [...container.querySelectorAll('button')]
    const sendButton = buttons.find(button => button.textContent?.includes('보내기') || button.textContent?.includes('응답 중'))
    expect(sendButton).not.toBeUndefined()
    const label = sendButton?.textContent ?? ''
    expect(label).toContain('응답 중')
    expect(label).not.toContain('...')
  })

  it('renders an audio player for assistant entries with an RFC-0235 clip', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'a1',
            role: 'assistant',
            source: 'direct_assistant',
            label: 'sangsu',
            text: 'hello operator',
            audio: {
              token: 'clip-1',
              audioUrl: '/api/v1/voice/audio/clip-1',
              mime: 'audio/mpeg',
              durationSec: 5,
              messageText: 'hello operator',
              deviceId: null,
            },
          }),
        ]}
        emptyText="empty"
      />`,
      container,
    )

    const player = container.querySelector('[data-chat-audio-clip]')
    expect(player).not.toBeNull()
    const audio = container.querySelector('audio')
    expect(audio).not.toBeNull()
    expect(audio?.getAttribute('src')).toBe('/api/v1/voice/audio/clip-1')
    expect(container.textContent).toContain('0:05')
  })

  it('shows the audio caption and a load-error fallback', async () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'a1',
            role: 'assistant',
            source: 'direct_assistant',
            label: 'sangsu',
            text: 'hello operator',
            audio: {
              token: 'clip-1',
              audioUrl: null,
              mime: 'audio/mpeg',
              durationSec: null,
              messageText: 'hello operator',
              deviceId: null,
            },
          }),
        ]}
        emptyText="empty"
      />`,
      container,
    )

    const audio = container.querySelector('audio') as HTMLAudioElement | null
    expect(audio).not.toBeNull()
    expect(audio?.getAttribute('src')).toContain('/api/v1/voice/audio/clip-1')
    expect(container.textContent).toContain('hello operator')
    audio?.dispatchEvent(new Event('error', { bubbles: true }))
    await flushUi()
    expect(container.textContent).toContain('음성을 불러올 수 없습니다')
  })

  it('shows an expired placeholder instead of the native player', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'a1',
            role: 'assistant',
            source: 'direct_assistant',
            label: 'sangsu',
            text: 'hello operator',
            audio: {
              token: 'clip-expired',
              audioUrl: '/api/v1/voice/audio/clip-expired',
              mime: 'audio/mpeg',
              durationSec: 5,
              messageText: 'hello operator',
              deviceId: null,
              expired: true,
            },
          }),
        ]}
        emptyText="empty"
      />`,
      container,
    )

    const player = container.querySelector('[data-chat-audio-clip]')
    expect(player).not.toBeNull()
    expect(container.querySelector('audio')).toBeNull()
    expect(container.textContent).toContain('음성이 만료되었습니다.')
    expect(container.textContent).toContain('hello operator')
  })

  it('renders a real audio element inside a voice block when src is provided', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'a1',
            role: 'assistant',
            source: 'direct_assistant',
            label: 'sangsu',
            text: '',
            blocks: [
              { t: 'voice', secs: 5, wave: [0.2, 0.5], src: 'https://example.com/voice.mp3', transcript: 'note' },
            ],
          }),
        ]}
        emptyText="empty"
      />`,
      container,
    )

    const voice = container.querySelector('[data-chat-block="voice"]')
    expect(voice).not.toBeNull()
    const audio = voice?.querySelector('audio')
    expect(audio).not.toBeNull()
    expect(audio?.getAttribute('src')).toBe('https://example.com/voice.mp3')
    expect(voice?.querySelectorAll('.chat-block-vbar').length).toBe(2)
  })
})

describe('ChatComposer queue & stall', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('keeps send enabled during streaming when queueing is on', () => {
    render(
      html`<${ChatComposer}
        draft="다음 질문"
        placeholder="메시지 입력..."
        disabled=${false}
        streaming=${true}
        queueEnabled=${true}
        queueCount=${2}
        onDraftChange=${() => {}}
        onSend=${() => {}}
      />`,
      container,
    )

    const buttons = [...container.querySelectorAll('button')]
    const queueButton = buttons.find(button => button.textContent?.includes('대기열 추가'))
    expect(queueButton).not.toBeUndefined()
    expect(queueButton?.hasAttribute('disabled')).toBe(false)
    expect(container.querySelector('[data-chat-queue-count]')?.textContent).toContain('대기 2')
  })

  it('blocks send during streaming when queueing is off', () => {
    render(
      html`<${ChatComposer}
        draft="다음 질문"
        placeholder="메시지 입력..."
        disabled=${false}
        streaming=${true}
        queueEnabled=${false}
        onDraftChange=${() => {}}
        onSend=${() => {}}
      />`,
      container,
    )

    const buttons = [...container.querySelectorAll('button')]
    const sendButton = buttons.find(button => button.textContent?.includes('응답 중'))
    expect(sendButton?.hasAttribute('disabled')).toBe(true)
  })

  it('surfaces a stall hint when no stream event arrived recently', () => {
    render(
      html`<${ChatComposer}
        draft=""
        placeholder="메시지 입력..."
        disabled=${false}
        streaming=${true}
        lastEventAt=${Date.now() - 30_000}
        onDraftChange=${() => {}}
        onSend=${() => {}}
      />`,
      container,
    )

    const hint = container.querySelector('[data-chat-stall-hint]')
    expect(hint).not.toBeNull()
    expect(hint?.textContent).toContain('지연')
  })

  it('shows no stall hint while events are flowing', () => {
    render(
      html`<${ChatComposer}
        draft=""
        placeholder="메시지 입력..."
        disabled=${false}
        streaming=${true}
        lastEventAt=${Date.now() - 1_000}
        onDraftChange=${() => {}}
        onSend=${() => {}}
      />`,
      container,
    )

    expect(container.querySelector('[data-chat-stall-hint]')).toBeNull()
  })

  it('labels the idle send button 전송 (regression: corrupted 볂이기 literal)', () => {
    render(
      html`<${ChatComposer}
        draft="보낼 메시지"
        placeholder="메시지 입력..."
        disabled=${false}
        streaming=${false}
        onDraftChange=${() => {}}
        onSend=${() => {}}
      />`,
      container,
    )
    const sendButton = [...container.querySelectorAll('button')].find((b) => b.classList.contains('send'))
    expect(sendButton?.textContent?.trim()).toBe('전송')
    expect(container.textContent).not.toContain('볂이기')
  })
})

describe('ChatComposer IME composition guard', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  function renderComposer(onSend: () => void) {
    render(
      html`<${ChatComposer}
        draft="소주에 갑오징어 먹었닭"
        placeholder="메시지 입력..."
        disabled=${false}
        streaming=${false}
        onDraftChange=${() => {}}
        onSend=${onSend}
      />`,
      container,
    )
    const textarea = container.querySelector('textarea')
    expect(textarea).not.toBeNull()
    return textarea as HTMLTextAreaElement
  }

  it('ignores Enter fired while the last Hangul syllable is composing', () => {
    // Regression: the composition-commit Enter used to send the message,
    // the IME flushed the trailing syllable back into the cleared input,
    // and the queue re-sent that single character after the reply arrived.
    let sent = 0
    const textarea = renderComposer(() => { sent += 1 })

    textarea.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', isComposing: true, bubbles: true }),
    )
    expect(sent).toBe(0)

    textarea.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    expect(sent).toBe(1)
  })

  it('keeps Shift+Enter as newline (no send)', () => {
    let sent = 0
    const textarea = renderComposer(() => { sent += 1 })

    textarea.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', shiftKey: true, bubbles: true }),
    )
    expect(sent).toBe(0)
  })

  it('keeps its own draft when uncontrolled and surfaces the typed text on send', () => {
    // The keeper-workspace chat omits onDraftChange so a keystroke updates the
    // composer's internal draft instead of the host panel — that is what stops
    // the transcript from re-rendering on every character. The composer must
    // still capture the text and carry it on the send payload (`text`).
    const onSend = vi.fn()
    render(
      html`<${ChatComposer}
        placeholder="메시지 입력..."
        disabled=${false}
        streaming=${false}
        onSend=${onSend}
      />`,
      container,
    )
    const textarea = container.querySelector('textarea') as HTMLTextAreaElement
    expect(textarea).not.toBeNull()

    fireEvent.input(textarea, { target: { value: '소주에 갑오징어' } })
    textarea.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))

    expect(onSend).toHaveBeenCalledTimes(1)
    const sent = onSend.mock.calls[0]?.[0] as ChatComposerSendPayload | undefined
    expect(sent?.text).toBe('소주에 갑오징어')
  })
})

describe('ChatComposer draft persistence (uncontrolled, per-keeper)', () => {
  let container: HTMLDivElement
  beforeEach(() => {
    _resetChatStoreForTests()
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    container.remove()
    _resetChatStoreForTests()
  })

  function mountComposer(draftPersistKey: string, onSend: () => void = () => {}) {
    render(
      html`<${ChatComposer}
        placeholder="메시지 입력..."
        disabled=${false}
        streaming=${false}
        draftPersistKey=${draftPersistKey}
        onSend=${onSend}
      />`,
      container,
    )
    return container.querySelector('textarea') as HTMLTextAreaElement
  }

  it('restores a keeper draft across remount and never leaks across keepers', () => {
    // Type for keeper 'rondo', then switch away (unmount — the key=keeperName
    // remount in the app).
    let textarea = mountComposer('rondo')
    fireEvent.input(textarea, { target: { value: '소주에 갑오징어' } })
    render(null, container)

    // Switch to a different keeper → fresh, empty composer (no cross-keeper leak).
    textarea = mountComposer('qa-king')
    expect(textarea.value).toBe('')

    // Switch back to 'rondo' → the half-typed draft is restored.
    render(null, container)
    textarea = mountComposer('rondo')
    expect(textarea.value).toBe('소주에 갑오징어')
  })

  it('resyncs immediately when the draft key changes without a remount', () => {
    let textarea = mountComposer('rondo')
    fireEvent.input(textarea, { target: { value: 'rondo draft' } })

    // Defensive path for future callers: even without key=${keeperName}
    // remounting the composer, the new keeper must not briefly inherit the old
    // keeper's visible buffer or write subsequent input under the wrong key.
    textarea = mountComposer('qa-king')
    expect(textarea.value).toBe('')

    fireEvent.input(textarea, { target: { value: 'qa draft' } })
    expect(readKeeperDraft('rondo')).toBe('rondo draft')
    expect(readKeeperDraft('qa-king')).toBe('qa draft')

    textarea = mountComposer('rondo')
    expect(textarea.value).toBe('rondo draft')
  })

  it('clears the persisted draft after a send', () => {
    const onSend = vi.fn()
    const textarea = mountComposer('rondo', onSend)
    fireEvent.input(textarea, { target: { value: 'send me' } })
    textarea.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))

    expect(onSend).toHaveBeenCalledTimes(1)
    expect(readKeeperDraft('rondo')).toBe('')
  })
})

describe('ChatMessageBubble memoization', () => {
  let container: HTMLDivElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    container.remove()
  })

  // Simulates a stream chunk: render a 2-message transcript, then re-render with
  // the SAME settled entry reference but a fresh streaming entry (new array), the
  // way a reconcile preserves settled refs. Returns how many message-bubble
  // bodies re-ran on the second render. `action` reference stability is the
  // variable under test (the inline `{ ...onClick }` literal in
  // KeeperConversationPanel is hoisted to a useMemo so it stays referentially
  // stable across stream re-renders).
  function bubbleRerendersOnStream(actionFor: () => unknown): number {
    type RenderHook = { __r?: (v: unknown) => void }
    let renders = 0
    const prev = (options as unknown as RenderHook).__r
    ;(options as unknown as RenderHook).__r = (vnode) => {
      const t = (vnode as { type?: { displayName?: string; name?: string } })?.type
      const label = t?.displayName ?? t?.name ?? ''
      // Count the inner component body, not the memo wrapper ('Memo(...)').
      if (label.includes('ChatMessageBubble') && !label.startsWith('Memo(')) renders++
      prev?.(vnode)
    }
    try {
      const settled = entry({ id: 'a', role: 'assistant', source: 'direct_assistant', text: 'settled reply' })
      const s1 = entry({ id: 'b', role: 'assistant', source: 'direct_assistant', text: 'partial' })
      render(html`<${ChatTranscript} entries=${[settled, s1]} emptyText="x" action=${actionFor()} />`, container)
      const initial = renders
      expect(initial).toBe(2) // both bubbles paint on first render
      const s2 = entry({ id: 'b', role: 'assistant', source: 'direct_assistant', text: 'partial reply' })
      render(html`<${ChatTranscript} entries=${[settled, s2]} emptyText="x" action=${actionFor()} />`, container)
      return renders - initial
    } finally {
      ;(options as unknown as RenderHook).__r = prev
    }
  }

  it('skips the settled bubble on a stream update when the action prop is referentially stable', () => {
    const stable = { label: '턴 상세', title: 't', onClick: () => {} }
    // Only the streaming bubble re-runs; the settled one is skipped.
    expect(bubbleRerendersOnStream(() => stable)).toBe(1)
  })

  it('re-renders the settled bubble when action is a new object each render (why the useMemo matters)', () => {
    // A fresh action object every render — the pre-fix behaviour — defeats the
    // shallow-equal skip, so the settled bubble re-runs on every stream chunk.
    expect(bubbleRerendersOnStream(() => ({ label: '턴 상세', title: 't', onClick: () => {} }))).toBe(2)
  })
})

describe('Keeper v2 chat blocks', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  function renderBlocks(blocks: ChatBlock[]) {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'b1',
            role: 'assistant',
            source: 'direct_assistant',
            label: 'sangsu',
            text: '',
            blocks,
          }),
        ]}
        emptyText="empty"
      />`,
      container,
    )
  }

  it('renders a callout block', () => {
    renderBlocks([{ t: 'callout', severity: 'warn', html: '<strong>주의</strong>' }])

    const callout = container.querySelector('[data-chat-block="callout"]')
    expect(callout).not.toBeNull()
    expect(callout?.classList.contains('warn')).toBe(true)
    expect(callout?.textContent).toContain('주의')
  })

  it('renders a markdown table with numeric and muted cell flags', () => {
    renderBlocks([
      {
        t: 'table',
        head: ['name', { v: 'count', num: true }],
        rows: [['a', { v: '42', num: true }], ['b', { v: 'n/a', muted: true }]],
      },
    ])

    const table = container.querySelector('[data-chat-block="table"]')
    expect(table).not.toBeNull()
    const nums = [...container.querySelectorAll('.chat-block-cell-num')].map((el) => el.textContent)
    expect(nums).toContain('count')
    expect(nums).toContain('42')
    const muted = container.querySelector('.chat-block-cell-muted')
    expect(muted?.textContent).toBe('n/a')
  })

  it('renders a code block with caption', () => {
    renderBlocks([{ t: 'code', cap: 'config.ml', html: 'let x = 1' }])

    const code = container.querySelector('[data-chat-block="code"]')
    expect(code).not.toBeNull()
    expect(code?.textContent).toContain('config.ml')
    expect(code?.textContent).toContain('let x = 1')
  })

  it('renders a shell block with prompt and exit status', () => {
    renderBlocks([
      {
        t: 'shell',
        title: 'keeper@worktree',
        lines: [
          { t: 'cmd', v: 'ls' },
          { t: 'out', v: 'file.txt' },
        ],
        exit: 1,
        dur: '0.3s',
      },
    ])

    const shell = container.querySelector('[data-chat-block="shell"]')
    expect(shell).not.toBeNull()
    expect(shell?.textContent).toContain('keeper@worktree')
    expect(shell?.textContent).toContain('$ ls')
    expect(shell?.textContent).toContain('file.txt')
    expect(shell?.textContent).toContain('exit 1')
  })

  it('renders an artifact card with open/download buttons', () => {
    renderBlocks([{ t: 'artifact', kind: 'json', name: 'report.json', size: '12 KB', note: '3 items' }])

    const artifact = container.querySelector('[data-chat-block="artifact"]')
    expect(artifact).not.toBeNull()
    expect(artifact?.textContent).toContain('report.json')
    expect(artifact?.textContent).toContain('JSON')
    const buttons = [...(artifact?.querySelectorAll('button') ?? [])].map((b) => b.textContent)
    expect(buttons).toContain('열기')
    expect(buttons).toContain('다운로드')
  })

  it('renders an attach card with inline svg', () => {
    renderBlocks([
      {
        t: 'attach',
        name: 'shape.svg',
        dims: '64×64',
        svg: '<svg viewBox="0 0 10 10"><rect width="10" height="10" fill="red"/></svg>',
        via: 'vision',
        size: '1 KB',
      },
    ])

    const attach = container.querySelector('[data-chat-block="attach"]')
    expect(attach).not.toBeNull()
    expect(attach?.textContent).toContain('shape.svg')
    expect(attach?.textContent).toContain('64×64')
    expect(attach?.querySelector('svg')).not.toBeNull()
  })

  it('renders a safe attach image src', () => {
    renderBlocks([
      {
        t: 'attach',
        name: 'screen.png',
        dims: '100×100',
        src: 'https://example.com/screen.png',
        via: 'vision',
        size: '12 KB',
      },
    ])

    const img = container.querySelector('[data-chat-block="attach"] img')
    expect(img?.getAttribute('src')).toBe('https://example.com/screen.png')
  })

  it('renders a data-url attach image src', () => {
    const src = 'data:image/png;base64,aGVsbG8='
    renderBlocks([
      {
        t: 'attach',
        name: 'screen.png',
        dims: '100×100',
        src,
        via: 'vision',
        size: '12 KB',
      },
    ])

    const img = container.querySelector('[data-chat-block="attach"] img')
    expect(img?.getAttribute('src')).toBe(src)
  })

  it('renders server-provided media blocks on user rows', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'u-rich',
            role: 'user',
            label: '사용자',
            text: 'uploaded',
            blocks: [
              {
                t: 'attach',
                name: 'screen.png',
                dims: '100×100',
                src: 'https://example.com/screen.png',
                via: 'vision',
                size: '12 KB',
              },
            ],
          }),
        ]}
        emptyText="empty"
      />`,
      container,
    )

    const blocks = container.querySelector('[data-chat-blocks]')
    const attach = container.querySelector('[data-chat-block="attach"]')
    expect(blocks).not.toBeNull()
    expect(attach?.textContent).toContain('screen.png')
    expect(attach?.querySelector('img')?.getAttribute('src')).toBe('https://example.com/screen.png')
  })

  it('blocks unsafe attach image src and falls back to placeholder', () => {
    renderBlocks([
      {
        t: 'attach',
        name: 'bad.png',
        dims: '100×100',
        src: 'javascript:alert(1)',
        via: 'vision',
        size: '12 KB',
      },
    ])

    expect(container.querySelector('[data-chat-block="attach"] img')).toBeNull()
    expect(container.textContent).toContain('unsafe URL')
  })

  it('renders a voice memo with waveform bars and transcript', () => {
    renderBlocks([
      {
        t: 'voice',
        secs: 14,
        wave: [0.2, 0.5, 0.8, 0.3, 0.6],
        via: 'whisper',
        size: '24 KB',
        transcript: 'hello world',
      },
    ])

    const voice = container.querySelector('[data-chat-block="voice"]')
    expect(voice).not.toBeNull()
    expect(voice?.querySelectorAll('.chat-block-vbar').length).toBe(5)
    expect(voice?.textContent).toContain('hello world')
    expect(voice?.textContent).toContain('whisper')
  })

  it('does not render a synthetic voice play button without a safe audio source', () => {
    renderBlocks([{ t: 'voice', secs: 2, wave: [0.2, 0.5] }])

    expect(container.querySelector('[data-chat-block="voice"] button')).toBeNull()
    expect(container.querySelector('[data-chat-block="voice"] audio')).toBeNull()
    expect(container.querySelectorAll('.chat-block-vbar').length).toBe(2)
  })

  it('renders an image block', () => {
    renderBlocks([{ t: 'image', src: '/img/screen.png', cap: '실행 화면' }])

    const img = container.querySelector('[data-chat-block="image"] img') as HTMLImageElement | null
    expect(img).not.toBeNull()
    expect(img?.getAttribute('src')).toBe('/img/screen.png')
    expect(container.textContent).toContain('실행 화면')
  })

  it('renders an svg block', () => {
    renderBlocks([{ t: 'svg', svg: '<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="5"/></svg>', cap: 'diagram' }])

    const svg = container.querySelector('[data-chat-block="svg"] svg')
    expect(svg).not.toBeNull()
    expect(container.textContent).toContain('diagram')
  })

  it('renders a trace block and expands a tool step', async () => {
    renderBlocks([
      {
        t: 'trace',
        trace: [
          { kind: 'think', text: 'planning' },
          { kind: 'tool', name: 'keeper_context_status', status: 'ok', dur: '0.2s', args: '{"path":"a"}', result: '{"ok":true}' },
        ],
      },
    ])

    const trace = container.querySelector('[data-chat-block="trace"]')
    expect(trace).not.toBeNull()
    expect(trace?.textContent).toContain('planning')
    expect(trace?.textContent).toContain('keeper_context_status')

    const toolRow = container.querySelector('[data-chat-trace-step="tool"] .chat-block-tstep-row.click') as HTMLElement | null
    expect(toolRow).not.toBeNull()
    toolRow?.click()
    await flushUi()

    expect(trace?.textContent).toContain('args')
    expect(trace?.textContent).toContain('"path"')
    expect(trace?.textContent).toContain('result')
  })

  it('renders a link unfurl card with extracted hostname', () => {
    renderBlocks([
      {
        t: 'link',
        url: 'https://example.com/post',
        title: 'Example post',
        desc: 'A useful article',
      },
    ])

    const link = container.querySelector('[data-chat-block="link"]') as HTMLAnchorElement | null
    expect(link).not.toBeNull()
    expect(link?.getAttribute('href')).toBe('https://example.com/post')
    expect(link?.textContent).toContain('Example post')
    expect(link?.textContent).toContain('example.com')
  })

  it('renders a broadcast card with recipient ack labels', () => {
    renderBlocks([
      {
        t: 'broadcast',
        scope: '@fleet',
        via: 'keeper-net',
        note: 'standby',
        recipients: [
          { id: 'masc', ack: 'acked', at: '12:00' },
          { id: 'sangsu', ack: 'delivered' },
        ],
      },
    ])

    const bcast = container.querySelector('[data-chat-block="broadcast"]')
    expect(bcast).not.toBeNull()
    expect(bcast?.textContent).toContain('브로드캐스트')
    expect(bcast?.textContent).toContain('standby')
    expect(bcast?.textContent).toContain('확인함')
    expect(bcast?.textContent).toContain('전달됨')
    expect(bcast?.textContent).toContain('1/2 확인')
  })

  it('falls back to markdown text when blocks are not provided', () => {
    render(
      html`<${ChatTranscript}
        entries=${[entry({ id: 'm1', text: 'plain markdown reply' })]}
        emptyText="empty"
      />`,
      container,
    )

    expect(container.textContent).toContain('plain markdown reply')
    expect(container.querySelector('[data-chat-blocks]')).toBeNull()
  })
})


describe('ChatComposer multimodal', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    vi.useFakeTimers({ shouldAdvanceTime: true })
    vi.mocked(collectAttachments).mockReset()
  })

  afterEach(() => {
    render(null, container)
    vi.runAllTimers()
    container.remove()
    vi.useRealTimers()
  })

  function renderComposer(props: {
    draft?: string
    onSend?: (payload: ChatComposerSendPayload) => void
    disabled?: boolean
    streaming?: boolean
  } = {}) {
    render(
      html`<${ChatComposer}
        draft=${props.draft ?? ''}
        placeholder="메시지 입력..."
        disabled=${props.disabled ?? false}
        streaming=${props.streaming ?? false}
        onDraftChange=${() => {}}
        onSend=${props.onSend ?? (() => {})}
      />`,
      container,
    )
  }

  it('renders attachment and voice buttons', () => {
    Object.assign(globalThis.navigator, { mediaDevices: { getUserMedia: vi.fn() } })
    Object.assign(globalThis, { MediaRecorder: vi.fn() })
    renderComposer()
    expect(container.querySelector('[title="이미지·파일 첨부"]')).not.toBeNull()
    expect(container.querySelector('[title="음성으로 입력"]')).not.toBeNull()
  })

  it('adds attachment chips from file input and removes them', async () => {
    vi.mocked(collectAttachments).mockResolvedValue({
      attachments: [
        {
          id: 'att-1',
          type: 'image',
          name: 'screen.png',
          size: 1024,
          mimeType: 'image/png',
          data: 'data:image/png;base64,abc123',
          dims: '100×100',
        },
        {
          id: 'att-2',
          type: 'file',
          name: 'log.txt',
          size: 512,
          mimeType: 'text/plain',
          data: 'data:text/plain;base64,bG9n',
        },
      ],
      errors: [],
    })

    renderComposer()
    const fileInput = container.querySelector('input[type="file"]') as HTMLInputElement
    setInputFiles(fileInput, [new File(['x'], 'screen.png', { type: 'image/png' })])
    fileInput.dispatchEvent(new Event('change'))
    await new Promise((r) => setTimeout(r, 10))

    expect(container.querySelector('[data-chat-attachment-draft="att-1"]')).not.toBeNull()
    expect(container.querySelector('[data-chat-attachment-draft="att-2"]')).not.toBeNull()
    expect(container.textContent).toContain('screen.png')
    expect(container.textContent).toContain('log.txt')

    const removeBtn = container.querySelector('[data-chat-attachment-draft="att-1"] .cdraft-x') as HTMLButtonElement
    removeBtn.click()
    await new Promise((r) => setTimeout(r, 10))
    expect(container.querySelector('[data-chat-attachment-draft="att-1"]')).toBeNull()
    expect(container.querySelector('[data-chat-attachment-draft="att-2"]')).not.toBeNull()
  })

  it('highlights drag-over state and ingests dropped files', async () => {
    vi.mocked(collectAttachments).mockResolvedValue({
      attachments: [
        {
          id: 'att-drop',
          type: 'file',
          name: 'drop.json',
          size: 128,
          mimeType: 'application/json',
          data: 'data:application/json;base64,e30=',
        },
      ],
      errors: [],
    })

    renderComposer()
    const composer = container.querySelector('.composer') as HTMLDivElement

    fireEvent.dragOver(composer)
    expect(composer.querySelector('.composer-box')?.classList.contains('drag')).toBe(true)

    fireEvent.drop(composer, {
      dataTransfer: dataTransferWith([new File(['{}'], 'drop.json', { type: 'application/json' })]),
    })
    await new Promise((r) => setTimeout(r, 10))

    expect(composer.querySelector('.composer-box')?.classList.contains('drag')).toBe(false)
    expect(container.querySelector('[data-chat-attachment-draft="att-drop"]')).not.toBeNull()
  })

  it('composes ordered blocks on send: attach, text', async () => {
    vi.mocked(collectAttachments).mockResolvedValue({
      attachments: [
        {
          id: 'att-img',
          type: 'image',
          name: 'screen.png',
          size: 1024,
          mimeType: 'image/png',
          data: 'data:image/png;base64,abc123',
          dims: '100×100',
        },
      ],
      errors: [],
    })

    const onSend = vi.fn()
    renderComposer({ draft: 'check this <tag>', onSend })

    const fileInput = container.querySelector('input[type="file"]') as HTMLInputElement
    setInputFiles(fileInput, [new File(['x'], 'screen.png', { type: 'image/png' })])
    fileInput.dispatchEvent(new Event('change'))
    await new Promise((r) => setTimeout(r, 10))

    const sendBtn = container.querySelector('.send') as HTMLButtonElement
    sendBtn.click()
    await new Promise((r) => setTimeout(r, 10))

    expect(onSend).toHaveBeenCalledOnce()
    const blocks = onSend.mock.calls[0]?.[0].blocks as ChatBlock[]
    expect(blocks).toHaveLength(2)
    expect(blocks[0]).toMatchObject({ t: 'attach', name: 'screen.png', kind: 'image' })
    expect(blocks[1]).toMatchObject({ t: 'p', html: 'check this &lt;tag&gt;' })
    expect(onSend.mock.calls[0]?.[0].userBlocks).toEqual([
      {
        type: 'image',
        attachmentId: 'att-img',
        name: 'screen.png',
        mimeType: 'image/png',
        size: 1024,
      },
      { type: 'text', text: 'check this <tag>' },
    ])
    const clientActionId = onSend.mock.calls[0]?.[0].clientActionId
    expect(clientActionId).toMatch(/^composer-send-\d+-\d+$/)
    expect(clientActionId).not.toContain('check this <tag>')
    expect(clientActionId).not.toContain('att-img')
  })

  it('mints content-independent client action ids for repeated sends', async () => {
    const onSend = vi.fn()
    renderComposer({ draft: 'same text', onSend })

    const sendBtn = container.querySelector('.send') as HTMLButtonElement
    sendBtn.click()
    sendBtn.click()
    await new Promise((r) => setTimeout(r, 10))

    expect(onSend).toHaveBeenCalledTimes(2)
    const firstId = onSend.mock.calls[0]?.[0].clientActionId
    const secondId = onSend.mock.calls[1]?.[0].clientActionId
    expect(firstId).toMatch(/^composer-send-\d+-\d+$/)
    expect(secondId).toMatch(/^composer-send-\d+-\d+$/)
    expect(firstId).not.toBe(secondId)
    expect(firstId).not.toContain('same text')
    expect(secondId).not.toContain('same text')
  })

  it('does not derive client action ids from attachment payloads', async () => {
    const baseAttachment: Omit<KeeperConversationAttachment, 'data'> = {
      id: 'att-same',
      type: 'image',
      name: 'screen.png',
      size: 1024,
      mimeType: 'image/png',
      dims: '100×100',
    }
    vi.mocked(collectAttachments)
      .mockResolvedValueOnce({
        attachments: [{ ...baseAttachment, data: 'data:image/png;base64,AAAA' }],
        errors: [],
      })
      .mockResolvedValueOnce({
        attachments: [{ ...baseAttachment, data: 'data:image/png;base64,BBBB' }],
        errors: [],
      })

    const onSend = vi.fn()
    renderComposer({ draft: 'same text', onSend })

    let fileInput = container.querySelector('input[type="file"]') as HTMLInputElement
    setInputFiles(fileInput, [new File(['a'], 'screen.png', { type: 'image/png' })])
    fileInput.dispatchEvent(new Event('change'))
    await new Promise((r) => setTimeout(r, 10))

    let sendBtn = container.querySelector('.send') as HTMLButtonElement
    sendBtn.click()
    await new Promise((r) => setTimeout(r, 10))

    fileInput = container.querySelector('input[type="file"]') as HTMLInputElement
    setInputFiles(fileInput, [new File(['b'], 'screen.png', { type: 'image/png' })])
    fileInput.dispatchEvent(new Event('change'))
    await new Promise((r) => setTimeout(r, 10))

    sendBtn = container.querySelector('.send') as HTMLButtonElement
    sendBtn.click()
    await new Promise((r) => setTimeout(r, 10))

    expect(onSend).toHaveBeenCalledTimes(2)
    const firstId = onSend.mock.calls[0]?.[0].clientActionId
    const secondId = onSend.mock.calls[1]?.[0].clientActionId
    expect(firstId).toMatch(/^composer-send-\d+-\d+$/)
    expect(secondId).toMatch(/^composer-send-\d+-\d+$/)
    expect(firstId).not.toBe(secondId)
    expect(firstId).not.toContain('same text')
    expect(firstId).not.toContain('att-same')
    expect(firstId).not.toContain('AAAA')
    expect(secondId).not.toContain('BBBB')
  })

  it('preserves audio attachments as audio user blocks', async () => {
    vi.mocked(collectAttachments).mockResolvedValue({
      attachments: [
        {
          id: 'att-audio',
          type: 'file',
          name: 'voice.webm',
          size: 2048,
          mimeType: 'audio/webm',
          data: 'data:audio/webm;base64,AAAA',
        },
      ],
      errors: [],
    })

    const onSend = vi.fn()
    renderComposer({ onSend })

    const fileInput = container.querySelector('input[type="file"]') as HTMLInputElement
    setInputFiles(fileInput, [new File(['x'], 'voice.webm', { type: 'audio/webm' })])
    fileInput.dispatchEvent(new Event('change'))
    await new Promise((r) => setTimeout(r, 10))

    const sendBtn = container.querySelector('.send') as HTMLButtonElement
    sendBtn.click()
    await new Promise((r) => setTimeout(r, 10))

    expect(onSend).toHaveBeenCalledOnce()
    expect(onSend.mock.calls[0]?.[0].userBlocks).toEqual([
      {
        type: 'audio',
        attachmentId: 'att-audio',
        name: 'voice.webm',
        mimeType: 'audio/webm',
        size: 2048,
      },
    ])
    expect(onSend.mock.calls[0]?.[0].clientActionId).toMatch(/^composer-send-\d+-\d+$/)
    expect(onSend.mock.calls[0]?.[0].clientActionId).not.toContain('att-audio')
  })

  it('keeps send disabled until there is content', () => {
    renderComposer()
    const sendBtn = container.querySelector('.send') as HTMLButtonElement
    expect(sendBtn.disabled).toBe(true)
  })

  it('handles voice draft transcription, rendering, removal, and serialization on send', async () => {
    const onSend = vi.fn()
    renderComposer({ onSend })

    const sendBtn = container.querySelector('.send') as HTMLButtonElement
    expect(sendBtn.disabled).toBe(true)

    // Simulate the capture/transcribe boundary completing transcription.
    if (mockTranscribeCallback) {
      mockTranscribeCallback('스케줄러 결과 확인 바람')
    }
    await new Promise((r) => setTimeout(r, 10))

    // 1. Voice draft should be rendered
    const voiceDraftEl = container.querySelector('[data-testid="composer-voice-draft"]')
    expect(voiceDraftEl).not.toBeNull()
    expect(voiceDraftEl?.textContent).toContain('스케줄러 결과 확인 바람')

    // 2. Send button should be enabled because we have content
    expect(sendBtn.disabled).toBe(false)

    // 3. Click send button and verify text-only STT serialization.
    sendBtn.click()
    await new Promise((r) => setTimeout(r, 10))

    expect(onSend).toHaveBeenCalledOnce()
    const payload = onSend.mock.calls[0]?.[0]
    expect(payload.text).toContain('스케줄러 결과 확인 바람')
    expect(payload.blocks).toHaveLength(1)
    expect(payload.blocks[0]).toMatchObject({ t: 'p' })
    expect(payload.blocks.some((block: ChatBlock) => block.t === 'voice')).toBe(false)

    // 4. Voice draft should be cleared after send
    expect(container.querySelector('[data-testid="composer-voice-draft"]')).toBeNull()
  })

  it('allows removing voice draft before send', async () => {
    renderComposer()

    if (mockTranscribeCallback) {
      mockTranscribeCallback('임시 받아쓰기')
    }
    await new Promise((r) => setTimeout(r, 10))

    expect(container.querySelector('[data-testid="composer-voice-draft"]')).not.toBeNull()

    const removeBtn = container.querySelector('[data-testid="composer-voice-draft"] .cdraft-x') as HTMLButtonElement
    removeBtn.click()
    await new Promise((r) => setTimeout(r, 10))

    expect(container.querySelector('[data-testid="composer-voice-draft"]')).toBeNull()
  })
})

describe('rich block URL safety', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders safe image block src', () => {
    const blocks: ChatBlock[] = [{ t: 'image', src: 'https://example.com/x.png' }]
    render(
      html`<${ChatTranscript}
        entries=${[entry({ id: 'e1', role: 'assistant', text: '', blocks })]}
      />`,
      container,
    )
    const img = container.querySelector('img')
    expect(img?.getAttribute('src')).toBe('https://example.com/x.png')
  })

  it('renders data-url image and audio block sources', () => {
    const imageSrc = 'data:image/png;base64,aGVsbG8='
    const audioSrc = 'data:audio/webm;base64,aGVsbG8='
    const blocks: ChatBlock[] = [
      { t: 'image', src: imageSrc },
      { t: 'voice', src: audioSrc, transcript: 'voice memo' },
    ]
    render(
      html`<${ChatTranscript}
        entries=${[entry({ id: 'e1', role: 'assistant', text: '', blocks })]}
      />`,
      container,
    )
    expect(container.querySelector('[data-chat-block="image"] img')?.getAttribute('src')).toBe(imageSrc)
    expect(container.querySelector('[data-chat-block="voice"] audio')?.getAttribute('src')).toBe(audioSrc)
  })

  it('blocks javascript: image src and shows placeholder', () => {
    const blocks: ChatBlock[] = [{ t: 'image', src: 'javascript:alert(1)' }]
    render(
      html`<${ChatTranscript}
        entries=${[entry({ id: 'e1', role: 'assistant', text: '', blocks })]}
      />`,
      container,
    )
    expect(container.querySelector('img')).toBeNull()
    expect(container.textContent).toContain('unsafe URL')
  })

  it('renders safe link block href', () => {
    const blocks: ChatBlock[] = [{ t: 'link', url: 'https://example.com', title: 'Example' }]
    render(
      html`<${ChatTranscript}
        entries=${[entry({ id: 'e1', role: 'assistant', text: '', blocks })]}
      />`,
      container,
    )
    const a = container.querySelector('a')
    expect(a?.getAttribute('href')).toBe('https://example.com')
  })

  it('blocks javascript: link href', () => {
    const blocks: ChatBlock[] = [{ t: 'link', url: 'javascript:alert(1)', title: 'Bad' }]
    render(
      html`<${ChatTranscript}
        entries=${[entry({ id: 'e1', role: 'assistant', text: '', blocks })]}
      />`,
      container,
    )
    const a = container.querySelector('a')
    expect(a?.getAttribute('href')).toBe('#')
    expect(container.textContent).toContain('unsafe URL')
  })
})

describe('ChatTranscript — workspace day dividers (C1)', () => {
  let container: HTMLDivElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('inserts one divider before the first message of each calendar day', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({ id: 'a', text: 'day one', timestamp: '2026-03-24T12:00:00.000Z' }),
          entry({ id: 'b', text: 'same day', timestamp: '2026-03-24T13:00:00.000Z' }),
          entry({ id: 'c', text: 'two days later', timestamp: '2026-03-26T12:00:00.000Z' }),
        ]}
        emptyText="empty"
        variant="messenger"
        showDayDividers=${true}
      />`,
      container,
    )
    // Two distinct days (a/b share one) → two dividers, not three.
    const dividers = container.querySelectorAll('.kw-daydiv')
    expect(dividers.length).toBe(2)
    // Absolute "M월 D일" label (timezone-independent shape assertion).
    expect(dividers[0]?.textContent ?? '').toMatch(/\d+월 \d+일/)
  })

  it('renders no dividers when the flag is off (every non-workspace surface)', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({ id: 'a', text: 'one', timestamp: '2026-03-24T12:00:00.000Z' }),
          entry({ id: 'c', text: 'two', timestamp: '2026-03-26T12:00:00.000Z' }),
        ]}
        emptyText="empty"
        variant="messenger"
      />`,
      container,
    )
    expect(container.querySelectorAll('.kw-daydiv').length).toBe(0)
  })

  it('does not duplicate a day divider when a null-timestamp entry splits a day', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          // Both timestamps are midday UTC so they land on one calendar day in
          // any plausible test TZ (the C1 baseline test uses the same window).
          entry({ id: 'a', text: 'morning', timestamp: '2026-03-24T12:00:00.000Z' }),
          // live placeholder with no timestamp, mid-day
          entry({ id: 'live', text: '응답 연결 중', role: 'assistant', source: 'direct_assistant', timestamp: null, delivery: 'sending' }),
          entry({ id: 'b', text: 'evening', timestamp: '2026-03-24T13:00:00.000Z' }),
        ]}
        emptyText="empty"
        variant="messenger"
        showDayDividers=${true}
      />`,
      container,
    )
    // One calendar day → exactly one divider. Adjacent-only comparison would
    // let the null-ts entry reset the previous key and re-emit a second one.
    expect(container.querySelectorAll('.kw-daydiv').length).toBe(1)
  })
})

describe('ChatTranscript — tool-call grouping (turn timeline)', () => {
  let container: HTMLDivElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    container.remove()
    resetToolCallOutputs()
  })

  it('folds consecutive tool calls into one turn timeline card when grouping is on', () => {
    recordToolCallOutputs([
      toolCallOutput({ tool_use_id: 't1', output: 'r1' }),
      toolCallOutput({ tool_use_id: 't2', output: 'r2' }),
    ])
    render(
      html`<${ChatTranscript}
        entries=${[
          toolEntry({ id: 'tool-t1', label: 'keeper_board_list' }),
          toolEntry({ id: 'tool-t2', label: 'keeper_tasks_list' }),
          entry({ id: 'a', text: '답변', role: 'assistant', source: 'direct_assistant' }),
        ]}
        emptyText="empty"
        groupToolCalls=${true}
      />`,
      container,
    )
    const cards = container.querySelectorAll('[data-chat-tool-trace]')
    expect(cards.length).toBe(1)
    expect(cards[0]?.textContent).toContain('턴 타임라인')
    expect(cards[0]?.textContent).toContain('3단계')
    expect(cards[0]?.textContent).toContain('도구 2')
    expect(cards[0]?.textContent).toContain('Chat 1')
    expect(cards[0]?.textContent).toContain('keeper_board_list')
    expect(cards[0]?.textContent).toContain('keeper_tasks_list')
    expect(cards[0]?.querySelector('[data-chat-trace-step="chat"]')?.textContent).toContain('답변')
    // Grouped surface keeps no standalone per-row tool bubbles.
    expect(container.querySelectorAll('[data-chat-variant="tool-call"]').length).toBe(0)
  })

  it('keeps grouped tool calls connected to the following assistant answer', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          toolEntry({ id: 'tool-t1', label: 'keeper_board_list', turnRef: 'trace-a#1' }),
          entry({
            id: 'a',
            text: '도구 결과로 답합니다',
            role: 'assistant',
            source: 'direct_assistant',
            turnRef: 'trace-a#1',
            traceSteps: [{ kind: 'think', text: 'reading tool output' }],
          }),
        ]}
        emptyText="empty"
        groupToolCalls=${true}
        variant="messenger"
      />`,
      container,
    )

    const bundle = container.querySelector('[data-chat-turn-bundle]')
    expect(bundle).not.toBeNull()
    expect(bundle?.querySelector('[data-chat-work-trace]')).not.toBeNull()
    expect(bundle?.querySelector('[data-chat-variant="messenger"]')).not.toBeNull()
    expect(bundle?.textContent).toContain('Thinking')
    expect(bundle?.textContent).toContain('reading tool output')
    expect(bundle?.textContent).toContain('keeper_board_list')
    expect(bundle?.textContent).toContain('도구 결과로 답합니다')
  })

  it('does not attach a turn_ref-mismatched tool run to the following assistant', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          toolEntry({ id: 'tool-t1', label: 'keeper_board_list', turnRef: 'trace-a#1' }),
          entry({
            id: 'a',
            text: '다른 턴 답변',
            role: 'assistant',
            source: 'direct_assistant',
            turnRef: 'trace-b#2',
          }),
        ]}
        emptyText="empty"
        groupToolCalls=${true}
        variant="messenger"
      />`,
      container,
    )

    const trace = container.querySelector('[data-chat-tool-trace]')
    expect(container.querySelector('[data-chat-turn-bundle]')).toBeNull()
    expect(trace?.textContent).toContain('keeper_board_list')
    expect(trace?.textContent).not.toContain('다른 턴 답변')
  })

  it('renders assistant thinking as a turn timeline even without tool calls', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'a',
            text: '곧 답합니다',
            role: 'assistant',
            source: 'direct_assistant',
            traceSteps: [{ kind: 'think', text: 'checking context' }],
          }),
        ]}
        emptyText="empty"
        groupToolCalls=${true}
        variant="messenger"
      />`,
      container,
    )

    const bundle = container.querySelector('[data-chat-turn-bundle]')
    expect(bundle).not.toBeNull()
    expect(bundle?.textContent).toContain('턴 타임라인')
    expect(bundle?.textContent).toContain('2단계')
    expect(bundle?.textContent).toContain('Think 1')
    expect(bundle?.textContent).toContain('Chat 1')
    expect(bundle?.textContent).toContain('Thinking')
    expect(bundle?.textContent).toContain('checking context')
    expect(bundle?.textContent).toContain('곧 답합니다')
    expect(bundle?.querySelector('[data-chat-trace-step="chat"]')?.textContent).toContain('곧 답합니다')
  })

  it('badges turn timeline rows with field-level provenance', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'a-provenance',
            text: '답합니다',
            role: 'assistant',
            source: 'direct_assistant',
            turnRef: 'trace-prov#7',
            traceSteps: [
              { kind: 'think', text: 'checking context', oasBlockIndex: 3 },
              {
                kind: 'tool',
                name: 'keeper_board_list',
                toolCallId: 'tc-prov',
                status: 'ok',
                args: '{"limit":1}',
                oasBlockIndex: 4,
              },
            ],
          }),
        ]}
        emptyText="empty"
        groupToolCalls=${true}
        variant="messenger"
      />`,
      container,
    )

    const badges = [...container.querySelectorAll('[data-chat-trace-provenance]')]
      .map(node => node.getAttribute('data-chat-trace-provenance'))
    expect(badges).toContain('OAS #3')
    expect(badges).toContain('OAS #4')
    expect(badges).toContain('reply')

    const think = container.querySelector('[data-chat-trace-step="think"]') as HTMLElement
    expect(think.getAttribute('data-chat-trace-provenance')).toBe('OAS #3')
    expect(think.getAttribute('data-chat-trace-oas-block-index')).toBe('3')

    const tool = container.querySelector('[data-chat-trace-step="tool"]') as HTMLElement
    expect(tool.getAttribute('data-chat-trace-provenance')).toBe('OAS #4')
    expect(tool.getAttribute('data-chat-trace-tool-call-id')).toBe('tc-prov')
    expect(tool.getAttribute('data-chat-trace-oas-block-index')).toBe('4')
    expect(tool.getAttribute('data-chat-trace-link-state')).toBe('trace-only')
    expect(tool.getAttribute('data-chat-trace-output-state')).toBe('ok')
    expect(tool.getAttribute('data-chat-trace-entry-id')).toBeNull()

    const chat = container.querySelector('[data-chat-trace-step="chat"]') as HTMLElement
    expect(chat.getAttribute('data-chat-trace-provenance')).toBe('reply')
    expect(chat.getAttribute('data-chat-trace-entry-id')).toBe('a-provenance')
    expect(chat.getAttribute('data-chat-trace-source')).toBe('direct_assistant')
    expect(chat.getAttribute('data-chat-trace-turn-ref')).toBe('trace-prov#7')
  })

  it('renders thinking text as sanitized markdown with newlines preserved', async () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'a',
            text: '답합니다',
            role: 'assistant',
            source: 'direct_assistant',
            traceSteps: [{ kind: 'think', text: '첫째 줄 **강조**\n둘째 줄\n\n<script>alert(1)</script>' }],
          }),
        ]}
        emptyText="empty"
        groupToolCalls=${true}
        variant="messenger"
      />`,
      container,
    )

    const findThink = () =>
      container.querySelector('[data-chat-trace-step="think"] .chat-block-tstep-text') as HTMLElement | null
    const think = findThink()
    expect(think).not.toBeNull()
    // Newline-preserving container (raw interpolation folded these to one line).
    expect(think?.className).toContain('whitespace-pre-wrap')
    expect(think?.className).toContain('markdown-body')
    // Markdown is rendered, not shown as literal `**강조**`.
    await waitFor(
      () => expect(findThink()?.querySelector('strong')?.textContent).toBe('강조'),
      { timeout: 3000 },
    )
    const renderedThink = findThink()
    // Both source lines survive the round-trip.
    expect(renderedThink?.textContent).toContain('첫째 줄')
    expect(renderedThink?.textContent).toContain('둘째 줄')
    // Untrusted model markup is stripped (no executable script element).
    expect(renderedThink?.querySelector('script')).toBeNull()
  })

  it('keeps long thinking traces collapsed until the operator expands them', () => {
    const hiddenTail = 'TAIL-MARKER-KEEPER-THINKING'
    const longThinking = `${'reasoning '.repeat(Math.ceil(THINKING_TRACE_PREVIEW_CHARS / 10) + 20)}${hiddenTail}`
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'a',
            text: '답합니다',
            role: 'assistant',
            source: 'direct_assistant',
            traceSteps: [{ kind: 'think', text: longThinking }],
          }),
        ]}
        emptyText="empty"
        groupToolCalls=${true}
        variant="messenger"
      />`,
      container,
    )

    const think = container.querySelector('[data-chat-trace-step="think"]') as HTMLElement | null
    expect(think).not.toBeNull()
    expect(think?.textContent).toContain('chars hidden')
    expect(think?.textContent).not.toContain(hiddenTail)

    const expand = think?.querySelector('button') as HTMLButtonElement | null
    expect(expand).not.toBeNull()
    fireEvent.click(expand!)

    expect(think?.textContent).toContain(hiddenTail)
  })

  it('bounds live thinking preview without parsing markdown on every stream chunk', () => {
    const longThinking = `old heading **gone**\n${'x'.repeat(6_500)}\nlatest **tail**`

    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'a',
            text: '응답 작성 중',
            role: 'assistant',
            source: 'direct_assistant',
            streamState: 'streaming',
            delivery: 'streaming',
            traceSteps: [{ kind: 'think', text: longThinking }],
          }),
        ]}
        emptyText="empty"
        groupToolCalls=${true}
        variant="messenger"
      />`,
      container,
    )

    const trace = container.querySelector('[data-chat-tool-trace]') as HTMLElement | null
    const traceToggle = container.querySelector('.chat-block-trace-hd') as HTMLButtonElement | null
    expect(trace).not.toBeNull()
    expect(traceToggle).not.toBeNull()
    expect(trace?.getAttribute('data-chat-turn-stream-state')).toBe('streaming')
    expect(trace?.getAttribute('data-chat-turn-complete')).toBe('false')
    expect(traceToggle?.getAttribute('aria-expanded')).toBe('false')
    expect(trace?.textContent).toContain('턴 타임라인')
    expect(container.querySelector('[data-chat-trace-step="think"]')).toBeNull()
    expect(trace?.textContent).not.toContain('latest **tail**')

    fireEvent.click(traceToggle!)

    const think = container.querySelector('[data-chat-trace-step="think"] .chat-block-tstep-text') as HTMLElement | null
    expect(think).not.toBeNull()
    expect(traceToggle?.getAttribute('aria-expanded')).toBe('true')
    expect(think?.getAttribute('data-chat-thinking-preview')).toBe('truncated')
    expect(think?.textContent).not.toContain('old heading')
    expect(think?.textContent).toContain('latest **tail**')
    expect(think?.querySelector('strong')).toBeNull()
    expect((think?.textContent ?? '').length).toBeLessThan(longThinking.length)
  })

  it('auto-opens a live thinking timeline when the assistant turn settles', async () => {
    const thinking = 'checked context and selected the final answer'
    const renderTurn = (assistant: KeeperConversationEntry): void => {
      render(
        html`<${ChatTranscript}
          entries=${[assistant]}
          emptyText="empty"
          groupToolCalls=${true}
          variant="messenger"
        />`,
        container,
      )
    }

    renderTurn(entry({
      id: 'a',
      text: '응답 작성 중',
      role: 'assistant',
      source: 'direct_assistant',
      streamState: 'streaming',
      delivery: 'streaming',
      traceSteps: [{ kind: 'think', text: thinking }],
    }))

    const initialToggle = container.querySelector('.chat-block-trace-hd') as HTMLButtonElement | null
    expect(initialToggle).not.toBeNull()
    expect(initialToggle?.getAttribute('aria-expanded')).toBe('false')
    expect(container.querySelector('[data-chat-trace-step="think"]')).toBeNull()

    renderTurn(entry({
      id: 'a',
      text: '완료된 응답',
      role: 'assistant',
      source: 'direct_assistant',
      streamState: null,
      delivery: 'history',
      traceSteps: [{ kind: 'think', text: thinking }],
    }))

    await waitFor(() => {
      const settledToggle = container.querySelector('.chat-block-trace-hd') as HTMLButtonElement | null
      expect(settledToggle?.getAttribute('aria-expanded')).toBe('true')
    })
    const settledTrace = container.querySelector('[data-chat-tool-trace]') as HTMLElement | null
    expect(settledTrace?.getAttribute('data-chat-turn-stream-state')).toBe('complete')
    expect(settledTrace?.getAttribute('data-chat-turn-complete')).toBe('true')
    expect(container.querySelector('[data-chat-trace-step="think"]')?.textContent).toContain(thinking)
    expect(container.querySelector('[data-chat-trace-step="chat"]')?.textContent).toContain('완료된 응답')
  })

  it('renders board post ids in assistant prose as board detail links', () => {
    const postId = 'p-59e2917e15de5367e81b2244a8f5095a'
    const label = postId.slice(0, 8)
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'a-board-link',
            text: `올렸다. 보드에 ${postId}.`,
            role: 'assistant',
            source: 'direct_assistant',
          }),
        ]}
        emptyText="empty"
        variant="messenger"
      />`,
      container,
    )

    const link = container.querySelector(`a[href="#board?post=${postId}"]`) as HTMLAnchorElement | null
    expect(link).not.toBeNull()
    expect(link?.classList.contains('chat-board-post-link')).toBe(true)
    expect(link?.getAttribute('data-board-post-id')).toBe(postId)
    expect(link?.getAttribute('aria-label')).toBe(`보드 글 ${postId} 열기`)
    expect(link?.getAttribute('title')).toBe(`보드 글 ${postId} 열기`)
    expect(link?.textContent).toContain('보드 글')
    expect(link?.textContent).toContain(label)
  })

  it('keeps the flat per-row tool bubbles when grouping is off (default)', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          toolEntry({ id: 'tool-t1', label: 'keeper_board_list' }),
          toolEntry({ id: 'tool-t2', label: 'keeper_tasks_list' }),
        ]}
        emptyText="empty"
      />`,
      container,
    )
    expect(container.querySelectorAll('[data-chat-tool-trace]').length).toBe(0)
    expect(container.querySelectorAll('[data-chat-variant="tool-call"]').length).toBe(2)
  })

  it('surfaces real failure status and result inside the card when expanded', async () => {
    recordToolCallOutputs([
      toolCallOutput({ tool_use_id: 't1', success: false, semantic_success: false, output: 'BOOM' }),
    ])
    render(
      html`<${ChatTranscript}
        entries=${[toolEntry({ id: 'tool-t1', label: 'keeper_board_post', text: '{"k":"v"}' })]}
        emptyText="empty"
        groupToolCalls=${true}
      />`,
      container,
    )
    expect(container.querySelector('[data-chat-tool-trace]')?.textContent).toContain('실패 1')
    const step = container.querySelector('[data-chat-trace-step="tool"]') as HTMLElement
    expect(step.querySelector('.chat-block-tstep-status.bad')).not.toBeNull()
    ;(step.querySelector('.chat-block-tstep-row') as HTMLElement).click()
    await flushUi()
    expect(step.textContent).toContain('BOOM')
  })

  it('marks a tool step pending until its output is joined', async () => {
    render(
      html`<${ChatTranscript}
        entries=${[toolEntry({ id: 'tool-unjoined', label: 'keeper_context_status' })]}
        emptyText="empty"
        groupToolCalls=${true}
      />`,
      container,
    )
    ;(container.querySelector('.chat-block-trace-hd') as HTMLButtonElement).click()
    await flushUi()
    const step = container.querySelector('[data-chat-trace-step="tool"]')
    expect(step?.querySelector('.chat-block-tstep-status.pending')).not.toBeNull()
  })

  it('marks trace-only tool steps without tool_call_id as unlinked, not pending', async () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'a-unlinked-trace-tool',
            text: 'legacy trace',
            role: 'assistant',
            source: 'direct_assistant',
            traceSteps: [{ kind: 'tool', name: 'legacy_tool_without_id' }],
          }),
        ]}
        emptyText="empty"
        groupToolCalls=${true}
        variant="messenger"
      />`,
      container,
    )

    const bundle = container.querySelector('[data-chat-turn-bundle]')
    expect(bundle?.textContent).toContain('조인 불가 1')
    const step = bundle?.querySelector('[data-chat-trace-step="tool"]') as HTMLElement | null
    expect(step?.querySelector('.chat-block-tstep-status.unlinked')).not.toBeNull()
    expect(step?.querySelector('.chat-block-tstep-status.pending')).toBeNull()
    expect(step?.querySelector('[data-chat-trace-provenance]')?.getAttribute('data-chat-trace-provenance')).toBe('unlinked_trace')
    expect(step?.getAttribute('data-chat-trace-link-state')).toBe('unlinked')
    expect(step?.getAttribute('data-chat-trace-output-state')).toBe('unlinked')
    expect(step?.getAttribute('data-chat-trace-tool-call-id')).toBeNull()
    expect(step?.getAttribute('data-chat-trace-entry-id')).toBeNull()

    ;(step?.querySelector('.chat-block-tstep-row') as HTMLElement).click()
    await flushUi()

    expect(step?.textContent).toContain('도구 호출 ID 없음')
    expect(step?.textContent).not.toContain('출력 대기 중')
  })

  it('marks an unjoined tool step as missing once the owning turn has settled', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          toolEntry({ id: 'tool-unjoined-settled', label: 'keeper_board_comment', turnRef: 'trace-s#1' }),
          entry({
            id: 'a-settled',
            text: '답합니다',
            role: 'assistant',
            source: 'direct_assistant',
            turnRef: 'trace-s#1',
            streamState: null,
          }),
        ]}
        emptyText="empty"
        groupToolCalls=${true}
        toolOutputsCoveredSinceMs=${Date.parse('2026-03-24T00:00:00.000Z')}
        toolOutputsCoveredThroughMs=${Date.parse('2026-03-24T00:00:01.000Z')}
      />`,
      container,
    )

    const bundle = container.querySelector('[data-chat-turn-bundle]')
    expect(bundle).not.toBeNull()
    const trace = bundle?.querySelector('[data-chat-tool-trace]') as HTMLElement | null
    expect(trace?.getAttribute('data-chat-tool-output-covered-since')).toBe(`${Date.parse('2026-03-24T00:00:00.000Z')}`)
    expect(trace?.getAttribute('data-chat-tool-output-covered-through')).toBe(`${Date.parse('2026-03-24T00:00:01.000Z')}`)
    const step = bundle?.querySelector('[data-chat-trace-step="tool"]')
    // Settled turn + never-joined output is a real gap, not an indefinite pending.
    expect(step?.querySelector('.chat-block-tstep-status.missing')).not.toBeNull()
    expect(step?.querySelector('.chat-block-tstep-status.pending')).toBeNull()
    expect(step?.getAttribute('data-chat-trace-output-state')).toBe('missing')
    expect(step?.getAttribute('data-chat-trace-output-coverage')).toBe('covered')
    // The gap is surfaced in the card header so silent failures are visible.
    expect(bundle?.textContent).toContain('결과 누락 1')
  })

  it('keeps a settled unjoined tool step pending until tool outputs hydrate', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          toolEntry({ id: 'tool-unjoined-before-hydration', label: 'keeper_board_comment', turnRef: 'trace-h#1' }),
          entry({
            id: 'a-before-hydration',
            text: '답합니다',
            role: 'assistant',
            source: 'direct_assistant',
            turnRef: 'trace-h#1',
            streamState: null,
          }),
        ]}
        emptyText="empty"
        groupToolCalls=${true}
      />`,
      container,
    )

    const bundle = container.querySelector('[data-chat-turn-bundle]')
    const step = bundle?.querySelector('[data-chat-trace-step="tool"]')
    expect(step?.querySelector('.chat-block-tstep-status.pending')).not.toBeNull()
    expect(step?.querySelector('.chat-block-tstep-status.missing')).toBeNull()
    expect(step?.getAttribute('data-chat-trace-output-state')).toBe('pending')
    expect(step?.getAttribute('data-chat-trace-output-coverage')).toBe('not-hydrated')
    expect(bundle?.textContent).not.toContain('결과 누락')
  })

  it('marks a settled unjoined tool step as coverage-gap when only older output hydration completed', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          toolEntry({
            id: 'tool-unjoined-after-old-hydration',
            label: 'keeper_board_comment',
            timestamp: '2026-03-24T00:00:10.000Z',
            turnRef: 'trace-old#1',
          }),
          entry({
            id: 'a-after-old-hydration',
            text: '답합니다',
            role: 'assistant',
            source: 'direct_assistant',
            turnRef: 'trace-old#1',
            streamState: null,
          }),
        ]}
        emptyText="empty"
        groupToolCalls=${true}
        toolOutputsCoveredThroughMs=${Date.parse('2026-03-24T00:00:01.000Z')}
      />`,
      container,
    )

    const bundle = container.querySelector('[data-chat-turn-bundle]')
    const step = bundle?.querySelector('[data-chat-trace-step="tool"]')
    expect(step?.querySelector('.chat-block-tstep-status.coverage-gap')).not.toBeNull()
    expect(step?.querySelector('.chat-block-tstep-status.pending')).toBeNull()
    expect(step?.querySelector('.chat-block-tstep-status.missing')).toBeNull()
    expect(step?.getAttribute('data-chat-trace-output-state')).toBe('coverage-gap')
    expect(step?.getAttribute('data-chat-trace-output-coverage')).toBe('coverage-gap')
    expect(bundle?.textContent).not.toContain('결과 누락')
    expect(bundle?.textContent).toContain('출력 범위 밖 1')
  })

  it('marks a settled unjoined tool step as coverage-gap when it predates the hydrated tool-output tail', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          toolEntry({
            id: 'tool-unjoined-before-covered-tail',
            label: 'keeper_board_comment',
            timestamp: '2026-03-24T00:00:05.000Z',
            turnRef: 'trace-tail#1',
          }),
          entry({
            id: 'a-before-covered-tail',
            text: '답합니다',
            role: 'assistant',
            source: 'direct_assistant',
            turnRef: 'trace-tail#1',
            streamState: null,
          }),
        ]}
        emptyText="empty"
        groupToolCalls=${true}
        toolOutputsCoveredSinceMs=${Date.parse('2026-03-24T00:00:10.000Z')}
        toolOutputsCoveredThroughMs=${Date.parse('2026-03-24T00:00:20.000Z')}
      />`,
      container,
    )

    const bundle = container.querySelector('[data-chat-turn-bundle]')
    const step = bundle?.querySelector('[data-chat-trace-step="tool"]')
    expect(step?.querySelector('.chat-block-tstep-status.coverage-gap')).not.toBeNull()
    expect(step?.querySelector('.chat-block-tstep-status.pending')).toBeNull()
    expect(step?.querySelector('.chat-block-tstep-status.missing')).toBeNull()
    expect(step?.getAttribute('data-chat-trace-output-state')).toBe('coverage-gap')
    expect(step?.getAttribute('data-chat-trace-output-coverage')).toBe('coverage-gap')
    expect(bundle?.textContent).not.toContain('결과 누락')
    expect(bundle?.textContent).toContain('출력 범위 밖 1')
  })

  it('keeps an unjoined tool step pending while the owning turn is still streaming', () => {
    render(
      html`<${ChatTranscript}
        entries=${[
          toolEntry({ id: 'tool-unjoined-live', label: 'keeper_board_comment', turnRef: 'trace-l#1' }),
          entry({
            id: 'a-live',
            text: '응답 작성 중',
            role: 'assistant',
            source: 'direct_assistant',
            turnRef: 'trace-l#1',
            streamState: 'streaming',
          }),
        ]}
        emptyText="empty"
        groupToolCalls=${true}
      />`,
      container,
    )

    const bundle = container.querySelector('[data-chat-turn-bundle]')
    const traceToggle = bundle?.querySelector('.chat-block-trace-hd') as HTMLButtonElement | null
    expect(traceToggle).not.toBeNull()
    fireEvent.click(traceToggle!)

    const step = bundle?.querySelector('[data-chat-trace-step="tool"]')
    // Output may still arrive while the turn streams, so keep it pending.
    expect(step?.querySelector('.chat-block-tstep-status.pending')).not.toBeNull()
    expect(step?.querySelector('.chat-block-tstep-status.missing')).toBeNull()
    expect(bundle?.textContent).not.toContain('결과 누락')
  })
})

describe('ChatMessageBubble — workspace source badge (C2)', () => {
  let container: HTMLDivElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('badges a non-obvious provenance (world-state) when enabled', () => {
    render(
      html`<${ChatTranscript}
        entries=${[entry({ id: 'w', text: 'injected context', role: 'system', source: 'world_state_prompt' })]}
        emptyText="empty"
        variant="messenger"
        showSourceBadge=${true}
      />`,
      container,
    )
    const badge = container.querySelector('.kw-src-badge.world')
    expect(badge).not.toBeNull()
    expect(badge?.textContent).toContain('월드')
  })

  it('leaves an ordinary user turn unbadged', () => {
    render(
      html`<${ChatTranscript}
        entries=${[entry({ id: 'u', text: 'hi', role: 'user', source: 'direct_user' })]}
        emptyText="empty"
        variant="messenger"
        showSourceBadge=${true}
      />`,
      container,
    )
    expect(container.querySelector('.kw-src-badge')).toBeNull()
  })

  it('renders no badge when the flag is off', () => {
    render(
      html`<${ChatTranscript}
        entries=${[entry({ id: 'w', text: 'injected', role: 'system', source: 'world_state_prompt' })]}
        emptyText="empty"
        variant="messenger"
      />`,
      container,
    )
    expect(container.querySelector('.kw-src-badge')).toBeNull()
  })
})

describe('fusion chat card', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    window.location.hash = '#workspace'
    vi.mocked(fetchBoardPost).mockReset()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  function fusionEntry(): KeeperConversationEntry {
    return {
      id: 'fusion-1',
      role: 'assistant',
      source: 'internal_assistant',
      label: 'sangsu',
      text: 'Fusion deliberation (run fus-1) — answer — done',
      rawText: 'Fusion deliberation (run fus-1) — answer — done',
      timestamp: '2026-06-19T00:00:00.000Z',
      delivery: 'history',
      streamState: null,
      details: null,
      error: null,
      blocks: [{ t: 'fusion', board_post_id: 'p-1', run_id: 'fus-1' }],
    }
  }

  it('renders a collapsed fusion card without fetching the board post', () => {
    render(html`<${ChatTranscript} entries=${[fusionEntry()]} emptyText="empty" />`, container)
    const card = container.querySelector('[data-fusion-card]')
    expect(card).not.toBeNull()
    expect(card?.textContent).toContain('Fusion 심의')
    // Collapsed: no detail rendered and no network call yet.
    expect(container.querySelector('[data-fusion-detail]')).toBeNull()
    expect(fetchBoardPost).not.toHaveBeenCalled()
    // Focus ring must be the resolved CHAT_FOCUS_RING string, not the stringified
    // ringFocusClasses function (a bare `${ringFocusClasses}` interpolation regression).
    const expandButton = card?.querySelector('button')
    expect(expandButton?.className).toContain('focus-visible:outline-none')
    expect(expandButton?.className).not.toContain('opts')
  })

  it('routes from the collapsed fusion card to the run and source board post', () => {
    render(html`<${ChatTranscript} entries=${[fusionEntry()]} emptyText="empty" />`, container)

    const openRun = container.querySelector('[data-testid="fusion-chat-open-run"]') as HTMLButtonElement | null
    const openBoard = container.querySelector('[data-testid="fusion-chat-open-board"]') as HTMLButtonElement | null
    expect(openRun).not.toBeNull()
    expect(openBoard).not.toBeNull()

    fireEvent.click(openRun as HTMLButtonElement)
    expect(window.location.hash).toBe('#fusion?run_id=fus-1')
    expect(container.querySelector('[data-fusion-detail]')).toBeNull()
    expect(fetchBoardPost).not.toHaveBeenCalled()

    fireEvent.click(openBoard as HTMLButtonElement)
    expect(window.location.hash).toBe('#board?post=p-1')
    expect(container.querySelector('[data-fusion-detail]')).toBeNull()
    expect(fetchBoardPost).not.toHaveBeenCalled()
  })

  it('lazy-fetches the board post and renders panel answers + judge on expand', async () => {
    vi.mocked(fetchBoardPost).mockResolvedValue({
      meta: {
        source: 'fusion',
        panel: [
          { model: 'ollama_cloud.kimi-k2-6', status: 'answered', answer: 'PANEL ONE ANSWER' },
          { model: 'ollama_cloud.minimax-m3', status: 'failed', reason: 'timeout' },
        ],
        judge: { status: 'synthesized', decision: 'answer — ok', resolved_answer: 'JUDGE RESOLVED ANSWER' },
      },
    } as unknown as Awaited<ReturnType<typeof fetchBoardPost>>)

    render(html`<${ChatTranscript} entries=${[fusionEntry()]} emptyText="empty" />`, container)
    const toggle = container.querySelector('[data-fusion-card] button') as HTMLButtonElement | null
    expect(toggle).not.toBeNull()
    fireEvent.click(toggle as HTMLButtonElement)
    await flushUi()

    expect(fetchBoardPost).toHaveBeenCalledWith('p-1')
    const detail = container.querySelector('[data-fusion-detail]')
    // Judge conclusion + failed-panel reason are visible immediately.
    expect(detail?.textContent).toContain('JUDGE RESOLVED ANSWER')
    expect(detail?.textContent).toContain('timeout')
    // Answered panel answers are collapsed by default — open the panel to read.
    expect(detail?.textContent).not.toContain('PANEL ONE ANSWER')
    const panelToggle = container.querySelector('[data-fusion-panel] button') as HTMLButtonElement | null
    expect(panelToggle).not.toBeNull()
    // Panel toggle carries the resolved focus ring, not a stringified function.
    expect(panelToggle?.className).toContain('focus-visible:outline-none')
    expect(panelToggle?.className).not.toContain('opts')
    fireEvent.click(panelToggle as HTMLButtonElement)
    await flushUi()
    expect(container.querySelector('[data-fusion-detail]')?.textContent).toContain('PANEL ONE ANSWER')
  })

  it('normalizes live fusion failure reasons and renders judge errors', async () => {
    vi.mocked(fetchBoardPost).mockResolvedValue({
      meta: {
        source: 'fusion',
        panel: [
          {
            model: 'ollama_cloud.kimi-k2-6',
            status: 'failed',
            reason_detail: "Provider 'unknown' timeout phase=http_operation",
            reason_code: 'provider_error',
          },
          {
            model: 'ollama_cloud.minimax-m3',
            status: 'failed',
            reason: "(Fusion_types.Provider_error \"Provider 'unknown' bad gateway\")",
          },
          {
            model: 'ollama_cloud.deepseek-v4-flash',
            status: 'failed',
            reason: 'Fusion_types.Timeout',
          },
        ],
        judge: { status: 'failed', decision: 'blocked', error: 'judge failed hard' },
      },
    } as unknown as Awaited<ReturnType<typeof fetchBoardPost>>)

    render(html`<${ChatTranscript} entries=${[fusionEntry()]} emptyText="empty" />`, container)
    fireEvent.click(container.querySelector('[data-fusion-card] > button') as HTMLButtonElement)
    await flushUi()

    const detail = container.querySelector('[data-fusion-detail]')
    expect(detail?.textContent).toContain("Provider 'ollama_cloud.kimi-k2-6' timeout phase=http_operation")
    expect(detail?.textContent).toContain("Provider 'ollama_cloud.minimax-m3' bad gateway")
    expect(detail?.textContent).toContain('timeout')
    expect(detail?.textContent).toContain('judge failed hard')
    expect(detail?.textContent).not.toContain('Fusion_types.Provider_error')
    expect(detail?.textContent).not.toContain("Provider 'unknown'")
  })

  it('shows an error message when the board post fetch fails', async () => {
    vi.mocked(fetchBoardPost).mockRejectedValue(new Error('boom'))
    render(html`<${ChatTranscript} entries=${[fusionEntry()]} emptyText="empty" />`, container)
    fireEvent.click(container.querySelector('[data-fusion-card] button') as HTMLButtonElement)
    await flushUi()
    expect(container.querySelector('[data-fusion-detail]')?.textContent).toContain('불러오지 못했습니다')
  })

  it('falls back to the persisted conclusion text when the board fetch fails', async () => {
    vi.mocked(fetchBoardPost).mockRejectedValue(new Error('boom'))
    render(html`<${ChatTranscript} entries=${[fusionEntry()]} emptyText="empty" />`, container)
    fireEvent.click(container.querySelector('[data-fusion-card] button') as HTMLButtonElement)
    await flushUi()
    const fallback = container.querySelector('[data-fusion-fallback]')
    expect(fallback).not.toBeNull()
    expect(fallback?.textContent).toContain('answer — done')
  })

  it('falls back to the persisted conclusion text when the board post has no panel/judge', async () => {
    vi.mocked(fetchBoardPost).mockResolvedValue({
      meta: { source: 'fusion', panel: [], judge: null },
    } as unknown as Awaited<ReturnType<typeof fetchBoardPost>>)
    render(html`<${ChatTranscript} entries=${[fusionEntry()]} emptyText="empty" />`, container)
    fireEvent.click(container.querySelector('[data-fusion-card] button') as HTMLButtonElement)
    await flushUi()
    const fallback = container.querySelector('[data-fusion-fallback]')
    expect(fallback).not.toBeNull()
    expect(fallback?.textContent).toContain('answer — done')
    expect(container.querySelector('[data-fusion-detail]')?.textContent).not.toContain('비어 있습니다')
  })

  it('does not show the fallback conclusion when panel/judge load successfully', async () => {
    vi.mocked(fetchBoardPost).mockResolvedValue({
      meta: {
        source: 'fusion',
        panel: [{ model: 'm1', status: 'answered', answer: 'A' }],
        judge: { status: 'synthesized', decision: 'd', resolved_answer: 'R' },
      },
    } as unknown as Awaited<ReturnType<typeof fetchBoardPost>>)
    render(html`<${ChatTranscript} entries=${[fusionEntry()]} emptyText="empty" />`, container)
    fireEvent.click(container.querySelector('[data-fusion-card] button') as HTMLButtonElement)
    await flushUi()
    expect(container.querySelector('[data-fusion-fallback]')).toBeNull()
  })

  it('shows a retention note in the expanded detail', async () => {
    vi.mocked(fetchBoardPost).mockResolvedValue({
      meta: {
        source: 'fusion',
        panel: [],
        judge: { status: 'synthesized', decision: 'd', resolved_answer: 'R' },
      },
    } as unknown as Awaited<ReturnType<typeof fetchBoardPost>>)
    render(html`<${ChatTranscript} entries=${[fusionEntry()]} emptyText="empty" />`, container)
    fireEvent.click(container.querySelector('[data-fusion-card] button') as HTMLButtonElement)
    await flushUi()
    const retention = container.querySelector('[data-fusion-retention]')
    expect(retention).not.toBeNull()
    expect(retention?.textContent).toContain('만료')
  })

  it('renders judge.synthesis as markdown (not the raw resolved_answer dump)', async () => {
    vi.mocked(fetchBoardPost).mockResolvedValue({
      meta: {
        source: 'fusion',
        panel: [{ model: 'm1', status: 'answered', answer: '## Heading One\n\n- bullet item', output_tokens: 100 }],
        judge: {
          status: 'synthesized',
          decision: 'answer — ok',
          synthesis: '**Consensus**\n\n- agreed point',
          resolved_answer: 'PLAIN RESOLVED',
        },
        observed_usage: { input_tokens: 712, output_tokens: 3432 },
      },
    } as unknown as Awaited<ReturnType<typeof fetchBoardPost>>)

    render(html`<${ChatTranscript} entries=${[fusionEntry()]} emptyText="empty" />`, container)
    fireEvent.click(container.querySelector('[data-fusion-card] button') as HTMLButtonElement)
    await flushUi()

    // Judge synthesis renders to real markdown elements immediately (not collapsed).
    const judge = container.querySelector('[data-fusion-judge]')
    expect(judge?.querySelector('strong')?.textContent).toBe('Consensus')
    // synthesis takes precedence over resolved_answer when both present.
    expect(judge?.textContent).toContain('agreed point')
    expect(judge?.textContent).not.toContain('PLAIN RESOLVED')
    // Panel answer markdown renders to real elements once its row is opened.
    // Scope to the panel — the judge synthesis above also contains an <li>.
    fireEvent.click(container.querySelector('[data-fusion-panel] button') as HTMLButtonElement)
    await flushUi()
    const panel = container.querySelector('[data-fusion-panel]')
    expect(panel?.querySelector('h2')?.textContent).toBe('Heading One')
    expect(panel?.querySelector('li')?.textContent).toContain('bullet item')
  })

  it('sanitizes untrusted model markup in judge synthesis and panel answers', async () => {
    const xss = '**ok**\n\n<script>alert(1)</script>\n\n<img src=x onerror=alert(2)>\n\n[click](javascript:alert(3))'
    vi.mocked(fetchBoardPost).mockResolvedValue({
      meta: {
        source: 'fusion',
        panel: [{ model: 'm1', status: 'answered', answer: xss, output_tokens: 10 }],
        judge: { status: 'synthesized', decision: 'answer', synthesis: xss },
      },
    } as unknown as Awaited<ReturnType<typeof fetchBoardPost>>)

    render(html`<${ChatTranscript} entries=${[fusionEntry()]} emptyText="empty" />`, container)
    fireEvent.click(container.querySelector('[data-fusion-card] button') as HTMLButtonElement)
    await flushUi()
    fireEvent.click(container.querySelector('[data-fusion-panel] button') as HTMLButtonElement)
    await flushUi()

    // Benign markdown still renders, but every executable vector is stripped by purifyHtml.
    const detail = container.querySelector('[data-fusion-detail]')
    expect(detail?.querySelector('strong')?.textContent).toBe('ok')
    expect(container.querySelector('[data-fusion-detail] script')).toBeNull()
    const html_ = detail?.innerHTML ?? ''
    expect(html_).not.toContain('onerror')
    expect(html_.toLowerCase()).not.toContain('javascript:')
  })

  it('surfaces token usage and answered count in the header', async () => {
    vi.mocked(fetchBoardPost).mockResolvedValue({
      meta: {
        source: 'fusion',
        panel: [
          { model: 'm1', status: 'answered', answer: 'a', output_tokens: 1200 },
          { model: 'm2', status: 'failed', reason: 'timeout' },
        ],
        judge: { status: 'synthesized', decision: 'answer', resolved_answer: 'r' },
        observed_usage: { input_tokens: 712, output_tokens: 3432 },
      },
    } as unknown as Awaited<ReturnType<typeof fetchBoardPost>>)

    render(html`<${ChatTranscript} entries=${[fusionEntry()]} emptyText="empty" />`, container)
    fireEvent.click(container.querySelector('[data-fusion-card] button') as HTMLButtonElement)
    await flushUi()

    const card = container.querySelector('[data-fusion-card]')
    // 1 of 2 answered, total output tokens formatted with separators.
    expect(card?.textContent).toContain('패널 1/2 합의')
    expect(card?.textContent).toContain('3,432 tok')
    // Per-panel token count present.
    expect(container.querySelector('[data-fusion-detail]')?.textContent).toContain('1,200 tok')
  })
})

describe('ChatMessageBubble — rich markdown rendering of assistant prose', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  function renderEntries(entries: KeeperConversationEntry[]) {
    render(html`<${ChatTranscript} entries=${entries} emptyText="empty" />`, container)
  }

  it('renders a code fence in assistant prose as a code block', async () => {
    renderEntries([
      entry({
        id: 'a1',
        role: 'assistant',
        source: 'direct_assistant',
        text: 'Here you go:\n\n```ts\nconst x = 1\n```',
      }),
    ])
    await waitFor(() => expect(container.querySelector('[data-chat-block="code"]')).not.toBeNull())
    const code = container.querySelector('[data-chat-block="code"]')
    expect(code).not.toBeNull()
    expect(code?.textContent).toContain('const x = 1')
  })

  it('routes inline markdown and lists through the rich parser', async () => {
    renderEntries([
      entry({
        id: 'a-inline',
        role: 'assistant',
        source: 'direct_assistant',
        text: 'Summary with **bold** and `code`.\n\n- first\n- second',
      }),
    ])

    await waitFor(() => expect(container.querySelector('[data-chat-blocks] strong')?.textContent).toBe('bold'))
    expect(container.querySelector('[data-chat-blocks] code')?.textContent).toBe('code')
    const items = Array.from(container.querySelectorAll('[data-chat-blocks] li')).map((node) => node.textContent)
    expect(items).toEqual(['first', 'second'])
  })

  it('keeps prior rich blocks visible while streaming text is re-parsed', async () => {
    renderEntries([
      entry({
        id: 'a-stream',
        role: 'assistant',
        source: 'direct_assistant',
        text: '```ts\nconst before = 1\n```',
      }),
    ])

    await waitFor(() => expect(container.querySelector('[data-chat-block="code"]')?.textContent).toContain('before'))

    renderEntries([
      entry({
        id: 'a-stream',
        role: 'assistant',
        source: 'direct_assistant',
        delivery: 'streaming',
        text: '```ts\nconst after = 2\n```',
      }),
    ])

    expect(container.querySelector('[data-chat-block="code"]')?.textContent).toContain('before')
    await waitFor(() => expect(container.querySelector('[data-chat-block="code"]')?.textContent).toContain('after'))
  })

  it('re-parses richly even when the backend supplied a degraded p-only block', async () => {
    // The backend persists a line-based parse (escaped <p>); the render path
    // must still recover the structured code block from the message text.
    renderEntries([
      entry({
        id: 'a2',
        role: 'assistant',
        source: 'direct_assistant',
        text: '```sh\nls -la\n```',
        blocks: [
          { t: 'p', html: '```sh' },
          { t: 'p', html: 'ls -la' },
          { t: 'p', html: '```' },
        ],
      }),
    ])
    await waitFor(() => expect(container.querySelector('[data-chat-block="code"]')).not.toBeNull())
  })

  it('keeps server blocks as-is when the message carries a non-text card/clip', () => {
    // A voice clip cannot be reconstructed from text, so the message renders its
    // server block and does not re-parse the (secondary) transcript prose.
    renderEntries([
      entry({
        id: 'a3',
        role: 'assistant',
        source: 'direct_assistant',
        text: 'transcript mentioning ```code``` inline',
        blocks: [
          { t: 'voice', secs: 3, wave: [0.2, 0.4], src: 'https://example.com/v.mp3', transcript: 'note' },
        ],
      }),
    ])
    expect(container.querySelector('[data-chat-block="voice"]')).not.toBeNull()
    expect(container.querySelector('[data-chat-block="code"]')).toBeNull()
  })
})

// Pixel-match of the v2 composer to the Claude-Design prototype (composer.jsx /
// styles/v2.css). jsdom does not apply the .css files, so these assert the
// markup contract the CSS depends on: the textarea must be a flush, borderless
// element with NO inline Tailwind box styling (border/rounded/padding/bg/
// control-textarea) — all box styling lives in .composer textarea (chat.css).
describe('ChatComposer v2 prototype surface', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  function renderComposer() {
    render(
      html`<${ChatComposer}
        draft=""
        placeholder="메시지 입력..."
        disabled=${false}
        streaming=${false}
        onDraftChange=${() => {}}
        onSend=${() => {}}
      />`,
      container,
    )
  }

  it('renders the composer box, tools, and send button structure', () => {
    renderComposer()
    expect(container.querySelector('.composer')).not.toBeNull()
    expect(container.querySelector('.composer-box')).not.toBeNull()
    expect(container.querySelector('.composer-tools')).not.toBeNull()
    expect(container.querySelector('.composer-tools .send')).not.toBeNull()
    // attachment ctool always present
    expect(container.querySelector('.composer-tools .ctool')).not.toBeNull()
  })

  it('renders a flush borderless textarea with no inline box styling', () => {
    renderComposer()
    const textarea = container.querySelector('.composer-box textarea') as HTMLTextAreaElement
    expect(textarea).not.toBeNull()
    const cls = textarea.className
    // flush class hook present
    expect(cls).toContain('composer-textarea')
    // no inline Tailwind border / radius / padding / background / utility that
    // would draw a nested box inside .composer-box (prototype has none).
    expect(cls).not.toContain('control-textarea')
    expect(cls).not.toMatch(/\bborder\b/)
    expect(cls).not.toMatch(/\brounded/)
    expect(cls).not.toMatch(/\bpx-/)
    expect(cls).not.toMatch(/\bpy-/)
    expect(cls).not.toMatch(/\bbg-\[/)
  })

  it('keeps send and attach controls operational', () => {
    const onSend = vi.fn()
    render(
      html`<${ChatComposer}
        draft="hello"
        placeholder="메시지 입력..."
        disabled=${false}
        streaming=${false}
        onDraftChange=${() => {}}
        onSend=${onSend}
      />`,
      container,
    )
    const send = container.querySelector('.composer-tools .send') as HTMLButtonElement
    expect(send).not.toBeNull()
    expect(send.disabled).toBe(false)
    send.click()
    expect(onSend).toHaveBeenCalledTimes(1)
  })

  it('runs the active slash command from the strict-index-safe menu selection', () => {
    const run = vi.fn()
    render(
      html`<${ChatComposer}
        draft="/res"
        placeholder="메시지 입력..."
        disabled=${false}
        streaming=${false}
        commands=${[
          {
            id: 'restart',
            group: 'lifecycle',
            label: 'Restart keeper',
            run,
          },
        ]}
        onDraftChange=${() => {}}
        onSend=${() => {}}
      />`,
      container,
    )

    expect(container.querySelector('.slashmenu')).not.toBeNull()
    const textarea = container.querySelector('.composer-box textarea') as HTMLTextAreaElement
    fireEvent.keyDown(textarea, { key: 'Enter' })

    expect(run).toHaveBeenCalledTimes(1)
  })

  it('shows the keeper label in the slash menu header', () => {
    const keeperLabel = 'ocaml-multicore/eio'
    render(
      html`<${ChatComposer}
        draft="/res"
        placeholder="메시지 입력..."
        disabled=${false}
        streaming=${false}
        draftPersistKey="draft:v1:internal:opaque"
        keeperLabel=${keeperLabel}
        commands=${[
          { id: 'restart', group: 'lifecycle', label: 'Restart keeper', run: () => {} },
        ]}
        onDraftChange=${() => {}}
        onSend=${() => {}}
      />`,
      container,
    )
    const header = container.querySelector('.slashmenu-h')
    expect(header?.textContent).toBe(`${keeperLabel} · ${CHAT_COMPOSER_COMMAND_HEADER_SUFFIX}`)
  })

  it('switches the textarea placeholder to the drop cue while files are dragged over', () => {
    render(
      html`<${ChatComposer}
        draft=""
        placeholder="ocaml-multicore/eio 에게 메시지…  (/ 명령 · ⌘+Enter 전송)"
        disabled=${false}
        streaming=${false}
        onDraftChange=${() => {}}
        onSend=${() => {}}
      />`,
      container,
    )
    const textarea = container.querySelector('.composer-box textarea') as HTMLTextAreaElement
    expect(textarea.placeholder).toBe('ocaml-multicore/eio 에게 메시지…  (/ 명령 · ⌘+Enter 전송)')

    const composer = container.querySelector('.composer') as HTMLDivElement
    fireEvent.dragOver(composer)
    const textareaAfterDrag = container.querySelector('.composer-box textarea') as HTMLTextAreaElement
    expect(textareaAfterDrag.placeholder).toBe(CHAT_COMPOSER_DROP_PLACEHOLDER)
  })
})
