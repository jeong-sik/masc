/**
 * Unified rich code-block preview engine for Markdown & Chat blocks.
 *
 * Supports:
 * - All 33 Pele / Mermaid diagram & chart types (full theme CSS variables
 *   including `--pele-accent` and `--pele-series-1..8`, click-to-zoom modal,
 *   SVG download, collapsible source, explicit syntax error card).
 * - AlphaTex / ATex musical notation (`<AlphaTexScoreView>` with dark/light
 *   palette, ResizeObserver, StaveProfile toggle, lightbox, built-in Web Audio
 *   playback via `sonivox.sf2`, and explicit parse diagnostics).
 * - Structured ```` ```chart ```` JSON blocks (`<StructuredChartView>` for
 *   line, bar, area, and pie charts).
 *
 * Exported both as a Preact component (`<RichCodePreviewCard>`) for VDOM-safe
 * rendering inside `ChatCodeBlock` AND as `enhanceRichCode(root)` for
 * HTML-rendered Markdown (`MarkdownContent`).
 */

import { html } from 'htm/preact'
import { render } from 'preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { ChatPreviewModal } from '../primitives/chat-preview-modal'
import { AlphaTexScoreView, resolveCssColorToRgba } from './alphatab-score'
import { StructuredChartView, parseChartFenceJson } from './structured-chart'
import './rich-code-preview.css'

export type RichCodeKind = 'diagram' | 'alphatex' | 'chart'

/**
 * Unambiguous Pele / Mermaid fence language tags (generic code-fence words like
 * `class`, `state`, `block`, `er`, `sequence`, `journey`, `packet`, `requirement`,
 * `info` are intentionally excluded so ordinary code blocks stay code blocks).
 */
export const PELE_FENCE_TAGS: ReadonlySet<string> = new Set([
  'mermaid',
  'pele',
  'xychart',
  'xychart-beta',
  'pie',
  'quadrant',
  'quadrantchart',
  'radar',
  'radar-beta',
  'sankey',
  'sankey-beta',
  'treemap',
  'treemap-beta',
  'gantt',
  'timeline',
  'kanban',
  'mindmap',
  'venn',
  'venn-beta',
  'gitgraph',
  'wardley',
  'ishikawa',
  'cynefin',
  'agentflow',
  'eventmodeling',
  'swimlane',
  'railroad',
  'c4',
  'architecture',
  'flowchart',
  'treeview',
  'usecase',
])

const ALPHATEX_FENCE_TAGS: ReadonlySet<string> = new Set(['alphatex', 'atex'])

export function isPeleFenceLang(tag: string): boolean {
  return PELE_FENCE_TAGS.has(tag.trim().toLowerCase())
}

export function richCodeKind(tag: string): RichCodeKind | null {
  const lower = tag.trim().toLowerCase()
  if (PELE_FENCE_TAGS.has(lower)) return 'diagram'
  if (ALPHATEX_FENCE_TAGS.has(lower)) return 'alphatex'
  if (lower === 'chart') return 'chart'
  return null
}

function isLightHost(host: HTMLElement | null): boolean {
  if (typeof document === 'undefined') return false
  const attr = host?.closest('[data-theme]')?.getAttribute('data-theme')
    ?? document.documentElement.getAttribute('data-theme')
  if (attr === 'light') return true
  if (attr === 'dark') return false
  return false
}

const DARK_PELE_SERIES: readonly string[] = [
  'oklch(0.78 0.14 75)',
  'oklch(0.74 0.15 155)',
  'oklch(0.73 0.14 235)',
  'oklch(0.75 0.16 35)',
  'oklch(0.72 0.16 310)',
  'oklch(0.76 0.13 195)',
  'oklch(0.77 0.14 115)',
  'oklch(0.72 0.16 10)',
]

const LIGHT_PELE_SERIES: readonly string[] = [
  'oklch(0.55 0.15 70)',
  'oklch(0.52 0.16 155)',
  'oklch(0.50 0.15 240)',
  'oklch(0.56 0.17 35)',
  'oklch(0.51 0.17 310)',
  'oklch(0.52 0.14 195)',
  'oklch(0.54 0.15 115)',
  'oklch(0.53 0.17 15)',
]

/**
 * Compute concrete theme CSS variables for Pele's SVG `<svg style="...">`
 * so standalone SVG data URIs (`<img>`) render with crisp contrast in both
 * dark and light themes across all 33 diagram/chart types.
 */
