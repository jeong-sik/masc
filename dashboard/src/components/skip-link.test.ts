// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { SkipLink } from './skip-link'

describe('SkipLink', () => {
  it('targets main content and uses the focus-visible skip-link style', () => {
    const container = document.createElement('div')
    render(html`<${SkipLink} />`, container)

    const link = container.querySelector('a')
    expect(link?.getAttribute('href')).toBe('#main-content')
    expect(link?.classList.contains('sr-only')).toBe(true)
    expect(link?.classList.contains('skip-link')).toBe(true)
    expect(link?.textContent).toBe('Skip to main content')
  })

  it('focuses the target without relying on hash navigation', () => {
    const container = document.createElement('div')
    document.body.appendChild(container)
    render(
      html`
        <${SkipLink} />
        <main id="main-content" tabindex="-1">Main</main>
      `,
      container,
    )

    const link = container.querySelector('a') as HTMLAnchorElement
    const main = container.querySelector('main') as HTMLElement
    link.click()

    expect(document.activeElement).toBe(main)
    render(null, container)
    document.body.removeChild(container)
  })
})
