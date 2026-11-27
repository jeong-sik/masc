/**
 * Typed client for Workspace Media Uploads (`POST /api/v1/media`) and shared
 * editor image-insertion helpers.
 *
 * Contract (`RFC-workspace-media-and-rich-embed` / FROZEN CONTRACT v1):
 * - Raw binary `POST /api/v1/media` with magic-byte verified raster `Content-Type`
 *   (`image/png`, `image/jpeg`, `image/gif`, `image/webp`; SVG strictly rejected).
 * - Mode-aware auth:
 *   - `single_user`: `Authorization: Bearer <token>` + `credentials: 'same-origin'`.
 *   - `multi_account_signed_in`: `credentials: 'same-origin'` + `x-masc-csrf-token`
 *     with single automatic 403 CSRF refresh-and-retry.
 * - Workspace/account `sessionEpoch` fence + `AbortSignal` cleanup (zero stale results).
 * - Strict flat JSON receipt decoding with closed union `MediaUploadError`.
 */

import {
  authSession,
  canAccessTokenAdmin,
  currentSessionEpoch,
  getActiveCsrfToken,
  getSingleUserToken,
  isEpochCurrent,
  refreshMultiAccountCsrf,
  resolveWorkspaceUrl,
  scheduleForbiddenRoleRecheck,
  sessionEpoch,
  type AuthSession,
} from '../core/auth'
import {
  WORKSPACE_MEDIA_MAX_BYTES,
  WORKSPACE_RASTER_MIMES,
  isWorkspaceMediaPath,
  isWorkspaceMediaSha256,
  parseWorkspaceRasterMime,
  type WorkspaceRasterMime,
} from './keeper-media'
import { err, ok, type Result } from './result'

export { WORKSPACE_MEDIA_MAX_BYTES, WORKSPACE_RASTER_MIMES, type WorkspaceRasterMime }

export const WORKSPACE_MEDIA_ACCEPT = WORKSPACE_RASTER_MIMES.join(',')
export const WORKSPACE_MEDIA_UPLOAD_PATH = '/api/v1/media'

const SNIFF_HEADER_BYTES = 256
const SVG_FILE_EXT_RE = /\.svg$/i
const IMAGE_FILE_EXT_RE = /\.(png|jpe?g|gif|webp|svg)$/i

export type SniffedMediaKind =
  | { readonly kind: 'raster'; readonly mime: WorkspaceRasterMime }
  | { readonly kind: 'svg' }
  | { readonly kind: 'unknown' }

export type MediaUploadErrorKind =
  | 'aborted'
  | 'epoch_stale'
  | 'empty_upload'
  | 'truncated_upload'
  | 'media_too_large'
  | 'svg_not_allowed'
  | 'unsupported_media_type'
  | 'mime_mismatch'
  | 'bad_request'
  | 'unauthorized'
  | 'forbidden'
  | 'csrf_rejected'
  | 'store_failed'
  | 'network'
  | 'decode'

export interface MediaUploadError {
  readonly kind: MediaUploadErrorKind
  readonly status: number | null
  readonly code: string | null
  readonly message: string
  readonly retryable: boolean
  readonly maxBytes?: number
  readonly sizeBytes?: number
}

export interface UploadedMediaReceipt {
  readonly path: string
  readonly sha256: string
  readonly mime: WorkspaceRasterMime
  readonly bytes: number
  readonly width: number | null
  readonly height: number | null
}

