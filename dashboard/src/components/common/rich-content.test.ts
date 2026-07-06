// @ts-nocheck
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { RichContent } from './rich-content'

vi.mock('../../api/link-previews', () => ({
  fetchLinkPreviews: vi.fn(),
}))

vi.mock('./markdown', () => ({
  Markdown: function Markdown(props: any) {
    return props.text
  },
}))

import { fetchLinkPreviews } from '../../api/link-previews'

const mockedFetchLinkPreviews = vi.mocked(fetchLinkPreviews)

describe('RichContent', () => {
  beforeEach(() => {
    mockedFetchLinkPreviews.mockReset()
    mockedFetchLinkPreviews.mockResolvedValue({})
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  it('returns null when text is empty', () => {
    const container = document.createElement('div')
    render(h(RichContent, { text: '' }), container)
    expect(container.firstElementChild).toBeNull()
  })

  it('renders markdown for non-empty text', () => {
    const container = document.createElement('div')
    render(h(RichContent, { text: 'hello world' }), container)
    expect(container.textContent).toContain('hello world')
  })

  it('calls fetchLinkPreviews when URLs are present', async () => {
    const container = document.createElement('div')
    render(h(RichContent, { text: 'Check out https://example.com' }), container)
    await waitFor(() => expect(mockedFetchLinkPreviews).toHaveBeenCalled())
    const urls = mockedFetchLinkPreviews.mock.calls[0]?.[0] as string[]
    expect(urls).toContain('https://example.com')
    render(null, container)
  })

  it('does not call fetchLinkPreviews when no URLs are present', async () => {
    const container = document.createElement('div')
    render(h(RichContent, { text: 'plain text without links' }), container)
    await new Promise((r) => setTimeout(r, 10))
    expect(mockedFetchLinkPreviews).not.toHaveBeenCalled()
    render(null, container)
  })

  it('renders preview cards when fetch returns data', async () => {
    mockedFetchLinkPreviews.mockResolvedValue({
      'https://example.com': {
        url: 'https://example.com',
        canonical_url: 'https://example.com',
        title: 'Example',
        site_name: 'Example Site',
        description: 'An example site',
        image_url: null,
        favicon_url: null,
        kind: 'article',
      },
    })
    const container = document.createElement('div')
    render(h(RichContent, { text: 'See https://example.com' }), container)
    await waitFor(() => expect(container.textContent).toContain('Example'))
    render(null, container)
  })

  it('respects previewLimit', async () => {
    const container = document.createElement('div')
    render(
      h(RichContent, {
        text: 'A https://a.com B https://b.com C https://c.com',
        previewLimit: 2,
      }),
      container,
    )
    await waitFor(() => expect(mockedFetchLinkPreviews).toHaveBeenCalled())
    const urls = mockedFetchLinkPreviews.mock.calls[0]?.[0] as string[]
    expect(urls.length).toBeLessThanOrEqual(2)
    render(null, container)
  })

  it('applies custom class', () => {
    const container = document.createElement('div')
    render(h(RichContent, { text: 'hello', class: 'rich-class' }), container)
    expect(container.querySelector('.rich-class')).not.toBeNull()
  })

  it('extracts URLs excluding markdown images', async () => {
    const container = document.createElement('div')
    render(
      h(RichContent, {
        text: '![alt](https://img.com/pic.png) and https://link.com',
      }),
      container,
    )
    await waitFor(() => expect(mockedFetchLinkPreviews).toHaveBeenCalled())
    const urls = mockedFetchLinkPreviews.mock.calls[0]?.[0] as string[]
    expect(urls).toContain('https://link.com')
    expect(urls).not.toContain('https://img.com/pic.png')
    render(null, container)
  })

  it('renders standalone video URLs as playable media instead of link cards', async () => {
    const container = document.createElement('div')
    render(h(RichContent, { text: 'https://cdn.example.com/demo.mp4' }), container)
    const video = container.querySelector('video') as HTMLVideoElement | null
    expect(video?.getAttribute('src')).toBe('https://cdn.example.com/demo.mp4')
    expect(video?.hasAttribute('controls')).toBe(true)
    await new Promise((r) => setTimeout(r, 10))
    expect(mockedFetchLinkPreviews).not.toHaveBeenCalled()
    render(null, container)
  })

  it('renders standalone YouTube URLs as safe iframe embeds', async () => {
    const container = document.createElement('div')
    render(h(RichContent, { text: 'https://youtu.be/dQw4w9WgXcQ' }), container)
    const frame = container.querySelector('iframe') as HTMLIFrameElement | null
    expect(frame?.getAttribute('src')).toBe('https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ')
    expect(frame?.getAttribute('referrerpolicy')).toBe('strict-origin-when-cross-origin')
    await new Promise((r) => setTimeout(r, 10))
    expect(mockedFetchLinkPreviews).not.toHaveBeenCalled()
    render(null, container)
  })
})
