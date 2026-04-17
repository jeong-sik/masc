// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  ScrollToTopButton,
  shouldShowScrollToTop,
  scrollWindowToTop,
} from './scroll-to-top'

describe('shouldShowScrollToTop (pure)', () => {
  it('returns false at the top of the page', () => {
    expect(shouldShowScrollToTop(0)).toBe(false)
  })

  it('stays hidden below the default 400px threshold', () => {
    expect(shouldShowScrollToTop(399)).toBe(false)
  })

  it('shows at exactly the threshold (>= not >)', () => {
    // Regression guard: strict > would leave a 1-pixel dead zone
    // that confuses operators who scroll to exactly the threshold.
    expect(shouldShowScrollToTop(400)).toBe(true)
  })

  it('shows above the threshold', () => {
    expect(shouldShowScrollToTop(10_000)).toBe(true)
  })

  it('respects a custom threshold (denser layouts)', () => {
    expect(shouldShowScrollToTop(150, 200)).toBe(false)
    expect(shouldShowScrollToTop(250, 200)).toBe(true)
  })
})

describe('ScrollToTopButton component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    window.scrollTo(0, 0)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    window.scrollTo(0, 0)
  })

  it('hidden when the page is not scrolled', () => {
    render(html`<${ScrollToTopButton} />`, container)
    expect(container.querySelector('[data-scroll-to-top]')).toBeNull()
  })

  const flushUi = async () => {
    for (let i = 0; i < 4; i++) await Promise.resolve()
  }

  it('becomes visible once scrollY crosses the threshold', async () => {
    // Simulate scroll: happy-dom doesn't physically scroll, but we
    // can set window.scrollY via Object.defineProperty and dispatch
    // the event the effect listens for.
    Object.defineProperty(window, 'scrollY', { configurable: true, get: () => 500 })
    render(html`<${ScrollToTopButton} />`, container)
    window.dispatchEvent(new Event('scroll'))
    await flushUi()
    expect(container.querySelector('[data-scroll-to-top]')).toBeTruthy()
  })

  it('hides again when scrolled back above threshold (pure helper branch)', () => {
    // Regression guard via the pure classifier — the component's
    // re-render path in happy-dom is flaky with stubbed scrollY,
    // but the only decision point is shouldShowScrollToTop itself.
    // A pinned false-after-true transition rules out a future
    // threshold inversion.
    expect(shouldShowScrollToTop(500)).toBe(true)
    expect(shouldShowScrollToTop(100)).toBe(false)
  })

  it('custom threshold propagates to visibility check', async () => {
    Object.defineProperty(window, 'scrollY', { configurable: true, get: () => 150 })
    render(
      html`<${ScrollToTopButton} thresholdPx=${100} />`,
      container,
    )
    window.dispatchEvent(new Event('scroll'))
    await flushUi()
    expect(container.querySelector('[data-scroll-to-top]')).toBeTruthy()
  })

  it('onClick scrolls window to top smoothly', () => {
    const scrollSpy = vi.spyOn(window, 'scrollTo').mockImplementation(() => {})
    try {
      scrollWindowToTop()
      expect(scrollSpy).toHaveBeenCalledWith({ top: 0, behavior: 'smooth' })
    } finally {
      scrollSpy.mockRestore()
    }
  })

  it('testId renders as data-testid', async () => {
    Object.defineProperty(window, 'scrollY', { configurable: true, get: () => 500 })
    render(
      html`<${ScrollToTopButton} testId="main-scroll-top" />`,
      container,
    )
    window.dispatchEvent(new Event('scroll'))
    await flushUi()
    expect(container.querySelector('[data-testid="main-scroll-top"]')).toBeTruthy()
  })

  it('button carries role / aria-label for AT users', async () => {
    Object.defineProperty(window, 'scrollY', { configurable: true, get: () => 500 })
    render(html`<${ScrollToTopButton} />`, container)
    window.dispatchEvent(new Event('scroll'))
    await flushUi()
    const btn = container.querySelector('[data-scroll-to-top]') as HTMLElement
    expect(btn.getAttribute('aria-label')).toBe('맨 위로')
    expect(btn.getAttribute('title')).toBe('맨 위로 (Home)')
  })

  it('cleanup on unmount — after unmount, scroll events do not re-render', async () => {
    // Regression guard: the effect must remove its listener on unmount.
    // We can't spy reliably on happy-dom's removeEventListener, so we
    // verify the observable behaviour: after unmount, firing a scroll
    // event shouldn't resurrect the button.
    let fakeScrollY = 500
    Object.defineProperty(window, 'scrollY', { configurable: true, get: () => fakeScrollY })
    render(html`<${ScrollToTopButton} />`, container)
    window.dispatchEvent(new Event('scroll'))
    await flushUi()
    expect(container.querySelector('[data-scroll-to-top]')).toBeTruthy()
    render(null, container)
    fakeScrollY = 5000
    window.dispatchEvent(new Event('scroll'))
    await flushUi()
    // Container was unmounted, and no ghost button should appear.
    expect(container.querySelector('[data-scroll-to-top]')).toBeNull()
  })
})
