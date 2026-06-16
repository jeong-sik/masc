// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { LoadingBar, summarizeLoadingBar } from './loading-bar'

describe('summarizeLoadingBar (pure)', () => {
  it('summarizes the default decorative state', () => {
    expect(summarizeLoadingBar({})).toEqual({
      isIndeterminate: true,
      hasSemanticLabel: false,
      hasTestId: false,
      ariaLabelLength: 0,
      testIdLength: 0,
    })
  })

  it('summarizes semantic + testId state', () => {
    expect(
      summarizeLoadingBar({ ariaLabel: '  Saving…  ', testId: 'save-bar' }),
    ).toEqual({
      isIndeterminate: true,
      hasSemanticLabel: true,
      hasTestId: true,
      ariaLabelLength: 7,
      testIdLength: 8,
    })
  })
})

describe('LoadingBar component', () => {
  let container: HTMLElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders the .loading-bar primitive with indeterminate marker', () => {
    render(html`<${LoadingBar} />`, container)
    const bar = container.querySelector('[data-loading-bar]') as HTMLElement
    expect(bar).not.toBeNull()
    expect(bar.classList.contains('loading-bar')).toBe(true)
    expect(bar.getAttribute('data-loading-bar-indeterminate')).toBe('true')
    expect(bar.getAttribute('data-loading-bar-has-semantic-label')).toBe('false')
    expect(bar.getAttribute('data-loading-bar-has-test-id')).toBe('false')
  })

  it('is decorative by default (aria-hidden, no role)', () => {
    render(html`<${LoadingBar} />`, container)
    const bar = container.querySelector('[data-loading-bar]') as HTMLElement
    expect(bar.getAttribute('aria-hidden')).toBe('true')
    expect(bar.getAttribute('role')).toBeNull()
  })

  it('ariaLabel promotes to semantic: role=status + aria-label', () => {
    render(html`<${LoadingBar} ariaLabel="Loading metrics" />`, container)
    const bar = container.querySelector('[data-loading-bar]') as HTMLElement
    expect(bar.getAttribute('role')).toBe('status')
    expect(bar.getAttribute('aria-label')).toBe('Loading metrics')
    expect(bar.getAttribute('aria-hidden')).toBeNull()
    expect(bar.getAttribute('data-loading-bar-has-semantic-label')).toBe('true')
    expect(bar.getAttribute('data-loading-bar-aria-label-length')).toBe('15')
  })

  it('blank ariaLabel stays decorative', () => {
    render(html`<${LoadingBar} ariaLabel="   " />`, container)
    const bar = container.querySelector('[data-loading-bar]') as HTMLElement
    expect(bar.getAttribute('role')).toBeNull()
    expect(bar.getAttribute('aria-hidden')).toBe('true')
    expect(bar.getAttribute('data-loading-bar-has-semantic-label')).toBe('false')
  })

  it('testId renders as data-testid', () => {
    render(html`<${LoadingBar} testId="stream-bar" />`, container)
    const bar = container.querySelector('[data-testid="stream-bar"]')!
    expect(bar).not.toBeNull()
    expect(bar.getAttribute('data-loading-bar-has-test-id')).toBe('true')
    expect(bar.getAttribute('data-loading-bar-test-id-length')).toBe('10')
  })
})
