import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { MarkdownContent } from './markdown-renderer'

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
