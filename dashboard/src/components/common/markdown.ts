// Lightweight markdown renderer — no external deps (except mermaid, lazy-loaded)
// Handles: headings, code fences (with syntax class + mermaid), inline code,
//          bold, italic, strikethrough, links, blockquotes, <think> blocks,
//          unordered/ordered lists, horizontal rules
// CSS classes: .markdown-content, .think-block (defined in components.css)

import { html } from 'htm/preact'
import { useRef, useEffect } from 'preact/hooks'

// Lazy mermaid loader — self-contained to avoid transitive import chains
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

/** Render a markdown string to Preact VDOM nodes */
export function Markdown({ text, class: className }: { text: string; class?: string }) {
  if (!text) return null
  const blocks = parseBlocks(text)
  const classes = ['markdown-content', className].filter(Boolean).join(' ')
  return html`<div class=${classes}>${blocks}</div>`
}

// ── Mermaid component ────────────────────────────────────

function MermaidBlock({ code }: { code: string }) {
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    let cancelled = false
    const render = async () => {
      const el = containerRef.current
      if (!el) return
      try {
        const mermaid = await getMermaid()
        if (cancelled) return
        const id = `mermaid-md-${++mermaidRenderCount}`
        const { svg } = await mermaid.render(id, code)
        if (!cancelled && el) {
          el.innerHTML = svg
        }
      } catch {
        if (!cancelled && el) {
          el.textContent = code
          el.classList.add('mermaid-error')
        }
      }
    }
    render()
    return () => { cancelled = true }
  }, [code])

  return html`<div ref=${containerRef} class="mermaid-container rounded-lg p-4 my-2 bg-[var(--white-3)] border border-[var(--border-slate-12)] overflow-x-auto"></div>`
}

// ── Block parsing ────────────────────────────────────────

