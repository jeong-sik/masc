import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { mediaEmbedForUrl } from '../common/rich-content-utils'
import { formatFileSize } from './composer-v2'
import { isRecord } from '../common/normalize'
import type { BoardAttachment, BoardAttachmentDecode } from '../../types'

/**
 * RFC-0000 §3.1: render the typed `meta.attachments` carrier of a board post
 * (kinds: image | video | youtube | external_link). Decode failures arrive as
 * `{ ok: false }` entries and are surfaced as explicit failure cards — an
 * attachment is never silently skipped.
 */

function isSafeAttachmentUrl(url: string): boolean {
  const trimmed = url.trim()
  if (trimmed.startsWith('/')) return true
  try {
    const parsed = new URL(trimmed)
    return parsed.protocol === 'https:' || parsed.protocol === 'http:'
  } catch {
    return false
  }
}

function hostOf(url: string): string {
  try {
    return new URL(url).hostname
  } catch {
    return ''
  }
}

function describeInvalidRaw(raw: unknown): string {
  if (!isRecord(raw)) return '첨부 메타데이터가 객체가 아닙니다'
  const parts: string[] = []
  const kind = typeof raw.kind === 'string' ? raw.kind : ''
  const id = typeof raw.id === 'string' ? raw.id : ''
  if (kind) parts.push(`kind=${kind}`)
  if (id) parts.push(`id=${id}`)
  return parts.length > 0
    ? `첨부 메타데이터가 올바르지 않습니다 (${parts.join(', ')})`
    : '첨부 메타데이터가 올바르지 않습니다'
}

