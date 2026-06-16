import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { KeeperConversationEntry } from '../../types'
import { ChatComposer, ChatTranscript } from './primitives'

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
