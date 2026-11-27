// Markdown renderer core — uses `marked` + `dompurify` (GFM tables, code fences,
// <think> blocks, authenticated lazy workspace media hydration, and typed Obsidian embeds).

import './markdown-embeds.css'
import { html } from 'htm/preact'
import type { JSX } from 'preact'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks'
import { Marked, Renderer, type Tokens } from 'marked'
import { enhanceRichCode } from './rich-code-preview'
import { ChatPreviewModal } from '../primitives/chat-preview-modal'
import {
  authSession,
  canAccessMemberWorkspace,
  canUseSingleUserTokenAdmin,
  isEpochCurrent,
  sessionEpoch,
} from '../../core/auth'
import { apiGet, apiGetV2 } from '../../core/transport'
import { sanitizeHtml } from '../../lib/dompurify'
import { escapeHtml } from '../../lib/html-escape'
import {
  WORKSPACE_MEDIA_PREFIX,
  isValidPublishedArtifactId,
  isValidWikiSlug,
  isWorkspaceMediaPath,
  parseObsidianEmbed,
  type WorkspaceEmbed,
} from '../../lib/keeper-media'
import { memoizeLru } from '../../lib/lru-cache'
import { parseUrl } from '../../lib/parse-url'
import {
  acquireWorkspaceMediaObjectUrl,
  type WorkspaceMediaObjectUrlLease,
} from '../../lib/workspace-media-cache'

const MASC_EMBED_DATA_ATTRS = [
  'data-masc-media-src',
  'data-masc-media-alt',
  'data-masc-embed-kind',
  'data-masc-embed-target',
  'data-masc-embed-label',
  'data-masc-embed-scheme',
] as const

const MEDIA_OBSERVER_ROOT_MARGIN = '200px'
const DEFAULT_MEDIA_ALT = '워크스페이스 이미지'
const EMBED_SUMMARY_MAX_CHARS = 180
const EMBED_META_CACHE_MAX = 128

function renderWorkspaceMediaSlotHtml(path: string, alt: string, isBlockEmbed: boolean): string {
  const kindAttr = isBlockEmbed ? ' data-masc-embed-kind="media"' : ''
  return `<span class="masc-media-slot"${kindAttr} data-masc-media-src="${escapeHtml(path)}" data-masc-media-alt="${escapeHtml(alt)}"></span>`
}

function renderInvalidEmbedHtml(rawTarget: string): string {
  return `<span class="masc-embed-invalid" data-masc-embed-kind="invalid" data-masc-embed-target="${escapeHtml(rawTarget)}">잘못된 임베드: ${escapeHtml(rawTarget)}</span>`
}

function renderObsidianEmbedHtml(embed: WorkspaceEmbed): string {
  switch (embed.kind) {
    case 'media':
      return renderWorkspaceMediaSlotHtml(embed.path, embed.caption ?? '', true)
    case 'wiki': {
      const displayLabel = embed.label ?? embed.slug
      const href = `#/knowledge/wiki/${encodeURIComponent(embed.slug)}`
      return `<a class="masc-embed-card masc-embed-card--wiki" href="${escapeHtml(href)}" data-masc-embed-kind="wiki" data-masc-embed-target="${escapeHtml(embed.slug)}" data-masc-embed-label="${escapeHtml(embed.label ?? '')}"><span class="masc-embed-card-head"><span class="masc-embed-badge">Wiki</span><span class="masc-embed-title">${escapeHtml(displayLabel)}</span><span class="masc-embed-meta">/knowledge/wiki/${escapeHtml(embed.slug)}</span></span></a>`
    }
    case 'artifact': {
      const displayLabel = embed.label ?? embed.id
      const href = `#/knowledge/artifacts/${encodeURIComponent(embed.id)}`
      return `<a class="masc-embed-card masc-embed-card--artifact" href="${escapeHtml(href)}" data-masc-embed-kind="artifact" data-masc-embed-target="${escapeHtml(embed.id)}" data-masc-embed-label="${escapeHtml(embed.label ?? '')}"><span class="masc-embed-card-head"><span class="masc-embed-badge">Artifact</span><span class="masc-embed-title">${escapeHtml(displayLabel)}</span><span class="masc-embed-meta">/knowledge/artifacts/${escapeHtml(embed.id)}</span></span></a>`
    }
    case 'invalid':
      return renderInvalidEmbedHtml(embed.rawTarget || embed.raw)
    case 'unsupported':
      return `<span class="masc-embed-unsupported" data-masc-embed-kind="unsupported" data-masc-embed-scheme="${escapeHtml(embed.scheme)}" data-masc-embed-target="${escapeHtml(embed.rawTarget)}">지원되지 않는 임베드(${escapeHtml(embed.scheme)}): ${escapeHtml(embed.rawTarget)}</span>`
  }
}

