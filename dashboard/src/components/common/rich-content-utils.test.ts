import { describe, expect, it } from 'vitest'
import {
  convertStandaloneImageUrlsToMarkdown,
  extractPreviewUrls,
  extractStandaloneImageUrls,
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
  })
})
