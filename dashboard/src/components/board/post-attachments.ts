import { html } from 'htm/preact'
import { useLayoutEffect, useRef, useState } from 'preact/hooks'
import { mediaEmbedForUrl } from '../common/rich-content-utils'
import { formatFileSize } from './composer-v2'
import { isRecord } from '../common/normalize'
import { fetchToolBlobBytes } from '../../api/tool-blob'
import type { BoardAttachmentDecode, BoardAttachmentSource } from '../../types'

type UrlSource = Extract<BoardAttachmentSource, { kind: 'url' }>
type ArtifactSource = Extract<BoardAttachmentSource, { kind: 'artifact' }>

/** Render validated Board attachments; malformed stored entries get a failure card. */

function isSafeAttachmentUrl(url: string): boolean {
  if (url.trim() !== url || /[\u0000-\u0020\u007f\\]/.test(url)) return false
  try {
    const parsed = new URL(url)
    return parsed.protocol === 'https:' && !!parsed.hostname && !parsed.username && !parsed.password
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

function UnsafeUrlCard({ url }: { url: string }) {
  return html`
    <${FailureCard}
      label=${`안전하지 않은 첨부 URL이라 렌더하지 않았습니다 (${url})`}
    />
  `
}

function ImageAttachment({ source, compact }: { source: UrlSource; compact: boolean }) {
  const [failed, setFailed] = useState(false)
  if (failed) {
    return html`
      <${FailureCard}
        label=${`이미지를 불러오지 못했습니다 (${source.name || source.url})`}
        url=${source.url}
      />
    `
  }
  const sizeLabel = source.sizeBytes === undefined ? '' : formatFileSize(source.sizeBytes)
  return html`
    <figure class="m-0 flex flex-col gap-1" data-testid="board-attachment-image">
      <img
        src=${source.url}
        alt=${source.name || '첨부 이미지'}
        loading="lazy"
        width=${source.width ?? undefined}
        height=${source.height ?? undefined}
        onError=${() => setFailed(true)}
        class=${compact
          ? 'max-h-24 w-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] object-cover'
          : 'max-h-[480px] w-auto max-w-full rounded-[var(--r-1)] border border-[var(--color-border-default)]'}
      />
      ${!compact && (source.name || sizeLabel)
        ? html`<figcaption class="text-2xs text-[var(--color-fg-muted)]">
            ${source.name}${source.name && sizeLabel ? ' · ' : ''}${sizeLabel}
          </figcaption>`
        : null}
    </figure>
  `
}

function VideoAttachment({ source, compact }: { source: UrlSource; compact: boolean }) {
  const [failed, setFailed] = useState(false)
  if (failed) {
    return html`
      <${FailureCard}
        label=${`동영상을 불러오지 못했습니다 (${source.name || source.url})`}
        url=${source.url}
      />
    `
  }
  return html`
    <div class="flex flex-col gap-1" data-testid="board-attachment-video">
      <video
        src=${source.url}
        controls
        preload="metadata"
        onError=${() => setFailed(true)}
        class=${compact
          ? 'max-h-24 w-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-black'
          : 'block w-full max-h-[480px] rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-black'}
      />
      ${!compact && source.name
        ? html`<div class="text-2xs text-[var(--color-fg-muted)]">${source.name}</div>`
        : null}
    </div>
  `
}

function YoutubeAttachment({ source, compact }: { source: UrlSource; compact: boolean }) {
  const embed = mediaEmbedForUrl(source.url)
  if (!embed || embed.kind !== 'iframe') {
    return html`
      <${FailureCard}
        label=${`YouTube 임베드 URL을 만들지 못했습니다 (${source.name || source.url})`}
        url=${source.url}
      />
    `
  }
  return html`
    <div class="flex flex-col gap-1" data-testid="board-attachment-youtube">
      <iframe
        src=${embed.url}
        title=${source.name || embed.title}
        loading="lazy"
        referrerpolicy="strict-origin-when-cross-origin"
        allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
        allowfullscreen
        class=${compact
          ? 'aspect-video max-h-24 w-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]'
          : 'block aspect-video w-full rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)]'}
      />
      ${!compact && source.name
        ? html`<div class="text-2xs text-[var(--color-fg-muted)]">${source.name}</div>`
        : null}
    </div>
  `
}

function ExternalLinkAttachment({ source }: { source: UrlSource }) {
  const host = hostOf(source.url)
  return html`
    <a
      class="flex flex-col gap-0.5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2 no-underline hover:border-[var(--accent-30)]"
      href=${source.url}
      target="_blank"
      rel="noopener noreferrer"
      data-testid="board-attachment-link"
    >
      <span class="text-xs font-semibold text-[var(--color-fg-secondary)]">
        🔗 ${source.name || source.url}
      </span>
      ${host
        ? html`<span class="text-2xs text-[var(--color-fg-muted)]">${host}</span>`
        : null}
    </a>
  `
}

function ArtifactAttachment({ source }: { source: ArtifactSource }) {
  const [downloadUrl, setDownloadUrl] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const mounted = useRef(true)
  const pending = useRef<AbortController | null>(null)
  const objectUrl = useRef<string | null>(null)
  useLayoutEffect(() => () => {
    mounted.current = false
    pending.current?.abort()
    if (objectUrl.current) URL.revokeObjectURL(objectUrl.current)
  }, [])
  const load = async () => {
    if (loading || downloadUrl !== null) return
    const controller = new AbortController()
    pending.current = controller
    setLoading(true)
    setError(null)
    try {
      const bytes = await fetchToolBlobBytes(source.sha256, { signal: controller.signal })
      if (!mounted.current) return
      const url = URL.createObjectURL(new Blob([bytes], { type: 'application/octet-stream' }))
      objectUrl.current = url
      setDownloadUrl(url)
    } catch (cause) {
      if (mounted.current) setError(cause instanceof Error ? cause.message : String(cause))
    } finally {
      pending.current = null
      if (mounted.current) setLoading(false)
    }
  }
  return html`
    <div
      class="flex flex-col gap-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2"
      data-testid="board-attachment-artifact"
    >
      <button type="button" class="text-left text-xs font-semibold text-[var(--color-fg-secondary)] underline"
        disabled=${loading} onClick=${() => void load()}>
        📎 아티팩트 다운로드 준비 (${source.sha256.slice(0, 12)})
      </button>
      <span class="text-2xs text-[var(--color-fg-muted)]">
        ${formatFileSize(source.bytes)} · ${source.mime}
      </span>
      ${loading ? html`<span role="status">읽는 중…</span>` : null}
      ${error ? html`<${FailureCard} label=${`아티팩트를 읽지 못했습니다 (${error})`} />` : null}
      ${downloadUrl !== null
        ? html`<a href=${downloadUrl} download=${`artifact-${source.sha256}.bin`}
            data-testid="board-attachment-artifact-download">다운로드</a>`
        : null}
    </div>
  `
}

function AttachmentView({ entry, compact }: { entry: BoardAttachmentDecode; compact: boolean }) {
  if (!entry.ok) {
    return html`<${FailureCard} label=${describeInvalidRaw(entry.raw)} />`
  }
  const attachment = entry.attachment
  const source = attachment.source
  if (source.kind === 'artifact') {
    return html`<${ArtifactAttachment} source=${source} />`
  }
  if (!isSafeAttachmentUrl(source.url)) {
    return html`<${UnsafeUrlCard} url=${source.url} />`
  }
  switch (attachment.kind) {
    case 'image':
      return html`<${ImageAttachment} source=${source} compact=${compact} />`
    case 'video':
      return html`<${VideoAttachment} source=${source} compact=${compact} />`
    case 'youtube':
      return html`<${YoutubeAttachment} source=${source} compact=${compact} />`
    case 'external_link':
      return html`<${ExternalLinkAttachment} source=${source} />`
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
          key=${entry.ok ? `${entry.attachment.source.kind === 'url' ? entry.attachment.source.url : entry.attachment.source.sha256}-${index}` : `invalid-${index}`}
          entry=${entry}
          compact=${compact}
        />`,
      )}
    </div>
  `
}
