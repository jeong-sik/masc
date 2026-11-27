/**
 * Shared `<AttachmentGallery>` for rendering user, tool, and model-generated
 * attachments inline across Keeper Chat and Board posts/comments.
 *
 * - Images: lazy `?max_px=640` thumbnails via `<WorkspaceChatImage>` with
 *   lightbox zoom, dimensions/MIME/origin metadata, Download (`?download=1`),
 *   and Copy ID/URL.
 * - Audio (WAV/MP3/OGG/M4A/WebM): auto-loads when visible -> `<audio controls preload="metadata">`
 *   with format badge, duration readout, Download, and Copy ID.
 * - MIDI (`audio/midi`, `.mid`/`.midi`): renders `<MidiScorePlayer>` (Web Audio
 *   + lazy `sonivox.sf2` + optional inline notation view), NEVER `<audio controls>`.
 * - Video (`video/mp4`, `video/webm`, `video/quicktime`): authenticated `<video controls playsInline>`
 *   with optional poster (`?max_px=640&format=png`), lightbox zoom, resolution/size/origin,
 *   Download, and Copy ID.
 * - Documents (PDF etc.): download card with filename, MIME, size, origin,
 *   Download (`?download=1`), and Copy ID/URL.
 */

import { html } from 'htm/preact'
import type { RefObject } from 'preact'
import { useCallback, useEffect, useRef, useState } from 'preact/hooks'
import {
  dedupeAttachments,
  downloadAttachment,
  fetchAttachmentBlob,
  type AttachmentRef,
} from '../../api/attachments'
import { currentSessionEpoch, resolveWorkspaceUrl, sessionEpoch } from '../../core/auth'
import { isWorkspaceRasterMime } from '../../lib/keeper-media'
import { WorkspaceChatImage } from '../chat/workspace-image'
import { MidiScorePlayer, formatPlaybackTime } from '../common/alphatab-score'
import { copyToClipboard } from '../common/copyable-code'
import { ChatPreviewModal } from '../primitives/chat-preview-modal'
import {
  audioFormatBadge,
  formatAttachmentBytes,
  formatAttachmentOrigin,
  isMidiMimeType,
  videoFormatBadge,
} from './validation'

function useInViewOnce<T extends HTMLElement>(rootMargin = '200px'): [RefObject<T>, boolean] {
  const ref = useRef<T>(null)
  const [inView, setInView] = useState(() => typeof IntersectionObserver === 'undefined')

  useEffect(() => {
    const el = ref.current
    if (!el || inView) return undefined
    if (typeof IntersectionObserver === 'undefined') {
      setInView(true)
      return undefined
    }
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry?.isIntersecting) setInView(true)
      },
      { rootMargin },
    )
    observer.observe(el)
    return () => observer.disconnect()
  }, [inView, rootMargin])

  return [ref, inView]
}

function revokeUrlSafe(url: string | null): void {
  if (!url || !url.startsWith('blob:')) return
  try {
    URL.revokeObjectURL(url)
  } catch {
    // Ignore revoke errors on released object URLs.
  }
}

