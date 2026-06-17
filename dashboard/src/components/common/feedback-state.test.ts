// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { h, render } from 'preact'
import { html } from 'htm/preact'
import {
  EmptyState,
  ErrorFatal,
  ErrorRecoverable,
  ErrorState,
  LoadingState,
  summarizeFeedbackState,
} from './feedback-state'

describe('summarizeFeedbackState', () => {
  it('normalizes boolean state flags', () => {
    expect(
      summarizeFeedbackState('empty', {
        compact: true,
        icon: 'IN',
        action: html`<button>act</button>`,
      }),
    ).toEqual({
      kind: 'empty',
      compact: true,
      hasIcon: true,
      hasAction: true,
      hasDetail: false,
    })
  })
})

describe('FeedbackState base primitives', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('publishes empty-state metadata', () => {
    render(
      html`<${EmptyState}
        icon="IN"
        message="No items"
        compact=${true}
        action=${html`<button>act</button>`}
      />`,
      container,
    )
    const state = container.querySelector('[data-feedback-state]')
    expect(state?.getAttribute('data-feedback-kind')).toBe('empty')
    expect(state?.getAttribute('data-feedback-compact')).toBe('true')
    expect(state?.getAttribute('data-feedback-has-icon')).toBe('true')
    expect(state?.getAttribute('data-feedback-has-action')).toBe('true')
  })

  it('publishes loading metadata and mono glyph', () => {
    render(html`<${LoadingState}>Loading<//>`, container)
    const state = container.querySelector('[data-feedback-state]')
    expect(state?.getAttribute('data-feedback-kind')).toBe('loading')
    expect(state?.getAttribute('data-feedback-has-icon')).toBe('true')
    expect(container.querySelector('[data-feedback-icon]')?.textContent).toContain('LD')
  })

  it('publishes error metadata and mono glyph', () => {
    render(html`<${ErrorState} message="bad" />`, container)
    const state = container.querySelector('[data-feedback-state]')
    expect(state?.getAttribute('data-feedback-kind')).toBe('error')
    expect(state?.getAttribute('data-feedback-has-icon')).toBe('true')
    expect(container.querySelector('[data-feedback-icon]')?.textContent).toContain('ER')
  })
})

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
    render(html`<${ErrorRecoverable} title="Runtime fallback exhausted" />`, container)
    const section = container.querySelector('section')!
    expect(section).toBeTruthy()
    expect(section.getAttribute('role')).toBe('alert')
    expect(section.textContent).toContain('Runtime fallback exhausted')
    expect(section.textContent).toContain('복구 가능')
    expect(section.getAttribute('data-feedback-kind')).toBe('recoverable')
    expect(section.getAttribute('data-feedback-has-action')).toBe('false')
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
    expect(
      container
        .querySelector('[data-feedback-state]')
        ?.getAttribute('data-feedback-has-detail'),
    ).toBe('true')
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
    expect(
      container
        .querySelector('[data-feedback-state]')
        ?.getAttribute('data-feedback-has-action'),
    ).toBe('true')
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
    expect(section.getAttribute('data-feedback-kind')).toBe('fatal')
    expect(section.getAttribute('data-feedback-has-action')).toBe('false')
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
    expect(
      container
        .querySelector('[data-feedback-state]')
        ?.getAttribute('data-feedback-has-detail'),
    ).toBe('true')
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
    expect(
      container
        .querySelector('[data-feedback-state]')
        ?.getAttribute('data-feedback-has-action'),
    ).toBe('true')
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

  it('uses the danger variant button (destructive outline)', () => {
    render(html`<${ErrorFatal} title="t" onReload=${() => {}} />`, container)
    const btn = container.querySelector('button')!
    // ActionButton variant=danger now renders as a destructive outline
    // (border-destructive/40, text-destructive, transparent bg with
    // hover tint) rather than a filled background.
    expect(btn.className).toContain('border-destructive/40')
    expect(btn.className).toContain('text-destructive')
    expect(btn.className).toContain('bg-transparent')
  })
})

// Folded in from the former empty-state.test.ts (which duplicated EmptyState
// coverage under a misleading filename + a @ts-nocheck pragma). These DOM-shape
// assertions complement the metadata coverage in 'FeedbackState base primitives'.
describe('EmptyState DOM', () => {
  it('renders with default props', () => {
    const container = document.createElement('div')
    render(h(EmptyState, {}), container)
    const el = container.querySelector('[role="status"]')
    expect(el).not.toBeNull()
  })

  it('renders message text', () => {
    const container = document.createElement('div')
    render(h(EmptyState, { message: 'No items found' }), container)
    expect(container.textContent).toContain('No items found')
  })

  it('renders icon when provided', () => {
    const container = document.createElement('div')
    render(h(EmptyState, { icon: '\u{1F50D}' }), container)
    expect(container.textContent).toContain('\u{1F50D}')
  })

  it('prefers children over message', () => {
    const container = document.createElement('div')
    render(
      h(EmptyState, { message: 'parent-msg' }, h('span', null, 'child-node')),
      container,
    )
    expect(container.textContent).toContain('child-node')
  })

  it('applies compact padding', () => {
    const container = document.createElement('div')
    render(h(EmptyState, { compact: true }), container)
    const el = container.querySelector('[role="status"]')
    expect(el?.classList.contains('py-4')).toBe(true)
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(EmptyState, { class: 'custom-empty' }), container)
    const el = container.querySelector('[role="status"]')
    expect(el?.classList.contains('custom-empty')).toBe(true)
  })

  it('renders action slot', () => {
    const container = document.createElement('div')
    render(h(EmptyState, { action: h('button', null, 'Retry') }), container)
    expect(container.textContent).toContain('Retry')
  })
})
