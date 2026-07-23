import { h } from 'preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

// Keep the test graph focused: the size formatter is a display detail.
vi.mock('./composer-v2', () => ({
  formatFileSize: (bytes: number) => `${bytes} B`,
}))

import { PostAttachments } from './post-attachments'
import type { BoardAttachment, BoardAttachmentDecode } from '../../types'

afterEach(() => {
  cleanup()
})

function attachment(overrides: Partial<BoardAttachment>): BoardAttachmentDecode {
  return {
    ok: true,
    attachment: {
      id: 'a-1',
      kind: 'image',
      origin_url: 'https://cdn.example.com/a.png',
      origin_name: 'a.png',
      origin_size_bytes: 128,
      mime_type: 'image/png',
      width: 640,
      height: 480,
      created_at: 1_714_989_600,
      ...overrides,
    },
  }
}

describe('PostAttachments', () => {
  it('renders an image attachment with src, alt and dimensions', () => {
    render(h(PostAttachments, { attachments: [attachment({})] }))
    const img = screen.getByTestId('board-attachment-image').querySelector('img')
    expect(img).not.toBeNull()
    expect(img).toHaveAttribute('src', 'https://cdn.example.com/a.png')
    expect(img).toHaveAttribute('alt', 'a.png')
    expect(img).toHaveAttribute('width', '640')
    expect(img).toHaveAttribute('height', '480')
  })

  it('renders a video attachment as a video element', () => {
    render(
      h(PostAttachments, {
        attachments: [
          attachment({
            kind: 'video',
            origin_url: 'https://cdn.example.com/b.mp4',
            origin_name: 'b.mp4',
            mime_type: 'video/mp4',
          }),
        ],
      }),
    )
    const video = screen.getByTestId('board-attachment-video').querySelector('video')
    expect(video).not.toBeNull()
    expect(video).toHaveAttribute('src', 'https://cdn.example.com/b.mp4')
    expect(video).toHaveAttribute('controls')
  })

  it('renders a youtube attachment as a nocookie embed iframe', () => {
    render(
      h(PostAttachments, {
        attachments: [
          attachment({
            kind: 'youtube',
            origin_url: 'https://www.youtube.com/watch?v=abc123def45',
            origin_name: 'demo',
            mime_type: 'text/uri-list',
          }),
        ],
      }),
    )
    const iframe = screen.getByTestId('board-attachment-youtube').querySelector('iframe')
    expect(iframe).not.toBeNull()
    expect(iframe).toHaveAttribute(
      'src',
      'https://www.youtube-nocookie.com/embed/abc123def45',
    )
  })

  it('renders an external_link attachment as a card linking out', () => {
    render(
      h(PostAttachments, {
        attachments: [
          attachment({
            kind: 'external_link',
            origin_url: 'https://example.com/spec',
            origin_name: 'spec',
            mime_type: 'text/uri-list',
          }),
        ],
      }),
    )
    const anchor = screen.getByTestId('board-attachment-link')
    expect(anchor).toHaveAttribute('href', 'https://example.com/spec')
    expect(anchor).toHaveAttribute('target', '_blank')
    expect(anchor).toHaveAttribute('rel', expect.stringContaining('noopener'))
    expect(anchor.textContent).toContain('spec')
    expect(anchor.textContent).toContain('example.com')
  })

  it('renders decode failures as explicit error cards, never skipped', () => {
    const entries: BoardAttachmentDecode[] = [
      { ok: false, raw: { kind: 'hologram', id: 'a-bad' } },
      { ok: false, raw: 'not-an-object' },
    ]
    render(h(PostAttachments, { attachments: entries }))
    const errors = screen.getAllByTestId('board-attachment-error')
    expect(errors).toHaveLength(2)
    expect(errors[0]!.textContent).toContain('첨부 메타데이터가 올바르지 않습니다')
    expect(errors[0]!.textContent).toContain('kind=hologram')
    expect(errors[1]!.textContent).toContain('첨부 메타데이터가 객체가 아닙니다')
  })

  it('refuses to render unsafe attachment URLs and says so explicitly', () => {
    render(
      h(PostAttachments, {
        attachments: [attachment({ origin_url: 'javascript:alert(1)' })],
      }),
    )
    const error = screen.getByTestId('board-attachment-error')
    expect(error.textContent).toContain('안전하지 않은 첨부 URL')
    expect(document.querySelector('img')).toBeNull()
  })

  it('shows an explicit failure card with a source link when an image fails to load', () => {
    render(h(PostAttachments, { attachments: [attachment({})] }))
    const img = screen.getByTestId('board-attachment-image').querySelector('img')!
    fireEvent.error(img)
    const error = screen.getByTestId('board-attachment-error')
    expect(error.textContent).toContain('이미지를 불러오지 못했습니다')
    const link = error.querySelector('a')
    expect(link).toHaveAttribute('href', 'https://cdn.example.com/a.png')
  })

  it('renders nothing when the attachments list is empty', () => {
    const { container } = render(h(PostAttachments, { attachments: [] }))
    expect(container.querySelector('[data-testid="board-attachments"]')).toBeNull()
  })
})
