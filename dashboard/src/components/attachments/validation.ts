/**
 * Client-side attachment MIME / size validation and local preview helpers.
 *
 * Shared by `<AttachmentComposer>` (Keeper Chat + Board) and `<AttachmentGallery>`.
 */

import type { AttachmentKind } from '../../api/attachments'

export const ALLOWED_IMAGE_TYPES: readonly string[] = [
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/gif',
]

export const ALLOWED_DOCUMENT_TYPES: readonly string[] = [
  'application/pdf',
]

export const ALLOWED_AUDIO_TYPES: readonly string[] = [
  'audio/mpeg',
  'audio/wav',
  'audio/ogg',
  'audio/midi',
  'audio/mp4',
  'audio/webm',
]

export const ALLOWED_VIDEO_TYPES: readonly string[] = [
  'video/mp4',
  'video/webm',
  'video/quicktime',
]

export const ALLOWED_ATTACHMENT_TYPES: readonly string[] = [
  ...ALLOWED_IMAGE_TYPES,
  ...ALLOWED_DOCUMENT_TYPES,
  ...ALLOWED_AUDIO_TYPES,
  ...ALLOWED_VIDEO_TYPES,
]

export const ATTACHMENT_INPUT_ACCEPT = 'image/*,application/pdf,audio/*,video/mp4,video/webm,video/quicktime'

/** Default per-file limit for images/documents/audio: 20 MiB. */
export const DEFAULT_MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024

/** Default per-file limit for video clips: 50 MiB. */
export const DEFAULT_MAX_VIDEO_BYTES = 50 * 1024 * 1024

/** Max attachments per single message or post. */
export const MAX_COMPOSER_ATTACHMENTS = 8

const MIME_ALIAS_MAP: Readonly<Record<string, string>> = {
  'audio/x-midi': 'audio/midi',
  'audio/mid': 'audio/midi',
  'audio/x-wav': 'audio/wav',
  'audio/wave': 'audio/wav',
  'audio/x-m4a': 'audio/mp4',
  'audio/mp3': 'audio/mpeg',
  'video/x-m4v': 'video/mp4',
  'image/jpg': 'image/jpeg',
}

const EXTENSION_MIME_MAP: Readonly<Record<string, string>> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.pdf': 'application/pdf',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.wave': 'audio/wav',
  '.ogg': 'audio/ogg',
  '.oga': 'audio/ogg',
  '.mid': 'audio/midi',
  '.midi': 'audio/midi',
  '.m4a': 'audio/mp4',
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.mov': 'video/quicktime',
  '.webm': 'video/webm',
}

const BLOCKED_EXECUTABLE_TYPES = new Set([
  'image/svg+xml',
  'text/html',
  'application/xhtml+xml',
  'application/javascript',
  'text/javascript',
])

const BLOCKED_EXTENSIONS = new Set([
  '.svg',
  '.html',
  '.htm',
  '.xhtml',
  '.js',
  '.mjs',
])

export function fileExtensionOf(name: string): string {
  const lower = name.trim().toLowerCase()
  const dot = lower.lastIndexOf('.')
  return dot >= 0 ? lower.slice(dot) : ''
}

export function normalizeAttachmentMimeType(rawMime: string): string {
  const base = rawMime.trim().toLowerCase().split(';')[0]?.trim() ?? ''
  if (!base) return ''
  return MIME_ALIAS_MAP[base] ?? base
}

/**
 * Resolve the effective MIME type for a browser `File`, normalizing aliases
 * (`audio/x-midi` -> `audio/midi`, `audio/x-wav` -> `audio/wav`, `video/x-m4v` -> `video/mp4`)
 * and falling back to filename extension when the browser supplies empty or
 * `application/octet-stream` MIME types.
 */
export function resolveAttachmentMimeType(file: Pick<File, 'name' | 'type'>): string {
  const raw = normalizeAttachmentMimeType(file.type)
  if (raw && raw !== 'application/octet-stream') return raw
  const ext = fileExtensionOf(file.name)
  if (ext && EXTENSION_MIME_MAP[ext]) return EXTENSION_MIME_MAP[ext]
  return raw || 'application/octet-stream'
}

export function classifyAttachmentKind(mimeType: string): AttachmentKind {
  const lower = normalizeAttachmentMimeType(mimeType)
  if (lower.startsWith('image/')) return 'image'
  if (lower.startsWith('audio/')) return 'audio'
  if (lower.startsWith('video/')) return 'video'
  return 'document'
}

export function isMidiMimeType(mimeType: string, filename?: string | null): boolean {
  const normalized = normalizeAttachmentMimeType(mimeType)
  if (normalized === 'audio/midi') return true
  if (filename) {
    const ext = fileExtensionOf(filename)
    if (ext === '.mid' || ext === '.midi') return true
  }
  return false
}

export function audioFormatBadge(mimeType: string, filename?: string | null): string {
  if (isMidiMimeType(mimeType, filename)) return 'MIDI'
  const normalized = normalizeAttachmentMimeType(mimeType)
  switch (normalized) {
    case 'audio/wav':
      return 'WAV'
    case 'audio/mpeg':
      return 'MP3'
    case 'audio/ogg':
      return 'OGG'
    case 'audio/mp4':
      return 'M4A'
    case 'audio/webm':
      return 'WEBM'
    default: {
      const ext = filename ? fileExtensionOf(filename).replace(/^\./, '').toUpperCase() : ''
      return ext || 'AUDIO'
    }
  }
}

