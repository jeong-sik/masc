import { h } from 'preact'
import { act, cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

// Keep the test graph focused: the size formatter is a display detail.
vi.mock('./composer-v2', () => ({
  formatFileSize: (bytes: number) => `${bytes} B`,
}))
vi.mock('../../api/tool-blob', () => ({ fetchToolBlobBytes: vi.fn() }))

import { PostAttachments } from './post-attachments'
import { fetchToolBlobBytes } from '../../api/tool-blob'
import type { BoardAttachmentKind, BoardAttachmentDecode } from '../../types'

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  vi.clearAllMocks()
})

function attachment(overrides: {
  kind?: BoardAttachmentKind
  url?: string
  name?: string
  sizeBytes?: number
  width?: number | null
  height?: number | null
}): BoardAttachmentDecode {
  return {
    ok: true,
    attachment: {
      kind: overrides.kind ?? 'image',
      source: {
        kind: 'url',
        url: overrides.url ?? 'https://cdn.example.com/a.png',
        name: overrides.name ?? 'a.png',
        sizeBytes: overrides.sizeBytes ?? 128,
        width: overrides.width ?? 640,
        height: overrides.height ?? 480,
      },
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
            url: 'https://cdn.example.com/b.mp4',
            name: 'b.mp4',
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
            url: 'https://www.youtube.com/watch?v=abc123def45',
            name: 'demo',
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
            url: 'https://example.com/spec',
            name: 'spec',
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
        attachments: [attachment({ url: 'javascript:alert(1)' })],
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

  it('fetches artifact bytes with auth before offering a download', async () => {
    const sha256 = 'a'.repeat(64)
    const NativeURL = URL
    const objectUrl = 'blob:board-attachment'
    const createObjectURL = vi.fn(() => objectUrl)
    const revokeObjectURL = vi.fn()
    vi.stubGlobal('URL', class extends NativeURL {
      static createObjectURL = createObjectURL
      static revokeObjectURL = revokeObjectURL
    })
    const binary = new ArrayBuffer(3)
    new Uint8Array(binary).set([0, 255, 42])
    vi.mocked(fetchToolBlobBytes).mockResolvedValue(binary)
    const { unmount } = render(h(PostAttachments, { attachments: [{
      ok: true,
      attachment: { kind: 'external_link', source: {
        kind: 'artifact', sha256, bytes: 12, mime: 'application/octet-stream',
      } },
    }] }))
    const card = screen.getByTestId('board-attachment-artifact')
    expect(card.querySelector('a')).toBeNull()
    fireEvent.click(card.querySelector('button')!)
    const link = await screen.findByTestId('board-attachment-artifact-download')
    expect(fetchToolBlobBytes).toHaveBeenCalledWith(sha256, {
      signal: expect.any(AbortSignal),
    })
    expect(link).toHaveAttribute('href', objectUrl)
    expect(link).toHaveAttribute('download', `artifact-${sha256}.bin`)
    expect(createObjectURL).toHaveBeenCalledOnce()
    expect(document.querySelector('img')).toBeNull()
    unmount()
    expect(revokeObjectURL).toHaveBeenCalledWith(objectUrl)
  })

  function stubObjectUrls(objectUrl: string) {
    const NativeURL = URL
    vi.stubGlobal('URL', class extends NativeURL {
      static createObjectURL = vi.fn(() => objectUrl)
      static revokeObjectURL = vi.fn()
    })
  }

  function renderArtifact(kind: BoardAttachmentKind) {
    render(h(PostAttachments, { attachments: [{
      ok: true,
      attachment: { kind, source: {
        kind: 'artifact', sha256: 'b'.repeat(64), bytes: 3, mime: 'application/octet-stream',
      } },
    }] }))
    fireEvent.click(screen.getByTestId('board-attachment-artifact').querySelector('button')!)
  }

  it('previews an image artifact once loaded and keeps the download link', async () => {
    stubObjectUrls('blob:artifact-image')
    vi.mocked(fetchToolBlobBytes).mockResolvedValue(new ArrayBuffer(3))
    renderArtifact('image')
    const image = await screen.findByTestId('board-attachment-artifact-image')
    expect(image.tagName).toBe('IMG')
    expect(image).toHaveAttribute('src', 'blob:artifact-image')
    expect(screen.getByTestId('board-attachment-artifact-download'))
      .toHaveAttribute('href', 'blob:artifact-image')
    expect(document.querySelector('video')).toBeNull()
  })

  it('previews a video artifact as a video element', async () => {
    stubObjectUrls('blob:artifact-video')
    vi.mocked(fetchToolBlobBytes).mockResolvedValue(new ArrayBuffer(3))
    renderArtifact('video')
    const video = await screen.findByTestId('board-attachment-artifact-video')
    expect(video.tagName).toBe('VIDEO')
    expect(video).toHaveAttribute('src', 'blob:artifact-video')
    expect(document.querySelector('img')).toBeNull()
  })

  it('falls back to the download when the bytes are not what kind claims', async () => {
    stubObjectUrls('blob:artifact-not-an-image')
    vi.mocked(fetchToolBlobBytes).mockResolvedValue(new ArrayBuffer(3))
    renderArtifact('image')
    fireEvent.error(await screen.findByTestId('board-attachment-artifact-image'))
    expect(await screen.findByTestId('board-attachment-artifact-preview-failed')).toBeInTheDocument()
    expect(screen.queryByTestId('board-attachment-artifact-image')).toBeNull()
    expect(screen.getByTestId('board-attachment-artifact-download'))
      .toHaveAttribute('href', 'blob:artifact-not-an-image')
  })

  it('shows an artifact read failure instead of a broken link', async () => {
    vi.mocked(fetchToolBlobBytes).mockRejectedValue(new Error('403 Forbidden'))
    render(h(PostAttachments, { attachments: [{
      ok: true,
      attachment: { kind: 'image', source: {
        kind: 'artifact', sha256: 'a'.repeat(64), bytes: 12, mime: 'application/octet-stream',
      } },
    }] }))
    fireEvent.click(screen.getByTestId('board-attachment-artifact').querySelector('button')!)
    const error = await screen.findByTestId('board-attachment-error')
    expect(error.textContent).toContain('403 Forbidden')
    expect(screen.queryByTestId('board-attachment-artifact-download')).toBeNull()
  })

  it('does not create a Blob URL after the attachment unmounts during a fetch', async () => {
    const NativeURL = URL
    const createObjectURL = vi.fn(() => 'blob:late')
    vi.stubGlobal('URL', class extends NativeURL {
      static createObjectURL = createObjectURL
      static revokeObjectURL = vi.fn()
    })
    let resolveFetch!: (bytes: ArrayBuffer) => void
    const pending = new Promise<ArrayBuffer>(resolve => { resolveFetch = resolve })
    vi.mocked(fetchToolBlobBytes).mockReturnValue(pending)
    const { unmount } = render(h(PostAttachments, { attachments: [{
      ok: true,
      attachment: { kind: 'image', source: {
        kind: 'artifact', sha256: 'a'.repeat(64), bytes: 12, mime: 'application/octet-stream',
      } },
    }] }))
    fireEvent.click(screen.getByTestId('board-attachment-artifact').querySelector('button')!)
    unmount()
    await act(async () => {
      resolveFetch(new ArrayBuffer(1))
      await pending
    })
    expect(createObjectURL).not.toHaveBeenCalled()
  })

  it('renders nothing when the attachments list is empty', () => {
    const { container } = render(h(PostAttachments, { attachments: [] }))
    expect(container.querySelector('[data-testid="board-attachments"]')).toBeNull()
  })
})
