// @vitest-environment jsdom
// jsdom: DOMPurify fails its smoke test under happy-dom and the renderer then
// escapes the whole body, so no heading would reach the DOM.

import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { axe } from 'jest-axe'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { WikiBodyWithToc } from './wiki-toc'

describe('WikiBodyWithToc a11y', () => {
  let container: HTMLDivElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.append(container)
  })
  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders the table of contents and the body accessibly', async () => {
    const source = '## Setup\n\nText.\n\n### Keys\n\nMore.\n\n## Use\n\nEnd.'
    act(() => {
      render(html`
        <main>
          <h1>Knowledge</h1>
          <h2>Page title</h2>
          <${WikiBodyWithToc} source=${source}>
            <${MarkdownContent} text=${source} document />
          </${WikiBodyWithToc}>
        </main>
      `, container)
    })

    const nav = container.querySelector('nav[aria-label="목차"]')
    expect(nav?.querySelectorAll('button[type="button"]')).toHaveLength(3)
    expect(await axe(container)).toHaveNoViolations()
  })
})