export function videoFormatBadge(mimeType: string, filename?: string | null): string {
  const normalized = normalizeAttachmentMimeType(mimeType)
  switch (normalized) {
    case 'video/mp4':
      return 'MP4'
    case 'video/webm':
      return 'WEBM'
    case 'video/quicktime':
      return 'MOV'
    default: {
      const ext = filename ? fileExtensionOf(filename).replace(/^\./, '').toUpperCase() : ''
      return ext || 'VIDEO'
    }
  }
}

export function maxBytesForAttachmentMime(mimeType: string, explicitMaxBytes?: number): number {
  if (typeof explicitMaxBytes === 'number' && Number.isFinite(explicitMaxBytes) && explicitMaxBytes > 0) {
    return explicitMaxBytes
  }
  return classifyAttachmentKind(mimeType) === 'video'
    ? DEFAULT_MAX_VIDEO_BYTES
    : DEFAULT_MAX_ATTACHMENT_BYTES
}

/**
 * Validate a candidate file before upload. Returns `null` when valid or a
 * human-readable Korean error message when rejected.
 */
export function validateAttachmentFile(
  file: Pick<File, 'name' | 'type' | 'size'>,
  maxBytes?: number,
): string | null {
  const mime = resolveAttachmentMimeType(file)
  const ext = fileExtensionOf(file.name)

  if (BLOCKED_EXECUTABLE_TYPES.has(mime) || BLOCKED_EXTENSIONS.has(ext)) {
    return `${file.name || '파일'}: SVG·HTML·스크립트 파일은 보안상 첨부할 수 없습니다.`
  }

  if (!ALLOWED_ATTACHMENT_TYPES.includes(mime)) {
    return `${file.name || '파일'}: 지원하지 않는 형식입니다 (${mime}). PNG, JPEG, WebP, GIF, PDF, MP3/WAV/OGG/MIDI/M4A/WebM 오디오, MP4/WebM/MOV 비디오만 가능합니다.`
  }

  if (file.size <= 0) {
    return `${file.name || '파일'}: 빈 파일은 첨부할 수 없습니다.`
  }

  const limit = maxBytesForAttachmentMime(mime, maxBytes)
  if (file.size > limit) {
    return `${file.name || '파일'}: 최대 크기(${formatAttachmentBytes(limit)})를 초과했습니다 (${formatAttachmentBytes(file.size)}).`
  }

  return null
}

export function formatAttachmentBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '0 B'
  if (bytes < 1024) return `${Math.round(bytes)} B`
  const kib = bytes / 1024
  if (kib < 1024) return `${kib < 10 ? kib.toFixed(1) : Math.round(kib)} KB`
  const mib = kib / 1024
  return `${mib < 10 ? mib.toFixed(1) : Math.round(mib)} MB`
}

export function formatAttachmentOrigin(origin?: string | null): string | null {
  if (!origin) return null
  switch (origin) {
    case 'user_upload':
      return '사용자 업로드'
    case 'tool_capture':
      return '도구 캡처'
    case 'model_generated':
      return '모델 생성'
    case 'board_upload':
      return '게시판 첨부'
    default:
      return origin
  }
}

export function createLocalPreviewUrl(file: File, mimeType: string): string | null {
  if (classifyAttachmentKind(mimeType) !== 'image') return null
  if (typeof URL === 'undefined' || typeof URL.createObjectURL !== 'function') return null
  try {
    return URL.createObjectURL(file)
  } catch {
    return null
  }
}

export function revokeLocalPreviewUrl(url: string | null | undefined): void {
  if (!url || !url.startsWith('blob:')) return
  if (typeof URL === 'undefined' || typeof URL.revokeObjectURL !== 'function') return
  try {
    URL.revokeObjectURL(url)
  } catch {
    // Ignore revoke failures on already-released URLs.
  }
}

/**
 * Best-effort client-side image dimension readout (returns `null` in non-DOM
 * environments or when decoding fails).
 */
export function readImageDimensions(file: File): Promise<{ width: number; height: number } | null> {
  if (typeof Image === 'undefined' || typeof URL === 'undefined' || typeof URL.createObjectURL !== 'function') {
    return Promise.resolve(null)
  }
  return new Promise((resolve) => {
    const objectUrl = URL.createObjectURL(file)
    const img = new Image()
    const cleanup = () => {
      try {
        URL.revokeObjectURL(objectUrl)
      } catch {
        // ignore
      }
    }
    img.onload = () => {
      const w = img.naturalWidth
      const h = img.naturalHeight
      cleanup()
      resolve(w > 0 && h > 0 ? { width: w, height: h } : null)
    }
    img.onerror = () => {
      cleanup()
      resolve(null)
    }
    img.src = objectUrl
  })
}

/**
 * Extract File instances from either a ClipboardEvent's `clipboardData` or a
 * DragEvent's `dataTransfer`. Deduplicates `items` vs `files`.
 */
export function extractTransferFiles(transfer: DataTransfer | null | undefined): File[] {
  if (!transfer) return []
  const out: File[] = []
  const seen = new Set<File>()

  if (transfer.items && transfer.items.length > 0) {
    for (let i = 0; i < transfer.items.length; i += 1) {
      const item = transfer.items[i]
      if (!item || item.kind !== 'file') continue
      const f = item.getAsFile()
      if (f && !seen.has(f)) {
        seen.add(f)
        out.push(f)
      }
    }
  }

  if (out.length === 0 && transfer.files && transfer.files.length > 0) {
    for (let i = 0; i < transfer.files.length; i += 1) {
      const f = transfer.files[i]
      if (f && !seen.has(f)) {
        seen.add(f)
        out.push(f)
      }
    }
  }

  return out
}
