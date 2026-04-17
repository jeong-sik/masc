import { describe, expect, it } from 'vitest'

import { safeParseLinkPreview } from './link-previews'

describe('safeParseLinkPreview', () => {
  it('accepts a minimal link preview', () => {
    const result = safeParseLinkPreview({
      url: 'https://example.com',
      kind: 'link',
    })
    expect(result.success).toBe(true)
    if (result.success) {
      expect(result.output.url).toBe('https://example.com')
      expect(result.output.kind).toBe('link')
      // optional fields are absent, not coerced to null
      expect(result.output.title).toBeUndefined()
    }
  })

  it('accepts an image preview with all optional fields populated', () => {
    const result = safeParseLinkPreview({
      url: 'https://cdn.example.com/pic.png',
      kind: 'image',
      canonical_url: 'https://cdn.example.com/pic.png',
      title: 'A picture',
      description: 'Scenic mountain view',
      site_name: 'Example CDN',
      image_url: 'https://cdn.example.com/pic.png',
      favicon_url: 'https://example.com/favicon.ico',
      content_type: 'image/png',
      fetched_at: '2026-04-17T00:00:00Z',
      cache_state: 'fresh',
    })
    expect(result.success).toBe(true)
    if (result.success) {
      expect(result.output.kind).toBe('image')
      expect(result.output.title).toBe('A picture')
    }
  })

  it('accepts explicit null for optional fields (backend nullability signal)', () => {
    const result = safeParseLinkPreview({
      url: 'https://example.com',
      kind: 'link',
      title: null,
      description: null,
    })
    expect(result.success).toBe(true)
    if (result.success) {
      expect(result.output.title).toBeNull()
    }
  })

  it('rejects an unknown kind (not coerced — dropped by caller)', () => {
    // kind is strict (not fallback): a preview the backend can't classify
    // should be dropped, not displayed as a link/image the user can click.
    const result = safeParseLinkPreview({
      url: 'https://example.com',
      kind: 'video',
    })
    expect(result.success).toBe(false)
  })

  it('rejects missing url', () => {
    const result = safeParseLinkPreview({ kind: 'link' })
    expect(result.success).toBe(false)
  })

  it('rejects non-object payload', () => {
    expect(safeParseLinkPreview(null).success).toBe(false)
    expect(safeParseLinkPreview('string').success).toBe(false)
    expect(safeParseLinkPreview(42).success).toBe(false)
  })
})
