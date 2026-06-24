import { html } from 'htm/preact'
import type { RefObject } from 'preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { EmptyState } from './feedback-state'
import { sanitizeHtml } from '../../lib/dompurify.js'
import { loadMermaid, type MermaidApi } from './mermaid-loader'

/**
 * Observe whether an element is in (or near) the viewport.
 * The caller receives a ref to attach and a boolean that flips to true
 * once and stays true. Used to defer heavy mermaid renders until the
 * diagram is actually visible, avoiding main-thread work for off-screen
 * chat history diagrams.
 */
export function useMermaidInView<T extends HTMLElement>(
  rootMargin = '200px',
): [RefObject<T>, boolean] {
  const ref = useRef<T>(null)
  const [inView, setInView] = useState(false)

  useEffect(() => {
    const el = ref.current
    if (!el || inView) return
    if (typeof IntersectionObserver === 'undefined') {
      setInView(true)
      return
    }
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry?.isIntersecting) {
          setInView(true)
        }
      },
      { rootMargin },
    )
    observer.observe(el)
    return () => observer.disconnect()
  }, [inView, rootMargin])

  return [ref, inView]
}

let mermaidConfigured = false
let mermaidRenderCount = 0

async function getMermaid(): Promise<MermaidApi> {
  const mermaid = await loadMermaid()
  if (mermaidConfigured) return mermaid
  mermaid.initialize({
    startOnLoad: false,
    theme: 'dark',
    securityLevel: 'strict',
    suppressErrorRendering: true,
  })
  mermaidConfigured = true
  return mermaid
}

function nextRenderId(prefix: string): string {
  mermaidRenderCount += 1
  return `${prefix}-${mermaidRenderCount}`
}

// mermaid.render() manipulates shared DOM state internally.
// Concurrent calls produce corrupt SVG for the second caller.
// Serialize all render calls through a single queue.
let renderQueue: Promise<void> = Promise.resolve()

function serializedRender(
  mermaid: MermaidApi,
  id: string,
  source: string,
): Promise<{ svg: string }> {
  const job = renderQueue.then(() => mermaid.render(id, source))
  // Update queue tail regardless of success/failure so the next
  // caller waits for this one to finish (not for it to succeed).
  renderQueue = job.then(
    () => {},
    () => {},
  )
  return job
}

// Bounded LRU cache for rendered mermaid SVGs. Re-rendering the same
// diagram (e.g., switching keepers and back, or re-mounting chat history)
// is expensive because mermaid re-runs its full DOMPurify pass. Caching
// the validated SVG string skips that work entirely.
const MAX_CACHED_SVGS = 50
const svgCache = new Map<string, string>()

function cacheKey(source: string, id?: string): string {
  return id ? `${source}::${id}` : source
}

function getCachedSvg(source: string, id?: string): string | undefined {
  const key = cacheKey(source, id)
  const svg = svgCache.get(key)
  if (svg === undefined) return undefined
  // Touch the entry so it moves to the end (LRU).
  svgCache.delete(key)
  svgCache.set(key, svg)
  return svg
}

function setCachedSvg(source: string, id: string | undefined, svg: string): void {
  const key = cacheKey(source, id)
  if (svgCache.size >= MAX_CACHED_SVGS) {
    const firstKey = svgCache.keys().next().value
    if (firstKey !== undefined) {
      svgCache.delete(firstKey)
    }
  }
  svgCache.set(key, svg)
}

/**
 * Clear the rendered-SVG cache. Exported only for test isolation;
 * production code should not call this.
 */
export function clearMermaidSvgCache(): void {
  svgCache.clear()
}

/**
 * Reset module-level mutable render state. Exported only for test isolation;
 * production code should not call this.
 */
export function resetMermaidRenderState(): void {
  mermaidConfigured = false
  mermaidRenderCount = 0
  renderQueue = Promise.resolve()
}

/**
 * Shared mermaid render path used by both MermaidGraph and ChatMermaidBlock.
 * Returns a sanitized SVG string (mermaid's own securityLevel:'strict' already
 * runs DOMPurify) and validates it is well-formed XML before handing it back.
 * Rendering is serialized globally because mermaid.render() mutates shared
 * temporary DOM state and concurrent calls corrupt the second caller's SVG.
 */
export async function renderMermaidSvg(
  source: string,
  id?: string,
): Promise<string> {
  const cached = getCachedSvg(source, id)
  if (cached !== undefined) return cached

  const mermaid = await getMermaid()
  const renderId = id ?? nextRenderId('mermaid-shared')
  const { svg } = await serializedRender(mermaid, renderId, source)
  // Mermaid's securityLevel:'strict' already sanitizes, but callers inject the
  // result directly via dangerouslySetInnerHTML. An explicit pass preserves the
  // prior security contract without paying the cost of duplicate sanitization
  // per chat block (the original perf bottleneck was sanitizing once per block).
  const clean = sanitizeHtml(svg)
  const parser = new DOMParser()
  const doc = parser.parseFromString(clean, 'image/svg+xml')
  const parseError = doc.querySelector('parsererror')
  const rootTag = doc.documentElement?.tagName?.toLowerCase()
  if (parseError || rootTag !== 'svg') {
    throw new Error('SVG parse failed')
  }
  setCachedSvg(source, id, clean)
  return clean
}

interface MermaidGraphProps {
  source: string
  prefix?: string
  class?: string
  diagramClass?: string
  minHeightClass?: string
  fallbackText?: string
}

export function MermaidGraph({
  source,
  prefix = 'mermaid-graph',
  class: className = '',
  diagramClass = '',
  minHeightClass = 'min-h-40',
  fallbackText,
}: MermaidGraphProps) {
  const hostRef = useRef<HTMLDivElement | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    const host = hostRef.current
    if (!host) return undefined
    host.textContent = ''
    setError(null)

    const render = async () => {
      try {
        const svg = await renderMermaidSvg(source, nextRenderId(prefix))
        const hostEl = hostRef.current
        if (cancelled || !hostEl) return
        const parser = new DOMParser()
        const doc = parser.parseFromString(svg, 'image/svg+xml')
        const svgEl = doc.documentElement
        if (svgEl && svgEl.tagName.toLowerCase() === 'svg') {
          hostEl.textContent = ''
          hostEl.appendChild(svgEl)
        } else {
          if (!cancelled) setError('Mermaid returned non-SVG output')
        }
      } catch (err) {
        if (cancelled) return
        setError(
          err instanceof Error ? err.message : 'Mermaid 렌더링에 실패했습니다',
        )
      }
    }

    void render()
    return () => {
      cancelled = true
      if (hostRef.current) hostRef.current.textContent = ''
    }
  }, [prefix, source])

  return html`
    <div class=${`${className} ${minHeightClass}`.trim()}>
      ${error ? html`
        <div class="space-y-2">
          <${EmptyState} message=${error} compact />
          ${fallbackText ? html`
            <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 text-sm leading-loose text-[var(--color-fg-disabled)]">
              ${fallbackText}
            </div>
          ` : null}
        </div>
      ` : html`
        <div
          class=${`overflow-auto rounded-[var(--radius-lg)] p-3 bg-[var(--color-bg-surface)] ${diagramClass}`.trim()}
          ref=${hostRef}
          role="img"
          aria-label=${fallbackText ?? '다이어그램'}
        ></div>
      `}
    </div>
  `
}
