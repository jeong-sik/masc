// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { waitFor } from '@testing-library/preact'
import { useIsMobile } from './use-is-mobile'

function TestHarness({ breakpoint }: { breakpoint?: number }) {
  const isMobile = useIsMobile({ breakpoint })
  return html`<span data-testid="result" data-is-mobile=${String(isMobile)} />`
}

describe('useIsMobile', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('returns true when viewport width is at the default 760px breakpoint', () => {
    window.innerWidth = 760
    render(html`<${TestHarness} />`, container)

    const result = container.querySelector('[data-testid="result"]')
    expect(result?.getAttribute('data-is-mobile')).toBe('true')
  })

  it('returns false when viewport width is above the default breakpoint', () => {
    window.innerWidth = 1024
    render(html`<${TestHarness} />`, container)

    const result = container.querySelector('[data-testid="result"]')
    expect(result?.getAttribute('data-is-mobile')).toBe('false')
  })

  it('respects a custom breakpoint', () => {
    window.innerWidth = 900
    render(html`<${TestHarness} breakpoint=${1000} />`, container)

    const result = container.querySelector('[data-testid="result"]')
    expect(result?.getAttribute('data-is-mobile')).toBe('true')
  })

  it('reacts to window resize events', async () => {
    window.innerWidth = 1024
    render(html`<${TestHarness} />`, container)

    const result = container.querySelector('[data-testid="result"]')
    expect(result?.getAttribute('data-is-mobile')).toBe('false')

    window.innerWidth = 360
    window.dispatchEvent(new Event('resize'))

    await waitFor(() => {
      expect(result?.getAttribute('data-is-mobile')).toBe('true')
    })
  })
})