export interface UploadWorkspaceMediaOptions {
  readonly signal?: AbortSignal
  readonly fetchImpl?: typeof fetch
  readonly maxBytes?: number
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function formatByteLimit(bytes: number): string {
  if (bytes >= 1024 * 1024) {
    const mb = bytes / (1024 * 1024)
    return Number.isInteger(mb) ? `${mb} MB` : `${mb.toFixed(1)} MB`
  }
  if (bytes >= 1024) {
    return `${Math.round(bytes / 1024)} KB`
  }
  return `${bytes} B`
}

function matchesAsciiPrefixCaseInsensitive(
  bytes: Uint8Array,
  offset: number,
  expectedLowerAscii: string,
): boolean {
  if (offset + expectedLowerAscii.length > bytes.length) return false
  for (let i = 0; i < expectedLowerAscii.length; i += 1) {
    const b = bytes[offset + i]!
    const lower = b >= 0x41 && b <= 0x5A ? b + 0x20 : b
    if (lower !== expectedLowerAscii.charCodeAt(i)) return false
  }
  return true
}

/**
 * Pure magic-byte sniffer matching the server contract (`PNG`, `JPEG`, `GIF`,
 * `WebP`, plus explicit `SVG`/`XML` rejection).
 */
export function sniffMediaBytes(bytes: Uint8Array): SniffedMediaKind {
  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (
    bytes.length >= 8
    && bytes[0] === 0x89
    && bytes[1] === 0x50
    && bytes[2] === 0x4E
    && bytes[3] === 0x47
    && bytes[4] === 0x0D
    && bytes[5] === 0x0A
    && bytes[6] === 0x1A
    && bytes[7] === 0x0A
  ) {
    return { kind: 'raster', mime: 'image/png' }
  }

  // JPEG: FF D8 FF
  if (bytes.length >= 3 && bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) {
    return { kind: 'raster', mime: 'image/jpeg' }
  }

  // GIF: GIF87a / GIF89a
  if (
    bytes.length >= 6
    && bytes[0] === 0x47
    && bytes[1] === 0x49
    && bytes[2] === 0x46
    && bytes[3] === 0x38
    && (bytes[4] === 0x37 || bytes[4] === 0x39)
    && bytes[5] === 0x61
  ) {
    return { kind: 'raster', mime: 'image/gif' }
  }

  // WebP: RIFF....WEBP
  if (
    bytes.length >= 12
    && bytes[0] === 0x52
    && bytes[1] === 0x49
    && bytes[2] === 0x46
    && bytes[3] === 0x46
    && bytes[8] === 0x57
    && bytes[9] === 0x45
    && bytes[10] === 0x42
    && bytes[11] === 0x50
  ) {
    return { kind: 'raster', mime: 'image/webp' }
  }

  // Detect XML/SVG payload (skip optional UTF-8 BOM, ASCII whitespace, and leading XML comments)
  let offset = 0
  if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
    offset = 3
  }
  const skipWhitespace = () => {
    while (offset < bytes.length) {
      const b = bytes[offset]!
      if (b === 0x20 || b === 0x09 || b === 0x0A || b === 0x0D) {
        offset += 1
      } else {
        break
      }
    }
  }
  skipWhitespace()
  while (matchesAsciiPrefixCaseInsensitive(bytes, offset, '<!--')) {
    offset += 4
    let closed = false
    while (offset + 2 < bytes.length) {
      if (bytes[offset] === 0x2D && bytes[offset + 1] === 0x2D && bytes[offset + 2] === 0x3E) {
        offset += 3
        closed = true
        break
      }
      offset += 1
    }
    if (!closed) break
    skipWhitespace()
  }
  if (
    matchesAsciiPrefixCaseInsensitive(bytes, offset, '<?xml')
    || matchesAsciiPrefixCaseInsensitive(bytes, offset, '<svg')
    || matchesAsciiPrefixCaseInsensitive(bytes, offset, '<!doctype svg')
  ) {
    return { kind: 'svg' }
  }

  return { kind: 'unknown' }
}

/**
 * Strictly parses a declared MIME string into a supported raster MIME or `'svg'`.
 * Accepts `image/jpg` alias normalized to `image/jpeg`. Returns `null` on unknown input.
 */
export function parseDeclaredRasterMime(raw: string): WorkspaceRasterMime | 'svg' | null {
  const base = raw.split(';', 1)[0]?.trim().toLowerCase() ?? ''
  if (base === 'image/svg+xml') return 'svg'
  return parseWorkspaceRasterMime(raw)
}

export function canUploadWorkspaceMedia(session: AuthSession): boolean {
  return canAccessTokenAdmin(session)
}

/**
 * Returns `true` only when the session has settled and lacks admin upload rights.
 * Keeps `probing` unblocked so component renders before auth bootstrap do not
 * prematurely hide upload controls.
 */
export function isUploadBlockedBySession(session: AuthSession): boolean {
  if (session.kind === 'probing') return false
  return !canUploadWorkspaceMedia(session)
}

