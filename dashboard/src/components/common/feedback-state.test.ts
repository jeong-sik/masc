// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { ErrorRecoverable, ErrorFatal } from './feedback-state'

describe('ErrorRecoverable', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders a role=alert section with title text', () => {
    render(html`<${ErrorRecoverable} title="Cascade fallback exhausted" />`, container)
    const section = container.querySelector('section')!
    expect(section).toBeTruthy()
    expect(section.getAttribute('role')).toBe('alert')
    expect(section.textContent).toContain('Cascade fallback exhausted')
    expect(section.textContent).toContain('복구 가능')
  })

  it('renders detail line when provided', () => {
    render(
      html`<${ErrorRecoverable}
        title="provider:openai"
        detail="2 fallback hops, timed out at 12.4s"
      />`,
      container,
    )
    expect(container.textContent).toContain('2 fallback hops, timed out at 12.4s')
  })

  it('omits the retry button when onRetry is not supplied', () => {
    render(html`<${ErrorRecoverable} title="t" />`, container)
    expect(container.querySelector('button')).toBeNull()
  })

  it('renders a retry button that calls onRetry on click', () => {
    const onRetry = vi.fn()
    render(html`<${ErrorRecoverable} title="t" onRetry=${onRetry} />`, container)
    const btn = container.querySelector('button')!
    expect(btn).toBeTruthy()
    expect(btn.textContent).toContain('다시 시도')
    btn.click()
    expect(onRetry).toHaveBeenCalledTimes(1)
  })

  it('honors a custom retryLabel', () => {
    render(
      html`<${ErrorRecoverable}
        title="t"
        onRetry=${() => {}}
        retryLabel="재시도"
      />`,
      container,
    )
    expect(container.querySelector('button')!.textContent).toContain('재시도')
  })
})

describe('ErrorFatal', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders a role=alert section with title text', () => {
    render(html`<${ErrorFatal} title="Cockpit lost connection" />`, container)
    const section = container.querySelector('section')!
    expect(section.getAttribute('role')).toBe('alert')
    expect(section.textContent).toContain('Cockpit lost connection')
    expect(section.textContent).toContain('치명적')
  })

  it('renders detail line when provided', () => {
    render(
      html`<${ErrorFatal}
        title="WebSocket closed"
        detail="Reconnect attempts: 3/3 exhausted"
      />`,
      container,
    )
    expect(container.textContent).toContain('Reconnect attempts: 3/3 exhausted')
  })

  it('omits the reload button when onReload is not supplied', () => {
    render(html`<${ErrorFatal} title="t" />`, container)
    expect(container.querySelector('button')).toBeNull()
  })

  it('renders a reload button that calls onReload on click', () => {
    const onReload = vi.fn()
    render(html`<${ErrorFatal} title="t" onReload=${onReload} />`, container)
    const btn = container.querySelector('button')!
    expect(btn).toBeTruthy()
    expect(btn.textContent).toContain('다시 불러오기')
    btn.click()
    expect(onReload).toHaveBeenCalledTimes(1)
  })

  it('honors a custom reloadLabel', () => {
    render(
      html`<${ErrorFatal}
        title="t"
        onReload=${() => {}}
        reloadLabel="새로고침"
      />`,
      container,
    )
    expect(container.querySelector('button')!.textContent).toContain('새로고침')
  })

  it('uses the danger variant button (background tint)', () => {
    render(html`<${ErrorFatal} title="t" onReload=${() => {}} />`, container)
    const btn = container.querySelector('button')!
    // ActionButton danger variant uses the component-level alias
    // --button-danger-bg, which tokens.generated.ts resolves to
    // var(--bad-10). Asserting on the literal classname keeps the
    // test honest about what the component actually outputs (was
    // missed in the cycle-34 migration to component-level aliases,
    // commit c8011e3).
    expect(btn.className).toContain('bg-[var(--button-danger-bg)]')
  })
})
