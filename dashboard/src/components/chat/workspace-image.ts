import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import {
  blobToDataUrl,
  downloadAttachment,
  fetchAttachmentBlob,
  type AttachmentRef,
} from '../../api/attachments'
import { fetchWithTimeout } from '../../api/core'
import { DEFAULT_GET_TIMEOUT_MS } from '../../config/constants'
import { authSession, getSingleUserToken, resolveWorkspaceUrl, sessionEpoch } from '../../core/auth'
import {
  appendAttachmentQuery,
  extractAttachmentIdFromPath,
  isWorkspaceAttachmentPath,
  isWorkspaceMediaPath,
  isWorkspaceRasterMime,
} from '../../lib/keeper-media'
import { parseUrl } from '../../lib/parse-url'
import { copyToClipboard } from '../common/copyable-code'
import { ChatPreviewModal } from '../primitives/chat-preview-modal'
import { formatAttachmentBytes, formatAttachmentOrigin } from '../attachments/validation'

// Match the server ceiling of 50 MiB.
const MAX_IMAGE_BYTES = 50 * 1024 * 1024
const DEFAULT_THUMBNAIL_MAX_PX = 640

async function readImage(response: Response): Promise<{ readonly blob: Blob; readonly contentType: string } | null> {
  const contentType = response.headers.get('content-type')?.split(';', 1)[0]?.trim()
  if (!response.ok || !isWorkspaceRasterMime(contentType)
    || Number(response.headers.get('content-length')) > MAX_IMAGE_BYTES
    || !response.body) {
    await response.body?.cancel()
    return null
  }
  const reader = response.body.getReader()
  const chunks: ArrayBuffer[] = []
  let size = 0
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) return size > 0 ? { blob: new Blob(chunks, { type: contentType }), contentType } : null
      size += value.byteLength
      if (size > MAX_IMAGE_BYTES) {
        await reader.cancel()
        return null
      }
      chunks.push(value.slice().buffer)
    }
  } finally {
    reader.releaseLock()
  }
}

export interface WorkspaceChatImageProps {
  readonly path: string
  readonly caption?: string
  readonly workspaceEpoch: number
  readonly attachment?: AttachmentRef
  /** Override `?max_px=N` thumbnail sizing for `/api/v1/attachments/*` URLs. Pass `null` for full-res. */
  readonly thumbnailMaxPx?: number | null
  readonly compact?: boolean
}

interface LoadedImageState {
  readonly path: string
  readonly epoch: number
  readonly src: string | null
  readonly contentType: string | null
}

