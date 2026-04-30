import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { AgentFailure, failureConfig, failureTypeFromDiagnostic } from './agent-failure'

describe('failureConfig', () => {
  it('returns config for retryable', () => {
    const cfg = failureConfig('retryable')
    expect(cfg.label).toBe('재시도 가능')
    expect(cfg.action).toContain('재시도')
  })

  it('returns config for non_retryable', () => {
    const cfg = failureConfig('non_retryable')
    expect(cfg.label).toBe('재시도 불가')
  })

  it('returns config for human_required', () => {
    const cfg = failureConfig('human_required')
    expect(cfg.label).toBe('승인 필요')
  })

  it('returns config for degraded', () => {
    const cfg = failureConfig('degraded')
    expect(cfg.label).toBe('성능 저하')
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

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(AgentFailure, { type: 'degraded', message: 'x', testId: 'af-1' }), container)
    expect(container.querySelector('[data-testid="af-1"]')).not.toBeNull()
  })
})
