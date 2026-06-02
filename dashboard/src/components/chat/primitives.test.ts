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

  it('does not render an ellipsis for empty streaming text', () => {
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

    const bodies = [...container.querySelectorAll('.whitespace-pre-wrap')]
    const latestBody = (bodies[bodies.length - 1]?.textContent ?? '').trim()
    expect(latestBody).toBe('')
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
})
