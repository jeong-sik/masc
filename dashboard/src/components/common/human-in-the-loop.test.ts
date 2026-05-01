import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { HumanInTheLoop } from './human-in-the-loop'

const baseRequest = {
  id: 'r1',
  agentId: 'agent-alpha-123',
  action: 'approve deployment',
  details: 'deploy to prod',
  riskLevel: 'medium' as const,
  timeoutSeconds: 60,
  requestedAt: Date.now(),
}

describe('HumanInTheLoop', () => {
  it('renders alertdialog role', () => {
    const container = document.createElement('div')
    render(h(HumanInTheLoop, { request: baseRequest, onApprove: vi.fn(), onReject: vi.fn(), onModify: vi.fn() }), container)
    expect(container.querySelector('[role="alertdialog"]')).not.toBeNull()
  })

  it('renders action text', () => {
    const container = document.createElement('div')
    render(h(HumanInTheLoop, { request: baseRequest, onApprove: vi.fn(), onReject: vi.fn(), onModify: vi.fn() }), container)
    expect(container.textContent).toContain('approve deployment')
  })

  it('renders details text', () => {
    const container = document.createElement('div')
    render(h(HumanInTheLoop, { request: baseRequest, onApprove: vi.fn(), onReject: vi.fn(), onModify: vi.fn() }), container)
    expect(container.textContent).toContain('deploy to prod')
  })

  it('renders risk label', () => {
    const container = document.createElement('div')
    render(h(HumanInTheLoop, { request: baseRequest, onApprove: vi.fn(), onReject: vi.fn(), onModify: vi.fn() }), container)
    expect(container.textContent).toContain('중간 위험')
  })

  it('renders timer', () => {
    const container = document.createElement('div')
    render(h(HumanInTheLoop, { request: baseRequest, onApprove: vi.fn(), onReject: vi.fn(), onModify: vi.fn() }), container)
    expect(container.textContent).toContain('1:00')
  })

  it('calls onApprove when approve clicked', () => {
    const onApprove = vi.fn()
    const container = document.createElement('div')
    render(h(HumanInTheLoop, { request: baseRequest, onApprove, onReject: vi.fn(), onModify: vi.fn() }), container)
    const btn = container.querySelector('button') as HTMLElement
    btn.click()
    expect(onApprove).toHaveBeenCalledWith('r1')
  })

  it('calls onReject when reject clicked', () => {
    const onReject = vi.fn()
    const container = document.createElement('div')
    render(h(HumanInTheLoop, { request: baseRequest, onApprove: vi.fn(), onReject, onModify: vi.fn() }), container)
    const buttons = container.querySelectorAll('button')
    buttons[1]?.click()
    expect(onReject).toHaveBeenCalledWith('r1')
  })

  it('toggles modify mode', async () => {
    const container = document.createElement('div')
    render(h(HumanInTheLoop, { request: baseRequest, onApprove: vi.fn(), onReject: vi.fn(), onModify: vi.fn() }), container)
    const buttons = container.querySelectorAll('button')
    const modifyBtn = buttons[2] as HTMLElement
    modifyBtn.click()
    await new Promise((r) => setTimeout(r, 0))
    expect(container.querySelector('textarea')).not.toBeNull()
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(HumanInTheLoop, { request: baseRequest, onApprove: vi.fn(), onReject: vi.fn(), onModify: vi.fn(), testId: 'hitl-1' }), container)
    expect(container.querySelector('[data-testid="hitl-1"]')).not.toBeNull()
  })

  it('renders low risk label', () => {
    const container = document.createElement('div')
    const req = { ...baseRequest, riskLevel: 'low' as const }
    render(h(HumanInTheLoop, { request: req, onApprove: vi.fn(), onReject: vi.fn(), onModify: vi.fn() }), container)
    expect(container.textContent).toContain('낮은 위험')
  })

  it('renders critical risk label', () => {
    const container = document.createElement('div')
    const req = { ...baseRequest, riskLevel: 'critical' as const }
    render(h(HumanInTheLoop, { request: req, onApprove: vi.fn(), onReject: vi.fn(), onModify: vi.fn() }), container)
    expect(container.textContent).toContain('심각한 위험')
  })
})
