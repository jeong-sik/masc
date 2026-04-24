import { html } from 'htm/preact'
import { render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { Markdown } from './markdown'
import { MarkdownContent as MarkdownRenderer } from './markdown-renderer'

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

  it('can transition from empty to populated text in the same mount point', async () => {
    render(html`<${Markdown} text="" />`, container)
    expect(container.querySelector('.markdown-content')).toBeNull()

    render(html`<${Markdown} text="later" />`, container)
    await waitFor(() => {
      expect(container.querySelector('.markdown-content')?.textContent).toContain('later')
    })
  })

  it('renders a paragraph', () => {
    render(html`<${MarkdownRenderer} text="hello world" />`, container)
    expect(container.querySelector('p')?.textContent).toBe('hello world')
  })

  it('renders GFM table', () => {
    const md = '| a | b |\n|---|---|\n| 1 | 2 |'
    render(html`<${MarkdownRenderer} text=${md} />`, container)
    const table = container.querySelector('table')
    expect(table).not.toBeNull()
    expect(table?.querySelectorAll('th').length).toBe(2)
    expect(table?.querySelectorAll('td').length).toBe(2)
    expect(table?.querySelector('td')?.textContent).toBe('1')
  })

  it('renders table with alignment', () => {
    const md = '| left | center | right |\n|:---|:---:|---:|\n| a | b | c |'
    render(html`<${MarkdownRenderer} text=${md} />`, container)
    const ths = container.querySelectorAll('th')
    expect(ths.length).toBe(3)
    // marked generates align attributes on th/td
    const tds = container.querySelectorAll('td')
    expect(tds.length).toBe(3)
  })

  it('converts line breaks with breaks: true', () => {
    render(html`<${MarkdownRenderer} text=${'line1\nline2'} />`, container)
    const br = container.querySelector('br')
    expect(br).not.toBeNull()
  })

  it('renders code block with language class', () => {
    const md = '```js\nconsole.log("hi")\n```'
    render(html`<${MarkdownRenderer} text=${md} />`, container)
    const code = container.querySelector('code.language-js')
    expect(code).not.toBeNull()
    expect(code?.textContent).toContain('console.log')
  })

  it('renders think block as collapsible details', () => {
    const md = '<think>some **reasoning**</think>'
    render(html`<${MarkdownRenderer} text=${md} />`, container)
    const details = container.querySelector('details.think-block')
    expect(details).not.toBeNull()
    expect(details?.querySelector('summary')?.textContent).toBe('생각 중...')
    // Think block content is parsed as markdown
    expect(details?.querySelector('strong')?.textContent).toBe('reasoning')
  })

  it('strips script tags (XSS prevention)', () => {
    const md = 'safe text <script>alert("xss")</script> more text'
    render(html`<${MarkdownRenderer} text=${md} />`, container)
    expect(container.innerHTML).not.toContain('<script')
    expect(container.textContent).toContain('safe text')
  })

  it('applies custom class alongside markdown-content', () => {
    render(html`<${MarkdownRenderer} text="test" class="custom" />`, container)
    const div = container.querySelector('.markdown-content.custom')
    expect(div).not.toBeNull()
  })

  it('renders inline formatting (bold, italic, code)', () => {
    const md = '**bold** and *italic* and `code`'
    render(html`<${MarkdownRenderer} text=${md} />`, container)
    expect(container.querySelector('strong')?.textContent).toBe('bold')
    expect(container.querySelector('em')?.textContent).toBe('italic')
    expect(container.querySelector('code')?.textContent).toBe('code')
  })

  it('preserves ASCII art inside code blocks', () => {
    const md = '```\n+-----+-----+\n| A   | B   |\n+-----+-----+\n```'
    render(html`<${MarkdownRenderer} text=${md} />`, container)
    const pre = container.querySelector('pre')
    expect(pre).not.toBeNull()
    expect(pre?.textContent).toContain('+-----+-----+')
  })

  it('renders strikethrough (GFM)', () => {
    render(html`<${MarkdownRenderer} text="~~deleted~~" />`, container)
    expect(container.querySelector('del')?.textContent).toBe('deleted')
  })

  it('adds target="_blank" and rel="noopener noreferrer" to links', () => {
    render(html`<${MarkdownRenderer} text="[example](https://example.com)" />`, container)
    const a = container.querySelector('a')
    expect(a).not.toBeNull()
    expect(a?.getAttribute('target')).toBe('_blank')
    expect(a?.getAttribute('rel')).toBe('noopener noreferrer')
  })

  it('sanitizes event handlers via DOMPurify', () => {
    const md = '<img src=x onerror="alert(1)">'
    render(html`<${MarkdownRenderer} text=${md} />`, container)
    expect(container.innerHTML).not.toContain('onerror')
  })

  it('sanitizes javascript: URLs in links', () => {
    const md = '[blocked](javascript:alert(1))'
    render(html`<${MarkdownRenderer} text=${md} />`, container)
    const anchor = container.querySelector('a')
    if (!anchor) return // DOMPurify removed entire tag — safe
    const href = anchor.getAttribute('href')
    if (!href) return // DOMPurify removed href attribute — safe
    expect(href.toLowerCase()).not.toMatch(/^javascript:/)
  })

  it('sanitizes javascript: URLs in images', () => {
    const md = '![malicious](javascript:alert(1))'
    render(html`<${MarkdownRenderer} text=${md} />`, container)
    const img = container.querySelector('img')
    if (!img) return // DOMPurify removed entire tag — safe
    const src = img.getAttribute('src') ?? ''
    expect(src.toLowerCase()).not.toMatch(/^javascript:/)
  })

  it('preserves dangerous-looking strings inside code blocks without mangling', () => {
    const md = [
      '```html',
      '<img src="x" onerror="alert(1)">',
      '<a href="https://example.com/?onclick=alert(1)">click</a>',
      '```',
    ].join('\n')
    render(html`<${MarkdownRenderer} text=${md} />`, container)
    const code = container.querySelector('code.language-html') ?? container.querySelector('code')
    expect(code).not.toBeNull()
    const text = code?.textContent ?? ''
    // Literal strings inside code blocks must be preserved, not sanitized
    expect(text).toContain('onerror=')
    expect(text).toContain('?onclick=')
  })

  it('handles think block with trailing whitespace in close tag', () => {
    const md = '<think>reasoning</think >'
    render(html`<${MarkdownRenderer} text=${md} />`, container)
    const details = container.querySelector('details.think-block')
    expect(details).not.toBeNull()
  })

  // ── Shiki syntax highlighting integration ─────────────────
  describe('shiki highlighting', () => {
    const waitForShiki = () => waitFor(() => {
      expect(container.querySelector('pre.shiki-rendered')).not.toBeNull()
    })

    it('highlights non-mermaid code fences via shiki', async () => {
      const md = '```typescript\nconst x = 1\n```'
      render(html`<${MarkdownRenderer} text=${md} />`, container)
      await waitForShiki()
      const shikiPre = container.querySelector('pre.shiki-rendered')
      expect(shikiPre).not.toBeNull()
      // The mock escapes HTML entities — verify content is present
      expect(shikiPre?.textContent).toContain('const x = 1')
    })

    it('does not apply shiki to mermaid code fences', async () => {
      // Render both a mermaid and a non-mermaid block to verify selectivity
      const md = '```mermaid\ngraph TD\nA-->B\n```\n\n```js\nconst a = 1\n```'
      render(html`<${MarkdownRenderer} text=${md} />`, container)
      await waitForShiki()
      // Only the JS block should get shiki highlighting
      const shikiBlocks = container.querySelectorAll('pre.shiki-rendered')
      expect(shikiBlocks.length).toBe(1)
      expect(shikiBlocks[0]?.textContent).toContain('const a = 1')
    })

    it('escapes HTML entities in highlighted code (XSS prevention)', async () => {
      const md = '```html\n<script>alert("xss")</script>\n```'
      render(html`<${MarkdownRenderer} text=${md} />`, container)
      await waitForShiki()
      // The shiki mock escapes < and > so no raw <script> in DOM
      expect(container.innerHTML).not.toContain('<script>')
    })
  })

  describe('truncated markdown repair', () => {
    it('repairs trailing orphan backtick from truncated tool output', () => {
      // Reproduces the ani1999 board post symptom: LLM output cut at
      // max_tokens mid-bullet, leaving "- `" as the final line.
      const md = 'first line\n- `keeper_memory_search`\n- `'
      render(html`<${MarkdownRenderer} text=${md} />`, container)
      // Body is still rendered; the trailing backtick doesn't swallow it.
      expect(container.textContent).toContain('first line')
      expect(container.textContent).toContain('keeper_memory_search')
      // Repair marker is visible so the operator knows it was cut.
      expect(container.textContent).toContain('[잘림]')
    })

    it('repairs unclosed triple-backtick code fence', () => {
      const md = 'before\n```ocaml\nlet x = 1'
      render(html`<${MarkdownRenderer} text=${md} />`, container)
      expect(container.textContent).toContain('before')
      expect(container.textContent).toContain('let x = 1')
      expect(container.textContent).toContain('[잘림]')
    })

    it('leaves balanced markdown untouched', () => {
      const md = 'plain `inline` and ```\ncode\n```'
      render(html`<${MarkdownRenderer} text=${md} />`, container)
      expect(container.textContent).not.toContain('[잘림]')
    })
  })
})
