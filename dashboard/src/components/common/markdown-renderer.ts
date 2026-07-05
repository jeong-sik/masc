// Markdown renderer core — uses `marked` for full GFM parsing
// Handles: tables, code fences, line breaks, inline formatting,
//          mermaid diagrams (lazy-loaded), <think> blocks (collapsible)
// CSS classes: .markdown-content (ui.css), .think-block (ui.css),
//              .mermaid-rendered (ui.css)

import { html } from 'htm/preact'
import { useRef, useEffect, useMemo } from 'preact/hooks'
import { Marked } from 'marked'

import { highlightCodeHtml } from './shiki-highlighter'
import { renderMermaidSvg } from './mermaid-graph'
import { sanitizeHtml } from '../../lib/dompurify'
import { memoizeLru } from '../../lib/lru-cache'

// ── Marked instance (GFM tables + line-break support) ────────
const md = new Marked({ gfm: true, breaks: true })

// Custom renderer: links open in new tab with noopener
md.use({
  renderer: {
    link({ href, title, text }) {
      const titleAttr = title ? ` title="${title}"` : ''
      return `<a href="${href}"${titleAttr} target="_blank" rel="noopener noreferrer">${text}</a>`
    }
  }
})

// ── HTML sanitization via DOMPurify ──────────────────────────
// VDOM→innerHTML migration requires explicit sanitization.
// DOMPurify handles script/iframe/event handler/SVG attacks.
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

// `renderMermaidSvg` returns an already-sanitized SVG string; parse it once
// into an element for insertion (mirrors MermaidGraph's consumer). appendChild
// adopts the cross-document node into the live tree.
function parseSvgElement(clean: string): Element | null {
  const doc = new DOMParser().parseFromString(clean, 'image/svg+xml')
  const svg = doc.documentElement
  if (!svg || svg.tagName.toLowerCase() !== 'svg') return null
  return svg
}

// ── Repair truncated markdown ────────────────────────────────
// Keeper tool outputs occasionally arrive with an unclosed code fence
// (```) or an odd count of inline backticks (`) — the LLM ran out of
// max_tokens mid-write and the `board_post` payload is stored as-is.
// Marked's parser then "swallows" everything after the opening backtick.
// Repair: close any dangling fence/inline and append a visible marker
// so the operator can tell the post was cut, not just strangely rendered.
function repairTruncatedMarkdown(text: string): string {
  const fenceCount = (text.match(/```/g) ?? []).length
  if (fenceCount % 2 === 1) {
    return `${text}\n…[잘림]\n\`\`\``
  }
  // Only count inline backticks OUTSIDE fenced blocks, otherwise
  // a balanced fence would be miscounted as odd.
  const outsideFences = text.replace(/```[\s\S]*?```/g, '')
  const inlineCount = (outsideFences.match(/`/g) ?? []).length
  if (inlineCount % 2 === 1) {
    return `${text}…[잘림]\``
  }
  return text
}

// ── Parse markdown with <think> block extraction ─────────────
// Think blocks are extracted first, their content is parsed
// separately as markdown, then reassembled as <details>.
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
      `<details class="think-block rounded-[var(--r-1)]"><summary>생각 중...</summary><div>${innerHtml}</div></details>`
    )
    lastIdx = m.index + m[0].length
  }

  if (lastIdx < repaired.length) {
    parts.push(md.parse(repaired.slice(lastIdx)) as string)
  }

  return sanitize(parts.join(''))
}

// Cache the sanitized HTML by source text. `renderMarkdownUncached` is pure
// (given the module `md` instance + PURIFY_CONFIG), and each call runs marked
// + DOMPurify, where DOMPurify parses HTML via DOMParser. Identical content
// re-rendered across component mounts (e.g. a keeper turn list that remounts)
// then reuses the result instead of re-parsing. Exported for tests.
const MARKDOWN_CACHE_MAX = 256
export const renderMarkdown = memoizeLru(renderMarkdownUncached, { max: MARKDOWN_CACHE_MAX })

// ── Component ────────────────────────────────────────────────
export function MarkdownContent({ text, class: className }: { text: string; class?: string }) {
  const containerRef = useRef<HTMLDivElement>(null)
  const htmlStr = useMemo(() => renderMarkdown(text), [text])
  const classes = ['markdown-content', className].filter(Boolean).join(' ')

  // Post-render: replace mermaid code blocks with rendered SVG
  useEffect(() => {
    const el = containerRef.current
    if (!el) return
    const mermaidCodes = el.querySelectorAll<HTMLElement>('pre > code.language-mermaid')
    if (mermaidCodes.length === 0) return

    let cancelled = false
    void (async () => {
      for (const codeEl of mermaidCodes) {
        if (cancelled) break
        const pre = codeEl.parentElement
        if (!pre) continue
        const code = codeEl.textContent ?? ''
        try {
          // Shared, cached render path (deduped across the dashboard). No id is
          // passed so the cache is keyed by source: identical diagrams across
          // turns reuse the render instead of re-running mermaid.
          const svg = await renderMermaidSvg(code)
          if (!cancelled && pre.parentElement) {
            const safeSvg = parseSvgElement(svg)
            if (!safeSvg) continue // keep original code block on parse failure
            const div = document.createElement('div')
            div.className = 'mermaid-rendered'
            div.appendChild(safeSvg)
            pre.replaceWith(div)
          }
        } catch (err) {
          // Keep code block as fallback on render error, but remain observable.
          console.warn('[markdown-renderer] mermaid fence render failed', err)
        }
      }
    })()
    return () => { cancelled = true }
  }, [htmlStr])

  // Post-render: highlight code blocks with shiki
  useEffect(() => {
    const el = containerRef.current
    if (!el) return
    const codeBlocks = el.querySelectorAll<HTMLElement>('pre > code:not(.language-mermaid)')
    if (codeBlocks.length === 0) return

    let cancelled = false
    void (async () => {
      for (const codeEl of codeBlocks) {
        if (cancelled) break
        if (codeEl.dataset.highlighted) continue
        
        const pre = codeEl.parentElement
        if (!pre) continue
        const code = codeEl.textContent ?? ''
        
        let lang = 'text'
        for (const cls of codeEl.classList) {
          if (cls.startsWith('language-')) {
            lang = cls.replace('language-', '')
            break
          }
        }

        try {
          const safeHtml = await highlightCodeHtml(code, lang)
          if (cancelled) break

          const div = document.createElement('div')
          div.innerHTML = safeHtml
          const shikiPre = div.firstElementChild as HTMLElement

          if (shikiPre && shikiPre.tagName === 'PRE') {
            // Apply dashboard specific classes to match existing UI
            shikiPre.classList.add('shiki-rendered', 'rounded-[var(--r-1)]', 'my-3', 'text-sm', 'leading-relaxed')

            pre.replaceWith(shikiPre)
          }
          codeEl.dataset.highlighted = 'true'
        } catch (e) {
          // Keep original code block on error — do not mark as highlighted
          console.warn('[shiki] highlight failed', e)
        }
      }
    })()
    
    return () => { cancelled = true }
  }, [htmlStr])

  return html`<div ref=${containerRef} class=${classes} dangerouslySetInnerHTML=${{ __html: htmlStr }}></div>`
}