function WorkspaceMidiAttachment({
  attachment,
  workspaceEpoch,
}: {
  readonly attachment: AttachmentRef
  readonly workspaceEpoch: number
}) {
  const epoch = sessionEpoch.value
  const currentWorkspace = workspaceEpoch === epoch
  const [hostRef, inView] = useInViewOnce<HTMLDivElement>()
  const [bytes, setBytes] = useState<Uint8Array | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [downloading, setDownloading] = useState(false)
  const [copied, setCopied] = useState(false)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    if (!currentWorkspace || !inView) return
    const ctrl = new AbortController()
    setLoading(true)
    setError(null)
    void fetchAttachmentBlob(attachment.url, { signal: ctrl.signal })
      .then(async (res) => {
        if (ctrl.signal.aborted) return
        if (!res.ok) {
          setError(res.error.message)
          return
        }
        const buf = await res.value.blob.arrayBuffer()
        if (ctrl.signal.aborted) return
        setBytes(new Uint8Array(buf))
      })
      .catch((err) => {
        if (ctrl.signal.aborted) return
        setError(err instanceof Error ? err.message : 'MIDI 데이터를 불러오지 못했습니다.')
      })
      .finally(() => {
        if (!ctrl.signal.aborted) setLoading(false)
      })
    return () => ctrl.abort()
  }, [attachment.url, currentWorkspace, inView, attempt])

  if (!currentWorkspace) return null

  const origin = formatAttachmentOrigin(attachment.origin)
  const meta = [attachment.mime_type, formatAttachmentBytes(attachment.bytes), origin].filter(Boolean).join(' · ')
  const title = attachment.filename || attachment.attachment_id

  return html`
    <div
      ref=${hostRef}
      class="att-card att-audio-card att-midi-card"
      data-testid="attachment-midi-card"
      data-attachment-id=${attachment.attachment_id}
    >
      <div class="att-card-head">
        <span class="att-audio-badge mono">MIDI</span>
        <div class="att-card-info">
          <div class="att-card-title">${title}</div>
          <div class="att-card-meta mono">${meta}</div>
        </div>
        <div class="att-card-actions">
          ${error && html`
            <button type="button" class="btn-ghost btn-compact" onClick=${() => setAttempt((n) => n + 1)}>
              다시 불러오기
            </button>
          `}
          <button
            type="button"
            class="btn-ghost btn-compact"
            disabled=${downloading}
            onClick=${async () => {
              setDownloading(true)
              setError(null)
              try {
                const res = await downloadAttachment(attachment)
                if (!res.ok) setError(res.error.message)
              } finally {
                setDownloading(false)
              }
            }}
          >
            ${downloading ? '다운로드 중…' : '다운로드'}
          </button>
          <button
            type="button"
            class="btn-ghost btn-compact"
            onClick=${async () => {
              if (await copyToClipboard(attachment.attachment_id)) {
                setCopied(true)
                setTimeout(() => setCopied(false), 1500)
              }
            }}
          >
            ${copied ? 'ID 복사됨' : 'ID 복사'}
          </button>
        </div>
      </div>
      ${error && html`<div class="ap-error" role="alert">${error}</div>`}
      ${loading && !bytes && html`<div class="rich-code-loading">MIDI 불러오는 중…</div>`}
      ${bytes && html`<${MidiScorePlayer} bytes=${bytes} title=${title} />`}
    </div>
  `
}

