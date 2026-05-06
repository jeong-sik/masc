// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { FailureHistory } from './failure-history'

describe('FailureHistory a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const failures = [
    {
      id: 'f1',
      agentId: 'agent-abc-123',
      errorType: 'network',
      message: 'Connection reset by peer',
      timestamp: Date.now() - 60000,
      retryable: true,
      resolved: false,
    },
    {
      id: 'f2',
      agentId: 'agent-def-456',
      errorType: 'timeout',
      message: 'Request timed out after 30s',
      timestamp: Date.now() - 120000,
      retryable: false,
      resolved: false,
    },
    {
      id: 'f3',
      agentId: 'agent-ghi-789',
      errorType: 'auth',
      message: 'Token expired',
      timestamp: Date.now() - 180000,
      retryable: true,
      resolved: true,
    },
  ]

  it('renders accessibly', async () => {
    render(html`<${FailureHistory} failures=${failures} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has role=region with aria-label', () => {
    render(html`<${FailureHistory} failures=${failures} />`, container)
    const region = container.querySelector('[role="region"]')
    expect(region).not.toBeNull()
    expect(region?.getAttribute('aria-label')).toBe('실패 이력')
  })

  it('renders list items for each failure', () => {
    render(html`<${FailureHistory} failures=${failures} />`, container)
    const items = container.querySelectorAll('[role="listitem"]')
    expect(items.length).toBe(3)
  })

  it('renders failure messages', () => {
    render(html`<${FailureHistory} failures=${failures} />`, container)
    expect(container.textContent).toContain('Connection reset by peer')
    expect(container.textContent).toContain('Request timed out after 30s')
    expect(container.textContent).toContain('Token expired')
  })

  it('shows resolved count', () => {
    render(html`<${FailureHistory} failures=${failures} />`, container)
    expect(container.textContent).toContain('1/3 해결')
  })

  it('shows top error type tags', () => {
    render(html`<${FailureHistory} failures=${failures} />`, container)
    expect(container.textContent).toContain('network')
    expect(container.textContent).toContain('timeout')
    expect(container.textContent).toContain('auth')
  })

  it('shows retry button for retryable unresolved failures', () => {
    const onRetry = vi.fn()
    render(html`<${FailureHistory} failures=${failures} onRetry=${onRetry} />`, container)
    const buttons = Array.from(container.querySelectorAll('button'))
    const texts = buttons.map((b) => b.textContent)
    expect(texts).toContain('재시도')
  })

  it('calls onRetry when retry button clicked', async () => {
    const onRetry = vi.fn()
    render(html`<${FailureHistory} failures=${failures} onRetry=${onRetry} />`, container)
    const retryBtn = Array.from(container.querySelectorAll('button')).find(
      (b) => b.textContent?.trim() === '재시도',
    ) as HTMLButtonElement
    retryBtn.click()
    await act(async () => {
      await new Promise((r) => setTimeout(r, 0))
    })
    expect(onRetry).toHaveBeenCalledWith('f1')
  })

  it('shows dismiss button when onDismiss provided', () => {
    const onDismiss = vi.fn()
    render(html`<${FailureHistory} failures=${failures} onDismiss=${onDismiss} />`, container)
    const buttons = Array.from(container.querySelectorAll('button'))
    const texts = buttons.map((b) => b.textContent)
    expect(texts).toContain('해제')
  })

  it('calls onDismiss when dismiss button clicked', async () => {
    const onDismiss = vi.fn()
    render(html`<${FailureHistory} failures=${failures} onDismiss=${onDismiss} />`, container)
    const dismissBtn = Array.from(container.querySelectorAll('button')).find(
      (b) => b.textContent?.trim() === '해제',
    ) as HTMLButtonElement
    dismissBtn.click()
    await act(async () => {
      await new Promise((r) => setTimeout(r, 0))
    })
    expect(onDismiss).toHaveBeenCalledWith('f1')
  })

  it('shows bulk retry button when retryable unresolved exist', () => {
    const onRetry = vi.fn()
    render(html`<${FailureHistory} failures=${failures} onRetry=${onRetry} />`, container)
    expect(container.textContent).toContain('일괄 재시도')
  })

  it('hides bulk retry when no retryable unresolved', () => {
    const allResolved = failures.map((f) => ({ ...f, resolved: true }))
    render(html`<${FailureHistory} failures=${allResolved} onRetry=${vi.fn()} />`, container)
    expect(container.textContent).not.toContain('일괄 재시도')
  })

  it('renders empty state gracefully', async () => {
    render(html`<${FailureHistory} failures=${[]} />`, container)
    expect(container.querySelectorAll('[role="listitem"]').length).toBe(1)
    expect(container.querySelector('[data-failure-history-empty]')).not.toBeNull()
    expect(await axe(container)).toHaveNoViolations()
  })
})
