// Markdown renderer core — uses `marked` + `dompurify` (GFM tables, code fences, <think> blocks).

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import { Marked } from 'marked'
import { sanitizeHtml } from '../../lib/dompurify'
import { memoizeLru } from '../../lib/lru-cache'

const md = new Marked({ gfm: true, breaks: true })

md.use({
  renderer: {
    link({ href, title, text }) {
      const titleAttr = title ? ` title="${title}"` : ''
      return `<a href="${href}"${titleAttr} target="_blank" rel="noopener noreferrer">${text}</a>`
    },
  },
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
    'align',
  ],
  ALLOW_DATA_ATTR: false,
}

function sanitize(raw: string): string {
  return sanitizeHtml(raw, PURIFY_CONFIG)
}

function repairTruncatedMarkdown(text: string): string {
  const fenceCount = (text.match(/```/g) ?? []).length
  if (fenceCount % 2 === 1) {
    return `${text}\n…[잘림]\n\`\`\``
  }
  const outsideFences = text.replace(/```[\s\S]*?```/g, '')
  const inlineCount = (outsideFences.match(/`/g) ?? []).length
  if (inlineCount % 2 === 1) {
    return `${text}…[잘림]\``
  }
  return text
}

function renderMarkdownUncached(text: string): string {
  const repaired = repairTruncatedMarkdown(text)
  const parts: string[] = []
  let lastIdx = 0
  const thinkRe = /<think>([\s\S]*?)<\/think\s*>/g
  let m: RegExpExecArray | null

  while ((m = thinkRe.exec(repaired)) !== null) {
    if (m.index > lastIdx) {
      parts.push(md.parse(repaired.slice(lastIdx, m.index)) as string)
    }
    const innerHtml = md.parse((m[1] as string).trim()) as string
    parts.push(
      `<details class="think-block rounded-[var(--r-1)]"><summary>생각 중...</summary><div>${innerHtml}</div></details>`,
    )
    lastIdx = m.index + m[0].length
  }

  if (lastIdx < repaired.length) {
    parts.push(md.parse(repaired.slice(lastIdx)) as string)
  }

  return sanitize(parts.join(''))
}

const MARKDOWN_CACHE_MAX = 256
export const renderMarkdown = memoizeLru(renderMarkdownUncached, { max: MARKDOWN_CACHE_MAX })

export function MarkdownContent({ text, class: className }: { text: string; class?: string }) {
  const htmlStr = useMemo(() => renderMarkdown(text), [text])
  const classes = ['markdown-content', className].filter(Boolean).join(' ')
  return html`<div class=${classes} dangerouslySetInnerHTML=${{ __html: htmlStr }}></div>`
}
