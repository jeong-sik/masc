// @vitest-environment happy-dom
//
// jest-axe coverage for chat primitives (ChatTranscript empty +
// ChatComposer). Skip ChatMessageBubble for now — needs full
// KeeperConversationEntry fixtures (separate batch).
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { ChatTranscript, ChatComposer } from './primitives'

describe('ChatTranscript a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('empty transcript (default variant) passes axe', async () => {
    render(
      html`<${ChatTranscript}
        entries=${[]}
        emptyText="No messages yet."
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('empty transcript (messenger variant) passes axe', async () => {
    render(
      html`<${ChatTranscript}
        entries=${[]}
        emptyText="대화를 시작해보세요."
        variant="messenger"
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})

describe('ChatComposer a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('idle composer passes axe', async () => {
    render(
      html`<${ChatComposer}
        draft=""
        placeholder="Type a message..."
        disabled=${false}
        streaming=${false}
        onDraftChange=${() => {}}
        onSend=${() => {}}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('streaming composer passes axe', async () => {
    render(
      html`<${ChatComposer}
        draft="hello"
        placeholder="Type a message..."
        disabled=${false}
        streaming=${true}
        streamStartedAt=${Date.now() - 2000}
        onDraftChange=${() => {}}
        onSend=${() => {}}
        onAbort=${() => {}}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('disabled composer passes axe', async () => {
    render(
      html`<${ChatComposer}
        draft=""
        placeholder="Conversation closed"
        disabled=${true}
        streaming=${false}
        onDraftChange=${() => {}}
        onSend=${() => {}}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
