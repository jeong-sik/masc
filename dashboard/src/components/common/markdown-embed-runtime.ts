// Authenticated embed metadata batching, lazy workspace media hydration, and
// native Preact image lightbox extracted from `markdown-renderer.ts`.

import { html } from 'htm/preact'
import { render as preactRender } from 'preact'
import { useCallback, useEffect, useRef } from 'preact/hooks'
import { DialogOverlay } from './dialog'
import {
  authSession,
  canAccessMemberWorkspace,
  canUseSingleUserTokenAdmin,
  isEpochCurrent,
} from '../../core/auth'
import { resourceCache } from '../../core/resource-cache'
import { apiGet, apiGetV2 } from '../../core/transport'
import {
  appendAttachmentQuery,
  isValidPublishedArtifactId,
  isValidWikiSlug,
  isWorkspaceAttachmentPath,
  isWorkspaceMediaPath,
} from '../../lib/keeper-media'
import { err, ok, type Result } from '../../lib/result'
import type { ApiError } from '../../core/transport'
import {
  acquireWorkspaceMediaObjectUrl,
  type WorkspaceMediaObjectUrlLease,
} from '../../lib/workspace-media-cache'

const MEDIA_OBSERVER_ROOT_MARGIN = '200px'
const DEFAULT_MEDIA_ALT = '워크스페이스 이미지'
const EMBED_INDEX_TTL_MS = 15_000
const WIKI_EMBED_META_KEY = 'embed-meta:wiki'
const ARTIFACT_EMBED_META_KEY = 'embed-meta:artifacts'

// ── Optional Authenticated Embed Metadata Cache (resourceCache-backed) ──

type EmbedMetadata =
  | { readonly status: 'found'; readonly title: string; readonly summary: string | null; readonly meta: string }
  | { readonly status: 'not_found' }