function WorkspaceAudioAttachment({
  attachment,
  workspaceEpoch,
}: {
  readonly attachment: AttachmentRef
  readonly workspaceEpoch: number
}) {
  const epoch = sessionEpoch.value
  const currentWorkspace = workspaceEpoch === epoch
  const [hostRef, inView] = useInViewOnce<HTMLDivElement>()
  const [srcUrl, setSrcUrl] = useState<string | null>(null)
  const [durationMs, setDurationMs] = useState<number | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [downloading, setDownloading] = useState(false)
  const [copied, setCopied] = useState(false)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    return () => revokeUrlSafe(srcUrl)
  }, [srcUrl])

  useEffect(() => {
    if (!currentWorkspace || !inView) return
    const ctrl = new AbortController()
    setLoading(true)
    setError(null)
    void fetchAttachmentBlob(attachment.url, { signal: ctrl.signal })
      .then((res) => {
        if (ctrl.signal.aborted) return
        if (!res.ok) {
          setError(res.error.message)
          return
        }
        const nextUrl = URL.createObjectURL(res.value.blob)
        setSrcUrl((prev) => {
          revokeUrlSafe(prev)
          return nextUrl
        })
      })
      .catch((err) => {
        if (ctrl.signal.aborted) return
        setError(err instanceof Error ? err.message : '오디오를 불러오지 못했습니다.')
      })
      .finally(() => {
        if (!ctrl.signal.aborted) setLoading(false)
      })
    return () => ctrl.abort()
  }, [attachment.url, currentWorkspace, inView, attempt])

  if (!currentWorkspace) return null

  const badge = audioFormatBadge(attachment.mime_type, attachment.filename)
  const origin = formatAttachmentOrigin(attachment.origin)
  const durStr = durationMs !== null ? formatPlaybackTime(durationMs) : null
  const meta = [attachment.mime_type, durStr, formatAttachmentBytes(attachment.bytes), origin].filter(Boolean).join(' · ')

  return html`
    <div
      ref=${hostRef}
      class="att-card att-audio-card"
      data-testid="attachment-audio-card"
      data-attachment-id=${attachment.attachment_id}
    >
      <div class="att-card-head">
        <span class="att-audio-badge mono">${badge}</span>
        <div class="att-card-info">
          <div class="att-card-title">${attachment.filename || attachment.attachment_id}</div>
          <div class="att-card-meta mono">${meta}</div>
        </div>
        <div class="att-card-actions">
          ${!srcUrl && error && html`
            <button type="button" class="btn-ghost btn-compact" disabled=${loading} onClick=${() => setAttempt((n) => n + 1)}>
              다시 불러오기
            </button>
          `}
          <button
            type="button"
            class="btn-ghost btn-compact"
            disabled=${downloading}
            onClick=${async () => {
              setDownloading(true)
              setError(null)
              try {
                const res = await downloadAttachment(attachment)
                if (!res.ok) setError(res.error.message)
              } finally {
                setDownloading(false)
              }
            }}
          >
            ${downloading ? '다운로드 중…' : '다운로드'}
          </button>
          <button
            type="button"
            class="btn-ghost btn-compact"
            onClick=${async () => {
              if (await copyToClipboard(attachment.attachment_id)) {
                setCopied(true)
                setTimeout(() => setCopied(false), 1500)
              }
            }}
          >
            ${copied ? 'ID 복사됨' : 'ID 복사'}
          </button>
        </div>
      </div>
      ${error && html`<div class="ap-error" role="alert">${error}</div>`}
      ${loading && !srcUrl && html`<div class="rich-code-loading">오디오 불러오는 중…</div>`}
      ${srcUrl && html`
        <audio
          class="att-audio-player"
          controls
          src=${srcUrl}
          preload="metadata"
          onLoadedMetadata=${(e: Event) => {
            const el = e.currentTarget as HTMLAudioElement
            if (Number.isFinite(el.duration) && el.duration > 0) {
              setDurationMs(Math.round(el.duration * 1000))
            }
          }}
          onError=${() => {
            setSrcUrl((prev) => {
              revokeUrlSafe(prev)
              return null
            })
            setError('브라우저에서 이 오디오 형식을 디코딩하지 못했습니다. 다운로드하여 확인하세요.')
          }}
        />
      `}
    </div>
  `
}