interface ObsidianEmbedToken extends Tokens.Generic {
  type: 'obsidianEmbed'
  raw: string
  embed: WorkspaceEmbed
}

const obsidianEmbedExtension = {
  name: 'obsidianEmbed',
  level: 'inline' as const,
  start(source: string) {
    const idx = source.indexOf('![[')
    return idx === -1 ? undefined : idx
  },
  tokenizer(source: string): ObsidianEmbedToken | undefined {
    const match = /^!\[\[([^\r\n]+?)\]\]/.exec(source)
    if (!match) return undefined
    const inner = match[1] ?? ''
    if (inner.includes('[[') || inner.includes(']]')) return undefined
    return {
      type: 'obsidianEmbed',
      raw: match[0],
      embed: parseObsidianEmbed(inner, match[0]),
    }
  },
  renderer(token: Tokens.Generic): string {
    const embedToken = token as ObsidianEmbedToken
    return renderObsidianEmbedHtml(embedToken.embed)
  },
}

const documentRenderer = {
  image(this: Renderer, token: Tokens.Image) {
    const href = token.href?.trim() ?? ''
    const alt = token.text ?? ''
    if (href.startsWith(WORKSPACE_MEDIA_PREFIX)) {
      return isWorkspaceMediaPath(href)
        ? renderWorkspaceMediaSlotHtml(href, alt, false)
        : renderInvalidEmbedHtml(href)
    }
    return Renderer.prototype.image.call(this, token)
      .replace(/^<img /, '<img loading="lazy" decoding="async" referrerpolicy="no-referrer" ')
  },
  checkbox({ checked }: Tokens.Checkbox) {
    return checked ? '☑ ' : '☐ '
  },
  link(this: Renderer, token: Tokens.Link) {
    const rendered = Renderer.prototype.link.call(this, token)
    const href = token.href?.trim() ?? ''
    if (!href || href.startsWith('#')) return rendered
    return rendered.replace(/^<a /, '<a target="_blank" rel="noopener noreferrer" ')
  },
}

const renderer = documentRenderer

const md = new Marked({ gfm: true, breaks: false }).use({
  renderer: documentRenderer,
  extensions: [obsidianEmbedExtension],
})

const PURIFY_CONFIG = {
  ALLOWED_TAGS: [
    'p', 'br', 'strong', 'em', 'del', 'code', 'pre', 'blockquote',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'ul', 'ol', 'li', 'hr', 'a', 'img',
    'table', 'thead', 'tbody', 'tr', 'th', 'td',
    'details', 'summary', 'div', 'span',
  ],
  ALLOWED_ATTR: [
    'href', 'title', 'target', 'rel', 'src', 'alt', 'class',
    'align', 'start', 'loading', 'decoding', 'referrerpolicy',
    ...MASC_EMBED_DATA_ATTRS,
  ],
  ALLOW_DATA_ATTR: false,
}

const DOCUMENT_PURIFY_CONFIG = {
  USE_PROFILES: { html: true },
  FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form'],
  ALLOW_DATA_ATTR: false,
  ADD_ATTR: ['target', ...MASC_EMBED_DATA_ATTRS],
}

