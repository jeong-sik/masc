import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ChatBlock, KeeperConversationEntry } from '../../types'
import type { ToolCallEntry } from '../../api/dashboard'
import { ChatComposer, ChatTranscript } from './primitives'
import { collectAttachments } from './attachments'
import { recordToolCallOutputs, resetToolCallOutputs } from '../../tool-call-output-store'

vi.mock('./attachments', () => ({
  collectAttachments: vi.fn(),
}))

const flushUi = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 30))

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

  it('toggles the voice memo play button label', async () => {
    renderBlocks([{ t: 'voice', secs: 2, wave: [0.2, 0.5] }])

    const play = container.querySelector('[data-chat-block="voice"] button') as HTMLButtonElement
    expect(play?.textContent?.trim()).toBe('▶')
    play.click()
    await flushUi()
    expect(play?.textContent?.trim()).toBe('❙❙')
    play.click()
    await flushUi()
    expect(play?.textContent?.trim()).toBe('▶')
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
          { kind: 'tool', name: 'keeper_context_status', status: 'ok', dur: '0.2s', args: { path: 'a' }, result: '{"ok":true}' },
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
    container.remove()
    vi.useRealTimers()
  })

  function renderComposer(props: {
    draft?: string
    onSend?: (payload: { blocks: ChatBlock[] }) => void
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
    const dt = new DataTransfer()
    dt.items.add(new File(['x'], 'screen.png', { type: 'image/png' }))
    fileInput.files = dt.files
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

    const dt = new DataTransfer()
    dt.items.add(new File(['{}'], 'drop.json', { type: 'application/json' }))
    fireEvent.drop(composer, { dataTransfer: dt })
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
    const dt = new DataTransfer()
    dt.items.add(new File(['x'], 'screen.png', { type: 'image/png' }))
    fileInput.files = dt.files
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
  })

  it('keeps send disabled until there is content', () => {
    renderComposer()
    const sendBtn = container.querySelector('.send') as HTMLButtonElement
    expect(sendBtn.disabled).toBe(true)
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
