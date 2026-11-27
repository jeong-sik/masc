// @vitest-environment jsdom
// jsdom: DOMPurify fails its smoke test under happy-dom and the renderer then
// escapes the whole body, so no link would reach the DOM.

import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { describe, expect, it, vi } from 'vitest'

// Counts fence enhancement without loading a diagram renderer.
const enhanceRichCode = vi.hoisted(() => vi.fn(() => () => {}))
vi.mock('./rich-code-preview', () => ({ enhanceRichCode }))

import { MarkdownContent, type LinkRewrite } from './markdown-renderer'

describe('MarkdownContent linkRewrites', () => {
  const text = 'See [B](page-b.md).\n\n```mermaid\ngraph TD; A-->B\n```'
  const rewrites = (): ReadonlyMap<string, LinkRewrite> =>
    new Map([['page-b.md', { href: '#/knowledge/wiki/page-b', title: 'The second page' }]])

  it('rewrites before paint, leaves the fences alone when only the map changes, and restores the link', () => {
    const container = document.createElement('div')
    const link = () => container.querySelector('a')

    // Inside act, layout effects run with render and after-paint effects
    // wait for the scope to end, so the href read there is the painted one.
    let paintedHref: string | null | undefined
    act(() => {
      render(html`<${MarkdownContent} text=${text} document linkRewrites=${rewrites()} />`, container)
      paintedHref = link()?.getAttribute('href')
      expect(enhanceRichCode).not.toHaveBeenCalled()
    })
    expect(paintedHref).toBe('#/knowledge/wiki/page-b')
    expect(link()?.hasAttribute('target')).toBe(false)
    expect(link()?.getAttribute('title')).toBe('The second page')
    expect(enhanceRichCode).toHaveBeenCalledTimes(1)

    act(() => {
      render(html`<${MarkdownContent} text=${text} document linkRewrites=${rewrites()} />`, container)
    })
    expect(enhanceRichCode).toHaveBeenCalledTimes(1)
    expect(link()?.getAttribute('href')).toBe('#/knowledge/wiki/page-b')

    act(() => {
      render(html`<${MarkdownContent} text=${text} document />`, container)
    })
    expect(link()?.getAttribute('href')).toBe('page-b.md')
    expect(link()?.getAttribute('target')).toBe('_blank')
    expect(link()?.hasAttribute('title')).toBe(false)
    render(null, container)
  })
})
