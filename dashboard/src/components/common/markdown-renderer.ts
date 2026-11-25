// Markdown renderer core — uses `marked` + `dompurify` (GFM tables, code fences, <think> blocks).

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import { Marked, Renderer, type Tokens } from 'marked'
import { sanitizeHtml } from '../../lib/dompurify'
import { memoizeLru } from '../../lib/lru-cache'

const renderer = {
  checkbox({ checked }: Tokens.Checkbox) {
    return checked ? '☑ ' : '☐ '
  },
  link(this: Renderer, token: Tokens.Link) {
    return Renderer.prototype.link.call(this, token)
      .replace(/^<a /, '<a target="_blank" rel="noopener noreferrer" ')
  },
}

const md = new Marked({ gfm: true, breaks: false }).use({ renderer })

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
    'align', 'start',
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
    const index = source.indexOf('<think>')
    return index >= 0 ? index : undefined
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

const renderMarkdownDocument = memoizeLru(
  (text: string) => sanitize(md.parse(text, { async: false })),
  { max: MARKDOWN_CACHE_MAX },
)

export function MarkdownContent({
  text,
  class: className,
  document = false,
}: { text: string; class?: string; document?: boolean }) {
  const htmlStr = useMemo(
    () => (document ? renderMarkdownDocument : renderMarkdown)(text),
    [document, text],
  )
  const classes = ['markdown-content', className].filter(Boolean).join(' ')
  return html`<div class=${classes} dangerouslySetInnerHTML=${{ __html: htmlStr }}></div>`
}
