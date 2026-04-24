// Markdown component shell — loads the full parser/sanitizer renderer only
// after markdown content is mounted.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'

import { InlineSpinner } from './inline-spinner'
import type { MarkdownContent } from './markdown-renderer'

export interface MarkdownProps {
  text: string
  class?: string
}

type MarkdownContentComponent = typeof MarkdownContent

let rendererPromise: Promise<MarkdownContentComponent> | null = null
let rendererComponent: MarkdownContentComponent | null = null

function loadMarkdownRenderer(): Promise<MarkdownContentComponent> {
  if (rendererComponent) return Promise.resolve(rendererComponent)
  if (!rendererPromise) {
    rendererPromise = import('./markdown-renderer')
      .then((module) => {
        rendererComponent = module.MarkdownContent
        return module.MarkdownContent
      })
      .catch((err) => {
        rendererPromise = null
        throw err
      })
  }
  return rendererPromise
}

function loadingClasses(className?: string): string {
  return [
    'markdown-content',
    'markdown-content--loading',
    'inline-flex',
    'items-center',
    'text-2xs',
    'text-[var(--text-dim)]',
    className,
  ].filter(Boolean).join(' ')
}

export function Markdown({ text, class: className }: MarkdownProps) {
  const [Renderer, setRenderer] = useState<MarkdownContentComponent | null>(() => rendererComponent)
  const [failed, setFailed] = useState(false)

  useEffect(() => {
    if (!text) return undefined
    if (rendererComponent) {
      setRenderer(() => rendererComponent)
      setFailed(false)
      return undefined
    }

    let cancelled = false
    setFailed(false)
    void loadMarkdownRenderer()
      .then((component) => {
        if (!cancelled) setRenderer(() => component)
      })
      .catch(() => {
        if (!cancelled) setFailed(true)
      })

    return () => {
      cancelled = true
    }
  }, [text])

  if (!text) return null
  if (Renderer) return html`<${Renderer} text=${text} class=${className} />`

  return html`
    <div class=${loadingClasses(className)} role=${failed ? 'alert' : 'status'} aria-live="polite">
      ${failed
        ? '마크다운을 불러오지 못했습니다'
        : html`<${InlineSpinner} size="xs" tone="muted" class="mr-1.5" />마크다운 로딩중`}
    </div>
  `
}
