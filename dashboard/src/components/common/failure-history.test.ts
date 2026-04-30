import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { FailureHistory } from './failure-history'

const baseFailures = [
  { id: 'f1', agentId: 'agent-alpha-123', errorType: 'network', message: 'conn reset', timestamp: Date.now(), retryable: true, resolved: false },
  { id: 'f2', agentId: 'agent-beta-456', errorType: 'timeout', message: 'timed out', timestamp: Date.now() - 60000, retryable: false, resolved: true },
  { id: 'f3', agentId: 'agent-gamma-789', errorType: 'network', message: 'dns fail', timestamp: Date.now() - 120000, retryable: true, resolved: false },
]

describe('FailureHistory', () => {
  it('renders container', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: [] }), container)
    expect(container.querySelector('[data-failure-history]')).not.toBeNull()
  })

  it('renders region role', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: [] }), container)
    expect(container.querySelector('[role="region"]')).not.toBeNull()
  })

  it('renders title', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: [] }), container)
    expect(container.textContent).toContain('실패 이력')
  })

  it('renders stats', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: baseFailures }), container)
    expect(container.textContent).toContain('1/3 해결')
  })

  it('renders top error types', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: baseFailures }), container)
    expect(container.textContent).toContain('network')
  })

  it('renders failure entries', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: baseFailures }), container)
    expect(container.textContent).toContain('conn reset')
    expect(container.textContent).toContain('timed out')
  })

  it('renders listitems', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: baseFailures }), container)
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(3)
  })

  it('renders data-failure-id', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: baseFailures }), container)
    expect(container.querySelector('[data-failure-id="f1"]')).not.toBeNull()
  })

  it('renders resolved with line-through', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: baseFailures }), container)
    const resolved = container.querySelector('[data-failure-id="f2"]') as HTMLElement
    expect(resolved?.classList.contains('line-through') || resolved?.querySelector('.line-through')).toBeTruthy()
  })

  it('renders retry button for retryable unresolved', () => {
    const container = document.createElement('div')
    const onRetry = vi.fn()
    render(h(FailureHistory, { failures: baseFailures, onRetry }), container)
    const item = container.querySelector('[data-failure-id="f1"]') as HTMLElement
    expect(item?.textContent).toContain('재시도')
  })

  it('calls onRetry when retry clicked', () => {
    const onRetry = vi.fn()
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: baseFailures, onRetry }), container)
    const btn = container.querySelector('[aria-label*="재시도"]') as HTMLElement
    btn?.click()
    expect(onRetry).toHaveBeenCalledWith('f1')
  })

  it('calls onDismiss when dismiss clicked', () => {
    const onDismiss = vi.fn()
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: baseFailures, onDismiss }), container)
    const btn = container.querySelector('[aria-label*="해제"]') as HTMLElement
    btn?.click()
    expect(onDismiss).toHaveBeenCalledWith('f1')
  })

  it('renders bulk retry button', () => {
    const container = document.createElement('div')
    const onRetry = vi.fn()
    render(h(FailureHistory, { failures: baseFailures, onRetry }), container)
    expect(container.textContent).toContain('일괄 재시도')
  })

  it('calls onRetry for all retryable on bulk retry', () => {
    const onRetry = vi.fn()
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: baseFailures, onRetry }), container)
    const btn = Array.from(container.querySelectorAll('button')).find(b => b.textContent?.includes('일괄'))
    btn?.click()
    expect(onRetry).toHaveBeenCalledTimes(2)
    expect(onRetry).toHaveBeenCalledWith('f1')
    expect(onRetry).toHaveBeenCalledWith('f3')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: [], testId: 'fh-1' }), container)
    expect(container.querySelector('[data-testid="fh-1"]')).not.toBeNull()
  })
})
