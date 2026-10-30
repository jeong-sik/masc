import { describe, expect, it } from 'vitest'
import {
  convertStandaloneImageUrlsToMarkdown,
  extractMediaEmbeds,
  extractPreviewUrls,
  extractStandaloneImageUrls,
  mediaEmbedForUrl,
  prepareRichContent,
} from './rich-content-utils'

describe('rich-content-utils', () => {
  it('converts standalone image URLs into markdown images', () => {
    const source = 'before\nhttps://example.com/cat.png\nafter'
    const output = convertStandaloneImageUrlsToMarkdown(source)
    expect(output).toContain('![](<https://example.com/cat.png>)')
  })

  it('extracts standalone image URLs separately', () => {
    const source = 'https://example.com/cat.png\nhello'
    expect(extractStandaloneImageUrls(source)).toEqual(['https://example.com/cat.png'])
  })

  it('does not create preview cards for standalone image URLs', () => {
    const source = 'https://example.com/cat.png\nhttps://example.com/post'
    expect(extractPreviewUrls(source)).toEqual(['https://example.com/post'])
  })

  it('ignores markdown image URLs when collecting preview cards', () => {
    const source = '![alt](https://example.com/cat.png)\nhttps://example.com/post'
    expect(extractPreviewUrls(source)).toEqual(['https://example.com/post'])
  })

  it('prepares markdown text and previews together', () => {
    const prepared = prepareRichContent(
      '```ts\nconst x = 1\n```\nhttps://example.com/card',
      2,
    )
    expect(prepared.markdownText).toContain('```ts')
    expect(prepared.previewUrls).toEqual(['https://example.com/card'])
    expect(prepared.mediaEmbeds).toEqual([])
  })

  it('extracts direct video and audio URLs as playable media embeds', () => {
    expect(extractMediaEmbeds(
      'https://cdn.example.com/demo.mp4\nhttps://cdn.example.com/sound.mp3',
    )).toEqual([
      { kind: 'video', url: 'https://cdn.example.com/demo.mp4' },
      { kind: 'audio', url: 'https://cdn.example.com/sound.mp3' },
    ])
  })

  it('normalizes YouTube and Vimeo URLs to safe iframe embed URLs', () => {
    expect(mediaEmbedForUrl('https://youtu.be/dQw4w9WgXcQ')).toEqual({
      kind: 'iframe',
      url: 'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ',
      title: 'youtu.be',
    })
    expect(mediaEmbedForUrl('https://vimeo.com/123456789')).toEqual({
      kind: 'iframe',
      url: 'https://player.vimeo.com/video/123456789',
      title: 'vimeo.com',
    })
  })

  it('removes standalone media lines from markdown and link previews', () => {
    const prepared = prepareRichContent(
      'before\nhttps://cdn.example.com/demo.mp4\nhttps://example.com/card',
      4,
    )
    expect(prepared.markdownText).toContain('before')
    expect(prepared.markdownText).not.toContain('demo.mp4')
    expect(prepared.previewUrls).toEqual(['https://example.com/card'])
    expect(prepared.mediaEmbeds).toEqual([
      { kind: 'video', url: 'https://cdn.example.com/demo.mp4' },
    ])
  })
})
