import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { LiveRegion } from './live-region'

describe('LiveRegion', () => {
  it('renders empty region', () => {
    const container = document.createElement('div')
    render(h(LiveRegion, { messages: [] }), container)
    const region = container.querySelector('[data-live-region]')
    expect(region).not.toBeNull()
    expect(region?.classList.contains('sr-only')).toBe(true)
  })

  it('splits polite and assertive messages', () => {
    const container = document.createElement('div')
    const messages = [
      { id: '1', text: 'Saved', priority: 'polite' as const },
      { id: '2', text: 'Error', priority: 'assertive' as const },
    ]
    render(h(LiveRegion, { messages }), container)
    const polite = container.querySelector('[aria-live="polite"]')
    const assertive = container.querySelector('[aria-live="assertive"]')
    expect(polite?.textContent).toContain('Saved')
    expect(assertive?.textContent).toContain('Error')
    expect(polite?.textContent).not.toContain('Error')
    expect(assertive?.textContent).not.toContain('Saved')
  })

  it('sets aria-atomic correctly', () => {
    const container = document.createElement('div')
    render(h(LiveRegion, { messages: [] }), container)
    const polite = container.querySelector('[aria-live="polite"]')
    const assertive = container.querySelector('[aria-live="assertive"]')
    expect(polite?.getAttribute('aria-atomic')).toBe('false')
    expect(assertive?.getAttribute('aria-atomic')).toBe('true')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(LiveRegion, { messages: [], testId: 'live-1' }), container)
    const region = container.querySelector('[data-testid="live-1"]')
    expect(region).not.toBeNull()
  })
})