export function resolvePeleThemeVars(host: HTMLElement | null): Record<string, string> {
  const light = isLightHost(host)
  const cs = host && typeof getComputedStyle === 'function' ? getComputedStyle(host) : null
  const pick = (token: string, fallback: string): string => {
    const raw = cs?.getPropertyValue(token).trim()
    return resolveCssColorToRgba(raw || fallback, fallback)
  }

  const vars: Record<string, string> = {
    '--pele-fg': pick('--fg-1', light ? '#1c1a17' : '#ebe6dd'),
    '--pele-bg': pick('--bg-2', light ? '#f6f3ed' : '#1b1a18'),
    '--pele-line': pick('--fg-3', light ? '#6d665c' : '#9c9487'),
    '--pele-muted': pick('--fg-2', light ? '#565047' : '#b7afa3'),
    '--pele-border': pick('--line-2', light ? '#cfc8bc' : '#413d37'),
    '--pele-surface': pick('--bg-3', light ? '#ece8df' : '#252320'),
    '--pele-surface-alt': pick('--bg-1', light ? '#ffffff' : '#141311'),
    '--pele-accent': pick('--accent-brass-bright', light ? '#9a6b1b' : '#dfb160'),
    '--pele-fg-on-dark': '#f5f2eb',
    '--pele-fg-on-light': '#191714',
  }

  const fallbackSeries = light ? LIGHT_PELE_SERIES : DARK_PELE_SERIES
  for (let i = 0; i < 8; i += 1) {
    const idx = i + 1
    const token = `--pele-series-${idx}`
    const raw = cs?.getPropertyValue(token).trim() || fallbackSeries[i]!
    vars[token] = resolveCssColorToRgba(raw, raw)
  }

  return vars
}

function injectPeleThemeIntoSvg(svg: string, vars: Record<string, string>): string {
  const styleDecl = Object.entries(vars)
    .map(([k, v]) => `${k}:${v}`)
    .join(';')
  return svg.replace('<svg', `<svg style="${styleDecl}"`)
}

function triggerSvgDownload(svgText: string, filename: string): void {
  if (typeof URL === 'undefined' || typeof URL.createObjectURL !== 'function' || typeof document === 'undefined') {
    return
  }
  const blob = new Blob([svgText], { type: 'image/svg+xml;charset=utf-8' })
  const href = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = href
  a.download = filename
  a.style.display = 'none'
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => {
    try {
      URL.revokeObjectURL(href)
    } catch {
      // ignore
    }
  }, 1500)
}

