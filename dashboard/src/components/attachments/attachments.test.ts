// @vitest-environment jsdom

import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  decodeAttachmentRef,
  dedupeAttachments,
  uploadAttachment,
  type AttachmentRef,
} from '../../api/attachments'
import { clearStoredToken, setStoredToken } from '../../api/core'
import { currentSessionEpoch } from '../../core/auth'
import { ok, err } from '../../lib/result'
import { MarkdownContent } from '../common/markdown-renderer'
import { WorkspaceChatImage } from '../chat/workspace-image'
import {
  AttachmentComposer,
  AttachmentGallery,
  ATTACHMENT_INPUT_ACCEPT,
  DEFAULT_MAX_ATTACHMENT_BYTES,
  readyAttachmentsOf,
  resolveAttachmentMimeType,
  validateAttachmentFile,
  type ComposerAttachmentItem,
} from './index'

const PNG_BYTES = Uint8Array.from(
  atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII='),
  (c) => c.charCodeAt(0),
)
const ATT_SHA_A = 'a'.repeat(64)
const ATT_ID_A = `att_${ATT_SHA_A}`
const ATT_URL_A = `/api/v1/attachments/${ATT_ID_A}`
const ATT_SHA_B = 'b'.repeat(64)
const ATT_ID_B = `att_${ATT_SHA_B}`
const ATT_URL_B = `/api/v1/attachments/${ATT_ID_B}`

function makeAttachmentRef(overrides: Partial<AttachmentRef> = {}): AttachmentRef {
  return {
    id: ATT_ID_A,
    attachment_id: ATT_ID_A,
    sha256: ATT_SHA_A,
    url: ATT_URL_A,
    mime_type: 'image/png',
    kind: 'image',
    bytes: 4096,
    width: 1280,
    height: 720,
    filename: 'screenshot.png',
    origin: 'tool_capture',
    ...overrides,
  }
}

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  clearStoredToken()
})

