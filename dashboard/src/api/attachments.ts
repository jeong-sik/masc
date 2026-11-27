/**
 * Unified Attachment Store API client (`/api/v1/attachments`).
 *
 * - Upload-first binary transport (`POST /api/v1/attachments`) with mode-aware auth
 *   (Bearer token in single-user mode, same-origin cookie + CSRF retry in multi-account mode)
 *   and strict session-epoch fencing.
 * - Authenticated binary fetch (`GET /api/v1/attachments/<id>?max_px=...&download=1`)
 *   for thumbnails, full-resolution lightbox images, audio playback, document downloads,
 *   and inline Markdown attachment hydration.
 * - Strict boundary decoders for `AttachmentRef` across uploads, chat history rows,
 *   live `KEEPER_ATTACHMENT` events, and Board posts/comments.
 */

import {
  authSession,
  currentSessionEpoch,
  getActiveCsrfToken,
  getSingleUserToken,
  isEpochCurrent,
  refreshMultiAccountCsrf,
  resolveWorkspaceUrl,
  sessionEpoch,
} from '../core/auth'
import type { ApiError } from '../core/transport'
import {
  appendAttachmentQuery,
  attachmentUrlForId,
  extractAttachmentIdFromPath,
  isWorkspaceAttachmentId,
  isWorkspaceAttachmentPath,
  isWorkspaceMediaPath,
  isWorkspaceRasterMime,
} from '../lib/keeper-media'
import { parseUrl } from '../lib/parse-url'
import { err, ok, type Result } from '../lib/result'

export type AttachmentKind = 'image' | 'audio' | 'video' | 'document'

export type AttachmentOrigin =
  | 'user_upload'
  | 'tool_capture'
  | 'model_generated'
  | 'connector_inbound'
  | string

export interface AttachmentRef {
  readonly id: string
  readonly attachment_id: string
  readonly sha256: string
  readonly url: string
  readonly mime_type: string
  readonly kind: AttachmentKind
  readonly bytes: number
  readonly width?: number | null
  readonly height?: number | null
  readonly filename?: string | null
  readonly origin?: AttachmentOrigin
  readonly created_at_unix?: number
  readonly retention?: string
  readonly caption?: string | null
  readonly tool_call_id?: string | null
}

// Match server ceiling of 50 MiB for fetched media responses.
export const MAX_FETCH_ATTACHMENT_BYTES = 50 * 1024 * 1024

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function asNonEmptyStr(v: unknown): string | null {
  if (typeof v !== 'string') return null
  const t = v.trim()
  return t.length > 0 ? t : null
}