function WorkspaceVideoAttachment({
  attachment,
  workspaceEpoch,
}: {
  readonly attachment: AttachmentRef
  readonly workspaceEpoch: number
}) {
  const epoch = sessionEpoch.value
  const currentWorkspace = workspaceEpoch === epoch
  const [hostRef, inView] = useInViewOnce<HTMLDivElement>()
  const [videoUrl, setVideoUrl] = useState<string | null>(null)
  const [posterUrl, setPosterUrl] = useState<string | null>(null)
  const [naturalDims, setNaturalDims] = useState<{ w: number; h: number } | null>(
    attachment.width && attachment.height ? { w: attachment.width, h: attachment.height } : null,
  )
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [downloading, setDownloading] = useState(false)
  const [copied, setCopied] = useState(false)
  const [zoomOpen, setZoomOpen] = useState(false)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => () => revokeUrlSafe(videoUrl), [videoUrl])
  useEffect(() => () => revokeUrlSafe(posterUrl), [posterUrl])

  useEffect(() => {
    if (!currentWorkspace || !inView) return
    const ctrl = new AbortController()
    setLoading(true)
    setError(null)

    void fetchAttachmentBlob(attachment.url, { signal: ctrl.signal })
      .then((res) => {
        if (ctrl.signal.aborted) return
        if (!res.ok) {
          setError(res.error.message)
          return
        }
        const nextUrl = URL.createObjectURL(res.value.blob)
        setVideoUrl((prev) => {
          revokeUrlSafe(prev)
          return nextUrl
        })
      })
      .catch((err) => {
        if (ctrl.signal.aborted) return
        setError(err instanceof Error ? err.message : '비디오를 불러오지 못했습니다.')
      })
      .finally(() => {
        if (!ctrl.signal.aborted) setLoading(false)
      })

    // Best-effort poster frame fetch (?max_px=640&format=png) — ignore errors gracefully.
    void fetchAttachmentBlob(attachment.url, {
      maxPx: 640,
      format: 'png',
      requireRasterImage: true,
      signal: ctrl.signal,
    })
      .then((res) => {
        if (ctrl.signal.aborted || !res.ok) return
        const nextPoster = URL.createObjectURL(res.value.blob)
        setPosterUrl((prev) => {
          revokeUrlSafe(prev)
          return nextPoster
        })
      })
      .catch(() => {
        // Ignore poster fetch rejections; video playback remains independent.
      })

    return () => ctrl.abort()
  }, [attachment.url, currentWorkspace, inView, attempt])

  const handleDownload = useCallback(async () => {
    if (downloading) return
    setDownloading(true)
    setError(null)
    try {
      const res = await downloadAttachment(attachment)
      if (!res.ok) setError(res.error.message)
    } finally {
      setDownloading(false)
    }
  }, [attachment, downloading])

  if (!currentWorkspace) return null

  const badge = videoFormatBadge(attachment.mime_type, attachment.filename)
  const dims = naturalDims ? `${naturalDims.w}×${naturalDims.h}` : null
  const origin = formatAttachmentOrigin(attachment.origin)
  const meta = [attachment.mime_type, dims, formatAttachmentBytes(attachment.bytes), origin].filter(Boolean).join(' · ')
  const title = attachment.filename || attachment.attachment_id

  return html`
    <div
      ref=${hostRef}
      class="att-video-card"
      data-testid="attachment-video-card"
      data-attachment-id=${attachment.attachment_id}
    >
      ${(videoUrl || loading || (!inView && !error)) && html`
        <div class="att-video-frame">
          ${videoUrl
            ? html`
                <video
                  class="att-video-el"
                  controls
                  playsInline
                  preload="metadata"
                  src=${videoUrl}
                  poster=${posterUrl ?? undefined}
                  onLoadedMetadata=${(e: Event) => {
                    const el = e.currentTarget as HTMLVideoElement
                    if (el.videoWidth > 0 && el.videoHeight > 0) {
                      setNaturalDims({ w: el.videoWidth, h: el.videoHeight })
                    }
                  }}
                  onError=${() => {
                    setVideoUrl((prev) => {
                      revokeUrlSafe(prev)
                      return null
                    })
                    setError('브라우저에서 이 비디오 형식을 디코딩하지 못했습니다. 다운로드하여 확인하세요.')
                  }}
                />
              `
            : loading
              ? html`<div class="rich-code-loading">비디오 불러오는 중…</div>`
              : html`<div class="rich-code-loading" data-testid="video-idle-placeholder">화면에 보이면 비디오를 불러옵니다…</div>`}
        </div>
      `}

      <div class="att-video-footer">
        <div class="att-card-head" style="flex:1;min-width:0">
          <span class="att-audio-badge mono">${badge}</span>
          <div class="att-card-info">
            <div class="att-card-title">${title}</div>
            <div class="att-card-meta mono">${meta}</div>
          </div>
        </div>
        <div class="att-card-actions">
          ${error && html`
            <button type="button" class="btn-ghost btn-compact" onClick=${() => setAttempt((n) => n + 1)}>
              다시 불러오기
            </button>
          `}
          ${videoUrl && html`
            <button
              type="button"
              class="btn-ghost btn-compact"
              onClick=${() => setZoomOpen(true)}
              aria-label=${`${title} 크게 보기`}
            >
              확대
            </button>
          `}
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
            onClick=${async () => {
              if (await copyToClipboard(attachment.attachment_id)) {
                setCopied(true)
                setTimeout(() => setCopied(false), 1500)
              }
            }}
          >
            ${copied ? 'ID 복사됨' : 'ID 복사'}
          </button>
        </div>
      </div>

      ${error && html`<div class="ap-error" role="alert">${error}</div>`}

      ${zoomOpen && videoUrl && html`
        <${ChatPreviewModal}
          title=${title}
          subtitle=${meta}
          actions=${html`
            <button type="button" class="btn-ghost btn-compact" disabled=${downloading} onClick=${() => void handleDownload()}>
              ${downloading ? '다운로드 중…' : '다운로드'}
            </button>
          `}
          onClose=${() => setZoomOpen(false)}
        >
          <video
            class="att-video-modal-el"
            controls
            playsInline
            preload="metadata"
            src=${videoUrl}
            poster=${posterUrl ?? undefined}
          />
        <//>
      `}
    </div>
  `
}