function PeleDiagramView({
  source,
  lang,
  showSourceToggle = true,
}: {
  readonly source: string
  readonly lang?: string
  readonly showSourceToggle?: boolean
}) {
  const hostRef = useRef<HTMLDivElement>(null)
  const [svgMarkup, setSvgMarkup] = useState<string | null>(null)
  const [diagramType, setDiagramType] = useState<string | null>(null)
  const [renderError, setRenderError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [zoomOpen, setZoomOpen] = useState(false)

  useEffect(() => {
    let active = true
    setLoading(true)
    setRenderError(null)
    setSvgMarkup(null)

    void import('pele/lazy')
      .then(async (pele) => {
        if (!active) return
        const res = await pele.renderAsync(source)
        if (!active) return
        const rawSvg = res?.svg?.trim() ?? ''
        if (!rawSvg.startsWith('<svg')) {
          setRenderError('다이어그램 SVG를 생성하지 못했습니다.')
          return
        }
        const themeVars = resolvePeleThemeVars(hostRef.current)
        const styledSvg = injectPeleThemeIntoSvg(rawSvg, themeVars)
        setSvgMarkup(styledSvg)
        setDiagramType(res.type ?? lang ?? 'diagram')
        setRenderError(null)
      })
      .catch((err) => {
        if (!active) return
        const msg = err instanceof Error && err.message.trim()
          ? err.message.trim()
          : '다이어그램 문법을 해석하지 못했습니다.'
        setRenderError(msg)
      })
      .finally(() => {
        if (active) setLoading(false)
      })

    return () => {
      active = false
    }
  }, [source, lang])

  const dataUri = useMemo(
    () => (svgMarkup ? `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svgMarkup)}` : null),
    [svgMarkup],
  )

  const badgeLabel = (diagramType ?? lang ?? 'diagram').toUpperCase()

  if (loading) {
    return html`
      <div ref=${hostRef} class="rich-code-card" data-kind="diagram" data-testid="pele-diagram-card">
        <div class="rich-code-loading">다이어그램 렌더링 중…</div>
      </div>
    `
  }

  if (renderError || !dataUri || !svgMarkup) {
    return html`
      <div ref=${hostRef} class="rich-code-card is-error" data-kind="diagram" data-testid="pele-error-card">
        <div class="rich-code-toolbar">
          <span class="rich-code-badge mono">${badgeLabel} · 오류</span>
        </div>
        <div class="rich-code-error" role="alert">
          <strong>다이어그램 렌더링 오류:</strong> ${renderError ?? '유효하지 않은 다이어그램 문법입니다.'}
        </div>
        <pre class="rich-code-source-fallback"><code>${source}</code></pre>
      </div>
    `
  }

  return html`
    <div ref=${hostRef} class="rich-code-card" data-kind="diagram" data-testid="pele-diagram-card">
      <div class="rich-code-toolbar">
        <div class="rich-code-toolbar-left">
          <span class="rich-code-badge mono">${badgeLabel}</span>
        </div>
        <div class="rich-code-toolbar-right">
          <button
            type="button"
            class="rich-code-btn"
            onClick=${() => triggerSvgDownload(svgMarkup, `${(diagramType ?? lang ?? 'diagram').toLowerCase()}.svg`)}
            aria-label="SVG 다운로드"
          >
            SVG 다운로드
          </button>
          <button
            type="button"
            class="rich-code-btn"
            onClick=${() => setZoomOpen(true)}
            aria-label="다이어그램 확대 보기"
          >
            확대
          </button>
        </div>
      </div>

      <button
        type="button"
        class="rich-code-diagram-btn"
        onClick=${() => setZoomOpen(true)}
        aria-label="다이어그램 크게 보기"
      >
        <img
          src=${dataUri}
          alt=${`${badgeLabel} diagram`}
          class="rich-code-diagram-img"
        />
      </button>

      ${showSourceToggle && html`
        <details class="rich-code-source">
          <summary>원본 다이어그램 보기</summary>
          <pre><code>${source}</code></pre>
        </details>
      `}

      ${zoomOpen && html`
        <${ChatPreviewModal}
          title=${`${badgeLabel} 다이어그램`}
          actions=${html`
            <button
              type="button"
              class="btn-ghost btn-compact"
              onClick=${() => triggerSvgDownload(svgMarkup, `${(diagramType ?? lang ?? 'diagram').toLowerCase()}.svg`)}
            >
              SVG 다운로드
            </button>
          `}
          onClose=${() => setZoomOpen(false)}
        >
          <img
            src=${dataUri}
            alt=${`${badgeLabel} diagram`}
            class="rich-code-diagram-modal-img"
          />
        <//>
      `}
    </div>
  `
}

export interface RichCodePreviewCardProps {
  readonly kind: RichCodeKind
  readonly source: string
  readonly lang?: string
  readonly showSourceToggle?: boolean
}

export function RichCodePreviewCard({
  kind,
  source,
  lang,
  showSourceToggle = true,
}: RichCodePreviewCardProps) {
  if (kind === 'alphatex') {
    return html`<${AlphaTexScoreView} source=${source} showSourceToggle=${showSourceToggle} />`
  }

  if (kind === 'chart') {
    const parsed = useMemo(() => parseChartFenceJson(source), [source])
    if (!parsed) {
      return html`
        <div class="rich-code-card is-error" data-kind="chart" data-testid="chart-error-card">
          <div class="rich-code-toolbar">
            <span class="rich-code-badge mono">CHART · JSON 오류</span>
          </div>
          <div class="rich-code-error" role="alert">
            유효한 차트 JSON(<code>series</code> 배열 포함)이 아닙니다. 원본 코드를 표시합니다.
          </div>
          <pre class="rich-code-source-fallback"><code>${source}</code></pre>
        </div>
      `
    }
    return html`
      <div class="rich-code-card" data-kind="chart" data-testid="chart-preview-card">
        <${StructuredChartView} block=${parsed} />
        ${showSourceToggle && html`
          <details class="rich-code-source">
            <summary>원본 차트 JSON 보기</summary>
            <pre><code>${source}</code></pre>
          </details>
        `}
      </div>
    `
  }

  return html`<${PeleDiagramView} source=${source} lang=${lang} showSourceToggle=${showSourceToggle} />`
}

/**
 * Scan rendered HTML inside `root` for rich code fences (`mermaid`/Pele 33 types,
 * `alphatex`/`atex`, `chart`) and mount interactive Preact preview cards in place.
 * Returns a cleanup callback that unmounts all Preact subtrees cleanly.
 */
export function enhanceRichCode(root: HTMLElement): () => void {
  const mountedHosts: HTMLElement[] = []

  const codes = root.querySelectorAll('pre > code')
  for (const code of codes) {
    const match = /\blanguage-([a-z0-9_-]+)\b/i.exec(code.className)
    if (!match) continue
    const lang = match[1]!.toLowerCase()
    const kind = richCodeKind(lang)
    if (!kind) continue

    const pre = code.parentElement
    if (!pre || pre.getAttribute('data-rich-enhanced') === '1') continue

    const source = code.textContent?.trim() ?? ''
    if (!source) continue

    pre.setAttribute('data-rich-enhanced', '1')
    pre.style.display = 'none'

    const host = document.createElement('div')
    host.className = 'rich-code-preview'
    host.dataset.kind = kind
    pre.insertAdjacentElement('beforebegin', host)
    mountedHosts.push(host)

    render(
      html`<${RichCodePreviewCard} kind=${kind} source=${source} lang=${lang} showSourceToggle=${true} />`,
      host,
    )
  }

  return () => {
    for (const host of mountedHosts) {
      try {
        render(null, host)
      } catch {
        // ignore unmount errors
      }
      host.remove()
    }
  }
}
