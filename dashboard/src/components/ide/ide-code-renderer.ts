import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { highlightCodeLines } from '../common/shiki-highlighter'
import type { CodeDocumentLine, CodeDocumentSnapshot } from './code-document-store'

export function useHighlightedCodeLines(document: CodeDocumentSnapshot): ReadonlyArray<string> {
  const [highlightedLines, setHighlightedLines] = useState<ReadonlyArray<string>>([])

  useEffect(() => {
    let cancelled = false
    setHighlightedLines([])
    void highlightCodeLines(document.content, document.language, document.lines.length)
      .then(lines => {
        if (!cancelled) setHighlightedLines(lines)
      })
      .catch(() => {
        if (!cancelled) setHighlightedLines([])
      })

    return () => { cancelled = true }
  }, [document.content, document.language, document.lines.length])

  return highlightedLines
}

export function CodeLineText({
  line,
  highlightedHtml,
}: {
  line: CodeDocumentLine
  highlightedHtml: string | undefined
}) {
  const style = {
    color: 'var(--color-fg-secondary)',
    display: 'block',
    minWidth: 0,
    whiteSpace: 'pre',
  }
  if (highlightedHtml !== undefined) {
    return html`
      <span
        class="ide-code-line"
        data-syntax="shiki"
        style=${style}
        dangerouslySetInnerHTML=${{ __html: highlightedHtml }}
      ></span>
    `
  }
  return html`<span class="ide-code-line" data-syntax="plain" style=${style}>${line.text}</span>`
}
