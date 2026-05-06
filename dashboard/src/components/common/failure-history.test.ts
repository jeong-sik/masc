import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  FailureHistory,
  failureEntryStatus,
  summarizeFailureHistory,
} from './failure-history'
import type { FailureEntry } from './failure-history'

const now = new Date('2026-05-06T00:00:00Z').getTime()
const retryableFailure: FailureEntry = {
  id: 'f1',
  agentId: 'agent-alpha-123',
  errorType: 'network',
  message: 'conn reset',
  timestamp: now,
  retryable: true,
  resolved: false,
}
const baseFailures: FailureEntry[] = [
  retryableFailure,
  { id: 'f2', agentId: 'agent-beta-456', errorType: 'timeout', message: 'timed out', timestamp: now - 60000, retryable: false, resolved: true },
  { id: 'f3', agentId: 'agent-gamma-789', errorType: 'network', message: 'dns fail', timestamp: now - 120000, retryable: true, resolved: false },
]

describe('failureEntryStatus', () => {
  it('reports resolved before retryability', () => {
    expect(failureEntryStatus({ ...retryableFailure, resolved: true })).toBe('resolved')
  })

  it('reports retryable unresolved failures as retryable', () => {
    expect(failureEntryStatus(retryableFailure)).toBe('retryable')
  })

  it('reports non-retryable unresolved failures as blocked', () => {
    expect(failureEntryStatus({ ...retryableFailure, retryable: false })).toBe('blocked')
  })
})

describe('summarizeFailureHistory', () => {
  it('summarizes counts, status, latest timestamp, and top types', () => {
    const summary = summarizeFailureHistory(baseFailures)
    expect(summary.totalCount).toBe(3)
    expect(summary.resolvedCount).toBe(1)
    expect(summary.unresolvedCount).toBe(2)
    expect(summary.retryableCount).toBe(2)
    expect(summary.blockedCount).toBe(0)
    expect(summary.typeCount).toBe(2)
    expect(summary.latestTimestamp).toBe(now)
    expect(summary.status).toBe('actionable')
    expect(summary.topTypes[0]).toMatchObject({
      errorType: 'network',
      count: 2,
      retryableCount: 2,
    })
  })

  it('marks empty, all-resolved, and blocked-only histories', () => {
    expect(summarizeFailureHistory([]).status).toBe('empty')
    expect(summarizeFailureHistory(baseFailures.map((f) => ({ ...f, resolved: true }))).status).toBe('resolved')
    expect(summarizeFailureHistory([{ ...retryableFailure, retryable: false }]).status).toBe('blocked')
  })

  it('limits top error types', () => {
    const summary = summarizeFailureHistory(baseFailures, 1)
    expect(summary.topTypes.map((type) => type.errorType)).toEqual(['network'])
  })
})

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
    expect(container.textContent).toContain('미해결')
    expect(container.textContent).toContain('재시도')
  })

  it('exposes summary data attributes', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: baseFailures }), container)
    const root = container.querySelector('[data-failure-history]') as HTMLElement
    expect(root.dataset.failureHistoryTotalCount).toBe('3')
    expect(root.dataset.failureHistoryResolvedCount).toBe('1')
    expect(root.dataset.failureHistoryUnresolvedCount).toBe('2')
    expect(root.dataset.failureHistoryRetryableCount).toBe('2')
    expect(root.dataset.failureHistoryBlockedCount).toBe('0')
    expect(root.dataset.failureHistoryTypeCount).toBe('2')
    expect(root.dataset.failureHistoryLatestTimestamp).toBe(String(now))
    expect(root.dataset.failureHistoryTopErrorType).toBe('network')
    expect(root.dataset.failureHistoryTopErrorCount).toBe('2')
    expect(root.dataset.failureHistoryStatus).toBe('actionable')
  })

  it('renders top error types', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: baseFailures }), container)
    expect(container.textContent).toContain('network')
  })

  it('exposes top error type metadata', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: baseFailures }), container)
    const network = container.querySelector('[data-failure-history-type="network"]') as HTMLElement
    expect(network.dataset.failureHistoryTypeCount).toBe('2')
    expect(network.dataset.failureHistoryTypeResolvedCount).toBe('0')
    expect(network.dataset.failureHistoryTypeRetryableCount).toBe('2')
    expect(network.dataset.failureHistoryTypeLatestTimestamp).toBe(String(now))
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

  it('exposes row metadata', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: baseFailures }), container)
    const row = container.querySelector('[data-failure-id="f1"]') as HTMLElement
    expect(row.dataset.failureAgentId).toBe('agent-alpha-123')
    expect(row.dataset.failureErrorType).toBe('network')
    expect(row.dataset.failureTimestamp).toBe(String(now))
    expect(row.dataset.failureRetryable).toBe('true')
    expect(row.dataset.failureResolved).toBe('false')
    expect(row.dataset.failureStatus).toBe('retryable')
    expect(row.querySelector('time')?.getAttribute('datetime')).toBe(new Date(now).toISOString())
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

  it('renders an empty list row with empty summary status', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: [] }), container)
    const root = container.querySelector('[data-failure-history]') as HTMLElement
    expect(root.dataset.failureHistoryStatus).toBe('empty')
    expect(root.dataset.failureHistoryTopErrorType).toBe('')
    expect(container.querySelector('[data-failure-history-empty]')).not.toBeNull()
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(1)
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(FailureHistory, { failures: [], testId: 'fh-1' }), container)
    expect(container.querySelector('[data-testid="fh-1"]')).not.toBeNull()
  })
})