/**
 * Client-side pre-check before touching the network: verifies non-empty size,
 * ceiling, declared MIME, and actual magic bytes (rejecting SVG and mismatches).
 */
export async function validateWorkspaceMediaFile(
  file: Blob,
  opts: { readonly maxBytes?: number; readonly signal?: AbortSignal } = {},
): Promise<Result<WorkspaceRasterMime, MediaUploadError>> {
  if (opts.signal?.aborted) {
    return err({
      kind: 'aborted',
      status: null,
      code: null,
      message: '업로드가 취소되었습니다.',
      retryable: false,
    })
  }

  if (!Number.isFinite(file.size) || file.size <= 0) {
    return err({
      kind: 'empty_upload',
      status: null,
      code: 'empty_upload',
      message: '빈 파일은 업로드할 수 없습니다.',
      retryable: false,
    })
  }

  const maxBytes = opts.maxBytes ?? WORKSPACE_MEDIA_MAX_BYTES
  if (file.size > maxBytes) {
    return err({
      kind: 'media_too_large',
      status: null,
      code: 'media_too_large',
      message: `이미지 크기가 허용 한도(${formatByteLimit(maxBytes)})를 넘었습니다.`,
      retryable: false,
      maxBytes,
      sizeBytes: file.size,
    })
  }

  const declaredRaw = file.type.trim()
  const declared = declaredRaw ? parseDeclaredRasterMime(declaredRaw) : null
  const hasSvgExt = 'name' in file && typeof file.name === 'string' && SVG_FILE_EXT_RE.test(file.name.trim())
  if (declared === 'svg' || hasSvgExt) {
    return err({
      kind: 'svg_not_allowed',
      status: null,
      code: 'svg_not_allowed',
      message: 'SVG 파일은 보안 정책상 업로드할 수 없습니다. PNG, JPEG, GIF, WebP만 지원합니다.',
      retryable: false,
    })
  }

  let headerBytes: Uint8Array
  try {
    const buf = await file.slice(0, SNIFF_HEADER_BYTES).arrayBuffer()
    headerBytes = new Uint8Array(buf)
  } catch {
    return err({
      kind: 'unsupported_media_type',
      status: null,
      code: 'unsupported_media_type',
      message: '이미지 파일 헤더를 읽지 못했습니다.',
      retryable: false,
    })
  }

  if (opts.signal?.aborted) {
    return err({
      kind: 'aborted',
      status: null,
      code: null,
      message: '업로드가 취소되었습니다.',
      retryable: false,
    })
  }

  const sniffed = sniffMediaBytes(headerBytes)
  if (sniffed.kind === 'svg') {
    return err({
      kind: 'svg_not_allowed',
      status: null,
      code: 'svg_not_allowed',
      message: 'SVG 파일은 보안 정책상 업로드할 수 없습니다. PNG, JPEG, GIF, WebP만 지원합니다.',
      retryable: false,
    })
  }
  if (sniffed.kind === 'unknown') {
    return err({
      kind: 'unsupported_media_type',
      status: null,
      code: 'unsupported_media_type',
      message: '지원하지 않는 이미지 형식입니다. PNG, JPEG, GIF, WebP만 업로드할 수 있습니다.',
      retryable: false,
    })
  }

  if (declaredRaw) {
    if (declared === null) {
      return err({
        kind: 'unsupported_media_type',
        status: null,
        code: 'unsupported_media_type',
        message: '지원하지 않는 이미지 형식입니다. PNG, JPEG, GIF, WebP만 업로드할 수 있습니다.',
        retryable: false,
      })
    }
    if (declared !== sniffed.mime) {
      return err({
        kind: 'mime_mismatch',
        status: null,
        code: 'mime_mismatch',
        message: '파일 형식과 실제 이미지 내용이 일치하지 않습니다.',
        retryable: false,
      })
    }
  }

  return ok(sniffed.mime)
}

function decodeOptionalPositiveInt(raw: unknown): Result<number | null, MediaUploadError> {
  if (raw === undefined || raw === null) return ok(null)
  if (typeof raw === 'number' && Number.isSafeInteger(raw) && raw > 0) return ok(raw)
  return err({
    kind: 'decode',
    status: 201,
    code: 'invalid_receipt',
    message: '업로드 응답의 이미지 크기 필드가 올바르지 않습니다.',
    retryable: false,
  })
}

