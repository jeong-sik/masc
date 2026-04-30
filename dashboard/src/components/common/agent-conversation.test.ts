import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { AgentConversation } from './agent-conversation'

const messages = [
  { id: 'm1', role: 'user' as const, content: 'hello', timestamp: Date.now() },
  { id: 'm2', role: 'agent' as const, content: 'hi there', timestamp: Date.now() + 1000 },
]

describe('AgentConversation', () => {
  it('renders empty state', () => {
    const container = document.createElement('div')
    render(h(AgentConversation, { messages: [] }), container)
    expect(container.textContent).toContain('대화 내용이 없습니다')
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
  })

  it('renders user message with data-message-id', () => {
    const container = document.createElement('div')
    render(h(AgentConversation, { messages }), container)
    expect(container.querySelector('[data-message-id="m1"]')).not.toBeNull()
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
    expect(container.querySelector('[role="feed"]')).not.toBeNull()
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
  })
})