function FailureCard({ label, url }: { label: string; url?: string }) {
  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--warn-30)] bg-[var(--warn-10)] px-3 py-2 text-xs text-[var(--warn-bright)]"
      data-testid="board-attachment-error"
      role="note"
    >
      <span aria-hidden="true">⚠️</span> ${label}
      ${url
        ? html`<a
            class="ml-2 underline hover:text-[var(--color-accent-fg)]"
            href=${url}
            target="_blank"
            rel="noopener noreferrer"
          >원본 열기<//a>`
        : null}
    </div>
  `
}

function UnsafeUrlCard({ attachment }: { attachment: BoardAttachment }) {
  return html`
    <${FailureCard}
      label=${`안전하지 않은 첨부 URL이라 렌더하지 않았습니다 (${attachment.origin_name || attachment.id})`}
    />
  `
}

function ImageAttachment({ attachment, compact }: { attachment: BoardAttachment; compact: boolean }) {
  const [failed, setFailed] = useState(false)
  if (failed) {
    return html`
      <${FailureCard}
        label=${`이미지를 불러오지 못했습니다 (${attachment.origin_name || attachment.origin_url})`}
        url=${attachment.origin_url}
      />
    `
  }
  const sizeLabel = formatFileSize(attachment.origin_size_bytes)
  return html`
    <figure class="m-0 flex flex-col gap-1" data-testid="board-attachment-image">
      <img
        src=${attachment.origin_url}
        alt=${attachment.origin_name || '첨부 이미지'}
        loading="lazy"
        width=${attachment.width ?? undefined}
        height=${attachment.height ?? undefined}
        onError=${() => setFailed(true)}
        class=${compact
          ? 'max-h-24 w-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] object-cover'
          : 'max-h-[480px] w-auto max-w-full rounded-[var(--r-1)] border border-[var(--color-border-default)]'}
      />
      ${!compact && (attachment.origin_name || sizeLabel)
        ? html`<figcaption class="text-2xs text-[var(--color-fg-muted)]">
            ${attachment.origin_name}${attachment.origin_name && sizeLabel ? ' · ' : ''}${sizeLabel}
          </figcaption>`
        : null}
    </figure>
  `
}

function VideoAttachment({ attachment, compact }: { attachment: BoardAttachment; compact: boolean }) {
  const [failed, setFailed] = useState(false)
  if (failed) {
    return html`
      <${FailureCard}
        label=${`동영상을 불러오지 못했습니다 (${attachment.origin_name || attachment.origin_url})`}
        url=${attachment.origin_url}
      />
    `
  }
  return html`
    <div class="flex flex-col gap-1" data-testid="board-attachment-video">
      <video
        src=${attachment.origin_url}
        controls
        preload="metadata"
        onError=${() => setFailed(true)}
        class=${compact
          ? 'max-h-24 w-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-black'
          : 'block w-full max-h-[480px] rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-black'}
      />
      ${!compact && attachment.origin_name
        ? html`<div class="text-2xs text-[var(--color-fg-muted)]">${attachment.origin_name}</div>`
        : null}
    </div>
  `
}

function YoutubeAttachment({ attachment, compact }: { attachment: BoardAttachment; compact: boolean }) {
  const embed = mediaEmbedForUrl(attachment.origin_url)
  if (!embed || embed.kind !== 'iframe') {
    return html`
      <${FailureCard}
        label=${`YouTube 임베드 URL을 만들지 못했습니다 (${attachment.origin_name || attachment.origin_url})`}
        url=${attachment.origin_url}
      />
    `
  }
  return html`
    <div class="flex flex-col gap-1" data-testid="board-attachment-youtube">
      <iframe
        src=${embed.url}
        title=${attachment.origin_name || embed.title}
        loading="lazy"
        referrerpolicy="strict-origin-when-cross-origin"
        allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
        allowfullscreen
        class=${compact
          ? 'aspect-video max-h-24 w-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]'
          : 'block aspect-video w-full rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]'}
      />
      ${!compact && attachment.origin_name
        ? html`<div class="text-2xs text-[var(--color-fg-muted)]">${attachment.origin_name}</div>`
        : null}
    </div>
  `
}

function ExternalLinkAttachment({ attachment }: { attachment: BoardAttachment }) {
  const host = hostOf(attachment.origin_url)
  return html`
    <a
      class="flex flex-col gap-0.5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2 no-underline hover:border-[var(--accent-30)]"
      href=${attachment.origin_url}
      target="_blank"
      rel="noopener noreferrer"
      data-testid="board-attachment-link"
    >
      <span class="text-xs font-semibold text-[var(--color-fg-secondary)]">
        🔗 ${attachment.origin_name || attachment.origin_url}
      </span>
      ${host
        ? html`<span class="text-2xs text-[var(--color-fg-muted)]">${host}</span>`
        : null}
    </a>
  `
}

function AttachmentView({ entry, compact }: { entry: BoardAttachmentDecode; compact: boolean }) {
  if (!entry.ok) {
    return html`<${FailureCard} label=${describeInvalidRaw(entry.raw)} />`
  }
  const attachment = entry.attachment
  if (!isSafeAttachmentUrl(attachment.origin_url)) {
    return html`<${UnsafeUrlCard} attachment=${attachment} />`
  }
  switch (attachment.kind) {
    case 'image':
      return html`<${ImageAttachment} attachment=${attachment} compact=${compact} />`
    case 'video':
      return html`<${VideoAttachment} attachment=${attachment} compact=${compact} />`
    case 'youtube':
      return html`<${YoutubeAttachment} attachment=${attachment} compact=${compact} />`
    case 'external_link':
      return html`<${ExternalLinkAttachment} attachment=${attachment} />`
  }
}

export function PostAttachments({
  attachments,
  compact = false,
}: {
  attachments: BoardAttachmentDecode[]
  compact?: boolean
}) {
  if (attachments.length === 0) return null
  return html`
    <div
      class=${compact ? 'flex flex-row flex-wrap gap-2' : 'flex flex-col gap-2'}
      data-testid="board-attachments"
      aria-label="첨부"
    >
      ${attachments.map((entry, index) =>
        html`<${AttachmentView}
          key=${entry.ok ? entry.attachment.id : `invalid-${index}`}
          entry=${entry}
          compact=${compact}
        />`,
      )}
    </div>
  `
}
