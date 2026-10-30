import { describe, expect, it } from 'vitest'
import { parseTextToChatBlocks as parseChatBlocks } from './chat-blocks'

describe('parseChatBlocks', () => {
  it('turns plain text into an escaped HTML text block', () => {
    const blocks = parseChatBlocks('hello <world>')
    expect(blocks).toEqual([{ t: 'p', html: 'hello &lt;world&gt;' }])
  })

  it('detects markdown images and keeps surrounding text', () => {
    const blocks = parseChatBlocks('before ![alt text](https://example.com/a.png) after')
    expect(blocks).toEqual([
      { t: 'p', html: 'before ' },
      { t: 'image', src: 'https://example.com/a.png', cap: 'alt text' },
      { t: 'p', html: ' after' },
    ])
  })

  it('turns a bare image URL on its own line into an image block', () => {
    const blocks = parseChatBlocks('https://example.com/screen.webp')
    expect(blocks).toEqual([{ t: 'image', src: 'https://example.com/screen.webp' }])
  })

  it('turns a standalone non-image URL into a link card', () => {
    const blocks = parseChatBlocks('https://example.com/post')
    expect(blocks).toEqual([
      { t: 'link', url: 'https://example.com/post', title: 'example.com', meta: 'example.com' },
    ])
  })

  it('keeps inline URLs in text blocks (linkifyHtml handles them later)', () => {
    const blocks = parseChatBlocks('See https://example.com for more.')
    expect(blocks).toEqual([{ t: 'p', html: 'See https://example.com for more.' }])
  })

  it('handles multiple images and text lines in order', () => {
    const blocks = parseChatBlocks('intro\n![a](https://x.com/1.jpg)\nhttps://x.com/2.gif\noutro')
    expect(blocks).toEqual([
      { t: 'p', html: 'intro' },
      { t: 'image', src: 'https://x.com/1.jpg', cap: 'a' },
      { t: 'image', src: 'https://x.com/2.gif' },
      { t: 'p', html: 'outro' },
    ])
  })

  it('ignores empty lines without producing blocks', () => {
    const blocks = parseChatBlocks('line1\n\nline2')
    expect(blocks).toEqual([{ t: 'p', html: 'line1' }, { t: 'p', html: 'line2' }])
  })
})
