// Markdown renderer core — uses `marked` + `dompurify` (GFM tables, code fences, <think> blocks).

import { html } from 'htm/preact'
import type { JSX } from 'preact'
import { useEffect, useMemo, useRef } from 'preact/hooks'
import { enhanceRichCode } from './rich-code-preview'
import { Marked, Renderer, type Tokens } from 'marked'
import { sanitizeHtml } from '../../lib/dompurify'
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
}

const renderer = {
  ...documentRenderer,
  link(this: Renderer, token: Tokens.Link) {
    return Renderer.prototype.link.call(this, token)
      .replace(/^<a /, '<a target="_blank" rel="noopener noreferrer" ')
  },
}

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
    const index = source.indexOf('\n<think>')
    return index >= 0 ? index + 1 : undefined
  },
  tokenizer(source: string) {
    const match = /^<think>([\s\S]*?)<\/think\s*>/.exec(source)
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

function normalizeDocumentLinks(sanitizedHtml: string): string {
  if (!sanitizedHtml.includes('<a')) return sanitizedHtml
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

function linkUnloadedImages(container: HTMLElement) {
  const cleanups: Array<() => void> = []
  for (const image of container.querySelectorAll('img[src]')) {
    if (!(image instanceof HTMLImageElement) || image.closest('a')) continue
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

export function MarkdownContent({
  text,
  class: className,
  document = false,
  streaming = false,
}: { text: string; class?: string; document?: boolean; streaming?: boolean }) {
  const root = useRef<HTMLDivElement>(null)
  const htmlStr = useMemo(
    () => (document ? renderMarkdownDocument : renderMarkdown)(text),
    [document, text],
  )
  useEffect(() => {
    const element = root.current
    if (!element) return undefined
    const restoreImages = htmlStr.includes('<img ') ? linkUnloadedImages(element) : undefined
    const restoreFences = !streaming && htmlStr.includes('language-') ? enhanceRichCode(element) : undefined
    return () => {
      restoreImages?.()
      restoreFences?.()
    }
  }, [htmlStr, streaming])

  const classes = ['markdown-content', className].filter(Boolean).join(' ')
  return html`
    <div
      ref=${root}
      class=${classes}
      onClick=${document ? followDocumentFragment : undefined}
      dangerouslySetInnerHTML=${{ __html: htmlStr }}
    ></div>
  `
}