export function decodeUploadedMediaReceipt(
  raw: unknown,
  status = 201,
): Result<UploadedMediaReceipt, MediaUploadError> {
  if (!isRecord(raw)) {
    return err({
      kind: 'decode',
      status,
      code: 'invalid_receipt',
      message: '업로드 응답이 JSON 객체가 아닙니다.',
      retryable: false,
    })
  }
  const sha256 = typeof raw.sha256 === 'string' ? raw.sha256 : ''
  if (!isWorkspaceMediaSha256(sha256)) {
    return err({
      kind: 'decode',
      status,
      code: 'invalid_receipt',
      message: '업로드 응답의 SHA-256 값이 올바르지 않습니다.',
      retryable: false,
    })
  }
  const path = typeof raw.path === 'string' ? raw.path : ''
  if (!isWorkspaceMediaPath(path) || path !== `/api/v1/media/${sha256}`) {
    return err({
      kind: 'decode',
      status,
      code: 'invalid_receipt',
      message: '업로드 응답의 미디어 경로가 올바르지 않습니다.',
      retryable: false,
    })
  }
  const parsedMime = typeof raw.mime === 'string' ? parseDeclaredRasterMime(raw.mime) : null
  if (parsedMime === null || parsedMime === 'svg') {
    return err({
      kind: 'decode',
      status,
      code: 'invalid_receipt',
      message: '업로드 응답의 MIME 형식이 허용된 래스터 이미지가 아닙니다.',
      retryable: false,
    })
  }
  const bytes = raw.bytes
  if (typeof bytes !== 'number' || !Number.isSafeInteger(bytes) || bytes <= 0) {
    return err({
      kind: 'decode',
      status,
      code: 'invalid_receipt',
      message: '업로드 응답의 파일 크기 값이 올바르지 않습니다.',
      retryable: false,
    })
  }
  const width = decodeOptionalPositiveInt(raw.width)
  if (!width.ok) return width
  const height = decodeOptionalPositiveInt(raw.height)
  if (!height.ok) return height

  return ok({
    path,
    sha256,
    mime: parsedMime,
    bytes,
    width: width.value,
    height: height.value,
  })
}

function classifyUploadHttpError(status: number, body: unknown): MediaUploadError {
  let code: string | null = null
  let serverMessage: string | null = null
  let maxBytes: number | undefined
  let sizeBytes: number | undefined

  if (isRecord(body)) {
    if (isRecord(body.error)) {
      if (typeof body.error.code === 'string') code = body.error.code
      if (typeof body.error.message === 'string') serverMessage = body.error.message
    } else {
      if (typeof body.code === 'string') code = body.code
      if (typeof body.error === 'string') serverMessage = body.error
      else if (typeof body.message === 'string') serverMessage = body.message
    }
    if (typeof body.max_bytes === 'number' && Number.isSafeInteger(body.max_bytes)) {
      maxBytes = body.max_bytes
    }
    if (typeof body.size_bytes === 'number' && Number.isSafeInteger(body.size_bytes)) {
      sizeBytes = body.size_bytes
    }
  }

  if (status === 401) {
    return {
      kind: 'unauthorized',
      status,
      code,
      message: '이미지 업로드는 로그인이 필요합니다.',
      retryable: false,
    }
  }
  if (status === 403) {
    const isCsrf =
      code === 'csrf_invalid'
      || code === 'csrf_missing'
      || (serverMessage !== null && /\bcsrf\b/i.test(serverMessage))
    return isCsrf
      ? {
          kind: 'csrf_rejected',
          status,
          code,
          message: '보안 토큰(CSRF)이 만료되었습니다. 다시 시도하세요.',
          retryable: true,
        }
      : {
          kind: 'forbidden',
          status,
          code,
          message: '이미지 업로드 권한이 없습니다. 관리자 권한이 필요합니다.',
          retryable: false,
        }
  }
  if (status === 413 || code === 'media_too_large') {
    const limitLabel = maxBytes !== undefined ? `(${formatByteLimit(maxBytes)})` : ''
    return {
      kind: 'media_too_large',
      status,
      code: code ?? 'media_too_large',
      message: `이미지 크기가 서버 허용 한도${limitLabel}를 넘었습니다.`,
      retryable: false,
      ...(maxBytes !== undefined ? { maxBytes } : {}),
      ...(sizeBytes !== undefined ? { sizeBytes } : {}),
    }
  }
  if (code === 'svg_not_allowed') {
    return {
      kind: 'svg_not_allowed',
      status,
      code,
      message: 'SVG 파일은 보안 정책상 업로드할 수 없습니다. PNG, JPEG, GIF, WebP만 지원합니다.',
      retryable: false,
    }
  }
  if (code === 'mime_mismatch') {
    return {
      kind: 'mime_mismatch',
      status,
      code,
      message: '파일 형식과 실제 이미지 내용이 일치하지 않습니다.',
      retryable: false,
    }
  }
  if (status === 415 || code === 'unsupported_media_type') {
    return {
      kind: 'unsupported_media_type',
      status,
      code: code ?? 'unsupported_media_type',
      message: '지원하지 않는 이미지 형식입니다. PNG, JPEG, GIF, WebP만 업로드할 수 있습니다.',
      retryable: false,
    }
  }
  if (code === 'empty_upload') {
    return {
      kind: 'empty_upload',
      status,
      code,
      message: '빈 파일은 업로드할 수 없습니다.',
      retryable: false,
    }
  }
  if (code === 'truncated_upload') {
    return {
      kind: 'truncated_upload',
      status,
      code,
      message: '전송 중 이미지 파일이 잘렸습니다. 다시 시도하세요.',
      retryable: true,
    }
  }
  if (status >= 500 || code === 'media_store_failed') {
    return {
      kind: 'store_failed',
      status,
      code: code ?? 'media_store_failed',
      message: '서버에 이미지를 저장하지 못했습니다. 잠시 후 다시 시도하세요.',
      retryable: true,
    }
  }
  return {
    kind: 'bad_request',
    status,
    code,
    message: serverMessage ? `이미지 업로드 실패: ${serverMessage}` : `이미지 업로드 실패 (HTTP ${status})`,
    retryable: false,
  }
}

