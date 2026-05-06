import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  AgentConversation,
  summarizeAgentConversation,
} from './agent-conversation'

const messages = [
  { id: 'm1', role: 'user' as const, content: 'hello', timestamp: Date.now() },
  { id: 'm2', role: 'agent' as const, content: 'hi there', timestamp: Date.now() + 1000 },
]

describe('AgentConversation', () => {
  it('renders empty state', () => {
    const container = document.createElement('div')
    render(h(AgentConversation, { messages: [] }), container)
    expect(container.textContent).toContain('대화 내용이 없습니다')
    expect(container.textContent).toContain('메시지')
    expect(container.textContent).toContain('분기')
    expect(container.textContent).toContain('도구')
  })

  it('renders role region when empty', () => {
    const container = document.createElement('div')
    render(h(AgentConversation, { messages: [] }), container)
    expect(container.querySelector('[role="region"]')).not.toBeNull()
  })

  it('renders messages', () => {
    const container = document.createElement('div')
    render(h(AgentConversation, { messages }), container)
    expect(container.textContent).toContain('hello')
    expect(container.textContent).toContain('hi there')
    expect(container.querySelector('[data-agent-conversation]')).not.toBeNull()
  })

  it('renders user message with data-message-id', () => {
    const container = document.createElement('div')
    render(h(AgentConversation, { messages }), container)
    const msg = container.querySelector('[data-message-id="m1"]') as HTMLElement
    expect(msg).not.toBeNull()
    expect(msg.dataset.messageRole).toBe('user')
    expect(msg.dataset.messageOrphan).toBe('false')
  })

  it('renders agent message with data-message-id', () => {
    const container = document.createElement('div')
    render(h(AgentConversation, { messages }), container)
    expect(container.querySelector('[data-message-id="m2"]')).not.toBeNull()
  })

  it('renders system message', () => {
    const container = document.createElement('div')
    const sys = [{ id: 'm3', role: 'system' as const, content: 'sys msg', timestamp: Date.now() }]
    render(h(AgentConversation, { messages: sys }), container)
    expect(container.textContent).toContain('sys msg')
  })

  it('renders tool message', () => {
    const container = document.createElement('div')
    const tool = [{ id: 'm4', role: 'tool' as const, content: 'tool result', timestamp: Date.now() }]
    render(h(AgentConversation, { messages: tool }), container)
    expect(container.textContent).toContain('tool result')
  })

  it('renders branch label when present', () => {
    const container = document.createElement('div')
    const branch = [{ id: 'm5', role: 'agent' as const, content: 'branch', timestamp: Date.now(), branchLabel: 'v2' }]
    render(h(AgentConversation, { messages: branch }), container)
    expect(container.textContent).toContain('v2')
  })

  it('calls onSelectMessage on click', () => {
    const onSelect = vi.fn()
    const container = document.createElement('div')
    render(h(AgentConversation, { messages, onSelectMessage: onSelect }), container)
    const bubble = container.querySelector('[data-message-id="m1"]') as HTMLElement
    const clickable = bubble.querySelector('div[style*="cursor"]') || bubble
    ;(clickable as HTMLElement).click()
    expect(onSelect).toHaveBeenCalledWith('m1')
  })

  it('renders feed role when messages present', () => {
    const container = document.createElement('div')
    render(h(AgentConversation, { messages }), container)
    const feed = container.querySelector('[role="feed"]')
    expect(feed).not.toBeNull()
    expect(feed?.getAttribute('aria-label')).toContain('메시지 2개')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(AgentConversation, { messages: [], testId: 'ac-1' }), container)
    expect(container.querySelector('[data-testid="ac-1"]')).not.toBeNull()
  })

  it('renders timestamp', () => {
    const container = document.createElement('div')
    const ts = new Date('2024-01-01T09:30:00').getTime()
    render(h(AgentConversation, { messages: [{ id: 'm6', role: 'user' as const, content: 'x', timestamp: ts }] }), container)
    expect(container.textContent).toContain('09:30')
    expect(container.querySelector('time')?.getAttribute('datetime')).toBe(new Date(ts).toISOString())
  })

  it('exposes conversation summary metadata', () => {
    const container = document.createElement('div')
    const branchMessages = [
      messages[0]!,
      { id: 'm2', role: 'agent' as const, content: 'branch', timestamp: Date.now() + 1000, parentId: 'm1', branchLabel: 'v2' },
      { id: 'm3', role: 'tool' as const, content: 'tool result', timestamp: Date.now() + 2000, parentId: 'missing' },
    ]
    render(h(AgentConversation, { messages: branchMessages }), container)
    const root = container.querySelector('[data-agent-conversation]') as HTMLElement
    const branch = container.querySelector('[data-message-id="m2"]') as HTMLElement
    const orphan = container.querySelector('[data-message-id="m3"]') as HTMLElement

    expect(root.dataset.agentConversationMessageCount).toBe('3')
    expect(root.dataset.agentConversationUserCount).toBe('1')
    expect(root.dataset.agentConversationAgentCount).toBe('1')
    expect(root.dataset.agentConversationToolCount).toBe('1')
    expect(root.dataset.agentConversationBranchCount).toBe('2')
    expect(root.dataset.agentConversationOrphanCount).toBe('1')
    expect(root.dataset.agentConversationStatus).toBe('orphaned')
    expect(branch.dataset.messageParentId).toBe('m1')
    expect(branch.dataset.messageBranchLabel).toBe('v2')
    expect(orphan.dataset.messageOrphan).toBe('true')
  })

  it('summarizes linear, branched, and empty conversations', () => {
    expect(summarizeAgentConversation([])).toMatchObject({
      messageCount: 0,
      status: 'empty',
    })
    expect(summarizeAgentConversation(messages)).toMatchObject({
      messageCount: 2,
      userCount: 1,
      agentCount: 1,
      status: 'linear',
    })
    expect(summarizeAgentConversation([
      messages[0]!,
      { id: 'm2', role: 'agent' as const, content: 'branch', timestamp: Date.now(), parentId: 'm1', branchLabel: 'v2' },
    ])).toMatchObject({
      branchCount: 1,
      orphanCount: 0,
      status: 'branched',
    })
  })
})
