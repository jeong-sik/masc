/**
 * Shared client-side attachment validation, MIME resolution, dimension probing,
 * and formatting helpers (ported cleanly from the retired legacy chat helper).
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

// Matches server Attachment_store default `MASC_ATTACHMENT_MAX_BYTES` (20 MiB).
export const DEFAULT_MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024
export const MAX_COMPOSER_ATTACHMENTS = 8

export const ATTACHMENT_INPUT_ACCEPT = 'image/*,application/pdf,audio/*'

// Only consulted when File.type is empty; a declared unsupported MIME type is
// authoritative and never overwritten by a filename extension.
const EXTENSION_MIME_FALLBACK: Readonly<Record<string, string>> = {
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  webp: 'image/webp',
  gif: 'image/gif',
  pdf: 'application/pdf',
  mp3: 'audio/mpeg',
  wav: 'audio/wav',
  ogg: 'audio/ogg',
  mid: 'audio/midi',
  midi: 'audio/midi',
  m4a: 'audio/mp4',
  webm: 'audio/webm',
}

const REJECTED_ACTIVE_MIMES = new Set([
  'image/svg+xml',
  'text/html',
  'application/xhtml+xml',
])

export function resolveAttachmentMimeType(file: Pick<File, 'type' | 'name'>): string {
  const declared = file.type.trim().toLowerCase().split(';', 1)[0]?.trim() ?? ''
  if (declared !== '') {
    return declared === 'image/jpg' ? 'image/jpeg' : declared
  }
  const dot = file.name.lastIndexOf('.')
  const ext = dot >= 0 ? file.name.slice(dot + 1).toLowerCase() : ''
  return EXTENSION_MIME_FALLBACK[ext] ?? ''
}

export function classifyAttachmentKind(mimeType: string): AttachmentKind {
  const normalized = mimeType.toLowerCase()
  if (normalized.startsWith('image/')) return 'image'
  if (normalized.startsWith('audio/')) return 'audio'
  return 'document'
}

export function validateAttachmentFile(
  file: Pick<File, 'type' | 'name' | 'size'>,
  maxBytes = DEFAULT_MAX_ATTACHMENT_BYTES,
): string | null {
  const mimeType = resolveAttachmentMimeType(file)
  if (REJECTED_ACTIVE_MIMES.has(mimeType)) {
    return `보안상 업로드할 수 없는 형식입니다: ${mimeType}`
  }
  const allowed =
    ALLOWED_IMAGE_TYPES.includes(mimeType)
    || ALLOWED_DOCUMENT_TYPES.includes(mimeType)
    || ALLOWED_AUDIO_TYPES.includes(mimeType)
  if (!allowed) {
    return `지원하지 않는 파일 형식입니다: ${mimeType === '' ? (file.name || '알 수 없음') : mimeType}`
  }
  if (file.size <= 0) {
    return `빈 파일은 첨부할 수 없습니다: ${file.name || '파일'}`
  }
  if (file.size > maxBytes) {
    const limitMb = Math.round(maxBytes / (1024 * 1024))
    return `파일 크기 초과 (최대 ${limitMb}MB): ${file.name}`
  }
  return null
}

/**
 * Best-effort image dimension reader for immediate composer thumbnail metadata.
 */
export function readImageDimensions(
  file: File | Blob,
): Promise<{ readonly width: number; readonly height: number } | null> {
  if (typeof Image === 'undefined' || typeof URL === 'undefined' || typeof URL.createObjectURL !== 'function') {
    return Promise.resolve(null)
  }
  return new Promise((resolve) => {
    const img = new Image()
    const objectUrl = URL.createObjectURL(file)
    const finish = (dims: { readonly width: number; readonly height: number } | null) => {
      try {
        URL.revokeObjectURL(objectUrl)
      } catch { /* ignore */ }
      resolve(dims)
    }
    img.onload = () => {
      if (img.naturalWidth > 0 && img.naturalHeight > 0) {
        finish({ width: img.naturalWidth, height: img.naturalHeight })
      } else {
        finish(null)
      }
    }
    img.onerror = () => finish(null)
    img.src = objectUrl
  })
}

/**
 * Best-effort local object URL for immediate image preview chips while uploading.
 */
export function createLocalPreviewUrl(file: File | Blob, mimeType: string): string | null {
  if (!mimeType.startsWith('image/')) return null
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
  } catch { /* ignore */ }
}

/**
 * Extracts pasted/dropped File objects cleanly from a DataTransfer.
 * Handles both `clipboardData.items` (Chrome/Safari pasted screenshots) and
 * `clipboardData.files` (Firefox/jsdom/happy-dom tests), deduplicating files.
 */
export function extractTransferFiles(transfer: DataTransfer | null | undefined): File[] {
  if (!transfer) return []
  const files: File[] = []
  if (transfer.items && transfer.items.length > 0) {
    for (let i = 0; i < transfer.items.length; i += 1) {
      const item = transfer.items[i]
      if (!item || item.kind !== 'file') continue
      const f = item.getAsFile()
      if (f) files.push(f)
    }
  }
  if (files.length === 0 && transfer.files && transfer.files.length > 0) {
    for (let i = 0; i < transfer.files.length; i += 1) {
      const f = transfer.files[i]
      if (f) files.push(f)
    }
  }
  return files
}

export function formatAttachmentBytes(bytes: number | null | undefined): string {
  if (bytes == null || !Number.isFinite(bytes) || bytes < 0) return ''
  if (bytes < 1024) return `${Math.trunc(bytes)} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`
}

export function formatAttachmentOrigin(origin: string | undefined): string | null {
  if (!origin) return null
  switch (origin) {
    case 'user_upload':
      return '사용자 업로드'
    case 'tool_capture':
      return '도구 캡처'
    case 'model_generated':
      return '모델 생성'
    case 'connector_inbound':
      return '외부 채널'
    default:
      return origin
  }
}