export function WorkspaceChatImage({
  path,
  caption,
  workspaceEpoch,
  attachment,
  thumbnailMaxPx,
  compact = false,
}: WorkspaceChatImageProps) {
  const ref = useRef<HTMLElement>(null)
  const [visible, setVisible] = useState(typeof IntersectionObserver === 'undefined')
  const [attempt, setAttempt] = useState(0)
  const epoch = sessionEpoch.value
  const currentWorkspace = workspaceEpoch === epoch
  const [loaded, setLoaded] = useState<LoadedImageState | null>(null)
  const [fullLoaded, setFullLoaded] = useState<LoadedImageState | null>(null)
  const [zoomed, setZoomed] = useState(false)
  const [actualSize, setActualSize] = useState(false)
  const [naturalDims, setNaturalDims] = useState<{ readonly width: number; readonly height: number } | null>(null)
  const [downloading, setDownloading] = useState(false)
  const [copiedKey, setCopiedKey] = useState<'id' | 'url' | null>(null)

  const isCanonicalAttachment = isWorkspaceAttachmentPath(path)
  const effectiveThumbPx = isCanonicalAttachment
    ? (thumbnailMaxPx === undefined ? DEFAULT_THUMBNAIL_MAX_PX : thumbnailMaxPx)
    : null
  const thumbPath = effectiveThumbPx !== null && effectiveThumbPx > 0
    ? appendAttachmentQuery(path, { max_px: effectiveThumbPx })
    : path

  useEffect(() => {
    const figure = ref.current
    if (!currentWorkspace || !figure || typeof IntersectionObserver === 'undefined') return
    const observer = new IntersectionObserver(([entry]) => {
      if (entry?.isIntersecting) {
        setVisible(true)
        observer.disconnect()
      }
    }, {
      rootMargin: '160px',
    })
    observer.observe(figure)
    return () => observer.disconnect()
  }, [currentWorkspace])

  useEffect(() => {
    if (!visible || !currentWorkspace || sessionEpoch.peek() !== epoch || !isWorkspaceMediaPath(path)) return
    const destination = parseUrl(resolveWorkspaceUrl(thumbPath), window.location.origin)
    if (!destination || destination.origin !== window.location.origin) {
      setLoaded({ path, epoch, src: null, contentType: null })
      return
    }
    const controller = new AbortController()
    const token = authSession.peek().kind === 'multi_account_signed_in' ? null : getSingleUserToken()
    const store = (result: { readonly src: string | null; readonly contentType: string | null }) => {
      if (!controller.signal.aborted && sessionEpoch.peek() === epoch) {
        setLoaded({ path, epoch, src: result.src, contentType: result.contentType })
      }
    }
    void fetchWithTimeout(
      destination.href,
      {
        credentials: 'same-origin',
        mode: 'same-origin',
        redirect: 'error',
        signal: controller.signal,
        headers: token ? { Authorization: `Bearer ${token}` } : undefined,
      },
      DEFAULT_GET_TIMEOUT_MS,
      readImage,
    ).then(async (image) => {
      if (!image) return { src: null, contentType: null }
      const src = await blobToDataUrl(image.blob)
      return { src, contentType: image.contentType }
    }).then(store, () => store({ src: null, contentType: null }))
    return () => controller.abort()
  }, [attempt, currentWorkspace, epoch, path, thumbPath, visible])

  // Upgrade lightbox image to full resolution when a downscaled thumbnail was loaded.
  useEffect(() => {
    if (!zoomed || !currentWorkspace || effectiveThumbPx === null) return
    if (fullLoaded?.path === path && fullLoaded.epoch === epoch && fullLoaded.src) return
    const controller = new AbortController()
    void fetchAttachmentBlob(path, {
      maxPx: null,
      requireRasterImage: true,
      signal: controller.signal,
    }).then(async (res) => {
      if (controller.signal.aborted || sessionEpoch.peek() !== epoch) return
      if (!res.ok) return
      const src = await blobToDataUrl(res.value.blob)
      if (!controller.signal.aborted && sessionEpoch.peek() === epoch && src) {
        setFullLoaded({ path, epoch, src, contentType: res.value.contentType })
      }
    })
    return () => controller.abort()
  }, [zoomed, currentWorkspace, effectiveThumbPx, epoch, path, fullLoaded])

  if (!currentWorkspace) return null
  const current = loaded?.path === path && loaded.epoch === epoch ? loaded : null
  const lightboxSrc = (fullLoaded?.path === path && fullLoaded.epoch === epoch && fullLoaded.src)
    ? fullLoaded.src
    : current?.src ?? null

  const attachmentId = attachment?.attachment_id ?? attachment?.id ?? extractAttachmentIdFromPath(path) ?? path
  const displayName = caption || attachment?.caption || attachment?.filename || '첨부 이미지'
  const width = attachment?.width ?? naturalDims?.width ?? null
  const height = attachment?.height ?? naturalDims?.height ?? null
  const dimsLabel = width && height ? `${width}×${height}` : null
  const mimeLabel = attachment?.mime_type ?? current?.contentType ?? null
  const sizeLabel = attachment && attachment.bytes > 0 ? formatAttachmentBytes(attachment.bytes) : null
  const originLabel = formatAttachmentOrigin(attachment?.origin)
  const metaParts = [dimsLabel, mimeLabel, sizeLabel, originLabel].filter((p): p is string => Boolean(p))

  const handleDownload = async () => {
    if (downloading) return
    setDownloading(true)
    try {
      await downloadAttachment({
        url: path,
        id: attachmentId,
        mime_type: mimeLabel ?? 'image/png',
        filename: attachment?.filename ?? null,
      })
    } finally {
      setDownloading(false)
    }
  }

  const handleCopy = async (kind: 'id' | 'url') => {
    const value = kind === 'id' ? attachmentId : resolveWorkspaceUrl(path)
    const copied = await copyToClipboard(value)
    if (copied) {
      setCopiedKey(kind)
      setTimeout(() => setCopiedKey((cur) => (cur === kind ? null : cur)), 1500)
    }
  }

  return html`
    <figure class=${`img-out${compact ? ' img-out--compact' : ''}`} ref=${ref} data-attachment-id=${attachmentId}>
      ${current?.src ? html`
        <div
          class="chat-block-media-frame img-frame cursor-zoom-in"
          role="button"
          tabIndex=${0}
          aria-label=${`${displayName} 크게 보기`}
          onClick=${() => {
            setActualSize(false)
            setZoomed(true)
          }}
          onKeyDown=${(e: KeyboardEvent) => {
            if (e.isComposing || e.keyCode === 229) return
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault()
              setActualSize(false)
              setZoomed(true)
            }
          }}
        >
          <img
            src=${current.src}
            alt=${displayName}
            class=${compact ? 'max-h-48 w-full rounded-[var(--r-1)] object-contain' : 'max-h-96 w-full rounded-[var(--r-1)] object-contain'}
            onLoad=${(e: Event) => {
              const img = e.currentTarget as HTMLImageElement
              if (img.naturalWidth > 0 && img.naturalHeight > 0) {
                setNaturalDims({ width: img.naturalWidth, height: img.naturalHeight })
              }
            }}
            onError=${() => {
              setZoomed(false)
              setLoaded({ path, epoch, src: null, contentType: null })
            }}
          />
        </div>
      ` : html`
        <div class="chat-block-media-ph img-ph">
          <span role="status">${current ? '이미지를 불러올 수 없습니다' : displayName}</span>
          ${current && html`
            <button type="button" class="btn-ghost" aria-label="이미지 다시 시도" onClick=${() => {
              setLoaded(null)
              setAttempt(previous => previous + 1)
            }}>다시 시도</button>
          `}
        </div>
      `}
      ${(caption || metaParts.length > 0) && html`
        <figcaption class="att-figcaption">
          ${caption && html`<span>${caption}</span>`}
          ${metaParts.length > 0 && html`<span class="mono att-meta-inline">${metaParts.join(' · ')}</span>`}
        </figcaption>
      `}
      ${zoomed && lightboxSrc && html`
        <${ChatPreviewModal}
          title=${displayName}
          subtitle=${metaParts.join(' · ') || undefined}
          onClose=${() => setZoomed(false)}
          actions=${html`
            <button
              type="button"
              class="btn-ghost btn-compact"
              onClick=${() => setActualSize((prev) => !prev)}
            >
              ${actualSize ? '화면에 맞추기' : '원본 크기 (1:1)'}
            </button>
            <button
              type="button"
              class="btn-ghost btn-compact"
              disabled=${downloading}
              onClick=${() => void handleDownload()}
            >
              ${downloading ? '다운로드 중…' : '다운로드'}
            </button>
            <button
              type="button"
              class="btn-ghost btn-compact"
              onClick=${() => void handleCopy('id')}
            >
              ${copiedKey === 'id' ? 'ID 복사됨' : 'ID 복사'}
            </button>
            <button
              type="button"
              class="btn-ghost btn-compact"
              onClick=${() => void handleCopy('url')}
            >
              ${copiedKey === 'url' ? 'URL 복사됨' : 'URL 복사'}
            </button>
          `}
          footer=${html`
            <span class="mono" data-testid="lightbox-meta-id">${attachmentId}</span>
            <span class="mono" data-testid="lightbox-meta-details">
              ${metaParts.join(' · ') || path}
            </span>
          `}
        >
          <img
            src=${lightboxSrc}
            alt=${displayName}
            class=${actualSize
              ? 'max-w-none rounded-[var(--r-1)]'
              : 'max-h-[75vh] max-w-full rounded-[var(--r-1)] object-contain'}
          />
        <//>
      `}
    </figure>
  `
}
