// @vitest-environment jsdom

import { describe, expect, it } from 'vitest'
import { parseMarkdownToBlocks } from './markdown-blocks'
import type { ChatBlock } from '../../types'

describe('parseMarkdownToBlocks', () => {
  it('returns an empty array for empty/whitespace input', () => {
    expect(parseMarkdownToBlocks('')).toEqual([])
    expect(parseMarkdownToBlocks('   \n  ')).toEqual([])
  })

  it('parses paragraphs with inline formatting and links', () => {
    const blocks = parseMarkdownToBlocks('Hello **world**. Visit http://example.com')
    expect(blocks).toHaveLength(1)
    expect(blocks[0]).toMatchObject({ t: 'p' })
    const html = (blocks[0] as Extract<ChatBlock, { t: 'p' }>).html
    expect(html).toContain('Hello')
    expect(html).toContain('<strong>world</strong>')
    expect(html).toContain('<a')
    expect(html).toContain('http://example.com')
  })

  it('parses headings as h4 blocks', () => {
    const blocks = parseMarkdownToBlocks('# Title\n\n## Subtitle')
    expect(blocks).toHaveLength(2)
    expect(blocks[0]).toMatchObject({ t: 'h4' })
    expect(blocks[1]).toMatchObject({ t: 'h4' })
    expect((blocks[0] as Extract<ChatBlock, { t: 'h4' }>).html).toContain('Title')
  })

  it('parses unordered lists', () => {
    const blocks = parseMarkdownToBlocks('- first\n- **second**\n- [third](http://x.com)')
    expect(blocks).toHaveLength(1)
    const list = blocks[0] as Extract<ChatBlock, { t: 'ul' }>
    expect(list.t).toBe('ul')
    expect(list.items).toHaveLength(3)
    expect(list.items[0]).toContain('first')
    expect(list.items[1]).toContain('<strong>second</strong>')
    expect(list.items[2]).toContain('<a')
  })

  it('parses ordered lists', () => {
    const blocks = parseMarkdownToBlocks('1. first\n2. second')
    const list = blocks[0] as Extract<ChatBlock, { t: 'ul' }>
    expect(list.t).toBe('ul')
    expect(list.items).toHaveLength(2)
  })

  it('parses code fences with language caption', () => {
    const blocks = parseMarkdownToBlocks('```typescript\nconst x = 1 < 2\n```')
    expect(blocks).toHaveLength(1)
    const code = blocks[0] as Extract<ChatBlock, { t: 'code' }>
    expect(code.t).toBe('code')
    expect(code.cap).toBe('typescript')
    expect(code.html).toContain('const x = 1')
    expect(code.html).toContain('&lt;') // escaped, not raw
  })

  it('parses mermaid fences into mermaid blocks', () => {
    const blocks = parseMarkdownToBlocks('```mermaid\ngraph TD\n  A --> B\n```')
    expect(blocks).toHaveLength(1)
    const mermaid = blocks[0] as Extract<ChatBlock, { t: 'mermaid' }>
    expect(mermaid.t).toBe('mermaid')
    expect(mermaid.source).toContain('graph TD')
  })

  it('parses GitHub-style callouts', () => {
    const cases: Array<{ input: string; severity: string; label: string }> = [
      { input: '> [!NOTE]\n> note body', severity: 'info', label: 'NOTE' },
      { input: '> [!TIP]\n> tip body', severity: 'info', label: 'TIP' },
      { input: '> [!WARNING]\n> warning body', severity: 'warn', label: 'WARNING' },
      { input: '> [!CAUTION]\n> caution body', severity: 'bad', label: 'CAUTION' },
      { input: '> [!DANGER]\n> danger body', severity: 'bad', label: 'DANGER' },
    ]

    for (const { input, severity, label } of cases) {
      const blocks = parseMarkdownToBlocks(input)
      expect(blocks).toHaveLength(1)
      const callout = blocks[0] as Extract<ChatBlock, { t: 'callout' }>
      expect(callout.t).toBe('callout')
      expect(callout.severity).toBe(severity)
      expect(callout.html).toContain(`${label.toLowerCase()} body`)
      expect(callout.html).not.toContain('[!')
    }
  })

  it('turns plain blockquotes into info callouts', () => {
    const blocks = parseMarkdownToBlocks('> plain quote')
    const callout = blocks[0] as Extract<ChatBlock, { t: 'callout' }>
    expect(callout.t).toBe('callout')
    expect(callout.severity).toBe('info')
    expect(callout.html).toContain('plain quote')
  })

  it('parses tables and detects numeric/muted cells', () => {
    const blocks = parseMarkdownToBlocks('|name|count|\n|---|---|\n|a|42|\n|b|n/a|\n')
    expect(blocks).toHaveLength(1)
    const table = blocks[0] as Extract<ChatBlock, { t: 'table' }>
    expect(table.t).toBe('table')
    expect(table.head).toHaveLength(2)
    expect(table.rows).toHaveLength(2)
    expect(table.rows[0]![1]).toMatchObject({ v: '42', num: true })
    expect(table.rows[1]![1]).toMatchObject({ v: 'n/a', muted: true })
  })

  it('promotes image-only paragraphs to image blocks', () => {
    const blocks = parseMarkdownToBlocks('![alt text](http://x.com/img.png)')
    expect(blocks).toHaveLength(1)
    const image = blocks[0] as Extract<ChatBlock, { t: 'image' }>
    expect(image.t).toBe('image')
    expect(image.src).toBe('http://x.com/img.png')
    expect(image.cap).toBe('alt text')
  })

  it('keeps inline images inside paragraphs', () => {
    const blocks = parseMarkdownToBlocks('See ![icon](http://x.com/icon.png) here')
    expect(blocks).toHaveLength(1)
    const p = blocks[0] as Extract<ChatBlock, { t: 'p' }>
    expect(p.html).toContain('<img')
    expect(p.html).toContain('icon')
  })

  it('parses top-level SVG html into svg blocks', () => {
    const blocks = parseMarkdownToBlocks('<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="5"/></svg>')
    expect(blocks).toHaveLength(1)
    const svg = blocks[0] as Extract<ChatBlock, { t: 'svg' }>
    expect(svg.t).toBe('svg')
    expect(svg.svg).toContain('<svg')
  })

  it('ignores horizontal rules', () => {
    const blocks = parseMarkdownToBlocks('before\n\n---\n\nafter')
    expect(blocks).toHaveLength(2)
    expect(blocks[0]).toMatchObject({ t: 'p' })
    expect(blocks[1]).toMatchObject({ t: 'p' })
  })

  it('does not throw on malformed input so callers can fall back', () => {
    // Passing an extremely malformed string should not throw.
    expect(() => parseMarkdownToBlocks('\0')).not.toThrow()
    expect(Array.isArray(parseMarkdownToBlocks('\0'))).toBe(true)
  })

  it('preserves HTML escaping in inline code', () => {
    const blocks = parseMarkdownToBlocks('Use `<script>`')
    const p = blocks[0] as Extract<ChatBlock, { t: 'p' }>
    expect(p.html).toContain('<code>')
    expect(p.html).not.toContain('<script>')
  })

  // Strict-superset of lib/chat-blocks.ts: a URL alone on its line becomes a
  // card, so this parser can supersede the line-based one on the render path
  // without losing the link/image affordance.
  it('turns a standalone URL into a link card', () => {
    const blocks = parseMarkdownToBlocks('https://example.com/docs/page')
    expect(blocks).toHaveLength(1)
    const link = blocks[0] as Extract<ChatBlock, { t: 'link' }>
    expect(link.t).toBe('link')
    expect(link.url).toBe('https://example.com/docs/page')
    expect(link.title).toBe('example.com')
  })

  it('turns a standalone image URL into an image block', () => {
    const blocks = parseMarkdownToBlocks('https://example.com/pic.png')
    expect(blocks).toHaveLength(1)
    const image = blocks[0] as Extract<ChatBlock, { t: 'image' }>
    expect(image.t).toBe('image')
    expect(image.src).toBe('https://example.com/pic.png')
  })

  it('keeps a URL with surrounding prose as an inline link, not a card', () => {
    const blocks = parseMarkdownToBlocks('See https://example.com for details')
    expect(blocks).toHaveLength(1)
    expect(blocks[0]).toMatchObject({ t: 'p' })
    expect((blocks[0] as Extract<ChatBlock, { t: 'p' }>).html).toContain('<a')
  })

  it('links generated board post ids to the board detail route', () => {
    const postId = 'p-59e2917e15de5367e81b2244a8f5095a'
    const label = postId.slice(0, 8)
    const blocks = parseMarkdownToBlocks(`올렸다. 보드에 ${postId}.`)
    expect(blocks).toHaveLength(1)
    const html = (blocks[0] as Extract<ChatBlock, { t: 'p' }>).html
    expect(html).toContain(`href="#board?post=${postId}"`)
    expect(html).toContain('class="inline-link chat-board-post-link"')
    expect(html).toContain(`data-board-post-id="${postId}"`)
    expect(html).toContain(`title="보드 글 ${postId} 열기"`)
    expect(html).toContain('보드 글')
    expect(html).toContain(label)
  })

  // Per-line superset: a soft-wrapped paragraph (single newlines, no blank line)
  // that interleaves prose with a standalone-URL line must still yield the card,
  // matching the line-based parser the render path supersedes.
  it('splits a soft-wrapped paragraph so a mid-message image URL line stays a card', () => {
    const blocks = parseMarkdownToBlocks('Here is the chart:\nhttps://cdn.example.com/run/abc.png\nLet me know.')
    expect(blocks).toHaveLength(3)
    expect(blocks[0]).toMatchObject({ t: 'p' })
    expect(blocks[1]).toMatchObject({ t: 'image', src: 'https://cdn.example.com/run/abc.png' })
    expect(blocks[2]).toMatchObject({ t: 'p' })
  })

  it('splits consecutive bare URL lines into separate link cards', () => {
    const blocks = parseMarkdownToBlocks('https://a.example.com/x\nhttps://b.example.com/y')
    expect(blocks).toHaveLength(2)
    expect(blocks[0]).toMatchObject({ t: 'link', url: 'https://a.example.com/x' })
    expect(blocks[1]).toMatchObject({ t: 'link', url: 'https://b.example.com/y' })
  })

  // Unterminated code fences: an LLM that opens ``` and never closes it makes
  // marked absorb all following prose into one code token. We demote that to a
  // text block so the prose is readable instead of trapped in a monospace box.
  it('keeps a closed fence as a code block (regression guard)', () => {
    const blocks = parseMarkdownToBlocks('```js\nconst x = 1\n```')
    expect(blocks).toHaveLength(1)
    const code = blocks[0] as Extract<ChatBlock, { t: 'code' }>
    expect(code.t).toBe('code')
    expect(code.cap).toBe('js')
    expect(code.html).toContain('const x = 1')
  })

  it('renders an unterminated fence as text, preserving the absorbed prose', () => {
    const blocks = parseMarkdownToBlocks(
      '```json\n{"x":1}\nThis prose should not be trapped.\nMore prose.',
    )
    expect(blocks).toHaveLength(1)
    expect(blocks[0]).toMatchObject({ t: 'p' })
    const p = blocks[0] as Extract<ChatBlock, { t: 'p' }>
    // The body is not a code block...
    expect((blocks[0] as ChatBlock).t).not.toBe('code')
    // ...and the trailing prose survives (not swallowed into a code box).
    expect(p.html).toContain('This prose should not be trapped.')
    expect(p.html).toContain('More prose.')
    // The fenced JSON body is rendered literally after HTML escaping.
    expect(p.html).toContain('{&quot;x&quot;:1}')
    // Newlines are preserved as <br> for the multi-line body.
    expect(p.html).toContain('<br>')
  })

  it('escapes angle brackets in an unterminated fence body (no raw HTML)', () => {
    const blocks = parseMarkdownToBlocks('```\n<script>alert(1)</script>\nremaining prose')
    expect(blocks).toHaveLength(1)
    const p = blocks[0] as Extract<ChatBlock, { t: 'p' }>
    expect(p.t).toBe('p')
    expect(p.html).toContain('&lt;script&gt;')
    expect(p.html).not.toContain('<script>')
    expect(p.html).toContain('remaining prose')
  })

  it('renders an unterminated tilde fence as text', () => {
    const blocks = parseMarkdownToBlocks('~~~\nsome code\nthen prose runs on')
    expect(blocks).toHaveLength(1)
    expect(blocks[0]).toMatchObject({ t: 'p' })
    const p = blocks[0] as Extract<ChatBlock, { t: 'p' }>
    expect(p.html).toContain('some code')
    expect(p.html).toContain('then prose runs on')
  })

  it('does not treat a mismatched closing fence as closed', () => {
    const blocks = parseMarkdownToBlocks('~~~\nsome code\n```')
    expect(blocks).toHaveLength(1)
    expect(blocks[0]).toMatchObject({ t: 'p' })
    const p = blocks[0] as Extract<ChatBlock, { t: 'p' }>
    expect(p.html).toContain('some code')
  })

  it('does not treat the opposite mismatched closing fence as closed', () => {
    const blocks = parseMarkdownToBlocks('```\nsome code\n~~~')
    expect(blocks).toHaveLength(1)
    expect(blocks[0]).toMatchObject({ t: 'p' })
    const p = blocks[0] as Extract<ChatBlock, { t: 'p' }>
    expect(p.html).toContain('some code')
  })

  it('leaves a 4-space indented code block untouched', () => {
    const blocks = parseMarkdownToBlocks('    line1\n    line2')
    expect(blocks).toHaveLength(1)
    const code = blocks[0] as Extract<ChatBlock, { t: 'code' }>
    expect(code.t).toBe('code')
    expect(code.html).toContain('line1')
    expect(code.html).toContain('line2')
  })

  it('leaves 4-space indented code whose first literal line looks fenced untouched', () => {
    const blocks = parseMarkdownToBlocks('    ```\n    literal fence inside indented code')
    expect(blocks).toHaveLength(1)
    const code = blocks[0] as Extract<ChatBlock, { t: 'code' }>
    expect(code.t).toBe('code')
    expect(code.html).toContain('```')
    expect(code.html).toContain('literal fence inside indented code')
  })

  it('does not treat a 4-space indented closing-looking line as a closing fence', () => {
    const blocks = parseMarkdownToBlocks('```\nsome code\n    ```')
    expect(blocks).toHaveLength(1)
    expect(blocks[0]).toMatchObject({ t: 'p' })
    const p = blocks[0] as Extract<ChatBlock, { t: 'p' }>
    expect(p.html).toContain('some code')
  })

  it('keeps a closed fence followed by prose as separate code + paragraph blocks', () => {
    const blocks = parseMarkdownToBlocks('```js\nc\n```\n\nAnd here is prose.')
    expect(blocks).toHaveLength(2)
    expect(blocks[0]).toMatchObject({ t: 'code' })
    expect((blocks[0] as Extract<ChatBlock, { t: 'code' }>).html).toContain('c')
    expect(blocks[1]).toMatchObject({ t: 'p' })
    expect((blocks[1] as Extract<ChatBlock, { t: 'p' }>).html).toContain('And here is prose.')
  })
})
