// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { useMediaQuery } from './use-media-query'

function tick() {
  return new Promise((r) => setTimeout(r, 0))
}

function MediaQueryTester({ query }: { query: string }) {
  const matches = useMediaQuery(query)
  return html`<div data-matches=${matches ? 'true' : 'false'} />`
}

describe('useMediaQuery', () => {
  let container: HTMLElement
  let changeListeners: Array<(e: MediaQueryListEvent) => void> = []
  const originalMatchMedia = window.matchMedia

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    changeListeners = []

    window.matchMedia = vi.fn((query: string) => {
      let matches = query === '(min-width: 1px)'
      return {
        get matches() {
          return matches
        },
        addEventListener: (_event: string, handler: (e: MediaQueryListEvent) => void) => {
          changeListeners.push(handler)
        },
        removeEventListener: (_event: string, handler: (e: MediaQueryListEvent) => void) => {
          changeListeners = changeListeners.filter((l) => l !== handler)
        },
        dispatchEvent: (e: Event) => {
          if (e.type === 'change') {
            matches = (e as MediaQueryListEvent).matches
            changeListeners.forEach((l) => l(e as MediaQueryListEvent))
          }
          return true
        },
      } as MediaQueryList
    })
  })

  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    window.matchMedia = originalMatchMedia
  })

  it('returns initial match state', async () => {
    render(html`<${MediaQueryTester} query="(min-width: 1px)" />`, container)
    await tick()
    const el = container.querySelector('div') as HTMLElement
    expect(el.getAttribute('data-matches')).toBe('true')
  })

  it('returns false when query does not match', async () => {
    render(html`<${MediaQueryTester} query="(min-width: 99999px)" />`, container)
    await tick()
    const el = container.querySelector('div') as HTMLElement
    expect(el.getAttribute('data-matches')).toBe('false')
  })

  it('updates on media query change', async () => {
    render(html`<${MediaQueryTester} query="(min-width: 500px)" />`, container)
    await tick()
    const el = container.querySelector('div') as HTMLElement
    expect(el.getAttribute('data-matches')).toBe('false')

    const mql = window.matchMedia('(min-width: 500px)')
    mql.dispatchEvent(new Event('change', { bubbles: false }) as MediaQueryListEvent)
    await tick()

    expect(el.getAttribute('data-matches')).toBe('false')
  })
})