function asFiniteNum(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

function asPositiveInt(v: unknown): number | null {
  return typeof v === 'number' && Number.isInteger(v) && v > 0 ? v : null
}

export function inferAttachmentKind(mimeType: string | null | undefined, declaredKind?: unknown): AttachmentKind {
  if (declaredKind === 'image' || declaredKind === 'audio' || declaredKind === 'video' || declaredKind === 'document') {
    return declaredKind
  }
  const normalized = (mimeType ?? '').toLowerCase().split(';', 1)[0]?.trim() ?? ''
  if (normalized.startsWith('image/')) return 'image'
  if (normalized.startsWith('audio/')) return 'audio'
  if (normalized.startsWith('video/')) return 'video'
  return 'document'
}

/**
 * Decodes a server wire `AttachmentRef`, a history `blocks[]` attachment/image
 * item, or a live `KEEPER_ATTACHMENT` payload. Rejects external or protocol-relative
 * URLs to keep attachment fetching strictly same-origin.
 */
export function decodeAttachmentRef(raw: unknown): AttachmentRef | null {
  if (!isRecord(raw)) return null

  const explicitAttId = asNonEmptyStr(raw.attachment_id)
  const explicitId = asNonEmptyStr(raw.id)
  const rawUrl = asNonEmptyStr(raw.url) ?? asNonEmptyStr(raw.src) ?? asNonEmptyStr(raw.media_ref)

  let url: string | null = null
  let id: string | null = null

  if (rawUrl) {
    if (!isWorkspaceMediaPath(rawUrl)) return null
    url = rawUrl
    id = explicitAttId ?? explicitId ?? extractAttachmentIdFromPath(rawUrl) ?? rawUrl
  } else {
    const candidateId = explicitAttId ?? explicitId
    if (!candidateId || !isWorkspaceAttachmentId(candidateId)) return null
    id = candidateId
    url = attachmentUrlForId(candidateId)
  }

  const attachmentId = explicitAttId ?? (isWorkspaceAttachmentId(id) ? id : extractAttachmentIdFromPath(url) ?? id)
  const sha256FromId = attachmentId.startsWith('att_') ? attachmentId.slice(4) : ''
  const sha256 = asNonEmptyStr(raw.sha256) ?? sha256FromId
  const rawMime = asNonEmptyStr(raw.mime_type) ?? asNonEmptyStr(raw.media_type)
  const mimeType = rawMime ?? (raw.t === 'image' ? 'image/png' : 'application/octet-stream')
  const kind = inferAttachmentKind(mimeType, raw.kind ?? (raw.t === 'image' ? 'image' : undefined))
  const bytes = Math.max(0, Math.trunc(asFiniteNum(raw.bytes) ?? asFiniteNum(raw.size) ?? 0))
  const width = asPositiveInt(raw.width)
  const height = asPositiveInt(raw.height)
  const filename = asNonEmptyStr(raw.filename) ?? asNonEmptyStr(raw.name)
  const origin = asNonEmptyStr(raw.origin) ?? undefined
  const createdAtUnix = asFiniteNum(raw.created_at_unix) ?? undefined
  const retention = asNonEmptyStr(raw.retention) ?? undefined
  const caption = asNonEmptyStr(raw.caption) ?? asNonEmptyStr(raw.cap) ?? asNonEmptyStr(raw.alt)
  const toolCallId = asNonEmptyStr(raw.tool_call_id) ?? asNonEmptyStr(raw.toolCallId)

  return {
    id: explicitId ?? attachmentId,
    attachment_id: attachmentId,
    sha256,
    url,
    mime_type: mimeType,
    kind,
    bytes,
    ...(width !== null ? { width } : {}),
    ...(height !== null ? { height } : {}),
    ...(filename !== null ? { filename } : {}),
    ...(origin !== undefined ? { origin } : {}),
    ...(createdAtUnix !== undefined ? { created_at_unix: createdAtUnix } : {}),
    ...(retention !== undefined ? { retention } : {}),
    ...(caption !== null ? { caption } : {}),
    ...(toolCallId !== null ? { tool_call_id: toolCallId } : {}),
  }
}

export function attachmentDedupeKey(att: Pick<AttachmentRef, 'attachment_id' | 'id' | 'url'>): string {
  if (isWorkspaceAttachmentId(att.attachment_id)) return att.attachment_id
  if (isWorkspaceAttachmentId(att.id)) return att.id
  const extracted = extractAttachmentIdFromPath(att.url)
  if (extracted) return extracted
  return att.url || att.attachment_id || att.id
}

function mergeAttachmentMetadata(a: AttachmentRef, b: AttachmentRef): AttachmentRef {
  return {
    id: isWorkspaceAttachmentId(a.id) ? a.id : b.id,
    attachment_id: isWorkspaceAttachmentId(a.attachment_id) ? a.attachment_id : b.attachment_id,
    sha256: a.sha256 || b.sha256,
    url: isWorkspaceAttachmentPath(a.url) ? a.url : b.url,
    mime_type: a.mime_type !== 'application/octet-stream' ? a.mime_type : b.mime_type,
    kind: a.kind === 'document' && b.kind !== 'document' ? b.kind : a.kind,
    bytes: a.bytes > 0 ? a.bytes : b.bytes,
    width: a.width ?? b.width,
    height: a.height ?? b.height,
    filename: a.filename ?? b.filename,
    origin: a.origin ?? b.origin,
    created_at_unix: a.created_at_unix ?? b.created_at_unix,
    retention: a.retention ?? b.retention,
    caption: a.caption ?? b.caption,
    tool_call_id: a.tool_call_id ?? b.tool_call_id,
  }
}

export function dedupeAttachments(list: readonly AttachmentRef[]): readonly AttachmentRef[] {
  if (list.length <= 1) return list
  const order: string[] = []
  const byKey = new Map<string, AttachmentRef>()
  for (const item of list) {
    const key = attachmentDedupeKey(item)
    const prev = byKey.get(key)
    if (!prev) {
      order.push(key)
      byKey.set(key, item)
    } else {
      byKey.set(key, mergeAttachmentMetadata(prev, item))
    }
  }
  return order.map((key) => byKey.get(key)!)
}

/**
 * Lightweight wire metadata object sent in chat/board JSON payloads after uploading
 * bytes via `POST /api/v1/attachments` (strictly zero inline base64 data).
 */
export function toAttachmentWirePayload(ref: AttachmentRef): Record<string, unknown> {
  const id = ref.attachment_id || ref.id
  return {
    attachment_id: id,
    id,
    url: ref.url,
    mime_type: ref.mime_type,
    kind: ref.kind,
    bytes: ref.bytes,
    ...(ref.width != null ? { width: ref.width } : {}),
    ...(ref.height != null ? { height: ref.height } : {}),
    ...(ref.filename != null ? { filename: ref.filename } : {}),
  }
}

function encodeFilenameHeader(filename: string): string {
  // Fetch header values must be ISO-8859-1 ByteStrings without CR/LF.
  const cleaned = filename.replace(/[\r\n]/g, ' ').trim()
  if (/^[\x20-\x7e]+$/.test(cleaned)) return cleaned
  return encodeURIComponent(cleaned)
}

export function buildAttachmentAuthHeaders(
  method: 'GET' | 'POST',
  extra?: Record<string, string>,
): Record<string, string> {
  const headers: Record<string, string> = { ...extra }
  const session = authSession.peek()
  if (session.kind === 'multi_account_signed_in') {
    if (method === 'POST') {
      const csrf = getActiveCsrfToken()
      if (csrf) headers['x-masc-csrf-token'] = csrf
    }
  } else {
    const token = getSingleUserToken()
    if (token && !('Authorization' in headers)) {
      headers.Authorization = `Bearer ${token}`
    }
  }
  return headers
}

function classifyUploadFailure(status: number, body: unknown): ApiError {
  let code: string | null = null
  let message = `HTTP ${status}`
  if (isRecord(body)) {
    if (isRecord(body.error)) {
      if (typeof body.error.code === 'string') code = body.error.code
      if (typeof body.error.message === 'string') message = body.error.message
    } else if (typeof body.error === 'string') {
      message = body.error
      if (typeof body.code === 'string') code = body.code
    } else if (typeof body.message === 'string') {
      message = body.message
    }
  } else if (typeof body === 'string' && body.trim()) {
    message = body.trim()
  }
  if (status === 401) return { kind: 'unauthorized', status, code, message, retryable: false }
  if (status === 403) {
    const isCsrf = code === 'csrf_invalid' || code === 'csrf_missing' || /\bcsrf\b/i.test(message)
    return { kind: isCsrf ? 'csrf_rejected' : 'forbidden', status, code, message, retryable: false }
  }
  if (status === 404) return { kind: 'not_found', status, code, message, retryable: false }
  if (status >= 400 && status < 500) return { kind: 'validation', status, code, message, retryable: false }
  return { kind: 'server', status, code, message, retryable: status >= 500 }
}

export interface UploadAttachmentOptions {
  readonly filename?: string
  readonly mimeType?: string
  readonly retention?: 'durable' | 'ephemeral'
  readonly signal?: AbortSignal
  readonly onProgress?: (percent: number) => void
  readonly fetchImpl?: typeof fetch
}

/**
 * Uploads a single File/Blob to `POST /api/v1/attachments` as raw binary with
 * verified `Content-Type` and optional `X-Filename` header.
 */
export async function uploadAttachment(
  file: File | Blob,
  opts: UploadAttachmentOptions = {},
): Promise<Result<AttachmentRef, ApiError>> {
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch
  const startEpoch = currentSessionEpoch()
  if (opts.signal?.aborted) {
    return err({ kind: 'aborted', status: null, code: null, message: '업로드가 취소되었습니다.', retryable: false })
  }

  const controller = new AbortController()
  const onCallerAbort = () => controller.abort(opts.signal?.reason)
  opts.signal?.addEventListener('abort', onCallerAbort, { once: true })
  const unsubEpoch = sessionEpoch.subscribe((ep) => {
    if (ep !== startEpoch && !controller.signal.aborted) {
      controller.abort('epoch_stale')
    }
  })

  const resolvedMime = (opts.mimeType ?? file.type ?? '').trim() || 'application/octet-stream'
  const filename = opts.filename ?? (file instanceof File ? file.name : undefined)

  const executeOnce = async (): Promise<Result<AttachmentRef, ApiError>> => {
    if (!isEpochCurrent(startEpoch)) {
      return err({ kind: 'epoch_stale', status: null, code: 'epoch_stale', message: '세션이 변경되었습니다.', retryable: false })
    }
    const extra: Record<string, string> = {
      Accept: 'application/json',
      'Content-Type': resolvedMime,
    }
    if (filename && filename.trim()) {
      extra['X-Filename'] = encodeFilenameHeader(filename)
    }
    if (opts.retention) {
      extra['X-Retention'] = opts.retention
    }

    opts.onProgress?.(15)
    let response: Response
    try {
      response = await fetchImpl(resolveWorkspaceUrl('/api/v1/attachments'), {
        method: 'POST',
        credentials: 'same-origin',
        headers: buildAttachmentAuthHeaders('POST', extra),
        body: file,
        signal: controller.signal,
      })
    } catch (cause) {
      if (!isEpochCurrent(startEpoch)) {
        return err({ kind: 'epoch_stale', status: null, code: 'epoch_stale', message: '세션이 변경되었습니다.', retryable: false, cause })
      }
      if (controller.signal.aborted) {
        return err({ kind: 'aborted', status: null, code: null, message: '업로드가 취소되었습니다.', retryable: false, cause })
      }
      return err({
        kind: 'network',
        status: null,
        code: 'network_error',
        message: cause instanceof Error ? cause.message : '네트워크 오류로 업로드에 실패했습니다.',
        retryable: true,
        cause,
      })
    }

    if (!isEpochCurrent(startEpoch)) {
      return err({ kind: 'epoch_stale', status: null, code: 'epoch_stale', message: '세션이 변경되었습니다.', retryable: false })
    }

    let parsedBody: unknown = null
    const ct = response.headers.get('content-type') ?? ''
    try {
      parsedBody = ct.includes('application/json') || ct === ''
        ? await response.json()
        : await response.text()
    } catch {
      parsedBody = null
    }

    if (!response.ok) {
      return err(classifyUploadFailure(response.status, parsedBody))
    }

    const payload = isRecord(parsedBody) && parsedBody.ok === true && isRecord(parsedBody.data)
      ? parsedBody.data
      : isRecord(parsedBody) && isRecord(parsedBody.data)
        ? parsedBody.data
        : parsedBody

    const decoded = decodeAttachmentRef(payload)
    if (!decoded) {
      return err({
        kind: 'decode',
        status: response.status,
        code: 'invalid_attachment_ref',
        message: '서버가 올바른 첨부 참조(AttachmentRef)를 반환하지 않았습니다.',
        retryable: false,
      })
    }
    opts.onProgress?.(100)
    return ok(decoded)
  }

  try {
    const prevCsrf = getActiveCsrfToken()
    const first = await executeOnce()
    if (
      !first.ok
      && first.error.kind === 'csrf_rejected'
      && authSession.peek().kind === 'multi_account_signed_in'
      && isEpochCurrent(startEpoch)
    ) {
      const refreshed = await refreshMultiAccountCsrf(fetchImpl)
      if (refreshed && refreshed !== prevCsrf && isEpochCurrent(startEpoch)) {
        return await executeOnce()
      }
    }
    return first
  } finally {
    unsubEpoch()
    opts.signal?.removeEventListener('abort', onCallerAbort)
  }
}

export interface FetchAttachmentBlobOptions {
  readonly maxPx?: number | null
  readonly format?: string | null
  readonly download?: boolean
  readonly signal?: AbortSignal
  readonly maxBytes?: number
  readonly requireRasterImage?: boolean
  readonly fetchImpl?: typeof fetch
}

async function readBoundedBlob(
  response: Response,
  contentType: string,
  maxBytes: number,
): Promise<Blob | null> {
  const declaredLen = Number(response.headers.get('content-length'))
  if (Number.isFinite(declaredLen) && declaredLen > maxBytes) {
    await response.body?.cancel()
    return null
  }
  if (!response.body) {
    const blob = await response.blob()
    return blob.size > 0 && blob.size <= maxBytes ? blob : null
  }
  const reader = response.body.getReader()
  const chunks: ArrayBuffer[] = []
  let size = 0
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) return size > 0 ? new Blob(chunks, { type: contentType }) : null
      size += value.byteLength
      if (size > maxBytes) {
        await reader.cancel()
        return null
      }
      chunks.push(value.slice().buffer)
    }
  } finally {
    reader.releaseLock()
  }
}

