// Markdown renderer — uses `marked` for full GFM parsing
// Handles: tables, code fences, line breaks, inline formatting,
//          mermaid diagrams (lazy-loaded), <think> blocks (collapsible)
// CSS classes: .markdown-content (ui.css), .think-block (ui.css),
//              .mermaid-rendered (ui.css)

import { html } from 'htm/preact'
import { useRef, useEffect, useMemo } from 'preact/hooks'
import { Marked } from 'marked'
import DOMPurify from 'dompurify'

// ── Lazy mermaid loader ──────────────────────────────────────
type MermaidApi = typeof import('mermaid')['default']
let mermaidPromise: Promise<MermaidApi> | null = null
let mermaidConfigured = false
let mermaidRenderCount = 0

function getMermaid(): Promise<MermaidApi> {
  if (!mermaidPromise) {
    mermaidPromise = import('mermaid').then(m => m.default)
  }
  return mermaidPromise.then(mermaid => {
    if (mermaidConfigured) return mermaid
    mermaid.initialize({ startOnLoad: false, theme: 'dark', securityLevel: 'strict' })
    mermaidConfigured = true
    return mermaid
  })
}

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
}

function sanitize(raw: string): string {
  return DOMPurify.sanitize(raw, PURIFY_CONFIG)
}

function sanitizeMermaidSvg(raw: string): SVGElement | null {
  const safeSvg = DOMPurify.sanitize(raw, {
    USE_PROFILES: { svg: true },
  })
  if (!safeSvg || !safeSvg.includes('<svg')) {
    return null
  }
  const parsed = new DOMParser().parseFromString(safeSvg, 'image/svg+xml')
  const svg = parsed.documentElement
  if (!svg || svg.tagName.toLowerCase() !== 'svg') return null
  return document.importNode(svg, true) as unknown as SVGElement
}

// ── Parse markdown with <think> block extraction ─────────────
// Think blocks are extracted first, their content is parsed
// separately as markdown, then reassembled as <details>.
function renderMarkdown(text: string): string {
  const parts: string[] = []
  let lastIdx = 0
  const thinkRe = /<think>([\s\S]*?)<\/think\s*>/g
  let m: RegExpExecArray | null

  while ((m = thinkRe.exec(text)) !== null) {
    if (m.index > lastIdx) {
      parts.push(md.parse(text.slice(lastIdx, m.index)) as string)
    }
    const innerHtml = md.parse((m[1] as string).trim()) as string
    parts.push(
      `<details class="think-block rounded-lg"><summary>생각 중...</summary><div>${innerHtml}</div></details>`
    )
    lastIdx = m.index + m[0].length
  }

  if (lastIdx < text.length) {
    parts.push(md.parse(text.slice(lastIdx)) as string)
  }

  return sanitize(parts.join(''))
}

// ── Component ────────────────────────────────────────────────
export function Markdown({ text, class: className }: { text: string; class?: string }) {
  if (!text) return null
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
    ;(async () => {
      const mermaid = await getMermaid()
      if (cancelled) return
      for (const codeEl of mermaidCodes) {
        const pre = codeEl.parentElement
        if (!pre) continue
        const code = codeEl.textContent ?? ''
        try {
          const id = `mermaid-md-${++mermaidRenderCount}`
          const { svg } = await mermaid.render(id, code)
          if (!cancelled && pre.parentElement) {
            const div = document.createElement('div')
            div.className = 'mermaid-rendered'
            const safeSvg = sanitizeMermaidSvg(svg)
            if (!safeSvg) continue // keep original code block on sanitization failure
            div.appendChild(safeSvg)
            pre.replaceWith(div)
          }
        } catch {
          // Keep code block as fallback on render error
        }
      }
    })()
    return () => { cancelled = true }
  }, [htmlStr])

  return html`<div ref=${containerRef} class=${classes} dangerouslySetInnerHTML=${{ __html: htmlStr }}></div>`
}
