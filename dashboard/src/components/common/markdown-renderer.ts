// Markdown renderer core — uses `marked` + `dompurify` (GFM tables, code fences, <think> blocks).

import { html } from 'htm/preact'
import type { JSX } from 'preact'
import { useEffect, useLayoutEffect, useMemo, useRef } from 'preact/hooks'
import { decorateColorLiterals } from './color-swatch'
import { enhanceRichCode } from './rich-code-preview'
import { Marked, Renderer, type Tokens } from 'marked'
import { fetchAttachmentBlob } from '../../api/attachments'
import { sessionEpoch } from '../../core/auth'
import { sanitizeHtml } from '../../lib/dompurify'
import { isWorkspaceAttachmentPath, isWorkspaceMediaPath } from '../../lib/keeper-media'
import { memoizeLru } from '../../lib/lru-cache'
import { parseUrl } from '../../lib/parse-url'

const documentRenderer = {
  image(this: Renderer, token: Tokens.Image) {
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

const md = new Marked({ gfm: true, breaks: false }).use({ renderer: documentRenderer })

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
  ],
  ALLOW_DATA_ATTR: false,
}

function sanitize(raw: string): string {
  return sanitizeHtml(raw, PURIFY_CONFIG)
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
  extensions: [thinkBlock],
})

function renderMarkdownUncached(text: string): string {
  return sanitize(chatMarkdown.parse(text, { async: false }))
}

const MARKDOWN_CACHE_MAX = 256
export const renderMarkdown = memoizeLru(renderMarkdownUncached, { max: MARKDOWN_CACHE_MAX })

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

function normalizeDocumentLinks(sanitizedHtml: string): string {
  if (!sanitizedHtml.includes('<a')) return sanitizedHtml
  if (allDocumentLinksAlreadyNormalized(sanitizedHtml)) return sanitizedHtml
  const template = window.document.createElement('template')
  template.innerHTML = sanitizedHtml
  for (const anchor of template.content.querySelectorAll('a')) {
    const href = anchor.getAttribute('href')?.trim() ?? ''
    if (!href || href.startsWith('#')) {
      anchor.removeAttribute('target')
    } else {
      anchor.setAttribute('target', '_blank')
      anchor.setAttribute('rel', 'noopener noreferrer')
    }
  }
  return template.innerHTML
}

const renderMarkdownDocument = memoizeLru(
  (text: string) => normalizeDocumentLinks(
    sanitizeHtml(md.parse(text, { async: false }), {
      USE_PROFILES: { html: true },
      FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form'],
      ADD_ATTR: ['target'],
    }),
  ),
  { max: MARKDOWN_CACHE_MAX },
)

function followDocumentFragment(event: JSX.TargetedMouseEvent<HTMLDivElement>) {
  if (event.defaultPrevented || event.button !== 0
    || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
  const root = event.currentTarget
  const link = event.target instanceof Element
    ? event.target.closest<HTMLAnchorElement>('a[href^="#"]')
    : null
  if (!link || !root.contains(link) || (link.target && link.target !== '_self')) return

  const fragment = link.getAttribute('href')?.slice(1) ?? ''
  if (fragment.startsWith('/')) return

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

/**
 * Hydrates same-origin `/api/v1/attachments/*` (and legacy `/api/v1/media/*`)
 * `<img>` elements via authenticated fetch so Bearer-token sessions render
 * inline Markdown attachments cleanly instead of failing with HTTP 401.
 * External images retain the existing `linkUnloadedImages` fallback.
 */
function enhanceMarkdownImages(container: HTMLElement) {
  const cleanups: Array<() => void> = []
  const controller = new AbortController()
  cleanups.push(() => controller.abort())

  for (const image of container.querySelectorAll('img[src]')) {
    if (!(image instanceof HTMLImageElement)) continue
    const rawAttr = image.getAttribute('src')?.trim() ?? ''
    if (!rawAttr) continue
    const url = parseUrl(rawAttr, container.ownerDocument.baseURI)
    if (!url || (url.protocol !== 'https:' && url.protocol !== 'http:')) continue

    const isSameOriginWorkspaceAttachment =
      url.origin === window.location.origin
      && isWorkspaceMediaPath(url.pathname)

    if (isSameOriginWorkspaceAttachment) {
      const originalSrc = rawAttr
      const maxPx = isWorkspaceAttachmentPath(url.pathname) && !url.searchParams.has('max_px')
        ? 640
        : null
      void fetchAttachmentBlob(`${url.pathname}${url.search}`, {
        maxPx,
        requireRasterImage: true,
        signal: controller.signal,
      }).then((res) => {
        if (controller.signal.aborted) return
        if (!res.ok) {
          if (image.closest('a')) return
          const fallback = container.ownerDocument.createElement('span')
          fallback.className = 'att-md-fallback'
          fallback.textContent = image.alt ? `${image.alt} · 이미지를 불러올 수 없습니다` : '이미지를 불러올 수 없습니다'
          image.replaceWith(fallback)
          cleanups.push(() => {
            if (fallback.parentNode) fallback.replaceWith(image)
          })
          return
        }
        const blobUrl = URL.createObjectURL(res.value.blob)
        image.src = blobUrl
        cleanups.push(() => {
          try {
            URL.revokeObjectURL(blobUrl)
          } catch { /* ignore */ }
          image.setAttribute('src', originalSrc)
        })
      })
      continue
    }

    if (image.closest('a')) continue
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

export function MarkdownContent({
  text,
  class: className,
  document = false,
  streaming = false,
  linkRewrites,
}: {
  text: string
  class?: string
  document?: boolean
  streaming?: boolean
  /** Links whose written target is a key open the value instead, in this tab. */
  linkRewrites?: ReadonlyMap<string, LinkRewrite>
}) {
  const root = useRef<HTMLDivElement>(null)
  const epoch = sessionEpoch.value
  const htmlStr = useMemo(
    () => (document ? renderMarkdownDocument : renderMarkdown)(text),
    [document, text],
  )
  useEffect(() => {
    const element = root.current
    if (!element) return undefined
    const restoreImages = htmlStr.includes('<img ') ? enhanceMarkdownImages(element) : undefined
    const restoreFences = !streaming && htmlStr.includes('language-') ? enhanceRichCode(element) : undefined
    const restoreColors = decorateColorLiterals(element)
    return () => {
      restoreImages?.()
      restoreFences?.()
      restoreColors()
    }
  }, [htmlStr, streaming, epoch])
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
      onClick=${followDocumentFragment}
      dangerouslySetInnerHTML=${{ __html: htmlStr }}
    ></div>
  `
}
