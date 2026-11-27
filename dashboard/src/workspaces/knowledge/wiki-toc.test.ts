// @vitest-environment jsdom
// jsdom: DOMPurify fails its smoke test under happy-dom and the renderer then
// escapes the whole body, so no heading would reach the DOM.

import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { WikiBodyWithToc, readTocEntries } from './wiki-toc'

describe('WikiBodyWithToc', () => {
  let container: HTMLDivElement
  let scrolled: HTMLElement[]

  beforeEach(() => {
    container = document.createElement('div')
    document.body.append(container)
    scrolled = []
    // jsdom has no scrollIntoView; each call records the element it was called on.
    Element.prototype.scrollIntoView = function (this: HTMLElement, arg?: boolean | ScrollIntoViewOptions) {
      if (JSON.stringify(arg) !== JSON.stringify({ block: 'start' })) throw new Error(`scrollIntoView(${JSON.stringify(arg)})`)
      scrolled.push(this)
    }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    Reflect.deleteProperty(Element.prototype, 'scrollIntoView')
  })

  // The page body as the Wiki tab draws it: the document renderer inside the TOC.
  function showPage(source: string): void {
    act(() => {
      render(html`
        <${WikiBodyWithToc} source=${source}>
          <${MarkdownContent} text=${source} document />
        </${WikiBodyWithToc}>
      `, container)
    })
  }
  const toc = () => container.querySelector('nav[aria-label="목차"]')
  const entryButtons = () => [...container.querySelectorAll<HTMLButtonElement>('nav[aria-label="목차"] button')]
  const entryTexts = () => entryButtons().map((button) => button.textContent?.trim())
  const body = () => container.querySelector<HTMLElement>('.markdown-content')!
  const drawnHeadings = () => [...body().querySelectorAll<HTMLElement>('h1, h2, h3, h4, h5, h6')]

  it('lists the drawn headings in order, with their levels', () => {
    showPage([
      '# Guide',
      'Intro.',
      '## The **bold** `code` part',
      '### Inner',
      'Setext\n------',
      '#### Deep',
    ].join('\n\n'))

    expect(entryTexts()).toEqual(['Guide', 'The bold code part', 'Inner', 'Setext', 'Deep'])
    const entries = readTocEntries(body())
    expect(entries.map((entry) => entry.level)).toEqual([1, 2, 3, 2, 4])
    expect(entries.map((entry) => entry.depth)).toEqual([0, 1, 2, 1, 3])
    expect(entries.map((entry) => entry.target)).toEqual(drawnHeadings())
  })

  it('indents from the highest level on the page, not from h1', () => {
    showPage('## First\n\n### Under\n\n## Second')

    expect(readTocEntries(body()).map((entry) => entry.depth)).toEqual([0, 1, 0])
  })

  it('scrolls to the drawn heading of the entry that is clicked', () => {
    showPage('## One\n\ntext\n\n## Two\n\ntext\n\n### Three')

    act(() => entryButtons()[2]!.click())
    expect(scrolled).toEqual([drawnHeadings()[2]])

    act(() => entryButtons()[0]!.click())
    expect(scrolled).toEqual([drawnHeadings()[2], drawnHeadings()[0]])
  })

  it('shows no table of contents for a page with fewer than two headings', () => {
    showPage('Only text, no heading.')
    expect(toc()).toBeNull()
    expect(body().textContent).toContain('Only text, no heading.')

    showPage('## Single\n\nOne heading.')
    expect(toc()).toBeNull()
    expect(drawnHeadings()).toHaveLength(1)
  })

  it('does not list heading lines inside fenced code', () => {
    showPage('## Real\n\n```md\n# not a heading\n## also not\n```\n\n    # indented code\n\n## Second real')

    expect(entryTexts()).toEqual(['Real', 'Second real'])
  })

  it('lists a raw HTML heading, which the document renderer draws', () => {
    showPage('## One\n\n<h3>Raw</h3>\n\n## Two')

    expect(entryTexts()).toEqual(['One', 'Raw', 'Two'])
    act(() => entryButtons()[1]!.click())
    expect(scrolled).toEqual([body().querySelector('h3')])
  })

  it('leaves out a heading with no text', () => {
    showPage('## One\n\n##\n\n## Two')

    expect(drawnHeadings()).toHaveLength(3)
    expect(entryTexts()).toEqual(['One', 'Two'])
  })

  it('reads the headings again when the page changes', () => {
    showPage('## A1\n\n## A2\n\n## A3')
    showPage('# B1\n\n## B2')

    expect(entryTexts()).toEqual(['B1', 'B2'])
    act(() => entryButtons()[1]!.click())
    expect(scrolled).toEqual([drawnHeadings()[1]])
    expect(scrolled[0]!.isConnected).toBe(true)

    showPage('## C1 only')
    expect(toc()).toBeNull()
  })

  it('scrolls to the heading drawn now when the body nodes were replaced with the page unchanged', () => {
    const source = '## One\n\ntext\n\n## Two\n\ntext\n\n## Three'
    showPage(source)
    const before = drawnHeadings()
    for (const heading of before) heading.replaceWith(heading.cloneNode(true))
    const after = drawnHeadings()
    expect(after).toHaveLength(3)
    expect(after[1]).not.toBe(before[1])

    act(() => entryButtons()[1]!.click())
    expect(scrolled).toEqual([after[1]])
    expect(scrolled[0]).not.toBe(before[1])
  })

  it('opens a closed details block around the heading before scrolling to it', () => {
    showPage('## Visible\n\n<details>\n<summary>More</summary>\n\n## Folded\n\n</details>\n\n## After')
    const details = body().querySelector('details')!
    expect(details.open).toBe(false)

    expect(entryTexts()).toEqual(['Visible', 'Folded', 'After'])
    act(() => entryButtons()[1]!.click())
    expect(details.open).toBe(true)
    expect(scrolled).toEqual([details.querySelector('h2')])
  })
})
