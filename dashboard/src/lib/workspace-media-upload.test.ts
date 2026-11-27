import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  authSession,
  bumpSessionEpoch,
  registerWorkspaceTargets,
  selectWorkspace,
  setSingleUserToken,
  wipeTransientSecrets,
} from '../core/auth'
import {
  WORKSPACE_MEDIA_UPLOAD_PATH,
  dataTransferHasFiles,
  decodeUploadedMediaReceipt,
  deriveImageAltText,
  extractUploadFilesFromDataTransfer,
  formatUploadedImageMarkdown,
  insertTextAtSelection,
  parseDeclaredRasterMime,
  sniffMediaBytes,
  uploadWorkspaceMedia,
  validateWorkspaceMediaFile,
} from './workspace-media-upload'

const VALID_SHA = 'a'.repeat(64)
const PNG_BYTES = new Uint8Array([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
])
const JPEG_BYTES = new Uint8Array([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
const GIF_BYTES = new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00])
const WEBP_BYTES = new Uint8Array([
  0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00,
  0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20,
])
const SVG_BYTES = new TextEncoder().encode('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>')
const XML_BOM_SVG_BYTES = new Uint8Array([
  0xEF, 0xBB, 0xBF,
  ...new TextEncoder().encode('  <?xml version="1.0"?><svg></svg>'),
])

function jsonResponse(body: unknown, status = 201): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

const DEFAULT_AUTH_METHODS = { google: false, github: false, dev_token: true } as const