function buildUploadHeaders(mime: WorkspaceRasterMime): Record<string, string> {
  const headers: Record<string, string> = {
    Accept: 'application/json',
    'Content-Type': mime,
  }
  const session = authSession.peek()
  if (session.kind === 'multi_account_signed_in') {
    const csrf = getActiveCsrfToken()
    if (csrf) headers['x-masc-csrf-token'] = csrf
  } else {
    const token = getSingleUserToken()
    if (token) headers.Authorization = `Bearer ${token}`
  }
  return headers
}

/**
 * Uploads a single validated raster image via raw binary `POST /api/v1/media`.
 * Enforces client-side magic-byte validation, same-origin workspace routing,
 * single-user Bearer / multi-account CSRF (+ 1x retry), epoch fencing, and `AbortSignal`.
 */
export async function uploadWorkspaceMedia(
  file: Blob,
  opts: UploadWorkspaceMediaOptions = {},
): Promise<Result<UploadedMediaReceipt, MediaUploadError>> {
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch
  const startEpoch = currentSessionEpoch()
  const controller = new AbortController()

  const onCallerAbort = () => controller.abort(opts.signal?.reason)
  if (opts.signal) {
    if (opts.signal.aborted) {
      return err({
        kind: 'aborted',
        status: null,
        code: null,
        message: '업로드가 취소되었습니다.',
        retryable: false,
      })
    }
    opts.signal.addEventListener('abort', onCallerAbort, { once: true })
  }

  const unsubEpoch = sessionEpoch.subscribe((epoch) => {
    if (epoch !== startEpoch) {
      controller.abort('epoch_stale')
    }
  })

  try {
    const validated = await validateWorkspaceMediaFile(file, {
      maxBytes: opts.maxBytes,
      signal: controller.signal,
    })
    if (!isEpochCurrent(startEpoch)) {
      return err({
        kind: 'epoch_stale',
        status: null,
        code: 'epoch_stale',
        message: '워크스페이스 또는 계정이 전환되어 업로드를 취소했습니다.',
        retryable: false,
      })
    }
    if (!validated.ok) return validated
    const verifiedMime = validated.value

    const targetUrl = resolveWorkspaceUrl(WORKSPACE_MEDIA_UPLOAD_PATH)

    const executeOnce = async (): Promise<Result<UploadedMediaReceipt, MediaUploadError>> => {
      if (!isEpochCurrent(startEpoch)) {
        return err({
          kind: 'epoch_stale',
          status: null,
          code: 'epoch_stale',
          message: '워크스페이스 또는 계정이 전환되어 업로드를 취소했습니다.',
          retryable: false,
        })
      }
      if (controller.signal.aborted) {
        return err({
          kind: 'aborted',
          status: null,
          code: null,
          message: '업로드가 취소되었습니다.',
          retryable: false,
        })
      }

      let response: Response
      try {
        response = await fetchImpl(targetUrl, {
          method: 'POST',
          credentials: 'same-origin',
          mode: 'same-origin',
          redirect: 'error',
          headers: buildUploadHeaders(verifiedMime),
          body: file,
          signal: controller.signal,
        })
      } catch (cause) {
        if (!isEpochCurrent(startEpoch)) {
          return err({
            kind: 'epoch_stale',
            status: null,
            code: 'epoch_stale',
            message: '워크스페이스 또는 계정이 전환되어 업로드를 취소했습니다.',
            retryable: false,
          })
        }
        if (controller.signal.aborted) {
          return err({
            kind: 'aborted',
            status: null,
            code: null,
            message: '업로드가 취소되었습니다.',
            retryable: false,
          })
        }
        return err({
          kind: 'network',
          status: null,
          code: 'network_error',
          message: cause instanceof Error
            ? `네트워크 오류로 업로드하지 못했습니다: ${cause.message}`
            : '네트워크 오류로 업로드하지 못했습니다.',
          retryable: true,
        })
      }

      if (!isEpochCurrent(startEpoch)) {
        return err({
          kind: 'epoch_stale',
          status: null,
          code: 'epoch_stale',
          message: '워크스페이스 또는 계정이 전환되어 업로드를 취소했습니다.',
          retryable: false,
        })
      }

      let parsedBody: unknown = null
      const contentType = response.headers.get('content-type') ?? ''
      try {
        parsedBody = contentType.includes('application/json') || contentType === ''
          ? await response.json()
          : await response.text()
      } catch {
        if (!isEpochCurrent(startEpoch)) {
          return err({
            kind: 'epoch_stale',
            status: null,
            code: 'epoch_stale',
            message: '워크스페이스 또는 계정이 전환되어 업로드를 취소했습니다.',
            retryable: false,
          })
        }
        if (controller.signal.aborted) {
          return err({
            kind: 'aborted',
            status: null,
            code: null,
            message: '업로드가 취소되었습니다.',
            retryable: false,
          })
        }
        if (!response.ok) {
          return err(classifyUploadHttpError(response.status, null))
        }
        return err({
          kind: 'decode',
          status: response.status,
          code: 'invalid_json',
          message: '업로드 응답 JSON을 해석하지 못했습니다.',
          retryable: false,
        })
      }

      if (!isEpochCurrent(startEpoch)) {
        return err({
          kind: 'epoch_stale',
          status: null,
          code: 'epoch_stale',
          message: '워크스페이스 또는 계정이 전환되어 업로드를 취소했습니다.',
          retryable: false,
        })
      }
      if (controller.signal.aborted) {
        return err({
          kind: 'aborted',
          status: null,
          code: null,
          message: '업로드가 취소되었습니다.',
          retryable: false,
        })
      }

      if (!response.ok) {
        return err(classifyUploadHttpError(response.status, parsedBody))
      }

      return decodeUploadedMediaReceipt(parsedBody, response.status)
    }

    const prevCsrf = getActiveCsrfToken()
    const first = await executeOnce()
    if (
      !first.ok
      && first.error.kind === 'csrf_rejected'
      && authSession.peek().kind === 'multi_account_signed_in'
      && isEpochCurrent(startEpoch)
      && !controller.signal.aborted
    ) {
      const refreshed = await refreshMultiAccountCsrf(fetchImpl)
      if (!isEpochCurrent(startEpoch)) {
        return err({
          kind: 'epoch_stale',
          status: null,
          code: 'epoch_stale',
          message: '워크스페이스 또는 계정이 전환되어 업로드를 취소했습니다.',
          retryable: false,
        })
      }
      if (controller.signal.aborted) {
        return err({
          kind: 'aborted',
          status: null,
          code: null,
          message: '업로드가 취소되었습니다.',
          retryable: false,
        })
      }
      if (refreshed && refreshed !== prevCsrf) {
        return await executeOnce()
      }
    }
    if (
      !first.ok
      && first.error.kind === 'forbidden'
      && authSession.peek().kind === 'multi_account_signed_in'
      && isEpochCurrent(startEpoch)
    ) {
      scheduleForbiddenRoleRecheck(fetchImpl)
    }
    return first
  } finally {
    unsubEpoch()
    if (opts.signal) opts.signal.removeEventListener('abort', onCallerAbort)
  }
}

