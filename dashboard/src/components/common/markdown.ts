// Markdown renderer — uses `marked` for full GFM parsing
// Handles: tables, code fences, line breaks, inline formatting,
//          mermaid diagrams (lazy-loaded), <think> blocks (collapsible)
// CSS classes: .markdown-content (ui.css), .think-block (ui.css),
//              .mermaid-rendered (ui.css)

import { html } from 'htm/preact'
import { useRef, useEffect, useMemo } from 'preact/hooks'
import { Marked } from 'marked'
import DOMPurify from 'dompurify'

// ── Lazy shiki loader ────────────────────────────────────────
import type { Highlighter } from 'shiki'
import type MermaidDefault from 'mermaid'

let shikiPromise: Promise<Highlighter> | null = null

function getShiki(): Promise<Highlighter> {
  if (!shikiPromise) {
    shikiPromise = import('shiki').then(async (shiki) => {
      return shiki.createHighlighter({
        themes: ['vitesse-dark'],
        langs: ['javascript', 'typescript', 'python', 'bash', 'json', 'yaml', 'html', 'css', 'sql', 'go', 'rust']
      })
    }).catch((err) => {
      shikiPromise = null  // allow retry on next call
      throw err
    })
  }
  return shikiPromise
}

// ── Lazy mermaid loader ──────────────────────────────────────
type MermaidApi = typeof MermaidDefault

function importMermaid(): Promise<MermaidApi> {
  return import('mermaid').then(module => module.default)
}
let mermaidPromise: Promise<MermaidApi> | null = null
let mermaidConfigured = false
let mermaidRenderCount = 0

function getMermaid(): Promise<MermaidApi> {
  const promise = mermaidPromise ?? (mermaidPromise = importMermaid())
  return promise.then(mermaid => {
    if (mermaidConfigured) return mermaid
    mermaid.initialize({ startOnLoad: false, theme: 'dark', securityLevel: 'strict', suppressErrorRendering: true })
    mermaidConfigured = true
    return mermaid
  }).catch((err) => {
    mermaidPromise = null
    mermaidConfigured = false
    throw err
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

// Shiki generates <span style="color: ..."> for syntax tokens.
// Allow `style` only when sanitizing trusted Shiki output.
const SHIKI_PURIFY_CONFIG = {
  ALLOWED_TAGS: ['pre', 'code', 'span'],
  ALLOWED_ATTR: ['class', 'style'],
}

function sanitizeShikiHtml(raw: string): string {
  return DOMPurify.sanitize(raw, SHIKI_PURIFY_CONFIG)
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
function renderMarkdown(text: string): string {
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
      `<details class="think-block rounded"><summary>생각 중...</summary><div>${innerHtml}</div></details>`
    )
    lastIdx = m.index + m[0].length
  }

  if (lastIdx < repaired.length) {
    parts.push(md.parse(repaired.slice(lastIdx)) as string)
  }

  return sanitize(parts.join(''))
}

// ── Component ────────────────────────────────────────────────
export function Markdown({ text, class: className }: { text: string; class?: string }) {
  if (!text) return null
  return html`<${MarkdownContent} text=${text} class=${className} />`
}

function MarkdownContent({ text, class: className }: { text: string; class?: string }) {
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

  // Post-render: highlight code blocks with shiki
  useEffect(() => {
    const el = containerRef.current
    if (!el) return
    const codeBlocks = el.querySelectorAll<HTMLElement>('pre > code:not(.language-mermaid)')
    if (codeBlocks.length === 0) return

    let cancelled = false
    void (async () => {
      let highlighter: Highlighter | null = null
      
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
        
        if (!highlighter) {
          highlighter = await getShiki()
          if (cancelled) break
        }
        
        try {
          const loadedLangs = highlighter.getLoadedLanguages()
          if (lang !== 'text' && !loadedLangs.includes(lang)) {
            lang = 'text'
          }
        } catch {
          lang = 'text'
        }
        
        if (cancelled) break

        try {
          const rawHtml = highlighter.codeToHtml(code, { lang, theme: 'vitesse-dark' })
          const safeHtml = sanitizeShikiHtml(rawHtml)

          const div = document.createElement('div')
          div.innerHTML = safeHtml
          const shikiPre = div.firstElementChild as HTMLElement

          if (shikiPre && shikiPre.tagName === 'PRE') {
            // Apply dashboard specific classes to match existing UI
            shikiPre.classList.add('shiki-rendered', 'rounded', 'my-3', 'text-sm', 'leading-relaxed')

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
