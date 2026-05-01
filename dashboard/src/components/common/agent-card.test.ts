// @ts-nocheck
import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { AgentCard } from './agent-card'

const baseAgent = {
  id: 'a1',
  name: 'Alpha',
  status: 'active',
  currentTask: 'task-1',
  capabilities: ['file_read', 'shell'],
  trustMetrics: { score: 85, confidence: 0.9 },
}

describe('AgentCard', () => {
  it('renders article', () => {
    const container = document.createElement('div')
    render(h(AgentCard, { agent: baseAgent }), container)
    expect(container.querySelector('article')).not.toBeNull()
  })

  it('renders agent name', () => {
    const container = document.createElement('div')
    render(h(AgentCard, { agent: baseAgent }), container)
    expect(container.textContent).toContain('Alpha')
  })

  it('renders avatar initial', () => {
    const container = document.createElement('div')
    render(h(AgentCard, { agent: baseAgent }), container)
    expect(container.textContent).toContain('A')
  })

  it('renders capability badges', () => {
    const container = document.createElement('div')
    render(h(AgentCard, { agent: baseAgent }), container)
    expect(container.textContent).toContain('파일 읽기')
    expect(container.textContent).toContain('터미널')
  })

  it('renders failure when present', () => {
    const agent = {
      ...baseAgent,
      failure: { type: 'retryable' as const, message: 'oops', retryCount: 1, maxRetries: 3 },
    }
    const container = document.createElement('div')
    render(h(AgentCard, { agent }), container)
    expect(container.textContent).toContain('oops')
    expect(container.textContent).toContain('1/3')
  })

  it('does not render failure when absent', () => {
    const container = document.createElement('div')
    render(h(AgentCard, { agent: baseAgent }), container)
    expect(container.querySelector('[data-agent-failure]')).toBeNull()
  })

  it('renders approvals when present', () => {
    const approvals = [{ id: 'r1', action: 'approve?', details: 'desc', agentId: 'a1', riskLevel: 'medium' as const, timeoutSeconds: 60, requestedAt: Date.now() }]
    const container = document.createElement('div')
    render(h(AgentCard, { agent: baseAgent, approvals }), container)
    expect(container.textContent).toContain('승인 대기 (1)')
    expect(container.textContent).toContain('approve?')
  })

  it('does not render approvals when empty', () => {
    const container = document.createElement('div')
    render(h(AgentCard, { agent: baseAgent, approvals: [] }), container)
    expect(container.textContent).not.toContain('승인 대기')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(AgentCard, { agent: baseAgent, testId: 'card-1' }), container)
    expect(container.querySelector('[data-testid="card-1"]')).not.toBeNull()
  })

  it('calls onApprove on approve click', async () => {
    const onApprove = vi.fn()
    const approvals = [{ id: 'r1', action: 't', details: 'd', agentId: 'a1', riskLevel: 'low' as const, timeoutSeconds: 60, requestedAt: Date.now() }]
    const container = document.createElement('div')
    render(h(AgentCard, { agent: baseAgent, approvals, onApprove }), container)
    const btn = container.querySelector('button') as HTMLElement
    btn?.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(onApprove).toHaveBeenCalledWith('r1')
  })
})