describe('workspace-media-upload', () => {
  beforeEach(() => {
    wipeTransientSecrets()
    registerWorkspaceTargets([{ id: 'default', label: 'Default Workspace' }])
    selectWorkspace('default')
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      role: 'admin',
      canTokenAdmin: true,
      canTokenRead: true,
      authMethods: DEFAULT_AUTH_METHODS,
      workspaceId: 'default',
    }
    setSingleUserToken('masc-test-admin-token')
  })

  afterEach(() => {
    wipeTransientSecrets()
    vi.restoreAllMocks()
  })

  describe('sniffMediaBytes & parseDeclaredRasterMime', () => {
    it('sniffs PNG, JPEG, GIF, WebP and rejects SVG/XML and arbitrary payloads', () => {
      expect(sniffMediaBytes(PNG_BYTES)).toEqual({ kind: 'raster', mime: 'image/png' })
      expect(sniffMediaBytes(JPEG_BYTES)).toEqual({ kind: 'raster', mime: 'image/jpeg' })
      expect(sniffMediaBytes(GIF_BYTES)).toEqual({ kind: 'raster', mime: 'image/gif' })
      expect(sniffMediaBytes(WEBP_BYTES)).toEqual({ kind: 'raster', mime: 'image/webp' })
      expect(sniffMediaBytes(SVG_BYTES)).toEqual({ kind: 'svg' })
      expect(sniffMediaBytes(XML_BOM_SVG_BYTES)).toEqual({ kind: 'svg' })
      expect(sniffMediaBytes(new TextEncoder().encode('plain text'))).toEqual({ kind: 'unknown' })
    })

    it('normalizes image/jpg alias and strictly returns null for unsupported MIMEs', () => {
      expect(parseDeclaredRasterMime('image/png; charset=binary')).toBe('image/png')
      expect(parseDeclaredRasterMime('image/jpg')).toBe('image/jpeg')
      expect(parseDeclaredRasterMime('image/svg+xml')).toBe('svg')
      expect(parseDeclaredRasterMime('application/pdf')).toBeNull()
      expect(parseDeclaredRasterMime('')).toBeNull()
    })
  })

  describe('validateWorkspaceMediaFile', () => {
    it('accepts valid raster bytes matching declared MIME or omitted browser MIME', async () => {
      const pngFile = new File([PNG_BYTES], 'diagram.png', { type: 'image/png' })
      expect(await validateWorkspaceMediaFile(pngFile)).toEqual({ ok: true, value: 'image/png' })

      const jpegAlias = new File([JPEG_BYTES], 'photo.jpg', { type: 'image/jpg' })
      expect(await validateWorkspaceMediaFile(jpegAlias)).toEqual({ ok: true, value: 'image/jpeg' })

      const emptyMimePng = new File([PNG_BYTES], 'clipboard.png', { type: '' })
      expect(await validateWorkspaceMediaFile(emptyMimePng)).toEqual({ ok: true, value: 'image/png' })
    })

    it('rejects empty files, oversized files, SVG payloads, and MIME mismatches before network', async () => {
      const empty = new File([], 'empty.png', { type: 'image/png' })
      const emptyRes = await validateWorkspaceMediaFile(empty)
      expect(emptyRes.ok).toBe(false)
      if (!emptyRes.ok) expect(emptyRes.error.kind).toBe('empty_upload')

      const oversized = new File([PNG_BYTES], 'big.png', { type: 'image/png' })
      const sizeRes = await validateWorkspaceMediaFile(oversized, { maxBytes: 8 })
      expect(sizeRes.ok).toBe(false)
      if (!sizeRes.ok) {
        expect(sizeRes.error.kind).toBe('media_too_large')
        expect(sizeRes.error.maxBytes).toBe(8)
        expect(sizeRes.error.sizeBytes).toBe(PNG_BYTES.byteLength)
      }

      const svgDeclared = new File([SVG_BYTES], 'xss.svg', { type: 'image/svg+xml' })
      const svgRes1 = await validateWorkspaceMediaFile(svgDeclared)
      expect(svgRes1.ok).toBe(false)
      if (!svgRes1.ok) expect(svgRes1.error.kind).toBe('svg_not_allowed')

      const svgDisguisedAsPng = new File([SVG_BYTES], 'spoof.png', { type: 'image/png' })
      const svgRes2 = await validateWorkspaceMediaFile(svgDisguisedAsPng)
      expect(svgRes2.ok).toBe(false)
      if (!svgRes2.ok) expect(svgRes2.error.kind).toBe('svg_not_allowed')

      const mismatch = new File([JPEG_BYTES], 'wrong.png', { type: 'image/png' })
      const mismatchRes = await validateWorkspaceMediaFile(mismatch)
      expect(mismatchRes.ok).toBe(false)
      if (!mismatchRes.ok) expect(mismatchRes.error.kind).toBe('mime_mismatch')
    })
  })

  describe('decodeUploadedMediaReceipt', () => {
    it('strictly decodes canonical receipt and rejects mismatched path or unknown MIME', () => {
      const valid = decodeUploadedMediaReceipt({
        path: `/api/v1/media/${VALID_SHA}`,
        sha256: VALID_SHA,
        mime: 'image/webp',
        bytes: 2048,
        width: 640,
        height: null,
      })
      expect(valid).toEqual({
        ok: true,
        value: {
          path: `/api/v1/media/${VALID_SHA}`,
          sha256: VALID_SHA,
          mime: 'image/webp',
          bytes: 2048,
          width: 640,
          height: null,
        },
      })

      const badPath = decodeUploadedMediaReceipt({
        path: `/api/v1/media/${'b'.repeat(64)}`,
        sha256: VALID_SHA,
        mime: 'image/png',
        bytes: 100,
      })
      expect(badPath.ok).toBe(false)

      const svgMime = decodeUploadedMediaReceipt({
        path: `/api/v1/media/${VALID_SHA}`,
        sha256: VALID_SHA,
        mime: 'image/svg+xml',
        bytes: 100,
      })
      expect(svgMime.ok).toBe(false)
    })
  })

  describe('uploadWorkspaceMedia', () => {
    it('sends raw binary POST /api/v1/media with Bearer auth in single_user mode', async () => {
      const fetchMock = vi.fn<typeof fetch>().mockResolvedValueOnce(
        jsonResponse({
          path: `/api/v1/media/${VALID_SHA}`,
          sha256: VALID_SHA,
          mime: 'image/png',
          bytes: PNG_BYTES.byteLength,
          width: 120,
          height: 80,
        }),
      )
      const file = new File([PNG_BYTES], 'arch.png', { type: 'image/png' })
      const res = await uploadWorkspaceMedia(file, { fetchImpl: fetchMock })

      expect(res.ok).toBe(true)
      if (res.ok) {
        expect(res.value.path).toBe(`/api/v1/media/${VALID_SHA}`)
        expect(res.value.width).toBe(120)
        expect(res.value.height).toBe(80)
      }
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const [url, init] = fetchMock.mock.calls[0]!
      expect(url).toBe(WORKSPACE_MEDIA_UPLOAD_PATH)
      expect(init?.method).toBe('POST')
      expect(init?.credentials).toBe('same-origin')
      expect(init?.redirect).toBe('error')
      expect(init?.body).toBe(file)
      const headers = init?.headers as Record<string, string>
      expect(headers['Content-Type']).toBe('image/png')
      expect(headers.Authorization).toBe('Bearer masc-test-admin-token')
      expect(headers['x-masc-csrf-token']).toBeUndefined()
    })

    it('uses same-origin CSRF header (zero Bearer) and retries once on 403 csrf_invalid in multi-account mode', async () => {
      authSession.value = {
        kind: 'multi_account_signed_in',
        mode: 'multi_account',
        accountId: 'acc-1',
        email: 'admin@example.com',
        displayName: 'Admin',
        role: 'admin',
        csrfToken: 'csrf-old',
        authMethods: DEFAULT_AUTH_METHODS,
        workspaceId: 'default',
      }

      const fetchMock = vi.fn<typeof fetch>(async (input, init) => {
        const url = String(input)
        if (url === '/auth/session') {
          return jsonResponse({ user_id: 'acc-1', csrf_token: 'csrf-fresh' }, 200)
        }
        if (url === '/api/v1/auth/whoami') {
          return jsonResponse({ principal: { kind: 'human', id: 'acc-1' }, role: 'admin' }, 200)
        }
        const headers = init?.headers as Record<string, string>
        expect(headers.Authorization).toBeUndefined()
        if (headers['x-masc-csrf-token'] === 'csrf-old') {
          return jsonResponse({ code: 'csrf_invalid', error: 'CSRF expired' }, 403)
        }
        expect(headers['x-masc-csrf-token']).toBe('csrf-fresh')
        return jsonResponse({
          path: `/api/v1/media/${VALID_SHA}`,
          sha256: VALID_SHA,
          mime: 'image/png',
          bytes: PNG_BYTES.byteLength,
          width: null,
          height: null,
        }, 201)
      })

      const res = await uploadWorkspaceMedia(new File([PNG_BYTES], 'shot.png', { type: 'image/png' }), {
        fetchImpl: fetchMock,
      })
      expect(res.ok).toBe(true)
      expect(fetchMock).toHaveBeenCalledTimes(4)
    })

    it('maps server 413/415/403/500 error codes to typed MediaUploadError kinds', async () => {
      const file = new File([PNG_BYTES], 'shot.png', { type: 'image/png' })

      const res413 = await uploadWorkspaceMedia(file, {
        fetchImpl: vi.fn<typeof fetch>().mockResolvedValueOnce(
          jsonResponse({ code: 'media_too_large', error: 'too big', max_bytes: 10 * 1024 * 1024 }, 413),
        ),
      })
      expect(res413.ok).toBe(false)
      if (!res413.ok) {
        expect(res413.error.kind).toBe('media_too_large')
        expect(res413.error.maxBytes).toBe(10 * 1024 * 1024)
        expect(res413.error.message).toContain('10 MB')
      }

      const res415 = await uploadWorkspaceMedia(file, {
        fetchImpl: vi.fn<typeof fetch>().mockResolvedValueOnce(
          jsonResponse({ code: 'svg_not_allowed', error: 'svg blocked' }, 415),
        ),
      })
      expect(res415.ok).toBe(false)
      if (!res415.ok) expect(res415.error.kind).toBe('svg_not_allowed')

      const res503 = await uploadWorkspaceMedia(file, {
        fetchImpl: vi.fn<typeof fetch>().mockResolvedValueOnce(
          jsonResponse({ code: 'media_store_failed', error: 'disk full' }, 503),
        ),
      })
      expect(res503.ok).toBe(false)
      if (!res503.ok) {
        expect(res503.error.kind).toBe('store_failed')
        expect(res503.error.retryable).toBe(true)
      }
    })

    it('aborts and fails closed with epoch_stale when workspace epoch switches mid-flight', async () => {
      const fetchMock = vi.fn<typeof fetch>((_input, init) => {
        return new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')))
          queueMicrotask(() => bumpSessionEpoch())
        })
      })

      const res = await uploadWorkspaceMedia(new File([PNG_BYTES], 'shot.png', { type: 'image/png' }), {
        fetchImpl: fetchMock,
      })
      expect(res.ok).toBe(false)
      if (!res.ok) expect(res.error.kind).toBe('epoch_stale')
    })

    it('respects caller AbortSignal without issuing network requests', async () => {
      const ctrl = new AbortController()
      ctrl.abort()
      const fetchMock = vi.fn<typeof fetch>()
      const res = await uploadWorkspaceMedia(new File([PNG_BYTES], 'shot.png', { type: 'image/png' }), {
        signal: ctrl.signal,
        fetchImpl: fetchMock,
      })
      expect(res.ok).toBe(false)
      if (!res.ok) expect(res.error.kind).toBe('aborted')
      expect(fetchMock).not.toHaveBeenCalled()
    })
  })

  describe('Markdown & DataTransfer helpers', () => {
    it('formats image Markdown and inserts cleanly at cursor selection', () => {
      expect(deriveImageAltText('system-[v2]\nchart.png')).toBe('system-v2 chart')
      expect(deriveImageAltText('')).toBe('이미지')
      expect(formatUploadedImageMarkdown({ path: `/api/v1/media/${VALID_SHA}` }, '구조도')).toBe(
        `![구조도](/api/v1/media/${VALID_SHA})`,
      )
      expect(insertTextAtSelection('Hello world', 6, 11, 'MASC')).toEqual({
        value: 'Hello MASC',
        cursor: 10,
      })
    })

    it('extracts image files cleanly while ignoring non-image files on paste', () => {
      const png = new File([PNG_BYTES], 'shot.png', { type: 'image/png' })
      const txt = new File(['hello'], 'notes.txt', { type: 'text/plain' })
      const dt = {
        types: ['Files'],
        files: [png, txt],
        items: [],
      } as unknown as DataTransfer

      expect(dataTransferHasFiles(dt)).toBe(true)
      expect(extractUploadFilesFromDataTransfer(dt, { imagesOnly: true })).toEqual([png])
      expect(extractUploadFilesFromDataTransfer(dt, { imagesOnly: false })).toEqual([png, txt])
    })
  })
})
