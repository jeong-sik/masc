import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { Markdown } from './markdown'

describe('Markdown', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('returns null for empty text', () => {
    render(html`<${Markdown} text="" />`, container)
    expect(container.querySelector('.markdown-content')).toBeNull()
  })

  it('renders a paragraph', () => {
    render(html`<${Markdown} text="hello world" />`, container)
    expect(container.querySelector('p')?.textContent).toBe('hello world')
  })

  it('renders GFM table', () => {
    const md = '| a | b |\n|---|---|\n| 1 | 2 |'
    render(html`<${Markdown} text=${md} />`, container)
    const table = container.querySelector('table')
    expect(table).not.toBeNull()
    expect(table?.querySelectorAll('th').length).toBe(2)
    expect(table?.querySelectorAll('td').length).toBe(2)
    expect(table?.querySelector('td')?.textContent).toBe('1')
  })

  it('renders table with alignment', () => {
    const md = '| left | center | right |\n|:---|:---:|---:|\n| a | b | c |'
    render(html`<${Markdown} text=${md} />`, container)
    const ths = container.querySelectorAll('th')
    expect(ths.length).toBe(3)
    // marked generates align attributes on th/td
    const tds = container.querySelectorAll('td')
    expect(tds.length).toBe(3)
  })

  it('converts line breaks with breaks: true', () => {
    render(html`<${Markdown} text=${'line1\nline2'} />`, container)
    const br = container.querySelector('br')
    expect(br).not.toBeNull()
  })

  it('renders code block with language class', () => {
    const md = '```js\nconsole.log("hi")\n```'
    render(html`<${Markdown} text=${md} />`, container)
    const code = container.querySelector('code.language-js')
    expect(code).not.toBeNull()
    expect(code?.textContent).toContain('console.log')
  })

  it('renders think block as collapsible details', () => {
    const md = '<think>some **reasoning**</think>'
    render(html`<${Markdown} text=${md} />`, container)
    const details = container.querySelector('details.think-block')
    expect(details).not.toBeNull()
    expect(details?.querySelector('summary')?.textContent).toBe('생각 중...')
    // Think block content is parsed as markdown
    expect(details?.querySelector('strong')?.textContent).toBe('reasoning')
  })

  it('strips script tags (XSS prevention)', () => {
    const md = 'safe text <script>alert("xss")</script> more text'
    render(html`<${Markdown} text=${md} />`, container)
    expect(container.innerHTML).not.toContain('<script')
    expect(container.textContent).toContain('safe text')
  })

  it('applies custom class alongside markdown-content', () => {
    render(html`<${Markdown} text="test" class="custom" />`, container)
    const div = container.querySelector('.markdown-content.custom')
    expect(div).not.toBeNull()
  })

  it('renders inline formatting (bold, italic, code)', () => {
    const md = '**bold** and *italic* and `code`'
    render(html`<${Markdown} text=${md} />`, container)
    expect(container.querySelector('strong')?.textContent).toBe('bold')
    expect(container.querySelector('em')?.textContent).toBe('italic')
    expect(container.querySelector('code')?.textContent).toBe('code')
  })

  it('preserves ASCII art inside code blocks', () => {
    const md = '```\n+-----+-----+\n| A   | B   |\n+-----+-----+\n```'
    render(html`<${Markdown} text=${md} />`, container)
    const pre = container.querySelector('pre')
    expect(pre).not.toBeNull()
    expect(pre?.textContent).toContain('+-----+-----+')
  })

  it('renders strikethrough (GFM)', () => {
    render(html`<${Markdown} text="~~deleted~~" />`, container)
    expect(container.querySelector('del')?.textContent).toBe('deleted')
  })

  it('adds target="_blank" and rel="noopener noreferrer" to links', () => {
    render(html`<${Markdown} text="[example](https://example.com)" />`, container)
    const a = container.querySelector('a')
    expect(a).not.toBeNull()
    expect(a?.getAttribute('target')).toBe('_blank')
    expect(a?.getAttribute('rel')).toBe('noopener noreferrer')
  })

  it('sanitizes event handlers via DOMPurify', () => {
    const md = '<img src=x onerror="alert(1)">'
    render(html`<${Markdown} text=${md} />`, container)
    expect(container.innerHTML).not.toContain('onerror')
  })

  it('handles think block with trailing whitespace in close tag', () => {
    const md = '<think>reasoning</think >'
    render(html`<${Markdown} text=${md} />`, container)
    const details = container.querySelector('details.think-block')
    expect(details).not.toBeNull()
  })
})