function parseBlocks(src: string) {
  const lines = src.split('\n')
  const nodes: unknown[] = []
  let i = 0

  while (i < lines.length) {
    const line = lines[i] as string

    // Code fence (``` or ~~~)
    if (/^(`{3,}|~{3,})/.test(line)) {
      const fence = line.match(/^(`{3,}|~{3,})/)![0]
      const lang = line.slice(fence.length).trim()
      const codeLines: string[] = []
      i++
      while (i < lines.length && !(lines[i] as string).startsWith(fence)) {
        codeLines.push(lines[i] as string)
        i++
      }
      i++ // skip closing fence
      const code = codeLines.join('\n')

      // Mermaid diagram
      if (lang === 'mermaid') {
        nodes.push(html`<${MermaidBlock} code=${code} />`)
        continue
      }

      nodes.push(html`<pre class="code-block rounded-lg p-3 my-2 bg-[var(--white-3)] border border-[var(--border-slate-12)] overflow-x-auto"><code class=${lang ? `language-${lang}` : ''}>${code}</code></pre>`)
      continue
    }

    // Think block: <think>...</think>
    if (line.trim() === '<think>' || line.trim().startsWith('<think>')) {
      const thinkLines: string[] = []
      const firstContent = line.trim().replace(/^<think>/, '').trim()
      if (firstContent && firstContent !== '</think>') {
        thinkLines.push(firstContent)
      }
      i++
      while (i < lines.length && !(lines[i] as string).includes('</think>')) {
        thinkLines.push(lines[i] as string)
        i++
      }
      if (i < lines.length) {
        const lastContent = (lines[i] as string).replace('</think>', '').trim()
        if (lastContent) thinkLines.push(lastContent)
        i++ // skip </think>
      }
      const inner = thinkLines.join('\n').trim()
      nodes.push(html`
        <details class="think-block rounded-lg">
          <summary>생각 중...</summary>
          <div>${inlineToVdom(inner)}</div>
        </details>
      `)
      continue
    }

    // Horizontal rule (---, ***, ___)
    if (/^(-{3,}|\*{3,}|_{3,})\s*$/.test(line.trim())) {
      nodes.push(html`<hr class="my-3 border-[var(--border-slate-16)]" />`)
      i++
      continue
    }

    // Heading (# to ###)
    const headingMatch = line.match(/^(#{1,3})\s+(.+)$/)
    if (headingMatch) {
      const level = (headingMatch[1] as string).length
      const content = headingMatch[2] as string
      const cls = level === 1
        ? 'text-[16px] font-bold mt-4 mb-2 text-[var(--text-heading)]'
        : level === 2
          ? 'text-[14px] font-semibold mt-3 mb-1.5 text-[var(--text-heading)]'
          : 'text-[13px] font-semibold mt-2 mb-1 text-[var(--text-body)]'
      const inner = inlineToVdom(content)
      if (level === 1) nodes.push(html`<h1 class=${cls}>${inner}</h1>`)
      else if (level === 2) nodes.push(html`<h2 class=${cls}>${inner}</h2>`)
      else nodes.push(html`<h3 class=${cls}>${inner}</h3>`)
      i++
      continue
    }

    // Blockquote (> line)
    if (line.startsWith('> ')) {
      const quoteLines: string[] = []
      while (i < lines.length && (lines[i] as string).startsWith('> ')) {
        quoteLines.push((lines[i] as string).slice(2))
        i++
      }
      nodes.push(html`<blockquote class="border-l-2 border-[var(--ff-gold-40)] pl-3 my-2 text-[var(--text-muted)]">${inlineToVdom(quoteLines.join('\n'))}</blockquote>`)
      continue
    }

    // Unordered list (- or * at start)
    if (/^[-*]\s+/.test(line)) {
      const items: string[] = []
      while (i < lines.length && /^[-*]\s+/.test(lines[i] as string)) {
        items.push((lines[i] as string).replace(/^[-*]\s+/, ''))
        i++
      }
      nodes.push(html`<ul class="list-disc pl-5 my-2 space-y-0.5">${items.map(item => html`<li class="text-[13px] text-[var(--text-body)]">${inlineToVdom(item)}</li>`)}</ul>`)
      continue
    }

    // Ordered list (1. 2. etc.)
    if (/^\d+\.\s+/.test(line)) {
      const items: string[] = []
      while (i < lines.length && /^\d+\.\s+/.test(lines[i] as string)) {
        items.push((lines[i] as string).replace(/^\d+\.\s+/, ''))
        i++
      }
      nodes.push(html`<ol class="list-decimal pl-5 my-2 space-y-0.5">${items.map(item => html`<li class="text-[13px] text-[var(--text-body)]">${inlineToVdom(item)}</li>`)}</ol>`)
      continue
    }

    // Empty line → skip (spacing handled by CSS margins)
    if (line.trim() === '') {
      i++
      continue
    }

    // Regular paragraph — collect consecutive non-special lines
    const paraLines: string[] = []
    while (i < lines.length) {
      const cur = lines[i] as string
      if (
        cur.trim() === '' ||
        /^(`{3,}|~{3,})/.test(cur) ||
        cur.startsWith('> ') ||
        cur.trim().startsWith('<think>') ||
        /^#{1,3}\s+/.test(cur) ||
        /^[-*]\s+/.test(cur) ||
        /^\d+\.\s+/.test(cur) ||
        /^(-{3,}|\*{3,}|_{3,})\s*$/.test(cur.trim())
      ) break
      paraLines.push(cur)
      i++
    }
    if (paraLines.length > 0) {
      nodes.push(html`<p>${inlineToVdom(paraLines.join('\n'))}</p>`)
    }
  }

  return nodes
}

// ── Inline parsing ────────────────────────────────────────

function inlineToVdom(text: string): (string | unknown)[] {
  // Process inline elements via regex splitting
  // Order: code first (protect from bold/italic), then bold, strikethrough, italic, links
  const parts: (string | unknown)[] = []
  const regex = /(`[^`]+`)|(~~[^~]+~~)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g

  let lastIndex = 0
  let match: RegExpExecArray | null

  while ((match = regex.exec(text)) !== null) {
    if (match.index > lastIndex) {
      parts.push(text.slice(lastIndex, match.index))
    }

    if (match[1]) {
      // Inline code: `code`
      const code = match[1].slice(1, -1)
      parts.push(html`<code class="px-1 py-0.5 rounded bg-[var(--white-8)] text-[var(--ff-gold-bright)] text-[12px]">${code}</code>`)
    } else if (match[2]) {
      // Strikethrough: ~~text~~
      const struck = match[2].slice(2, -2)
      parts.push(html`<del class="text-[var(--text-muted)]">${struck}</del>`)
    } else if (match[3]) {
      // Bold: **text**
      const bold = match[3].slice(2, -2)
      parts.push(html`<strong>${bold}</strong>`)
    } else if (match[4]) {
      // Italic: *text*
      const italic = match[4].slice(1, -1)
      parts.push(html`<em>${italic}</em>`)
    } else if (match[5] && match[6]) {
      // Link: [text](url)
      parts.push(html`<a href=${match[6]} target="_blank" rel="noopener" class="text-[var(--accent)] hover:underline">${match[5]}</a>`)
    }

    lastIndex = match.index + match[0].length
  }

  if (lastIndex < text.length) {
    parts.push(text.slice(lastIndex))
  }

  return parts.length > 0 ? parts : [text]
}
