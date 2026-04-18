import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ErrorBoundary } from './error-boundary'

void vi

function Boom() {
  throw new Error('boom')
}

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

describe('ErrorBoundary', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.restoreAllMocks()
  })

  it('renders the retry action with the shared card border token after a render error', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})

    expect(() => {
      render(html`<${ErrorBoundary} label="overview"><${Boom} /><//>`, container)
    }).not.toThrow()
    await flushUi()

    const button = container.querySelector('button')
    expect(button).not.toBeNull()
    expect(button?.className).toContain('border-[var(--card-border)]')
    expect(button?.className).not.toContain('card rounded-border')
  })

  it('renders children untouched when no error is thrown', async () => {
    render(
      html`<${ErrorBoundary} label="ok"><span data-testid="child">hi</span><//>`,
      container,
    )
    await flushUi()
    const child = container.querySelector('[data-testid="child"]')
    expect(child?.textContent).toBe('hi')
    expect(container.querySelector('button')).toBeNull()
  })

  it('calls onError with the thrown error and an info object', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const onError = vi.fn()

    render(
      html`<${ErrorBoundary} label="telemetry" onError=${onError}>
        <${Boom} />
      <//>`,
      container,
    )
    await flushUi()

    expect(onError).toHaveBeenCalledTimes(1)
    const firstCall = onError.mock.calls[0]
    if (!firstCall) throw new Error('onError not called')
    const [err, info] = firstCall
    expect(err).toBeInstanceOf(Error)
    expect((err as Error).message).toBe('boom')
    // info is an object (Preact passes { componentStack } when available,
    // but shape is best-effort across runtimes).
    expect(typeof info).toBe('object')
  })

  it('still calls the default console.error before onError (backwards-compatible log)', async () => {
    const consoleSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const onError = vi.fn()

    render(
      html`<${ErrorBoundary} label="ordered" onError=${onError}>
        <${Boom} />
      <//>`,
      container,
    )
    await flushUi()

    // Default log must always fire (backwards-compatibility guarantee).
    const loggedPrefix = consoleSpy.mock.calls.some(
      (args) =>
        typeof args[0] === 'string' && args[0].includes('[ErrorBoundary:ordered]'),
    )
    expect(loggedPrefix).toBe(true)
    expect(onError).toHaveBeenCalled()
  })

  it('renders a custom fallback instead of the default card when provided', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const fallback = (err: Error) =>
      html`<div data-testid="custom-fallback">custom: ${err.message}</div>`

    render(
      html`<${ErrorBoundary} label="custom" fallback=${fallback}>
        <${Boom} />
      <//>`,
      container,
    )
    await flushUi()

    const custom = container.querySelector('[data-testid="custom-fallback"]')
    expect(custom?.textContent).toBe('custom: boom')
    // Default card must NOT render when a fallback is supplied.
    expect(container.querySelector('.error-card')).toBeNull()
  })

  it('fallback receives a reset callback that clears the error', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const captured: { reset: (() => void) | null } = { reset: null }

    const fallback = (err: Error, reset: () => void): unknown => {
      captured.reset = reset
      return html`<div data-testid="fb">err:${err.message}</div>`
    }

    function Child({ shouldThrow }: { shouldThrow: boolean }) {
      if (shouldThrow) throw new Error('boom')
      return html`<span data-testid="ok">ok</span>`
    }

    // First render: throws -> fallback shown.
    render(
      html`<${ErrorBoundary} label="reset" fallback=${fallback}>
        <${Child} shouldThrow=${true} />
      <//>`,
      container,
    )
    await flushUi()
    expect(container.querySelector('[data-testid="fb"]')).not.toBeNull()
    expect(typeof captured.reset).toBe('function')

    // Re-render with non-throwing child, then call reset.
    render(
      html`<${ErrorBoundary} label="reset" fallback=${fallback}>
        <${Child} shouldThrow=${false} />
      <//>`,
      container,
    )
    await flushUi()

    captured.reset?.()
    await flushUi()

    // After reset, child renders normally.
    expect(container.querySelector('[data-testid="ok"]')?.textContent).toBe('ok')
    expect(container.querySelector('[data-testid="fb"]')).toBeNull()
  })
})
