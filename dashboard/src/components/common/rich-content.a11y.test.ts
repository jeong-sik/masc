// @vitest-environment happy-dom
//
// jest-axe coverage for RichContent — markdown-ish renderer with link
// preview cards. Tests pin empty text, plain text, text with URLs
// (link preview lazy-fetched), and code-fence content.
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { RichContent } from './rich-content'

describe('RichContent a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('empty text passes axe', async () => {
    render(html`<${RichContent} text="" />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('plain text passes axe', async () => {
    render(
      html`<${RichContent} text="Just a paragraph of plain text." />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('text with URL (preview lazy) passes axe', async () => {
    render(
      html`<${RichContent}
        text="See https://example.com for the docs."
        previewLimit=${1}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('code-fence content passes axe', async () => {
    const text = 'Here is code:\n\n```ts\nconst x = 1\n```\n\nDone.'
    render(html`<${RichContent} text=${text} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })
})
