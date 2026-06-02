// @vitest-environment happy-dom
//
// jest-axe coverage for ScrollToTopButton — floating "back to top"
// affordance. Icon-only button; tests guard the accessible-name
// contract (the wrapper button must have an aria-label since the
// only child is a ChevronUp svg).
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { ScrollToTopButton } from './scroll-to-top'

describe('ScrollToTopButton a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    // Mock scroll position so the button renders.
    Object.defineProperty(window, 'scrollY', {
      value: 1000,
      writable: true,
      configurable: true,
    })
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('renders accessibly when scroll position triggers visibility', async () => {
    render(html`<${ScrollToTopButton} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('with custom threshold prop passes axe', async () => {
    render(html`<${ScrollToTopButton} thresholdPx=${200} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