export function clearEmbedMetadataCache(): void {
  resourceCache.invalidateKey(WIKI_EMBED_META_KEY)
  resourceCache.invalidateKey(ARTIFACT_EMBED_META_KEY)
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function nonEmptyStr(v: unknown): string | null {
  if (typeof v !== 'string') return null
  const trimmed = v.trim()
  return trimmed.length > 0 ? trimmed : null
}

function decodeError(message: string): ApiError {
  return {
    kind: 'decode',
    status: 200,
    code: 'decode',
    message,
    retryable: false,
  }
}

async function loadWikiIndexMetaMap(signal: AbortSignal): Promise<Result<Map<string, EmbedMetadata>, ApiError>> {
  const res = await apiGetV2<unknown>('/api/v1/wiki', { signal })
  if (!res.ok) return res
  if (!isRecord(res.value) || !Array.isArray(res.value.pages)) {
    return err(decodeError('Invalid GET /api/v1/wiki index payload'))
  }
  const map = new Map<string, EmbedMetadata>()
  for (const row of res.value.pages) {
    if (!isRecord(row)) continue
    const slug = nonEmptyStr(row.slug)
    if (!slug) continue
    const title = nonEmptyStr(row.title) ?? slug
    const summary = nonEmptyStr(row.summary)
    const rev = typeof row.revision === 'number' && Number.isFinite(row.revision)
      ? `rev ${row.revision}`
      : null
    const meta = rev ? `/knowledge/wiki/${slug} · ${rev}` : `/knowledge/wiki/${slug}`
    map.set(slug, { status: 'found', title, summary, meta })
  }
  return ok(map)
}

async function loadArtifactIndexMetaMap(signal: AbortSignal): Promise<Result<Map<string, EmbedMetadata>, ApiError>> {
  const res = await apiGet<unknown>('/api/v1/published-artifacts', { signal })
  if (!res.ok) return res
  if (!isRecord(res.value) || !Array.isArray(res.value.artifacts)) {
    return err(decodeError('Invalid GET /api/v1/published-artifacts index payload'))
  }
  const map = new Map<string, EmbedMetadata>()
  for (const row of res.value.artifacts) {
    if (!isRecord(row)) continue
    const id = nonEmptyStr(row.id)
    if (!id) continue
    const title = nonEmptyStr(row.title) ?? id
    const summary = nonEmptyStr(row.summary)
    const format = row.format === 'html' ? 'HTML' : 'MARKDOWN'
    const rev = typeof row.revision === 'number' && Number.isFinite(row.revision)
      ? `rev ${row.revision}`
      : null
    const meta = rev ? `${format} · ${rev}` : format
    map.set(id, { status: 'found', title, summary, meta })
  }
  return ok(map)
}

async function fetchWikiEmbedMeta(slug: string, epoch: number, signal: AbortSignal): Promise<EmbedMetadata | null> {
  if (!canAccessMemberWorkspace(authSession.peek()) || !isEpochCurrent(epoch)) return null
  const obs = await resourceCache.fetch<Map<string, EmbedMetadata>>(
    WIKI_EMBED_META_KEY,
    loadWikiIndexMetaMap,
    { ttlMs: EMBED_INDEX_TTL_MS, topics: ['wiki', 'wiki_updated'], reason: 'mount' },
  )
  if (obs.kind !== 'value' || signal.aborted || !isEpochCurrent(epoch)) return null
  return obs.data.get(slug) ?? { status: 'not_found' }
}

async function fetchArtifactEmbedMeta(id: string, epoch: number, signal: AbortSignal): Promise<EmbedMetadata | null> {
  if (!canUseSingleUserTokenAdmin(authSession.peek()) || !isEpochCurrent(epoch)) return null
  const obs = await resourceCache.fetch<Map<string, EmbedMetadata>>(
    ARTIFACT_EMBED_META_KEY,
    loadArtifactIndexMetaMap,
    { ttlMs: EMBED_INDEX_TTL_MS, topics: ['artifacts', 'artifact_published'], reason: 'mount' },
  )
  if (obs.kind !== 'value' || signal.aborted || !isEpochCurrent(epoch)) return null
  return obs.data.get(id) ?? { status: 'not_found' }
}

function applyEmbedMetadata(anchor: HTMLAnchorElement, kind: 'wiki' | 'artifact', meta: EmbedMetadata): void {
  const doc = anchor.ownerDocument
  const head = anchor.querySelector('.masc-embed-card-head')
  if (!head) return
  if (meta.status === 'not_found') {
    if (!head.querySelector('.masc-embed-missing')) {
      const pill = doc.createElement('span')
      pill.className = 'masc-embed-missing'
      pill.textContent = kind === 'wiki' ? '문서 없음' : '아티팩트 없음'
      head.append(pill)
    }
    return
  }

  head.querySelector('.masc-embed-missing')?.remove()
  const customLabel = anchor.getAttribute('data-masc-embed-label')?.trim() ?? ''
  const titleEl = head.querySelector('.masc-embed-title')
  if (titleEl && !customLabel) {
    titleEl.textContent = meta.title
  }
  const metaEl = head.querySelector('.masc-embed-meta')
  if (metaEl) {
    metaEl.textContent = meta.meta
  }
  if (meta.summary) {
    let summaryEl = anchor.querySelector<HTMLElement>('.masc-embed-summary')
    if (!summaryEl) {
      summaryEl = doc.createElement('span')
      summaryEl.className = 'masc-embed-summary'
      anchor.append(summaryEl)
    }
    summaryEl.textContent = meta.summary
  }
}

export function hydrateEmbedCards(container: HTMLElement, epoch: number): () => void {
  const controllers: AbortController[] = []
  const pending = new Map<Element, () => void>()
  const observer = typeof IntersectionObserver === 'undefined'
    ? undefined
    : new IntersectionObserver((entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue
          observer?.unobserve(entry.target)
          pending.get(entry.target)?.()
          pending.delete(entry.target)
        }
      }, { rootMargin: MEDIA_OBSERVER_ROOT_MARGIN })

  for (const anchor of container.querySelectorAll<HTMLAnchorElement>('a.masc-embed-card[data-masc-embed-kind]')) {
    const kind = anchor.getAttribute('data-masc-embed-kind')
    const target = anchor.getAttribute('data-masc-embed-target')?.trim() ?? ''
    const href = anchor.getAttribute('href')?.trim() ?? ''
    if (kind === 'wiki' && isValidWikiSlug(target) && href === `#/knowledge/wiki/${encodeURIComponent(target)}`) {
      if (!canAccessMemberWorkspace(authSession.peek())) continue
      const load = () => {
        const controller = new AbortController()
        controllers.push(controller)
        void fetchWikiEmbedMeta(target, epoch, controller.signal).then((meta) => {
          if (meta && !controller.signal.aborted && isEpochCurrent(epoch) && anchor.isConnected) {
            applyEmbedMetadata(anchor, 'wiki', meta)
          }
        })
      }
      if (observer) {
        pending.set(anchor, load)
        observer.observe(anchor)
      } else {
        load()
      }
    } else if (kind === 'artifact' && isValidPublishedArtifactId(target) && href === `#/knowledge/artifacts/${encodeURIComponent(target)}`) {
      if (!canUseSingleUserTokenAdmin(authSession.peek())) continue
      const load = () => {
        const controller = new AbortController()
        controllers.push(controller)
        void fetchArtifactEmbedMeta(target, epoch, controller.signal).then((meta) => {
          if (meta && !controller.signal.aborted && isEpochCurrent(epoch) && anchor.isConnected) {
            applyEmbedMetadata(anchor, 'artifact', meta)
          }
        })
      }
      if (observer) {
        pending.set(anchor, load)
        observer.observe(anchor)
      } else {
        load()
      }
    }
  }

  return () => {
    observer?.disconnect()
    pending.clear()
    for (const controller of controllers) controller.abort()
  }
}

