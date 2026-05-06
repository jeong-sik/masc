// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { AgentConversation } from './agent-conversation'

describe('AgentConversation a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const makeMessages = (): import('./agent-conversation').ConversationMessage[] => [
    { id: 'm1', role: 'user', content: 'Hello', timestamp: Date.now() - 60000 },
    { id: 'm2', role: 'agent', content: 'Hi there', timestamp: Date.now() - 50000 },
    { id: 'm3', role: 'system', content: 'System notice', timestamp: Date.now() - 40000 },
    { id: 'm4', role: 'tool', content: 'tool result', timestamp: Date.now() - 30000 },
  ]

  it('renders accessibly with messages', async () => {
    render(html`<${AgentConversation} messages=${makeMessages()} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly when empty', async () => {
    render(html`<${AgentConversation} messages=${[]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has feed role', () => {
    render(html`<${AgentConversation} messages=${makeMessages()} />`, container)
    const feed = container.querySelector('[role="feed"]')
    const root = container.querySelector('[data-agent-conversation]') as HTMLElement
    expect(feed).not.toBeNull()
    expect(feed?.getAttribute('aria-label')).toContain('메시지 4개')
    expect(root.dataset.agentConversationStatus).toBe('linear')
    expect(root.dataset.agentConversationMessageCount).toBe('4')
  })

  it('renders user message with align class', () => {
    render(
      html`<${AgentConversation} messages=${[{ id: 'u1', role: 'user', content: 'Hey', timestamp: Date.now() }]} />`,
      container,
    )
    const article = container.querySelector('article')
    expect(article?.classList.contains('items-end')).toBe(true)
  })

  it('renders agent message with align class', () => {
    render(
      html`<${AgentConversation} messages=${[{ id: 'a1', role: 'agent', content: 'OK', timestamp: Date.now() }]} />`,
      container,
    )
    const article = container.querySelector('article')
    expect(article?.classList.contains('items-start')).toBe(true)
  })

  it('renders branch label', () => {
    render(
      html`<${AgentConversation}
        messages=${[{ id: 'b1', role: 'agent', content: 'Branch', timestamp: Date.now(), branchLabel: 'feat/auth' }]}
      />`,
      container,
    )
    expect(container.textContent).toContain('feat/auth')
    const article = container.querySelector('[data-message-id="b1"]') as HTMLElement
    expect(article.dataset.messageBranchLabel).toBe('feat/auth')
  })

  it('calls onSelectMessage when clicked', () => {
    const onSelect = vi.fn()
    render(
      html`<${AgentConversation}
        messages=${[{ id: 's1', role: 'agent', content: 'Click me', timestamp: Date.now() }]}
        onSelectMessage=${onSelect}
      />`,
      container,
    )
    const bubble = container.querySelector('[data-message-id="s1"] div')
    ;(bubble as HTMLElement)?.click()
    expect(onSelect).toHaveBeenCalledWith('s1')
  })

  it('renders system message centered', () => {
    render(
      html`<${AgentConversation}
        messages=${[{ id: 'sys1', role: 'system', content: 'Notice', timestamp: Date.now() }]}
      />`,
      container,
    )
    const article = container.querySelector('article')
    expect(article?.classList.contains('items-center')).toBe(true)
  })

  it('marks orphaned branches in metadata', () => {
    render(
      html`<${AgentConversation}
        messages=${[{ id: 'o1', role: 'agent', content: 'Missing parent', timestamp: Date.now(), parentId: 'missing' }]}
      />`,
      container,
    )
    const root = container.querySelector('[data-agent-conversation]') as HTMLElement
    const article = container.querySelector('[data-message-id="o1"]') as HTMLElement
    expect(root.dataset.agentConversationStatus).toBe('orphaned')
    expect(root.dataset.agentConversationOrphanCount).toBe('1')
    expect(article.dataset.messageOrphan).toBe('true')
  })
})
