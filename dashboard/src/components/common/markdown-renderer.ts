// Markdown renderer core — uses `marked` + `dompurify` (GFM tables, code fences,
// <think> blocks, authenticated lazy workspace media hydration, and typed Obsidian embeds).

import './markdown-embeds.css'
import { html } from 'htm/preact'
import type { JSX } from 'preact'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks'
import { decorateColorLiterals } from './color-swatch'
import { Marked, Renderer, type Tokens } from 'marked'
import { enhanceRichCode } from './rich-code-preview'
import {
  clearEmbedMetadataCache,
  hydrateEmbedCards,
  hydrateWorkspaceMediaSlots,
  MarkdownImageLightbox,
  type MarkdownLightboxImage,
  type MarkdownLightboxRequest,
} from './markdown-embed-runtime'
import { sessionEpoch } from '../../core/auth'
import { sanitizeHtml } from '../../lib/dompurify'
import { escapeHtml } from '../../lib/html-escape'
import {
  hasWorkspaceMediaPrefix,
  isValidPublishedArtifactId,
  isValidWikiSlug,
  isWorkspaceMediaPath,
  parseObsidianEmbed,
  type WorkspaceEmbed,
} from '../../lib/keeper-media'
import { memoizeLru } from '../../lib/lru-cache'
import { parseUrl } from '../../lib/parse-url'
import { acquireWorkspaceMediaObjectUrl, type WorkspaceMediaObjectUrlLease } from '../../lib/workspace-media-cache'

export { clearEmbedMetadataCache }

const MASC_EMBED_DATA_ATTRS = [
  'data-masc-media-src',
  'data-masc-media-alt',
  'data-masc-embed-kind',
  'data-masc-embed-target',
  'data-masc-embed-label',
  'data-masc-embed-scheme',
] as const

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
    if (hasWorkspaceMediaPrefix(href)) {
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
  // A box that scrolls sideways when the table's words do not fit, so cells
  // wrap only between words. The table itself keeps its display and semantics.
  table(this: Renderer, token: Tokens.Table) {
    return `<div class="markdown-table-scroll">${Renderer.prototype.table.call(this, token)}</div>`
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
      if (!hasWorkspaceMediaPrefix(rawSrc)) continue
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
  readonly alt: string
  readonly image: MarkdownLightboxImage
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
  // The request whose answer the lightbox may still show; a newer open or a
  // close replaces it, so a late answer releases its lease instead.
  const lightboxRequestRef = useRef<AbortController | null>(null)
  const [lightbox, setLightbox] = useState<LightboxState | null>(null)

  const closeLightbox = useCallback(() => {
    lightboxRequestRef.current?.abort()
    lightboxRequestRef.current = null
    const previous = lightboxLeaseRef.current
    lightboxLeaseRef.current = null
    previous?.release()
    setLightbox(null)
  }, [])

  const openLightbox = useCallback(({ path, alt }: MarkdownLightboxRequest) => {
    closeLightbox()
    const controller = new AbortController()
    lightboxRequestRef.current = controller
    setLightbox({ alt, image: { kind: 'loading' } })
    void acquireWorkspaceMediaObjectUrl(path, { signal: controller.signal }).then((res) => {
      if (lightboxRequestRef.current !== controller) {
        if (res.ok) res.value.release()
        return
      }
      lightboxRequestRef.current = null
      if (!res.ok) {
        setLightbox({ alt, image: { kind: 'error' } })
        return
      }
      lightboxLeaseRef.current = res.value
      setLightbox({ alt, image: { kind: 'ready', src: res.value.url } })
    })
  }, [closeLightbox])

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
    const restoreColors = decorateColorLiterals(element)
    return () => {
      restoreImages?.()
      restoreMedia?.()
      restoreEmbeds?.()
      restoreFences?.()
      restoreColors()
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
      <${MarkdownImageLightbox}
        title=${lightbox.alt}
        image=${lightbox.image}
        onClose=${closeLightbox}
      />
    `}
  `
}