describe('attachment validation & boundary decoders', () => {
  it('validates allowed image/pdf/audio types matching exact server sniff_mime set and rejects SVG, HTML, empty, and oversized files', () => {
    const exactServerMimes = [
      'image/png',
      'image/jpeg',
      'image/webp',
      'image/gif',
      'application/pdf',
      'audio/mpeg',
      'audio/wav',
      'audio/ogg',
      'audio/midi',
      'audio/mp4',
      'audio/webm',
    ]
    for (const mime of exactServerMimes) {
      expect(validateAttachmentFile({ name: `sample.${mime.split('/')[1]}`, type: mime, size: 1024 })).toBeNull()
    }
    expect(validateAttachmentFile({ name: 'fallback.webp', type: '', size: 100 })).toBeNull()
    expect(validateAttachmentFile({ name: 'voice.m4a', type: '', size: 100 })).toBeNull()
    expect(validateAttachmentFile({ name: 'clip.webm', type: '', size: 100 })).toBeNull()
    expect(resolveAttachmentMimeType({ name: 'renamed.png', type: 'application/x-msdownload' })).toBe('application/x-msdownload')

    expect(validateAttachmentFile({ name: 'xss.svg', type: 'image/svg+xml', size: 100 })).toContain('보안상')
    expect(validateAttachmentFile({ name: 'page.html', type: 'text/html', size: 100 })).toContain('보안상')
    expect(validateAttachmentFile({ name: 'empty.png', type: 'image/png', size: 0 })).toContain('빈 파일')
    expect(validateAttachmentFile({ name: 'huge.png', type: 'image/png', size: DEFAULT_MAX_ATTACHMENT_BYTES + 1 })).toContain('초과')
  })

  it('decodes canonical AttachmentRef and rejects external or protocol-relative URLs', () => {
    const decoded = decodeAttachmentRef({
      id: ATT_ID_A,
      attachment_id: ATT_ID_A,
      sha256: ATT_SHA_A,
      url: ATT_URL_A,
      mime_type: 'image/png',
      kind: 'image',
      bytes: 1234,
      width: 640,
      height: 480,
      filename: 'shot.png',
      origin: 'tool_capture',
    })
    expect(decoded).toMatchObject({
      id: ATT_ID_A,
      attachment_id: ATT_ID_A,
      url: ATT_URL_A,
      width: 640,
      height: 480,
      filename: 'shot.png',
    })

    expect(decodeAttachmentRef({ url: 'https://evil.example/img.png', mime_type: 'image/png' })).toBeNull()
    expect(decodeAttachmentRef({ url: `//evil.example${ATT_URL_A}`, mime_type: 'image/png' })).toBeNull()
    expect(decodeAttachmentRef({ url: '/api/v1/attachments/not-valid', mime_type: 'image/png' })).toBeNull()
  })

  it('deduplicates attachments by attachment_id while merging richer metadata', () => {
    const sparse = decodeAttachmentRef({ t: 'attachment', attachment_id: ATT_ID_A, url: ATT_URL_A, mime_type: 'image/png', kind: 'image' })!
    const rich = makeAttachmentRef()
    const merged = dedupeAttachments([sparse, rich])
    expect(merged).toHaveLength(1)
    expect(merged[0]).toMatchObject({ width: 1280, height: 720, filename: 'screenshot.png', bytes: 4096 })
  })

  it('uploads raw binary to POST /api/v1/attachments with Content-Type, encoded X-Filename, and Bearer auth', async () => {
    setStoredToken('secret-token-123', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const ref = makeAttachmentRef({ filename: '화면캡처.png' })
    const fetchMock = vi.fn<typeof fetch>(async () =>
      new Response(JSON.stringify({ ok: true, data: ref }), {
        status: 201,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    const file = new File([PNG_BYTES], '화면캡처.png', { type: 'image/png' })
    const res = await uploadAttachment(file, { fetchImpl: fetchMock })
    expect(res.ok).toBe(true)
    if (res.ok) expect(res.value.attachment_id).toBe(ATT_ID_A)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]!
    expect(String(url)).toBe('/api/v1/attachments')
    expect(init?.method).toBe('POST')
    const headers = init?.headers as Record<string, string>
    expect(headers['Content-Type']).toBe('image/png')
    expect(headers.Authorization).toBe('Bearer secret-token-123')
    expect(headers['X-Filename']).toBe(encodeURIComponent('화면캡처.png'))
  })
})

describe('<AttachmentComposer>', () => {
  function Harness({
    uploadImpl,
    onError,
  }: {
    readonly uploadImpl: typeof uploadAttachment
    readonly onError?: (m: string) => void
  }) {
    const [items, setItems] = useState<readonly ComposerAttachmentItem[]>([])
    return html`
      <div>
        <${AttachmentComposer}
          items=${items}
          onChange=${setItems}
          uploadImpl=${uploadImpl}
          onError=${onError}
        >
          <textarea aria-label="입력창" />
        <//>
        <div data-testid="ready-count">${readyAttachmentsOf(items).length}</div>
      </div>
    `
  }

  it('handles file picker accept attribute, clipboard paste, drag-and-drop, retry, and remove', async () => {
    const refA = makeAttachmentRef({ id: ATT_ID_A, attachment_id: ATT_ID_A, url: ATT_URL_A, filename: 'pasted.png' })
    const refB = makeAttachmentRef({ id: ATT_ID_B, attachment_id: ATT_ID_B, url: ATT_URL_B, filename: 'dropped.pdf', kind: 'document', mime_type: 'application/pdf' })
    const uploadMock = vi.fn<typeof uploadAttachment>()
      .mockResolvedValueOnce(ok(refA))
      .mockResolvedValueOnce(err({ kind: 'server', status: 500, code: 'err', message: '서버 일시 오류', retryable: true }))
      .mockResolvedValueOnce(ok(refB))

    const onError = vi.fn()
    const view = render(html`<${Harness} uploadImpl=${uploadMock} onError=${onError} />`)

    const fileInput = view.getByTestId('attachment-file-input') as HTMLInputElement
    expect(fileInput.getAttribute('accept')).toBe(ATTACHMENT_INPUT_ACCEPT)

    // 1. Clipboard paste of an image uploads immediately and shows thumbnail chip
    const pastedFile = new File([PNG_BYTES], 'pasted.png', { type: 'image/png' })
    const composerZone = view.getByTestId('attachment-composer')
    fireEvent.paste(composerZone, {
      clipboardData: {
        items: [{ kind: 'file', getAsFile: () => pastedFile }],
        files: [pastedFile],
      },
    })

    await waitFor(() => {
      expect(view.getByTestId('ready-count').textContent).toBe('1')
    })
    expect(view.getByText('pasted.png')).toBeTruthy()

    // 2. Drag-and-drop highlights drop zone, surfaces upload error, and recovers via Retry button
    fireEvent.dragEnter(composerZone, { dataTransfer: { types: ['Files'] } })
    expect(composerZone.getAttribute('data-drag-over')).toBe('true')
    expect(view.getByTestId('attachment-drop-overlay')).toBeTruthy()

    const droppedPdf = new File([new Uint8Array([0x25, 0x50, 0x44, 0x46])], 'dropped.pdf', { type: 'application/pdf' })
    fireEvent.drop(composerZone, {
      dataTransfer: {
        items: [{ kind: 'file', getAsFile: () => droppedPdf }],
        files: [droppedPdf],
      },
    })
    expect(composerZone.getAttribute('data-drag-over')).toBe('false')

    const retryBtn = await view.findByRole('button', { name: 'dropped.pdf 재시도' })
    expect(onError).toHaveBeenCalled()
    fireEvent.click(retryBtn)

    await waitFor(() => {
      expect(view.getByTestId('ready-count').textContent).toBe('2')
    })

    // 3. Remove chip decrements ready count
    fireEvent.click(view.getByRole('button', { name: 'pasted.png 첨부 제거' }))
    expect(view.getByTestId('ready-count').textContent).toBe('1')
  })
})

describe('<WorkspaceChatImage>, <AttachmentGallery>, and Markdown hydration', () => {
  it('fetches ?max_px=640 thumbnail for /api/v1/attachments/*, upgrades in lightbox, downloads ?download=1, and copies ID/URL', async () => {
    vi.stubGlobal('IntersectionObserver', undefined)
    setStoredToken('tok-view-1', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const requestedUrls: string[] = []
    const requestedAuth: Array<string | undefined> = []
    const fetchMock = vi.fn<typeof fetch>(async (input, init) => {
      requestedUrls.push(String(input))
      const hdrs = init?.headers as Record<string, string> | undefined
      requestedAuth.push(hdrs?.Authorization)
      return new Response(PNG_BYTES, { status: 200, headers: { 'Content-Type': 'image/png' } })
    })
    vi.stubGlobal('fetch', fetchMock)

    const createObjectURL = vi.fn(() => 'blob:mock-download')
    const revokeObjectURL = vi.fn()
    vi.stubGlobal('URL', Object.assign(URL, { createObjectURL, revokeObjectURL }))
    const writeText = vi.fn(async () => undefined)
    vi.stubGlobal('navigator', { ...navigator, clipboard: { writeText } })

    const att = makeAttachmentRef()
    const view = render(html`
      <${WorkspaceChatImage}
        path=${att.url}
        caption="브라우저 캡처"
        attachment=${att}
        workspaceEpoch=${currentSessionEpoch()}
      />
    `)

    await view.findByRole('img', { name: '브라우저 캡처' })
    expect(requestedUrls[0]).toBe(`${window.location.origin}${ATT_URL_A}?max_px=640`)
    expect(requestedAuth[0]).toBe('Bearer tok-view-1')

    // Open lightbox modal
    fireEvent.click(view.getByRole('button', { name: '브라우저 캡처 크게 보기' }))
    const dialog = document.querySelector('[role="dialog"][aria-modal="true"]')
    expect(dialog).not.toBeNull()
    expect(dialog?.textContent).toContain('1280×720')
    expect(dialog?.textContent).toContain('image/png')
    expect(dialog?.textContent).toContain('도구 캡처')

    // Full-res upgrade request fires without max_px
    await waitFor(() => {
      expect(requestedUrls).toContain(`${window.location.origin}${ATT_URL_A}`)
    })

    // Download button triggers authenticated ?download=1 fetch
    fireEvent.click(view.getByRole('button', { name: '다운로드' }))
    await waitFor(() => {
      expect(requestedUrls).toContain(`${window.location.origin}${ATT_URL_A}?download=1`)
    })

    // Copy ID button copies attachment_id
    fireEvent.click(view.getByRole('button', { name: 'ID 복사' }))
    await waitFor(() => {
      expect(writeText).toHaveBeenCalledWith(ATT_ID_A)
    })
  })

  it('renders audio player card and document download card in <AttachmentGallery>', async () => {
    vi.stubGlobal('IntersectionObserver', undefined)
    const fetchMock = vi.fn<typeof fetch>(async () =>
      new Response(new Uint8Array([1, 2, 3, 4]), { status: 200, headers: { 'Content-Type': 'audio/wav' } }),
    )
    vi.stubGlobal('fetch', fetchMock)
    const createObjectURL = vi.fn(() => 'blob:mock-audio')
    const revokeObjectURL = vi.fn()
    vi.stubGlobal('URL', Object.assign(URL, { createObjectURL, revokeObjectURL }))

    const audioAtt = makeAttachmentRef({
      id: ATT_ID_A,
      attachment_id: ATT_ID_A,
      url: ATT_URL_A,
      kind: 'audio',
      mime_type: 'audio/wav',
      filename: 'voice.wav',
      bytes: 8192,
      width: null,
      height: null,
    })
    const docAtt = makeAttachmentRef({
      id: ATT_ID_B,
      attachment_id: ATT_ID_B,
      url: ATT_URL_B,
      kind: 'document',
      mime_type: 'application/pdf',
      filename: 'spec.pdf',
      bytes: 16384,
      width: null,
      height: null,
    })

    const view = render(html`
      <${AttachmentGallery} attachments=${[audioAtt, docAtt]} workspaceEpoch=${currentSessionEpoch()} />
    `)

    expect(view.getByTestId('attachment-audio-card')).toBeTruthy()
    expect(view.getByTestId('attachment-document-card')).toBeTruthy()
    expect(view.getByText('spec.pdf')).toBeTruthy()

    fireEvent.click(view.getByRole('button', { name: '재생 불러오기' }))
    await waitFor(() => {
      const audioEl = view.container.querySelector('audio')
      expect(audioEl).not.toBeNull()
      expect(audioEl?.getAttribute('src')).toBe('blob:mock-audio')
    })
  })

  it('hydrates same-origin /api/v1/attachments/* images inside MarkdownContent under Bearer auth', async () => {
    setStoredToken('md-bearer-tok', { source: 'dev', actor: 'dashboard', role: 'admin' })
    const fetchMock = vi.fn<typeof fetch>(async () =>
      new Response(PNG_BYTES, { status: 200, headers: { 'Content-Type': 'image/png' } }),
    )
    vi.stubGlobal('fetch', fetchMock)
    const createObjectURL = vi.fn(() => 'blob:hydrated-md-img')
    const revokeObjectURL = vi.fn()
    vi.stubGlobal('URL', Object.assign(URL, { createObjectURL, revokeObjectURL }))

    const view = render(html`<${MarkdownContent} text=${`![차트](${ATT_URL_A})`} />`)

    await waitFor(() => {
      const img = view.container.querySelector('img')
      expect(img?.getAttribute('src')).toBe('blob:hydrated-md-img')
    })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]!
    expect(String(url)).toBe(`${window.location.origin}${ATT_URL_A}?max_px=640`)
    expect((init?.headers as Record<string, string>)?.Authorization).toBe('Bearer md-bearer-tok')
  })

  it('surfaces download failure errors on both lightbox and audio attachment cards', async () => {
    vi.stubGlobal('IntersectionObserver', undefined)
    const fetchMock = vi.fn<typeof fetch>(async (input) => {
      const url = new URL(String(input), window.location.origin)
      if (url.searchParams.get('download') === '1') {
        return new Response('download forbidden', { status: 403 })
      }
      return new Response(PNG_BYTES, { status: 200, headers: { 'Content-Type': 'image/png' } })
    })
    vi.stubGlobal('fetch', fetchMock)

    const imgAtt = makeAttachmentRef()
    const audioAtt = makeAttachmentRef({
      id: ATT_ID_B,
      attachment_id: ATT_ID_B,
      url: ATT_URL_B,
      kind: 'audio',
      mime_type: 'audio/mp4',
      filename: 'note.m4a',
      width: null,
      height: null,
    })

    const view = render(html`
      <${AttachmentGallery} attachments=${[imgAtt, audioAtt]} workspaceEpoch=${currentSessionEpoch()} />
    `)

    // 1. Lightbox image download failure surfaces alert inside preview modal
    await view.findByRole('img', { name: 'screenshot.png' })
    fireEvent.click(view.getByRole('button', { name: 'screenshot.png 크게 보기' }))
    const dialog = document.querySelector('[role="dialog"][aria-modal="true"]') as HTMLElement
    expect(dialog).not.toBeNull()
    const lightboxDownloadBtn = Array.from(dialog.querySelectorAll('button')).find(
      (b) => b.textContent?.trim() === '다운로드',
    ) as HTMLButtonElement
    fireEvent.click(lightboxDownloadBtn)

    await waitFor(() => {
      const errBanner = dialog.querySelector('[data-testid="lightbox-download-error"]')
      expect(errBanner?.getAttribute('role')).toBe('alert')
      expect(errBanner?.textContent).toContain('403')
    })

    // 2. Audio card download failure surfaces alert on the audio card
    const audioCard = view.getByTestId('attachment-audio-card')
    const audioDownloadBtn = Array.from(audioCard.querySelectorAll('button')).find(
      (b) => b.textContent?.trim() === '다운로드',
    ) as HTMLButtonElement
    fireEvent.click(audioDownloadBtn)

    await waitFor(() => {
      const audioAlert = audioCard.querySelector('[role="alert"]')
      expect(audioAlert).not.toBeNull()
      expect(audioAlert?.textContent).toContain('403')
    })
  })
})
