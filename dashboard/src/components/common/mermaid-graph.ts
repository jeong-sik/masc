import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { EmptyState } from './empty-state'

type MermaidApi = typeof import('mermaid')['default']

let mermaidPromise: Promise<MermaidApi> | null = null
let mermaidConfigured = false
let mermaidRenderCount = 0

async function getMermaid(): Promise<MermaidApi> {
  if (!mermaidPromise) {
    mermaidPromise = import('mermaid').then(module => module.default)
  }
  const mermaid = await mermaidPromise
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
        const mermaid = await getMermaid()
        const { svg } = await serializedRender(
          mermaid,
          nextRenderId(prefix),
          source,
        )
        const hostEl = hostRef.current
        if (cancelled || !hostEl) return
        const parser = new DOMParser()
        const doc = parser.parseFromString(svg, 'image/svg+xml')
        const parseError = doc.querySelector('parsererror')
        if (parseError) {
          if (!cancelled) setError('SVG parse failed')
          return
        }
        const svgEl = doc.documentElement
        if (svgEl instanceof SVGElement) {
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
            <div class="rounded border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2 text-sm leading-loose text-[var(--text-dim)]">
              ${fallbackText}
            </div>
          ` : null}
        </div>
      ` : html`
        <div
          class=${`overflow-auto rounded-[10px] p-3 bg-[rgba(9,12,20,0.7)] ${diagramClass}`.trim()}
          ref=${hostRef}
        ></div>
      `}
    </div>
  `
}
