import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  AgentFailure,
  failureConfig,
  failureTypeFromDiagnostic,
  summarizeAgentFailure,
  summarizeRetryBudget,
} from './agent-failure'

describe('failureConfig', () => {
  it('returns config for retryable', () => {
    const cfg = failureConfig('retryable')
    expect(cfg.label).toBe('재시도 가능')
    expect(cfg.action).toContain('재시도')
    expect(cfg.colorVar).toBe('var(--color-status-warn)')
  })

  it('returns config for non_retryable', () => {
    const cfg = failureConfig('non_retryable')
    expect(cfg.label).toBe('재시도 불가')
    expect(cfg.colorVar).toBe('var(--color-status-err)')
  })

  it('returns config for human_required', () => {
    const cfg = failureConfig('human_required')
    expect(cfg.label).toBe('승인 필요')
    expect(cfg.colorVar).toBe('var(--color-accent-fg)')
  })

  it('returns config for degraded', () => {
    const cfg = failureConfig('degraded')
    expect(cfg.label).toBe('성능 저하')
  })
})

describe('summarizeRetryBudget', () => {
  it('summarizes retry budget', () => {
    expect(summarizeRetryBudget(2, 5)).toEqual({
      current: 2,
      max: 5,
      remaining: 3,
      percent: 40,
      exhausted: false,
      visible: true,
    })
  })

  it('hides invalid or empty retry budgets', () => {
    expect(summarizeRetryBudget(undefined, 3).visible).toBe(false)
    expect(summarizeRetryBudget(1, 0).visible).toBe(false)
  })

  it('detects exhausted retry budget', () => {
    const budget = summarizeRetryBudget(7, 5)
    expect(budget.current).toBe(7)
    expect(budget.remaining).toBe(0)
    expect(budget.percent).toBe(100)
    expect(budget.exhausted).toBe(true)
  })
})

describe('summarizeAgentFailure', () => {
  it('reports retrying and exhausted retry statuses', () => {
    expect(summarizeAgentFailure('retryable', 1, 3).status).toBe('retrying')
    expect(summarizeAgentFailure('retryable', 3, 3).status).toBe('retry_exhausted')
  })

  it('reports non-retryable, human, and degraded statuses', () => {
    expect(summarizeAgentFailure('non_retryable').status).toBe('blocked')
    expect(summarizeAgentFailure('human_required').status).toBe('waiting_for_human')
    expect(summarizeAgentFailure('degraded').status).toBe('degraded')
  })
})

describe('failureTypeFromDiagnostic', () => {
  it('returns degraded when no error', () => {
    expect(failureTypeFromDiagnostic(null, true)).toBe('degraded')
  })

  it('returns retryable when recoverable', () => {
    expect(failureTypeFromDiagnostic('err', true)).toBe('retryable')
  })

  it('returns non_retryable when not recoverable', () => {
    expect(failureTypeFromDiagnostic('err', false)).toBe('non_retryable')
  })

  it('defaults to non_retryable when recoverable undefined', () => {
    expect(failureTypeFromDiagnostic('err', undefined)).toBe('non_retryable')
  })
})

describe('AgentFailure', () => {
  it('renders role alert', () => {
    const container = document.createElement('div')
    render(h(AgentFailure, { type: 'retryable', message: 'oops' }), container)
    expect(container.querySelector('[role="alert"]')).not.toBeNull()
  })

  it('renders message', () => {
    const container = document.createElement('div')
    render(h(AgentFailure, { type: 'non_retryable', message: 'failed' }), container)
    expect(container.textContent).toContain('failed')
  })

  it('renders retry count', () => {
    const container = document.createElement('div')
    render(h(AgentFailure, { type: 'retryable', message: 'x', retryCount: 2, maxRetries: 5 }), container)
    expect(container.textContent).toContain('2/5')
  })

  it('hides retry count when maxRetries is 0', () => {
    const container = document.createElement('div')
    render(h(AgentFailure, { type: 'retryable', message: 'x', retryCount: 1, maxRetries: 0 }), container)
    expect(container.textContent).not.toContain('1/0')
  })

  it('sets data-failure-type', () => {
    const container = document.createElement('div')
    render(h(AgentFailure, { type: 'human_required', message: 'x' }), container)
    const el = container.querySelector('[data-failure-type]')
    expect(el?.getAttribute('data-failure-type')).toBe('human_required')
  })

  it('exposes summary data attributes', () => {
    const container = document.createElement('div')
    render(h(AgentFailure, { type: 'retryable', message: 'x', retryCount: 2, maxRetries: 5 }), container)
    const root = container.querySelector('[data-agent-failure]') as HTMLElement
    expect(root.dataset.agentFailureStatus).toBe('retrying')
    expect(root.dataset.agentFailureLabel).toBe('재시도 가능')
    expect(root.dataset.agentFailureAction).toBe('자동 재시도 중...')
    expect(root.dataset.agentFailureRetryCurrent).toBe('2')
    expect(root.dataset.agentFailureRetryMax).toBe('5')
    expect(root.dataset.agentFailureRetryRemaining).toBe('3')
    expect(root.dataset.agentFailureRetryPercent).toBe('40')
    expect(root.dataset.agentFailureRetryExhausted).toBe('false')
    expect(root.dataset.agentFailureRetryVisible).toBe('true')
  })

  it('exposes exhausted retry status', () => {
    const container = document.createElement('div')
    render(h(AgentFailure, { type: 'retryable', message: 'x', retryCount: 5, maxRetries: 5 }), container)
    const root = container.querySelector('[data-agent-failure]') as HTMLElement
    expect(root.dataset.agentFailureStatus).toBe('retry_exhausted')
    expect(root.dataset.agentFailureRetryExhausted).toBe('true')
  })

  it('uses semantic aria label fallback for empty message', () => {
    const container = document.createElement('div')
    render(h(AgentFailure, { type: 'degraded', message: '' }), container)
    expect(container.querySelector('[role="alert"]')?.getAttribute('aria-label')).toContain('상세 메시지 없음')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(AgentFailure, { type: 'degraded', message: 'x', testId: 'af-1' }), container)
    expect(container.querySelector('[data-testid="af-1"]')).not.toBeNull()
  })
})
