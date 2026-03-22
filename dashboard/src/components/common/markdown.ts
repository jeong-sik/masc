// Lightweight markdown renderer — no external deps
// Handles: code fences, inline code, bold, italic, links, blockquotes, <think> blocks
// CSS classes: .markdown-content, .think-block (defined in components.css)

import { html } from 'htm/preact'

/** Render a markdown string to Preact VDOM nodes */
export function Markdown({ text }: { text: string }) {
  if (!text) return null
  const blocks = parseBlocks(text)
  return html`<div class="markdown-content">${blocks}</div>`
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
      nodes.push(html`<pre><code class=${lang ? `language-${lang}` : ''}>${codeLines.join('\n')}</code></pre>`)
      continue
    }

    // Think block: <think>...</think>
    if (line.trim() === '<think>' || line.trim().startsWith('<think>')) {
      const thinkLines: string[] = []
      // Handle content on same line as <think>
      const firstContent = line.trim().replace(/^<think>/, '').trim()
      if (firstContent && firstContent !== '</think>') {
        thinkLines.push(firstContent)
      }
      i++
      while (i < lines.length && !(lines[i] as string).includes('</think>')) {
        thinkLines.push(lines[i] as string)
        i++
      }
      // Handle content on the </think> line
      if (i < lines.length) {
        const lastContent = (lines[i] as string).replace('</think>', '').trim()
        if (lastContent) thinkLines.push(lastContent)
        i++ // skip </think>
      }
      const inner = thinkLines.join('\n').trim()
      nodes.push(html`
        <details class="think-block rounded-lg">
          <summary>Thinking...</summary>
          <div>${inlineToVdom(inner)}</div>
        </details>
      `)
      continue
    }

    // Blockquote (> line)
    if (line.startsWith('> ')) {
      const quoteLines: string[] = []
      while (i < lines.length && (lines[i] as string).startsWith('> ')) {
        quoteLines.push((lines[i] as string).slice(2))
        i++
      }
      nodes.push(html`<blockquote>${inlineToVdom(quoteLines.join('\n'))}</blockquote>`)
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
      if (cur.trim() === '' || /^(`{3,}|~{3,})/.test(cur) || cur.startsWith('> ') || cur.trim().startsWith('<think>')) break
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
  // Order matters: code first (protect from bold/italic), then bold, italic, links
  const parts: (string | unknown)[] = []
  const regex = /(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g

  let lastIndex = 0
  let match: RegExpExecArray | null

  while ((match = regex.exec(text)) !== null) {
    // Text before match
    if (match.index > lastIndex) {
      parts.push(text.slice(lastIndex, match.index))
    }

    if (match[1]) {
      // Inline code: `code`
      const code = match[1].slice(1, -1)
      parts.push(html`<code>${code}</code>`)
    } else if (match[2]) {
      // Bold: **text**
      const bold = match[2].slice(2, -2)
      parts.push(html`<strong>${bold}</strong>`)
    } else if (match[3]) {
      // Italic: *text*
      const italic = match[3].slice(1, -1)
      parts.push(html`<em>${italic}</em>`)
    } else if (match[4] && match[5]) {
      // Link: [text](url)
      parts.push(html`<a href=${match[5]} target="_blank" rel="noopener">${match[4]}</a>`)
    }

    lastIndex = match.index + match[0].length
  }

  // Remaining text after last match
  if (lastIndex < text.length) {
    parts.push(text.slice(lastIndex))
  }

  return parts.length > 0 ? parts : [text]
}
