// @vitest-environment jsdom

import { describe, expect, it, vi } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { MarkdownContent, renderMarkdown } from './markdown-renderer'
import { renderMermaidSvg } from './mermaid-graph'

// Mock the shared mermaid render path: markdown-renderer delegates to it for
// ```mermaid fences. Real mermaid is dynamically imported and unavailable here.
vi.mock('./mermaid-graph', () => ({
  renderMermaidSvg: vi.fn(
    async () => '<svg xmlns="http://www.w3.org/2000/svg"><rect width="4" height="4"/></svg>',
  ),
}))

describe('MarkdownContent', () => {
  it('renders container', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '' }), container)
    expect(container.querySelector('.markdown-content')).not.toBeNull()
  })

  it('renders plain text as paragraph', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: 'hello world' }), container)
    expect(container.querySelector('p')).not.toBeNull()
    expect(container.textContent).toContain('hello world')
  })

  it('renders bold text', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '**bold**' }), container)
    expect(container.querySelector('strong')).not.toBeNull()
    expect(container.textContent).toContain('bold')
  })

  it('renders italic text', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '*italic*' }), container)
    expect(container.querySelector('em')).not.toBeNull()
    expect(container.textContent).toContain('italic')
  })

  it('renders headings', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '# H1\n## H2' }), container)
    expect(container.querySelector('h1')).not.toBeNull()
    expect(container.querySelector('h2')).not.toBeNull()
  })

  it('renders code block', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '```js\nconst x = 1;\n```' }), container)
    expect(container.querySelector('pre')).not.toBeNull()
    expect(container.querySelector('code')).not.toBeNull()
  })

  it('renders inline code', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: 'use `code`' }), container)
    expect(container.querySelector('code')).not.toBeNull()
    expect(container.textContent).toContain('code')
  })

  it('renders unordered list', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '- a\n- b' }), container)
    expect(container.querySelector('ul')).not.toBeNull()
    expect(container.querySelectorAll('li').length).toBe(2)
  })

  it('renders ordered list', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '1. first\n2. second' }), container)
    expect(container.querySelector('ol')).not.toBeNull()
    expect(container.querySelectorAll('li').length).toBe(2)
  })

  it('renders link with target blank', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '[link](https://example.com)' }), container)
    const a = container.querySelector('a') as HTMLAnchorElement
    expect(a).not.toBeNull()
    expect(a?.getAttribute('target')).toBe('_blank')
    expect(a?.getAttribute('rel')).toContain('noopener')
  })

  it('renders blockquote', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '> quote' }), container)
    expect(container.querySelector('blockquote')).not.toBeNull()
  })

  it('renders table', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '| a | b |\n|---|---|\n| 1 | 2 |' }), container)
    expect(container.querySelector('table')).not.toBeNull()
    expect(container.querySelectorAll('td').length).toBe(2)
  })

  it('sanitizes script tags', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '<script>alert(1)</script>' }), container)
    expect(container.querySelector('script')).toBeNull()
  })

  it('renders sanitized HTML blocks without unsafe attributes', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, {
      text: '<div class="idea-card" onclick="alert(1)"><span data-x="bad">HTML idea</span></div>',
    }), container)

    const div = container.querySelector('.idea-card') as HTMLDivElement | null
    const span = container.querySelector('span') as HTMLSpanElement | null
    expect(div).not.toBeNull()
    expect(div?.textContent).toContain('HTML idea')
    expect(div?.getAttribute('onclick')).toBeNull()
    expect(span?.getAttribute('data-x')).toBeNull()
  })

  it('renders think block as details', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '<think>hidden thought</think>' }), container)
    expect(container.querySelector('details')).not.toBeNull()
    expect(container.querySelector('summary')).not.toBeNull()
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '', class: 'extra-class' }), container)
    const el = container.querySelector('.markdown-content') as HTMLElement
    expect(el?.classList.contains('extra-class')).toBe(true)
  })

  it('renders horizontal rule', () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '---' }), container)
    expect(container.querySelector('hr')).not.toBeNull()
  })
})

describe('renderMarkdown cache', () => {
  it('reuses sanitized HTML for identical source across calls', () => {
    renderMarkdown.clear()
    expect(renderMarkdown.size).toBe(0)

    const html = renderMarkdown('hello **world**')
    expect(html).toContain('<strong>')
    expect(renderMarkdown.size).toBe(1)

    renderMarkdown('hello **world**')
    expect(renderMarkdown.size).toBe(1) // cache hit: no new entry

    renderMarkdown('a different paragraph')
    expect(renderMarkdown.size).toBe(2)
  })
})

describe('MarkdownContent mermaid fences', () => {
  it('replaces a ```mermaid block with the shared-rendered svg', async () => {
    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '```mermaid\ngraph TD; A-->B\n```' }), container)
    await waitFor(() => {
      expect(container.querySelector('.mermaid-rendered svg')).not.toBeNull()
    })
    // the original code fence is replaced, not left behind
    expect(container.querySelector('code.language-mermaid')).toBeNull()
  })

  it('logs a warning and keeps the code block when mermaid render fails', async () => {
    vi.mocked(renderMermaidSvg).mockRejectedValueOnce(new Error('render fail'))
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

    const container = document.createElement('div')
    render(h(MarkdownContent, { text: '```mermaid\ngraph TD; A-->B\n```' }), container)

    await waitFor(() => {
      expect(warnSpy).toHaveBeenCalledWith(
        '[markdown-renderer] mermaid fence render failed',
        expect.any(Error),
      )
    })
    // original code fence remains as fallback
    expect(container.querySelector('code.language-mermaid')).not.toBeNull()

    warnSpy.mockRestore()
  })
})