/**
 * Fetches attachment bytes from a verified same-origin `/api/v1/attachments/<id>`
 * or legacy `/api/v1/media/<64hex>` path with Bearer/cookie auth and size cap.
 */
export async function fetchAttachmentBlob(
  path: string,
  opts: FetchAttachmentBlobOptions = {},
): Promise<Result<{ readonly blob: Blob; readonly contentType: string }, ApiError>> {
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch
  const startEpoch = currentSessionEpoch()
  if (!isWorkspaceMediaPath(path)) {
    return err({ kind: 'validation', status: null, code: 'invalid_path', message: '허용되지 않은 첨부 경로입니다.', retryable: false })
  }

  const queryParams: Record<string, string | number | undefined> = {}
  if (isWorkspaceAttachmentPath(path)) {
    if (typeof opts.maxPx === 'number' && opts.maxPx > 0) queryParams.max_px = Math.trunc(opts.maxPx)
    if (opts.format) queryParams.format = opts.format
    if (opts.download) queryParams.download = 1
  } else if (opts.download) {
    queryParams.download = 1
  }
  const requestPath = appendAttachmentQuery(path, queryParams)
  const destination = parseUrl(resolveWorkspaceUrl(requestPath), window.location.origin)
  if (!destination || destination.origin !== window.location.origin) {
    return err({ kind: 'validation', status: null, code: 'cross_origin', message: '외부 출처 첨부는 불러올 수 없습니다.', retryable: false })
  }

  let response: Response
  try {
    response = await fetchImpl(destination.href, {
      method: 'GET',
      credentials: 'same-origin',
      mode: 'same-origin',
      redirect: 'error',
      headers: buildAttachmentAuthHeaders('GET'),
      signal: opts.signal,
    })
  } catch (cause) {
    if (opts.signal?.aborted) {
      return err({ kind: 'aborted', status: null, code: null, message: '요청이 취소되었습니다.', retryable: false, cause })
    }
    return err({
      kind: 'network',
      status: null,
      code: 'network_error',
      message: cause instanceof Error ? cause.message : '첨부 조회에 실패했습니다.',
      retryable: true,
      cause,
    })
  }

  if (!isEpochCurrent(startEpoch)) {
    await response.body?.cancel().catch(() => {})
    return err({ kind: 'epoch_stale', status: null, code: 'epoch_stale', message: '세션이 변경되었습니다.', retryable: false })
  }

  if (!response.ok) {
    await response.body?.cancel().catch(() => {})
    return err(classifyUploadFailure(response.status, null))
  }

  const contentType = response.headers.get('content-type')?.split(';', 1)[0]?.trim() || 'application/octet-stream'
  if (opts.requireRasterImage && !isWorkspaceRasterMime(contentType)) {
    await response.body?.cancel().catch(() => {})
    return err({ kind: 'validation', status: response.status, code: 'non_raster_mime', message: `지원하지 않는 이미지 형식: ${contentType}`, retryable: false })
  }

  const maxBytes = opts.maxBytes ?? MAX_FETCH_ATTACHMENT_BYTES
  const blob = await readBoundedBlob(response, contentType, maxBytes)
  if (!blob) {
    return err({ kind: 'decode', status: response.status, code: 'empty_or_oversized', message: '첨부 데이터를 읽을 수 없습니다.', retryable: false })
  }
  return ok({ blob, contentType })
}