function allDocumentLinksAlreadyNormalized(sanitizedHtml: string): boolean {
  let pos = 0
  while (true) {
    const start = sanitizedHtml.indexOf('<a', pos)
    if (start === -1) return true
    const nextCh = sanitizedHtml.charCodeAt(start + 2)
    if (nextCh !== 32 && nextCh !== 62 && nextCh !== 9 && nextCh !== 10) {
      pos = start + 2
      continue
    }
    const end = sanitizedHtml.indexOf('>', start + 2)
    if (end === -1) return false
    const tag = sanitizedHtml.slice(start, end + 1)
    const hrefAttrIdx = tag.indexOf(' href="')
    const hrefStart = hrefAttrIdx !== -1 ? hrefAttrIdx + 7 : -1
    const hrefEnd = hrefStart !== -1 ? tag.indexOf('"', hrefStart) : -1
    const hrefTrimmed = hrefStart !== -1 && hrefEnd !== -1
      ? tag.slice(hrefStart, hrefEnd).trim()
      : ''
    const isExternalNormalized =
      hrefTrimmed.length > 0
      && !hrefTrimmed.startsWith('#')
      && tag.includes(' target="_blank"')
      && tag.includes(' rel="noopener noreferrer"')
    const isLocalAnchorNormalized =
      !tag.includes('target=')
      && (hrefAttrIdx !== -1
        ? (hrefTrimmed.length === 0 || hrefTrimmed.startsWith('#'))
        : !tag.includes('href='))
    if (!isExternalNormalized && !isLocalAnchorNormalized) return false
    pos = end + 1
  }
}

/**
 * Post-sanitize DOM normalizer running inside an inert `<template>`:
 * 1. Rewrites any surviving raw HTML `<img src="/api/v1/media/...">` into a non-fetching
 *    `.masc-media-slot` (or invalid notice) so `dangerouslySetInnerHTML` NEVER triggers
 *    unauthenticated browser GET 401s.
 * 2. Strips forged `data-masc-*` attributes from raw HTML elements whose values fail
 *    strict canonical validation.
 * 3. Normalizes external vs hash links when `normalizeLinks` is true.
 */
function normalizeSanitizedHtml(sanitizedHtml: string, normalizeLinks: boolean): string {
  const needsImgPass = sanitizedHtml.includes('<img')
  const needsDataPass = sanitizedHtml.includes('data-masc-')
  const needsLinkPass = normalizeLinks && sanitizedHtml.includes('<a') && !allDocumentLinksAlreadyNormalized(sanitizedHtml)
  if (!needsImgPass && !needsDataPass && !needsLinkPass) return sanitizedHtml

  const template = window.document.createElement('template')
  template.innerHTML = sanitizedHtml

  if (needsImgPass) {
    for (const img of [...template.content.querySelectorAll('img')]) {
      const rawSrc = img.getAttribute('src')?.trim() ?? ''
      if (!rawSrc.startsWith(WORKSPACE_MEDIA_PREFIX)) continue
      const replacement = window.document.createElement('span')
      if (isWorkspaceMediaPath(rawSrc)) {
        replacement.className = 'masc-media-slot'
        replacement.setAttribute('data-masc-media-src', rawSrc)
        replacement.setAttribute('data-masc-media-alt', img.getAttribute('alt') ?? '')
      } else {
        replacement.className = 'masc-embed-invalid'
        replacement.setAttribute('data-masc-embed-kind', 'invalid')
        replacement.setAttribute('data-masc-embed-target', rawSrc)
        replacement.textContent = `잘못된 임베드: ${rawSrc}`
      }
      img.replaceWith(replacement)
    }
  }

  if (needsDataPass) {
    for (const el of template.content.querySelectorAll('[data-masc-media-src]')) {
      const src = el.getAttribute('data-masc-media-src')?.trim() ?? ''
      if (!isWorkspaceMediaPath(src)) {
        el.removeAttribute('data-masc-media-src')
        el.removeAttribute('data-masc-media-alt')
        el.classList.remove('masc-media-slot')
      }
    }
    for (const el of template.content.querySelectorAll('[data-masc-embed-kind]')) {
      const kind = el.getAttribute('data-masc-embed-kind')
      const target = el.getAttribute('data-masc-embed-target') ?? ''
      const href = el.getAttribute('href')?.trim() ?? ''
      const valid =
        (kind === 'media' && isWorkspaceMediaPath(el.getAttribute('data-masc-media-src')))
        || (kind === 'wiki' && el.tagName === 'A' && isValidWikiSlug(target)
          && href === `#/knowledge/wiki/${encodeURIComponent(target)}`)
        || (kind === 'artifact' && el.tagName === 'A' && isValidPublishedArtifactId(target)
          && href === `#/knowledge/artifacts/${encodeURIComponent(target)}`)
        || kind === 'invalid'
        || kind === 'unsupported'
      if (!valid) {
        for (const attr of MASC_EMBED_DATA_ATTRS) el.removeAttribute(attr)
        el.classList.remove('masc-embed-card', 'masc-embed-card--wiki', 'masc-embed-card--artifact')
      }
    }
  }

  if (needsLinkPass) {
    for (const anchor of template.content.querySelectorAll('a')) {
      const href = anchor.getAttribute('href')?.trim() ?? ''
      if (!href || href.startsWith('#')) {
        anchor.removeAttribute('target')
      } else {
        anchor.setAttribute('target', '_blank')
        anchor.setAttribute('rel', 'noopener noreferrer')
      }
    }
  }

  return template.innerHTML
}