// ── Shared Editor Text & Clipboard/Drop Helpers ───────────────────────────

/**
 * Derives a clean Markdown alt caption from an uploaded filename.
 * Escapes/strips Markdown bracket syntax and control newlines.
 */
export function deriveImageAltText(fileName?: string | null): string {
  const raw = (fileName ?? '').trim()
  if (!raw) return '이미지'
  const withoutExt = raw.replace(/\.[^./\\]+$/, '')
  const cleaned = withoutExt
    .replace(/[\r\n\t]+/g, ' ')
    .replace(/[[\]]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
  return cleaned || '이미지'
}

/**
 * Formats an uploaded workspace media receipt using the canonical Markdown
 * image syntax (`![caption](/api/v1/media/<sha256>)`).
 */
export function formatUploadedImageMarkdown(
  receipt: Pick<UploadedMediaReceipt, 'path'>,
  alt?: string,
): string {
  const safeAlt = (alt ?? '')
    .replace(/[\r\n\t]+/g, ' ')
    .replace(/[[\]]/g, '')
    .replace(/\s+/g, ' ')
    .trim() || '이미지'
  return `![${safeAlt}](${receipt.path})`
}

/**
 * Inserts a Markdown snippet into `source` at `[selectionStart, selectionEnd]`,
 * returning the updated text and the resulting caret offset.
 */
export function insertTextAtSelection(
  source: string,
  selectionStart: number,
  selectionEnd: number,
  snippet: string,
): { readonly value: string; readonly cursor: number } {
  const start = Math.max(0, Math.min(source.length, selectionStart))
  const end = Math.max(start, Math.min(source.length, selectionEnd))
  const next = source.slice(0, start) + snippet + source.slice(end)
  return { value: next, cursor: start + snippet.length }
}

/**
 * Checks whether a DragEvent's DataTransfer carries files (and not merely
 * selected text being dragged around inside the editor).
 */
export function dataTransferHasFiles(dt: DataTransfer | null | undefined): boolean {
  if (!dt) return false
  if (dt.files && dt.files.length > 0) return true
  if (dt.types && Array.from(dt.types).includes('Files')) return true
  if (dt.items) {
    for (let i = 0; i < dt.items.length; i += 1) {
      if (dt.items[i]?.kind === 'file') return true
    }
  }
  return false
}

function isLikelyImageFile(file: File): boolean {
  if (file.type.toLowerCase().startsWith('image/')) return true
  return IMAGE_FILE_EXT_RE.test(file.name)
}

/**
 * Extracts `File` instances from a clipboard or drop `DataTransfer`.
 * For paste events (`imagesOnly: true`), only image files are returned so plain
 * text pastes continue to use native browser handling untouched.
 */
export function extractUploadFilesFromDataTransfer(
  dt: DataTransfer | null | undefined,
  opts: { readonly imagesOnly?: boolean } = {},
): readonly File[] {
  if (!dt) return []
  const extracted: File[] = []
  if (dt.items && dt.items.length > 0) {
    for (let i = 0; i < dt.items.length; i += 1) {
      const item = dt.items[i]
      if (item && item.kind === 'file') {
        const file = item.getAsFile()
        if (file) extracted.push(file)
      }
    }
  }
  if (extracted.length === 0 && dt.files && dt.files.length > 0) {
    for (let i = 0; i < dt.files.length; i += 1) {
      const file = dt.files[i]
      if (file) extracted.push(file)
    }
  }
  if (!opts.imagesOnly) return extracted
  return extracted.filter(isLikelyImageFile)
}