function WorkspaceDocumentAttachment({
  attachment,
}: {
  readonly attachment: AttachmentRef
}) {
  const [downloading, setDownloading] = useState(false)
  const [copiedKey, setCopiedKey] = useState<'id' | 'url' | null>(null)
  const [downloadError, setDownloadError] = useState<string | null>(null)

  const badge = attachment.mime_type === 'application/pdf' ? 'PDF' : 'DOC'
  const origin = formatAttachmentOrigin(attachment.origin)
  const meta = [attachment.mime_type, formatAttachmentBytes(attachment.bytes), origin].filter(Boolean).join(' · ')

  const handleDownload = async () => {
    if (downloading) return
    setDownloading(true)
    setDownloadError(null)
    try {
      const res = await downloadAttachment(attachment)
      if (!res.ok) setDownloadError(res.error.message)
    } finally {
      setDownloading(false)
    }
  }

  const handleCopy = async (kind: 'id' | 'url') => {
    const val = kind === 'id' ? attachment.attachment_id : resolveWorkspaceUrl(attachment.url)
    if (await copyToClipboard(val)) {
      setCopiedKey(kind)
      setTimeout(() => setCopiedKey((cur) => (cur === kind ? null : cur)), 1500)
    }
  }

  return html`
    <div class="att-card att-doc-card" data-testid="attachment-document-card" data-attachment-id=${attachment.attachment_id}>
      <div class="att-card-head">
        <span class="att-card-badge mono">${badge}</span>
        <div class="att-card-info">
          <div class="att-card-title">${attachment.filename || attachment.attachment_id}</div>
          <div class="att-card-meta mono">${meta}</div>
        </div>
        <div class="att-card-actions">
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
        </div>
      </div>
      ${downloadError && html`<div class="ap-error" role="alert">${downloadError}</div>`}
    </div>
  `
}

export interface AttachmentGalleryProps {
  readonly attachments: readonly AttachmentRef[]
  readonly workspaceEpoch?: number
  readonly compact?: boolean
}

export function AttachmentGallery({
  attachments,
  workspaceEpoch = currentSessionEpoch(),
  compact = false,
}: AttachmentGalleryProps) {
  const unique = dedupeAttachments(attachments)
  if (unique.length === 0) return null

  const images = unique.filter((a) => a.kind === 'image' || isWorkspaceRasterMime(a.mime_type))
  const others = unique.filter((a) => a.kind !== 'image' && !isWorkspaceRasterMime(a.mime_type))

  return html`
    <div class=${`att-gallery${compact ? ' att-gallery--compact' : ''}`} data-testid="attachment-gallery">
      ${images.length > 0 && html`
        <div class=${`att-image-grid${images.length === 1 ? ' att-image-grid--single' : ''}`}>
          ${images.map((att) => html`
            <${WorkspaceChatImage}
              key=${att.attachment_id || att.url}
              path=${att.url}
              caption=${att.caption ?? undefined}
              attachment=${att}
              workspaceEpoch=${workspaceEpoch}
              compact=${compact}
            />
          `)}
        </div>
      `}
      ${others.length > 0 && html`
        <div class="att-nonimage-list">
          ${others.map((att) => {
            const key = att.attachment_id || att.url
            if (isMidiMimeType(att.mime_type, att.filename)) {
              return html`<${WorkspaceMidiAttachment} key=${key} attachment=${att} workspaceEpoch=${workspaceEpoch} />`
            }
            if (att.kind === 'audio' || att.mime_type.toLowerCase().startsWith('audio/')) {
              return html`<${WorkspaceAudioAttachment} key=${key} attachment=${att} workspaceEpoch=${workspaceEpoch} />`
            }
            if (att.kind === 'video' || att.mime_type.toLowerCase().startsWith('video/')) {
              return html`<${WorkspaceVideoAttachment} key=${key} attachment=${att} workspaceEpoch=${workspaceEpoch} />`
            }
            return html`<${WorkspaceDocumentAttachment} key=${key} attachment=${att} />`
          })}
        </div>
      `}
    </div>
  `
}