// ── Workspace Media Slot Hydration (Lazy IntersectionObserver + Cache) ──

/** What a slot asks the lightbox to show: the image as written, not the
 * `?max_px=640` thumbnail the slot drew, so the large view is readable. */
export interface MarkdownLightboxRequest {
  readonly path: string
  readonly alt: string
}

export function hydrateWorkspaceMediaSlots(
  container: HTMLElement,
  epoch: number,
  onOpenLightbox: (request: MarkdownLightboxRequest) => void,
): () => void {
  const controllers: AbortController[] = []
  const leases = new Set<WorkspaceMediaObjectUrlLease>()
  const pending = new Map<Element, () => void>()
  let disposed = false

  const observer = typeof IntersectionObserver === 'undefined'
    ? undefined
    : new IntersectionObserver((entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue
          observer?.unobserve(entry.target)
          pending.get(entry.target)?.()
          pending.delete(entry.target)
        }
      }, { rootMargin: MEDIA_OBSERVER_ROOT_MARGIN })

  const releaseSlotLease = (lease: WorkspaceMediaObjectUrlLease | null) => {
    if (!lease) return
    leases.delete(lease)
    lease.release()
  }

  for (const slot of container.querySelectorAll<HTMLElement>('.masc-media-slot[data-masc-media-src]')) {
    const path = slot.getAttribute('data-masc-media-src')?.trim() ?? ''
    if (!isWorkspaceMediaPath(path)) continue

    const rawAlt = slot.getAttribute('data-masc-media-alt')?.trim() ?? ''
    const alt = rawAlt || DEFAULT_MEDIA_ALT
    const isBlockEmbed = slot.getAttribute('data-masc-embed-kind') === 'media'
    const insideLink = Boolean(slot.closest('a'))
    let activeSlotLease: WorkspaceMediaObjectUrlLease | null = null

    const renderLoading = () => {
      slot.setAttribute('data-masc-media-state', 'loading')
      slot.replaceChildren()
      const status = container.ownerDocument.createElement('span')
      status.setAttribute('role', 'status')
      status.textContent = rawAlt ? `${rawAlt} 불러오는 중…` : '이미지 불러오는 중…'
      slot.append(status)
    }

    const renderError = () => {
      slot.setAttribute('data-masc-media-state', 'error')
      slot.replaceChildren()
      const box = container.ownerDocument.createElement('span')
      box.className = 'masc-media-error'
      const msg = container.ownerDocument.createElement('span')
      msg.setAttribute('role', 'status')
      msg.textContent = '이미지를 불러올 수 없습니다'
      const retry = container.ownerDocument.createElement('button')
      retry.type = 'button'
      retry.className = 'masc-media-retry'
      retry.setAttribute('aria-label', '이미지 다시 불러오기')
      retry.textContent = '다시 시도'
      retry.addEventListener('click', (event) => {
        event.preventDefault()
        event.stopPropagation()
        if (!disposed) startFetch()
      })
      box.append(msg, retry)
      slot.append(box)
    }

    const startFetch = () => {
      if (disposed || !isEpochCurrent(epoch) || !slot.isConnected) return
      releaseSlotLease(activeSlotLease)
      activeSlotLease = null
      renderLoading()

      const controller = new AbortController()
      controllers.push(controller)

      const fetchPath = isWorkspaceAttachmentPath(path) && !path.includes('max_px=')
        ? appendAttachmentQuery(path, { max_px: 640 })
        : path

      void acquireWorkspaceMediaObjectUrl(fetchPath, {
        epoch,
        signal: controller.signal,
      }).then((res) => {
        if (disposed || controller.signal.aborted || !isEpochCurrent(epoch) || !slot.isConnected) {
          if (res.ok) res.value.release()
          return
        }
        if (!res.ok) {
          if (res.error.kind !== 'aborted') renderError()
          return
        }

        const lease = res.value
        activeSlotLease = lease
        leases.add(lease)

        slot.setAttribute('data-masc-media-state', 'ready')
        slot.replaceChildren()

        const img = container.ownerDocument.createElement('img')
        img.className = 'masc-media-img'
        img.src = lease.url
        img.alt = alt
        img.setAttribute('decoding', 'async')
        img.setAttribute('loading', 'lazy')
        img.addEventListener('error', () => {
          if (disposed) return
          releaseSlotLease(lease)
          if (activeSlotLease === lease) activeSlotLease = null
          renderError()
        }, { once: true })

        if (insideLink) {
          slot.append(img)
        } else {
          const trigger = container.ownerDocument.createElement('button')
          trigger.type = 'button'
          trigger.className = 'masc-media-trigger'
          trigger.setAttribute('aria-label', `${alt} 크게 보기`)
          trigger.addEventListener('click', (event) => {
            event.preventDefault()
            event.stopPropagation()
            if (disposed || activeSlotLease !== lease) return
            onOpenLightbox({ path, alt })
          })
          trigger.append(img)
          slot.append(trigger)
        }

        if (isBlockEmbed && rawAlt) {
          const caption = container.ownerDocument.createElement('span')
          caption.className = 'masc-media-caption'
          caption.textContent = rawAlt
          slot.append(caption)
        }
      })
    }

    renderLoading()
    if (observer) {
      pending.set(slot, startFetch)
      observer.observe(slot)
    } else {
      startFetch()
    }
  }

  return () => {
    disposed = true
    observer?.disconnect()
    pending.clear()
    for (const controller of controllers) controller.abort()
    for (const lease of [...leases]) {
      leases.delete(lease)
      lease.release()
    }
  }
}

