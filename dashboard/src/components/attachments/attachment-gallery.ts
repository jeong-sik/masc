/**
 * Shared `<AttachmentGallery>` for rendering user, tool, and model-generated
 * attachments inline across Keeper Chat and Board posts/comments.
 *
 * - Images: lazy `?max_px=640` thumbnails via `<WorkspaceChatImage>` with
 *   lightbox zoom, dimensions/MIME/origin metadata, Download (`?download=1`),
 *   and Copy ID/URL.
 * - Audio: authenticated fetch -> `<audio controls>` player + Download + Copy ID.
 * - Documents (PDF etc.): clean download card with filename, MIME, size, origin,
 *   Download (`?download=1`), and Copy ID/URL.
 */

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  dedupeAttachments,
  downloadAttachment,
  fetchAttachmentBlob,
  type AttachmentRef,
} from '../../api/attachments'
import { currentSessionEpoch, resolveWorkspaceUrl, sessionEpoch } from '../../core/auth'
import { isWorkspaceRasterMime } from '../../lib/keeper-media'
import { WorkspaceChatImage } from '../chat/workspace-image'
import { copyToClipboard } from '../common/copyable-code'
import { formatAttachmentBytes, formatAttachmentOrigin } from './validation'

function WorkspaceAudioAttachment({
  attachment,
  workspaceEpoch,
}: {
  readonly attachment: AttachmentRef
  readonly workspaceEpoch: number
}) {
  const epoch = sessionEpoch.value
  const currentWorkspace = workspaceEpoch === epoch
  const [srcUrl, setSrcUrl] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [downloading, setDownloading] = useState(false)
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    return () => {
      if (srcUrl && srcUrl.startsWith('blob:')) {
        try {
          URL.revokeObjectURL(srcUrl)
        } catch { /* ignore */ }
      }
    }
  }, [srcUrl])

  if (!currentWorkspace) return null

  const loadAudio = async () => {
    if (loading || srcUrl) return
    setLoading(true)
    setError(null)
    const res = await fetchAttachmentBlob(attachment.url)
    setLoading(false)
    if (!res.ok) {
      setError(res.error.message)
      return
    }
    setSrcUrl(URL.createObjectURL(res.value.blob))
  }

  const origin = formatAttachmentOrigin(attachment.origin)
  const meta = [attachment.mime_type, formatAttachmentBytes(attachment.bytes), origin].filter(Boolean).join(' · ')

  return html`
    <div class="att-card att-audio-card" data-testid="attachment-audio-card" data-attachment-id=${attachment.attachment_id}>
      <div class="att-card-head">
        <span class="att-card-badge mono">AUDIO</span>
        <div class="att-card-info">
          <div class="att-card-title">${attachment.filename || attachment.attachment_id}</div>
          <div class="att-card-meta mono">${meta}</div>
        </div>
        <div class="att-card-actions">
          ${!srcUrl && html`
            <button type="button" class="btn-ghost btn-compact" disabled=${loading} onClick=${() => void loadAudio()}>
              ${loading ? '불러오는 중…' : '재생 불러오기'}
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
      ${srcUrl && html`<audio class="att-audio-player" controls src=${srcUrl} preload="metadata" />`}
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
          ${others.map((att) =>
            att.kind === 'audio'
              ? html`<${WorkspaceAudioAttachment} key=${att.attachment_id || att.url} attachment=${att} workspaceEpoch=${workspaceEpoch} />`
              : html`<${WorkspaceDocumentAttachment} key=${att.attachment_id || att.url} attachment=${att} />`,
          )}
        </div>
      `}
    </div>
  `
}
