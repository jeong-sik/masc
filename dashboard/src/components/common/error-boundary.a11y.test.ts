// @vitest-environment happy-dom
//
// jest-axe coverage for ErrorBoundary. Two surfaces:
//   1. Happy path: children render unchanged → axe just verifies the
//      passthrough doesn't introduce wrapping issues.
//   2. Error path: a child throws on render → boundary catches and
//      shows the fatal/recoverable banner with retry (+reload for
//      fatal). axe verifies the banner's own a11y (heading hierarchy,
//      button labels, alert role).
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { ErrorBoundary } from './error-boundary'

function Boom(): unknown {
  throw new Error('boom')
}

describe('ErrorBoundary a11y', () => {
  let container: HTMLElement
  let errorSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    // Preact prints the caught error to console.error during render —
    // silence the noise so test output stays readable.
    errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    errorSpy.mockRestore()
  })

  it('happy path: children render passes axe', async () => {
    render(
      html`<${ErrorBoundary}>
        <button type="button" aria-label="ok">ok</button>
      <//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('error path with default fatal severity passes axe', async () => {
    render(
      html`<${ErrorBoundary} label="Test"><${Boom} /><//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('error path with recoverable severity passes axe', async () => {
    render(
      html`<${ErrorBoundary} label="Test" severity="recoverable">
        <${Boom} />
      <//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('custom fallback render passes axe when caller provides one', async () => {
    const fallback = (err: Error) =>
      html`<div role="alert" aria-live="assertive">
        <p>Custom: ${err.message}</p>
      </div>`
    render(
      html`<${ErrorBoundary} fallback=${fallback}>
        <${Boom} />
      <//>`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })
})