let lightboxIdSeq = 0

export type MarkdownLightboxImage =
  | { readonly kind: 'loading' }
  | { readonly kind: 'ready'; readonly src: string }
  | { readonly kind: 'error' }

export function MarkdownImageLightbox({
  title,
  image,
  onClose,
}: {
  title: string
  image: MarkdownLightboxImage
  onClose: () => void
}) {
  const titleIdRef = useRef<string | null>(null)
  if (titleIdRef.current === null) {
    lightboxIdSeq += 1
    titleIdRef.current = `masc-md-lightbox-title-${lightboxIdSeq}`
  }
  const hostRef = useRef<HTMLDivElement | null>(null)
  const onCloseRef = useRef(onClose)
  onCloseRef.current = onClose
  const stableOnClose = useCallback(() => {
    onCloseRef.current()
  }, [])

  // Render into document.body with native Preact (avoiding preact/compat global
  // options.vnode side effects) so the fixed overlay escapes content-visibility
  // and paint/layout containment inside markdown containers.
  useEffect(() => {
    const host = document.createElement('div')
    host.className = 'masc-md-lightbox-portal'
    document.body.appendChild(host)
    hostRef.current = host
    return () => {
      preactRender(null, host)
      host.remove()
      if (hostRef.current === host) hostRef.current = null
    }
  }, [])

  useEffect(() => {
    const host = hostRef.current
    if (!host) return
    const labelledBy = titleIdRef.current ?? 'masc-md-lightbox-title'
    preactRender(
      html`
        <${DialogOverlay}
          labelledBy=${labelledBy}
          onClose=${stableOnClose}
          overlayClass="fixed inset-0 z-[var(--z-modal)] flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm"
          panelClass="relative max-h-[90vh] max-w-[90vw] overflow-auto rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4 shadow-[var(--shadow-raised)]"
        >
          <div class="mb-3 flex items-center justify-between gap-4">
            <span id=${labelledBy} class="truncate text-sm font-semibold text-[var(--color-fg-primary)]">${title}</span>
            <button
              type="button"
              class="rounded-[var(--r-0)] px-2 py-1 text-xs text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]"
              onClick=${stableOnClose}
              aria-label="닫기"
            >
              ✕
            </button>
          </div>
          <div class="chat-preview-modal-body">
            ${image.kind === 'ready'
              ? html`<img
                  src=${image.src}
                  alt=${title}
                  decoding="async"
                  class="max-h-[80vh] max-w-full rounded-[var(--r-1)] object-contain"
                />`
              : html`<span role="status" class="text-sm text-[var(--color-fg-secondary)]">
                  ${image.kind === 'loading' ? '원본 이미지 불러오는 중…' : '원본 이미지를 불러올 수 없습니다'}
                </span>`}
          </div>
        <//>
      `,
      host,
    )
  }, [image, stableOnClose, title])

  return null
}