function sanitize(raw: string): string {
  return normalizeSanitizedHtml(sanitizeHtml(raw, PURIFY_CONFIG), false)
}

const thinkBlock = {
  name: 'thinkBlock',
  level: 'block' as const,
  start(source: string) {
    const match = /\n {0,3}<think>/i.exec(source)
    return match ? match.index + 1 : undefined
  },
  tokenizer(source: string) {
    const match = /^ {0,3}<think>([\s\S]*?)<\/think\s*>/i.exec(source)
    if (!match) return undefined
    return { type: 'thinkBlock', raw: match[0], text: (match[1] ?? '').trim() }
  },
  renderer(token: { type: string; raw: string; text?: string }) {
    return `<details class="think-block rounded-[var(--r-1)]"><summary>생각 중...</summary><div>${chatMarkdown.parse(token.text ?? '')}</div></details>`
  },
}

const chatMarkdown = new Marked({ gfm: true, breaks: true }).use({
  renderer,
  extensions: [thinkBlock, obsidianEmbedExtension],
})

function renderMarkdownUncached(text: string): string {
  return sanitize(chatMarkdown.parse(text, { async: false }))
}

const MARKDOWN_CACHE_MAX = 256
export const renderMarkdown = memoizeLru(renderMarkdownUncached, { max: MARKDOWN_CACHE_MAX })

const renderMarkdownDocument = memoizeLru(
  (text: string) => normalizeSanitizedHtml(
    sanitizeHtml(md.parse(text, { async: false }), DOCUMENT_PURIFY_CONFIG),
    true,
  ),
  { max: MARKDOWN_CACHE_MAX },
)

// ── Optional Authenticated Embed Metadata Cache (Epoch-Scoped, Depth-0) ──

type EmbedMetadata =
  | { readonly status: 'found'; readonly title: string; readonly summary: string | null; readonly meta: string }
  | { readonly status: 'not_found' }

const embedMetaCache = new Map<string, EmbedMetadata>()
let embedMetaEpoch = sessionEpoch.peek()

sessionEpoch.subscribe((next) => {
  if (next === embedMetaEpoch) return
  embedMetaEpoch = next
  embedMetaCache.clear()
})

export function clearEmbedMetadataCache(): void {
  embedMetaCache.clear()
}

