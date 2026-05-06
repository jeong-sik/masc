import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  formatCountdown,
  HumanInTheLoop,
  riskConfig,
  summarizeHumanInTheLoop,
} from './human-in-the-loop'

const baseRequest = {
  id: 'r1',
  agentId: 'agent-alpha-123',
  action: 'approve deployment',
  details: 'deploy to prod',
  riskLevel: 'medium' as const,
  timeoutSeconds: 60,
  requestedAt: Date.now(),
}

describe('riskConfig', () => {
  it('uses semantic status tokens for each risk level', () => {
    expect(riskConfig('low').border).toContain('var(--color-status-ok)')
    expect(riskConfig('medium').bg).toContain('var(--color-status-warn)')
    expect(riskConfig('high').border).toContain('var(--color-status-err)')
    expect(riskConfig('critical').bg).toContain('var(--color-status-err)')
  })
})

describe('formatCountdown', () => {
  it('formats seconds as m:ss and clamps below zero', () => {
    expect(formatCountdown(125)).toBe('2:05')
    expect(formatCountdown(0)).toBe('0:00')
    expect(formatCountdown(-1)).toBe('0:00')
  })
})

describe('summarizeHumanInTheLoop', () => {
  it('summarizes request metadata and countdown state', () => {
    expect(summarizeHumanInTheLoop(baseRequest, 59)).toEqual({
      requestId: 'r1',
      agentId: 'agent-alpha-123',
      agentShort: 'agent-al',
      riskLevel: 'medium',
      riskLabel: '중간 위험',
      isCritical: false,
      timeoutSeconds: 60,
      remainingSeconds: 59,
      countdown: '0:59',
      expired: false,
      actionLength: 'approve deployment'.length,
      detailsLength: 'deploy to prod'.length,
      hasDetails: true,
    })
  })

  it('summarizes expired critical requests', () => {
    const summary = summarizeHumanInTheLoop({ ...baseRequest, riskLevel: 'critical' }, 0)
    expect(summary.isCritical).toBe(true)
    expect(summary.expired).toBe(true)
    expect(summary.countdown).toBe('0:00')
    expect(summary.riskLabel).toBe('심각한 위험')
  })
})

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

  it('exposes summary metadata on the root', () => {
    const container = document.createElement('div')
    render(h(HumanInTheLoop, { request: baseRequest, onApprove: vi.fn(), onReject: vi.fn(), onModify: vi.fn() }), container)
    const el = container.querySelector('[data-human-in-the-loop]') as HTMLElement
    expect(el.dataset.approvalId).toBe('r1')
    expect(el.dataset.approvalAgentId).toBe('agent-alpha-123')
    expect(el.dataset.approvalAgentShort).toBe('agent-al')
    expect(el.dataset.approvalRiskLevel).toBe('medium')
    expect(el.dataset.approvalRiskLabel).toBe('중간 위험')
    expect(el.dataset.approvalCritical).toBe('false')
    expect(el.dataset.approvalTimeoutSeconds).toBe('60')
    expect(el.dataset.approvalRemainingSeconds).toBe('60')
    expect(el.dataset.approvalCountdown).toBe('1:00')
    expect(el.dataset.approvalExpired).toBe('false')
    expect(el.dataset.approvalModifying).toBe('false')
    expect(el.dataset.approvalHasDetails).toBe('true')
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
    const el = container.querySelector('[data-human-in-the-loop]') as HTMLElement
    expect(el.dataset.approvalModifying).toBe('true')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(HumanInTheLoop, { request: baseRequest, onApprove: vi.fn(), onReject: vi.fn(), onModify: vi.fn(), testId: 'hitl-1' }), container)
    expect(container.querySelector('[data-testid="hitl-1"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="hitl-1-timer"]')).not.toBeNull()
  })

  it('omits timer testId when testId is absent', () => {
    const container = document.createElement('div')
    render(h(HumanInTheLoop, { request: baseRequest, onApprove: vi.fn(), onReject: vi.fn(), onModify: vi.fn() }), container)
    expect(container.querySelector('[data-testid="undefined"]')).toBeNull()
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