export function blobToDataUrl(blob: Blob): Promise<string | null> {
  return new Promise((resolve) => {
    const reader = new FileReader()
    reader.onload = () => resolve(typeof reader.result === 'string' ? reader.result : null)
    reader.onerror = () => resolve(null)
    reader.readAsDataURL(blob)
  })
}

function defaultFilenameForMime(id: string, mimeType: string): string {
  const shortId = id.slice(0, 16)
  const extMap: Record<string, string> = {
    'image/png': 'png',
    'image/jpeg': 'jpg',
    'image/webp': 'webp',
    'image/gif': 'gif',
    'application/pdf': 'pdf',
    'audio/mpeg': 'mp3',
    'audio/wav': 'wav',
    'audio/ogg': 'ogg',
    'audio/midi': 'mid',
    'audio/mp4': 'm4a',
    'audio/webm': 'webm',
    'video/mp4': 'mp4',
    'video/webm': 'webm',
    'video/quicktime': 'mov',
  }
  const ext = extMap[mimeType.toLowerCase()] ?? 'bin'
  return `${shortId}.${ext}`
}

/**
 * Triggers an authenticated browser file download using `?download=1` so Bearer
 * token sessions download cleanly without hitting HTTP 401 on raw `<a href>`.
 */
export async function downloadAttachment(
  att: Pick<AttachmentRef, 'url' | 'id' | 'mime_type' | 'filename'>,
  opts: { readonly fetchImpl?: typeof fetch; readonly signal?: AbortSignal } = {},
): Promise<Result<void, ApiError>> {
  const res = await fetchAttachmentBlob(att.url, {
    download: true,
    signal: opts.signal,
    fetchImpl: opts.fetchImpl,
  })
  if (!res.ok) return res
  const objectUrl = URL.createObjectURL(res.value.blob)
  try {
    const link = document.createElement('a')
    link.href = objectUrl
    link.download = att.filename?.trim() || defaultFilenameForMime(att.id, res.value.contentType || att.mime_type)
    link.rel = 'noopener noreferrer'
    document.body.appendChild(link)
    link.click()
    link.remove()
  } finally {
    setTimeout(() => URL.revokeObjectURL(objectUrl), 1000)
  }
  return ok(undefined)
}