function setEmbedMeta(key: string, value: EmbedMetadata): void {
  if (embedMetaCache.has(key)) embedMetaCache.delete(key)
  embedMetaCache.set(key, value)
  if (embedMetaCache.size > EMBED_META_CACHE_MAX) {
    const oldest = embedMetaCache.keys().next().value
    if (oldest !== undefined) embedMetaCache.delete(oldest)
  }
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function nonEmptyStr(v: unknown): string | null {
  if (typeof v !== 'string') return null
  const trimmed = v.trim()
  return trimmed.length > 0 ? trimmed : null
}

function summarizePlainText(raw: string): string | null {
  const cleaned = raw
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/!\[\[[^\r\n]+?\]\]/g, ' ')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ')
    .replace(/[#>*`_[\]()]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  if (!cleaned) return null
  return cleaned.length > EMBED_SUMMARY_MAX_CHARS
    ? `${cleaned.slice(0, EMBED_SUMMARY_MAX_CHARS - 1)}…`
    : cleaned
}

async function fetchWikiEmbedMeta(slug: string, epoch: number, signal: AbortSignal): Promise<EmbedMetadata | null> {
  if (!canAccessMemberWorkspace(authSession.peek())) return null
  const key = `${epoch}:wiki:${slug}`
  const cached = embedMetaCache.get(key)
  if (cached) return cached

  const res = await apiGetV2<unknown>(`/api/v1/wiki/${encodeURIComponent(slug)}`, { signal })
  if (signal.aborted || !isEpochCurrent(epoch)) return null
  if (!res.ok) {
    if (res.error.kind === 'not_found') {
      const missing: EmbedMetadata = { status: 'not_found' }
      setEmbedMeta(key, missing)
      return missing
    }
    return null
  }
  const data = res.value
  if (!isRecord(data)) return null
  const fm = isRecord(data.frontmatter) ? data.frontmatter : null
  const title = (fm ? nonEmptyStr(fm.title) : null) ?? slug
  const fmSummary = fm ? nonEmptyStr(fm.summary) : null
  const bodyMd = typeof data.body_markdown === 'string' ? data.body_markdown : ''
  const summary = fmSummary ?? summarizePlainText(bodyMd)
  const rev = fm && typeof fm.revision === 'number' && Number.isFinite(fm.revision)
    ? `rev ${fm.revision}`
    : null
  const meta = rev ? `/knowledge/wiki/${slug} · ${rev}` : `/knowledge/wiki/${slug}`
  const found: EmbedMetadata = { status: 'found', title, summary, meta }
  setEmbedMeta(key, found)
  return found
}

async function fetchArtifactEmbedMeta(id: string, epoch: number, signal: AbortSignal): Promise<EmbedMetadata | null> {
  if (!canUseSingleUserTokenAdmin(authSession.peek())) return null
  const key = `${epoch}:artifact:${id}`
  const cached = embedMetaCache.get(key)
  if (cached) return cached

  const res = await apiGet<unknown>(`/api/v1/published-artifacts/${encodeURIComponent(id)}`, { signal })
  if (signal.aborted || !isEpochCurrent(epoch)) return null
  if (!res.ok) {
    if (res.error.kind === 'not_found') {
      const missing: EmbedMetadata = { status: 'not_found' }
      setEmbedMeta(key, missing)
      return missing
    }
    return null
  }
  const data = res.value
  if (!isRecord(data) || !isRecord(data.artifact)) return null
  const art = data.artifact
  const title = nonEmptyStr(art.title) ?? id
  const summary = nonEmptyStr(art.summary)
  const format = art.format === 'html' ? 'HTML' : 'MARKDOWN'
  const rev = typeof art.revision === 'number' && Number.isFinite(art.revision)
    ? `rev ${art.revision}`
    : null
  const meta = rev ? `${format} · ${rev}` : format
  const found: EmbedMetadata = { status: 'found', title, summary, meta }
  setEmbedMeta(key, found)
  return found
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

function hydrateEmbedCards(container: HTMLElement, epoch: number): () => void {
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

function hydrateWorkspaceMediaSlots(
  container: HTMLElement,
  epoch: number,
  onOpenLightbox: (lease: WorkspaceMediaObjectUrlLease, alt: string) => void,
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
      retry.setAttribute('aria-label', '이미지 다시 시도')
      retry.textContent = '다시 시도'
      retry.addEventListener('click', (event) => {
        event.preventDefault()
        event.stopPropagation()
        startFetch()
      })
      box.append(msg, retry)
      slot.append(box)
    }

    const startFetch = () => {
      if (disposed || !isEpochCurrent(epoch)) return
      releaseSlotLease(activeSlotLease)
      activeSlotLease = null
      renderLoading()

      const controller = new AbortController()
      controllers.push(controller)

      void acquireWorkspaceMediaObjectUrl(path, {
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
            onOpenLightbox(lease.retain(), alt)
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

function handleDocumentClick(
  event: JSX.TargetedMouseEvent<HTMLDivElement>,
  onNavigate?: (path: string) => void,
) {
  if (event.defaultPrevented || event.button !== 0
    || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
  const root = event.currentTarget
  const link = event.target instanceof Element
    ? event.target.closest<HTMLAnchorElement>('a[href^="#"]')
    : null
  if (!link || !root.contains(link) || (link.target && link.target !== '_self')) return

  const fragment = link.getAttribute('href')?.slice(1) ?? ''
  if (fragment.startsWith('/')) {
    if (onNavigate && link.classList.contains('masc-embed-card')) {
      event.preventDefault()
      onNavigate(fragment)
    }
    return
  }

  // The application routes on window.location.hash, so fragments in a
  // document must stay scoped to that document.
  event.preventDefault()
  if (!fragment) {
    root.scrollIntoView({ block: 'start' })
    return
  }
  let anchor = fragment
  try {
    anchor = decodeURIComponent(fragment)
  } catch {
    // An explicit anchor can contain a literal percent sign.
  }
  const targets = Array.from(root.querySelectorAll<HTMLElement>('[id], a[name]'))
  const findTarget = (id: string) =>
    targets.find((element) => element.id === id || element.getAttribute('name') === id)
  const target = findTarget(anchor) ?? (anchor !== fragment ? findTarget(fragment) : undefined)
  target?.scrollIntoView({ block: 'start' })
}

function linkUnloadedImages(container: HTMLElement) {
  const cleanups: Array<() => void> = []
  for (const image of container.querySelectorAll('img[src]')) {
    if (!(image instanceof HTMLImageElement) || image.closest('a') || image.closest('.masc-media-slot')) continue
    const url = parseUrl(image.src, container.ownerDocument.baseURI)
    if (!url || (url.protocol !== 'https:' && url.protocol !== 'http:')) continue
    const showOriginal = () => {
      const link = container.ownerDocument.createElement('a')
      link.href = url.href
      link.target = '_blank'
      link.rel = 'noopener noreferrer'
      link.textContent = image.alt ? `${image.alt} · 이미지 열기` : '이미지 열기'
      image.replaceWith(link)
      cleanups.push(() => {
        if (link.parentNode) link.replaceWith(image)
      })
    }
    if (image.complete && image.naturalWidth === 0) showOriginal()
    else {
      image.addEventListener('error', showOriginal, { once: true })
      cleanups.push(() => image.removeEventListener('error', showOriginal))
    }
  }
  return () => cleanups.forEach(cleanup => cleanup())
}

/** Where a document link goes instead of its written target. */
export type LinkRewrite = { readonly href: string; readonly title?: string }

const REWRITTEN_ATTRS = ['href', 'target', 'rel', 'title'] as const

function rewriteLinks(container: HTMLElement, rewrites: ReadonlyMap<string, LinkRewrite>) {
  const restores: Array<() => void> = []
  for (const anchor of container.querySelectorAll('a[href]')) {
    const rewrite = rewrites.get(anchor.getAttribute('href') ?? '')
    if (!rewrite) continue
    const saved = REWRITTEN_ATTRS.map(name => [name, anchor.getAttribute(name)] as const)
    anchor.setAttribute('href', rewrite.href)
    anchor.removeAttribute('target')
    anchor.removeAttribute('rel')
    if (rewrite.title) anchor.setAttribute('title', rewrite.title)
    restores.push(() => {
      for (const [name, value] of saved) {
        if (value === null) anchor.removeAttribute(name)
        else anchor.setAttribute(name, value)
      }
    })
  }
  return () => restores.forEach(restore => restore())
}

interface LightboxState {
  readonly path: string
  readonly alt: string
  readonly lease: WorkspaceMediaObjectUrlLease
}
export function MarkdownContent({
  text,
  class: className,
  document = false,
  streaming = false,
  linkRewrites,
  onNavigate,
}: {
  text: string
  class?: string
  document?: boolean
  streaming?: boolean
  /** Links whose written target is a key open the value instead, in this tab. */
  linkRewrites?: ReadonlyMap<string, LinkRewrite>
  onNavigate?: (path: string) => void
}) {
  const root = useRef<HTMLDivElement>(null)
  const epoch = sessionEpoch.value
  const lightboxLeaseRef = useRef<WorkspaceMediaObjectUrlLease | null>(null)
  const [lightbox, setLightbox] = useState<LightboxState | null>(null)

  const closeLightbox = useCallback(() => {
    const previous = lightboxLeaseRef.current
    lightboxLeaseRef.current = null
    previous?.release()
    setLightbox(null)
  }, [])

  const openLightbox = useCallback((lease: WorkspaceMediaObjectUrlLease, alt: string) => {
    if (!isEpochCurrent(lease.epoch)) {
      lease.release()
      return
    }
    const previous = lightboxLeaseRef.current
    lightboxLeaseRef.current = lease
    previous?.release()
    setLightbox({ path: lease.path, alt, lease })
  }, [])

  useEffect(() => {
    return () => {
      closeLightbox()
    }
  }, [closeLightbox, epoch])

  const htmlStr = useMemo(
    () => (document ? renderMarkdownDocument : renderMarkdown)(text),
    [document, text],
  )

  useEffect(() => {
    const element = root.current
    if (!element) return undefined
    const restoreImages = htmlStr.includes('<img ') ? linkUnloadedImages(element) : undefined
    const restoreMedia = htmlStr.includes('masc-media-slot')
      ? hydrateWorkspaceMediaSlots(element, epoch, openLightbox)
      : undefined
    const restoreEmbeds = !streaming && htmlStr.includes('masc-embed-card')
      ? hydrateEmbedCards(element, epoch)
      : undefined
    const restoreFences = !streaming && htmlStr.includes('language-')
      ? enhanceRichCode(element)
      : undefined
    return () => {
      restoreImages?.()
      restoreMedia?.()
      restoreEmbeds?.()
      restoreFences?.()
    }
  }, [epoch, htmlStr, openLightbox, streaming])
  // Apart from the enhancers, so a new rewrite map does not rebuild diagrams;
  // before paint, so no click reaches a link that is not rewritten yet.
  useLayoutEffect(() => {
    const element = root.current
    if (!element || !linkRewrites || !htmlStr.includes('<a')) return undefined
    return rewriteLinks(element, linkRewrites)
  }, [htmlStr, linkRewrites])

  const classes = ['markdown-content', className].filter(Boolean).join(' ')
  return html`
    <div
      ref=${root}
      class=${classes}
      onClick=${(event: JSX.TargetedMouseEvent<HTMLDivElement>) => handleDocumentClick(event, onNavigate)}
      dangerouslySetInnerHTML=${{ __html: htmlStr }}
    ></div>
    ${lightbox && html`
      <${ChatPreviewModal} title=${lightbox.alt} onClose=${closeLightbox}>
        <img
          src=${lightbox.lease.url}
          alt=${lightbox.alt}
          decoding="async"
          class="max-h-[80vh] max-w-full rounded-[var(--r-1)] object-contain"
        />
      <//>
    `}
  `
}
