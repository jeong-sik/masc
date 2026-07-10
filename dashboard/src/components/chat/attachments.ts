// Chat attachment helpers — file validation, resize, and data-URL
// encoding shared by the keeper conversation composer.
//
// Extracted from the former keeper-chat-panel.ts so the unified
// KeeperConversationPanel (keeper-shared.ts) owns the only attachment
// pipeline. Pure validation lives here for direct unit testing; the
// DOM-dependent steps (FileReader, canvas resize) stay best-effort and
// fall back to the original file on failure.

import type { KeeperConversationAttachment } from '../../types'

export const ALLOWED_IMAGE_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp']
export const ALLOWED_FILE_TYPES = ['text/plain', 'text/markdown', 'application/json', 'text/csv']
export const ALLOWED_AUDIO_TYPES = ['audio/mpeg', 'audio/mp4', 'audio/wav', 'audio/webm', 'audio/ogg']
export const MAX_IMAGE_SIZE = 5 * 1024 * 1024
export const MAX_FILE_SIZE = 2 * 1024 * 1024
export const MAX_TOTAL_PAYLOAD = 10 * 1024 * 1024
export const MAX_ATTACHMENTS = 5

export function validateFile(file: File): string | null {
  if (file.type.startsWith('image/')) {
    if (!ALLOWED_IMAGE_TYPES.includes(file.type)) return `지원하지 않는 이미지 형식: ${file.type}`
    if (file.size > MAX_IMAGE_SIZE) return '이미지 크기 초과 (최대 5MB)'
  } else if (file.type.startsWith('audio/')) {
    if (!ALLOWED_AUDIO_TYPES.includes(file.type)) return `지원하지 않는 오디오 형식: ${file.type}`
    if (file.size > MAX_FILE_SIZE) return '오디오 크기 초과 (최대 2MB)'
  } else {
    if (!ALLOWED_FILE_TYPES.includes(file.type)) return `지원하지 않는 파일 형식: ${file.type}`
    if (file.size > MAX_FILE_SIZE) return '파일 크기 초과 (최대 2MB)'
  }
  return null
}

export function readFileAsDataURL(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result as string)
    reader.onerror = () => reject(new Error('파일 읽기 실패'))
    reader.readAsDataURL(file)
  })
}

export async function resizeImage(file: File, maxWidth = 1920): Promise<File> {
  if (!file.type.startsWith('image/')) return file
  return new Promise((resolve) => {
    const img = new Image()
    const objectUrl = URL.createObjectURL(file)
    img.onload = () => {
      URL.revokeObjectURL(objectUrl)
      if (img.width <= maxWidth) { resolve(file); return }
      const canvas = document.createElement('canvas')
      const scale = maxWidth / img.width
      canvas.width = maxWidth
      canvas.height = Math.round(img.height * scale)
      const ctx = canvas.getContext('2d')
      if (!ctx) { resolve(file); return }
      ctx.drawImage(img, 0, 0, canvas.width, canvas.height)
      canvas.toBlob((blob) => {
        if (!blob) { resolve(file); return }
        resolve(new File([blob], file.name, { type: file.type }))
      }, file.type)
    }
    img.onerror = () => {
      URL.revokeObjectURL(objectUrl)
      resolve(file)
    }
    img.src = objectUrl
  })
}

export interface CollectAttachmentsResult {
  attachments: KeeperConversationAttachment[]
  errors: string[]
}

export interface StableAttachmentIdentity {
  name: string
  type?: string | null
  kind?: string | null
  mimeType?: string | null
  size?: number | null
  dims?: string | null
  data?: string | null
  src?: string | null
}

function stableAttachmentHash(value: string): string {
  let hash = 5381
  for (let i = 0; i < value.length; i += 1) {
    hash = ((hash << 5) + hash + value.charCodeAt(i)) | 0
  }
  return (hash >>> 0).toString(36)
}

export function stableAttachmentId(input: StableAttachmentIdentity): string {
  const payload = [
    input.name,
    input.type ?? '',
    input.kind ?? '',
    input.mimeType ?? '',
    String(input.size ?? ''),
    input.dims ?? '',
    input.data ?? input.src ?? '',
  ].join('\x1f')
  return `att-${stableAttachmentHash(payload)}`
}

function uniqueStableAttachmentId(
  baseId: string,
  existing: KeeperConversationAttachment[],
  pending: KeeperConversationAttachment[],
): string {
  const used = new Set([...existing, ...pending].map(att => att.id))
  if (!used.has(baseId)) return baseId

  let suffix = 2
  while (used.has(`${baseId}-${suffix}`)) suffix += 1
  return `${baseId}-${suffix}`
}

/** Validate, resize, and encode [files] into attachments, respecting the
 *  per-file rules plus the total-payload and count budgets relative to
 *  [existing]. Validation failures are collected, not thrown, so the
 *  caller can surface each as a toast. */
function readImageDimensions(file: File): Promise<string | null> {
  return new Promise((resolve) => {
    const img = new Image()
    const url = URL.createObjectURL(file)
    img.onload = () => {
      URL.revokeObjectURL(url)
      resolve(`${img.naturalWidth}×${img.naturalHeight}`)
    }
    img.onerror = () => {
      URL.revokeObjectURL(url)
      resolve(null)
    }
    img.src = url
  })
}

export async function collectAttachments(
  files: FileList,
  existing: KeeperConversationAttachment[],
): Promise<CollectAttachmentsResult> {
  const attachments: KeeperConversationAttachment[] = []
  const errors: string[] = []
  let totalSize = existing.reduce((sum, att) => sum + att.size, 0)

  for (const file of Array.from(files).slice(0, MAX_ATTACHMENTS - existing.length)) {
    const error = validateFile(file)
    if (error) { errors.push(error); continue }
    const resized = await resizeImage(file)
    const dataUrl = await readFileAsDataURL(resized)
    const base64Size = Math.ceil(dataUrl.length * 0.75)
    totalSize += base64Size
    if (totalSize > MAX_TOTAL_PAYLOAD) {
      errors.push('총 첨부 크기가 10MB를 초과합니다.')
      break
    }
    const dims = resized.type.startsWith('image/') ? await readImageDimensions(resized) : null
    const baseId = stableAttachmentId({
      name: resized.name,
      type: resized.type.startsWith('image/') ? 'image' : 'file',
      mimeType: resized.type,
      size: base64Size,
      data: dataUrl,
      dims,
    })
    attachments.push({
      id: uniqueStableAttachmentId(baseId, existing, attachments),
      type: resized.type.startsWith('image/') ? 'image' : 'file',
      name: resized.name,
      size: base64Size,
      mimeType: resized.type,
      data: dataUrl,
      dims: dims ?? undefined,
    })
  }
  return { attachments, errors }
}
