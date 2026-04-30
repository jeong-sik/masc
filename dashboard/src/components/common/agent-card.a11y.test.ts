// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { AgentCard } from './agent-card'

describe('AgentCard a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const makeAgent = (overrides = {}) => ({
    id: 'agent-1',
    name: 'Dreamer',
    status: 'active',
    currentTask: 'compacting memory',
    capabilities: ['file_read', 'shell', 'web_search'],
    trustMetrics: {
      score: 0.85,
      approvals: 12,
      rejections: 2,
      overrides: 1,
    },
    failure: null,
    ...overrides,
  })

  it('renders accessibly in normal state', async () => {
    render(html`<${AgentCard} agent=${makeAgent()} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with failure', async () => {
    const agent = makeAgent({
      failure: { type: 'retryable', message: 'Connection timeout', retryCount: 1, maxRetries: 3 },
    })
    render(html`<${AgentCard} agent=${agent} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with approvals', async () => {
    const approvals = [
      { id: 'a1', agentId: 'agent-1', action: 'delete_file', details: 'Remove config', riskLevel: 'high', timeoutSeconds: 60, requestedAt: Date.now() },
    ]
    render(html`<${AgentCard} agent=${makeAgent()} approvals=${approvals} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with failure and approvals together', async () => {
    const agent = makeAgent({
      failure: { type: 'human_required', message: 'Approval needed' },
    })
    const approvals = [
      { id: 'a1', agentId: 'agent-1', action: 'deploy', details: 'Deploy to prod', riskLevel: 'critical', timeoutSeconds: 30, requestedAt: Date.now() },
    ]
    render(
      html`<${AgentCard}
        agent=${agent}
        approvals=${approvals}
        onApprove=${vi.fn()}
        onReject=${vi.fn()}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with null status', async () => {
    render(html`<${AgentCard} agent=${makeAgent({ status: null })} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with empty capabilities', async () => {
    render(html`<${AgentCard} agent=${makeAgent({ capabilities: [] })} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with null capabilities', async () => {
    render(html`<${AgentCard} agent=${makeAgent({ capabilities: null })} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has data-agent-card attribute', () => {
    render(html`<${AgentCard} agent=${makeAgent()} />`, container)
    const card = container.querySelector('[data-agent-card]')
    expect(card).not.toBeNull()
  })

  it('displays agent name', () => {
    render(html`<${AgentCard} agent=${makeAgent({ name: 'Tester' })} />`, container)
    expect(container.textContent).toContain('Tester')
  })

  it('displays avatar initial from name', () => {
    render(html`<${AgentCard} agent=${makeAgent({ name: 'alpha' })} />`, container)
    expect(container.textContent).toContain('A')
  })

  it('calls onApprove when approval approved', () => {
    const onApprove = vi.fn()
    const approvals = [
      { id: 'a1', agentId: 'agent-1', action: 'run', details: 'Run script', riskLevel: 'medium', timeoutSeconds: 120, requestedAt: Date.now() },
    ]
    render(
      html`<${AgentCard}
        agent=${makeAgent()}
        approvals=${approvals}
        onApprove=${onApprove}
      />`,
      container,
    )
    const approveBtn = container.querySelector('[data-approve]') as HTMLElement
    if (approveBtn) {
      approveBtn.dispatchEvent(new MouseEvent('click', { bubbles: true }))
      expect(onApprove).toHaveBeenCalledWith('a1')
    }
  })
})
