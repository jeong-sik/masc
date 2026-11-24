/**
 * Lazy-loaded Canvas uPlot primitive wired to OKLCH SSOT tokens & shared crosshair sync.
 *
 * - Dynamically imports `uplot` so chart code stays strictly in the lazy `charts` chunk.
 * - Reads OKLCH CSS variables at mount and automatically re-renders on `data-theme` or
 *   `data-contrast` changes via `MutationObserver`.
 * - Shares crosshair across Telemetry & Cost charts via `uPlot.sync('masc-telemetry')`.
 * - Responsive via `ResizeObserver` inside a `min-width: 0` `.uplot-host`.
 */

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type uPlot from 'uplot'
import { getUPlotSync, publishCrosshair } from '../../core/time-window'

export interface UPlotSeriesSpec {
  readonly label: string
  /** CSS custom property token (e.g. '--brass-1', '--ok-fg', '--info-fg') or OKLCH color */
  readonly colorToken?: string
  readonly width?: number
  readonly fillAlpha?: number
  readonly unit?: string
  readonly dash?: number[]
  readonly show?: boolean
}

export interface UPlotChartProps {
  readonly id?: string
  readonly title?: string
  readonly subtitle?: ComponentChildren
  /** uPlot columnar aligned data: [timestampsInSeconds, ...seriesValues] */
  readonly data: uPlot.AlignedData
  readonly series: readonly UPlotSeriesSpec[]
  readonly height?: number
  readonly syncCrosshair?: boolean
  readonly valueFormatter?: (seriesIdx: number, raw: number | null) => string
  readonly className?: string
  readonly emptyLabel?: string
}

const DEFAULT_SERIES_TOKENS = [
  '--brass-1',
  '--info-fg',
  '--ok-fg',
  '--warn-fg',
  '--stalled-fg',
  '--err-fg',
] as const

export interface ChartPalette {
  readonly fg: string
  readonly grid: string
  readonly axis: string
  readonly bg: string
  readonly font: string
  readonly resolveColor: (tokenOrColor: string | undefined, fallbackIdx: number) => string
}

export function readChartPalette(root?: Element | null): ChartPalette {
  const el = root ?? (typeof document !== 'undefined' ? document.documentElement : null)
  const cs = el && typeof getComputedStyle === 'function' ? getComputedStyle(el) : null
  const getVar = (name: string, fallback: string): string => {
    const val = cs?.getPropertyValue(name)?.trim()
    return val && val.length > 0 ? val : fallback
  }

  return {
    fg: getVar('--fg-3', 'oklch(0.68 0.008 70)'),
    grid: getVar('--line-1', 'oklch(0.30 0.006 70)'),
    axis: getVar('--line-2', 'oklch(0.36 0.006 70)'),
    bg: getVar('--bg-1', 'oklch(0.175 0.005 70)'),
    font: `11px ${getVar('--font-mono', 'ui-monospace, monospace')}`,
    resolveColor(tokenOrColor: string | undefined, fallbackIdx: number): string {
      const candidate = tokenOrColor ?? DEFAULT_SERIES_TOKENS[fallbackIdx % DEFAULT_SERIES_TOKENS.length]!
      if (candidate.startsWith('--')) {
        return getVar(candidate, 'oklch(0.77 0.135 74)')
      }
      return candidate
    },
  }
}

function withAlpha(oklchColor: string, alpha: number): string {
  if (alpha <= 0) return 'transparent'
  const pct = Math.round(Math.min(1, Math.max(0, alpha)) * 100)
  return `color-mix(in oklch, ${oklchColor} ${pct}%, transparent)`
}

export function UPlotChart(props: UPlotChartProps) {
  const mountRef = useRef<HTMLDivElement>(null)
  const plotRef = useRef<uPlot | null>(null)
  const [themeRevision, setThemeRevision] = useState(0)
  const [loadError, setLoadError] = useState<string | null>(null)

  const height = props.height ?? 220
  const hasPoints = Array.isArray(props.data[0]) && props.data[0].length > 0

  // Re-read OKLCH CSS tokens whenever data-theme or data-contrast changes
  useEffect(() => {
    if (typeof MutationObserver === 'undefined' || typeof document === 'undefined') return
    const observer = new MutationObserver(() => {
      setThemeRevision((v) => v + 1)
    })
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['data-theme', 'data-contrast'],
    })
    return () => observer.disconnect()
  }, [])

  useEffect(() => {
    const mountEl = mountRef.current
    if (!mountEl || !hasPoints) return

    let disposed = false
    let resizeObserver: ResizeObserver | null = null

    const init = async () => {
      try {
        const mod = await import('uplot')
        if (disposed || !mountRef.current) return
        const UPlotCtor = mod.default
        const palette = readChartPalette()
        const width = Math.max(240, Math.floor(mountRef.current.clientWidth || 480))
        const sync = props.syncCrosshair === false
          ? undefined
          : (getUPlotSync(UPlotCtor) as uPlot.SyncPubSub)

        const seriesDefs: uPlot.Series[] = [
          {},
          ...props.series.map((spec, idx) => {
            const stroke = palette.resolveColor(spec.colorToken, idx)
            return {
              label: spec.label,
              stroke,
              width: spec.width ?? 1.75,
              dash: spec.dash,
              show: spec.show ?? true,
              fill: spec.fillAlpha ? withAlpha(stroke, spec.fillAlpha) : undefined,
              value: (_self: uPlot, raw: number) => {
                if (raw == null || Number.isNaN(raw)) return '없음'
                if (props.valueFormatter) return props.valueFormatter(idx, raw)
                const formatted = Number.isInteger(raw) ? String(raw) : raw.toFixed(2)
                return spec.unit ? `${formatted} ${spec.unit}` : formatted
              },
            } satisfies uPlot.Series
          }),
        ]

        const opts: uPlot.Options = {
          width,
          height,
          series: seriesDefs,
          cursor: {
            drag: { x: false, y: false },
            ...(sync ? { sync: { key: sync.key } } : {}),
          },
          scales: {
            x: { time: true },
          },
          axes: [
            {
              stroke: palette.fg,
              font: palette.font,
              grid: { show: true, stroke: palette.grid, width: 1 },
              ticks: { show: true, stroke: palette.axis, width: 1 },
            },
            {
              stroke: palette.fg,
              font: palette.font,
              grid: { show: true, stroke: palette.grid, width: 1 },
              ticks: { show: false },
              size: 56,
            },
          ],
          hooks: {
            setCursor: [
              (u) => {
                const idx = u.cursor.idx
                const ts = idx != null && u.data[0] ? u.data[0][idx] ?? null : null
                publishCrosshair(ts, props.id ?? props.title ?? null)
              },
            ],
          },
        }

        mountRef.current.innerHTML = ''
        const plot = new UPlotCtor(opts, props.data, mountRef.current)
        plotRef.current = plot
        setLoadError(null)

        if (typeof ResizeObserver !== 'undefined') {
          resizeObserver = new ResizeObserver((entries) => {
            const entry = entries[0]
            if (!entry || !plotRef.current) return
            const nextW = Math.max(200, Math.floor(entry.contentRect.width))
            if (nextW > 0 && nextW !== plotRef.current.width) {
              plotRef.current.setSize({ width: nextW, height })
            }
          })
          resizeObserver.observe(mountRef.current)
        }
      } catch (err) {
        if (!disposed) {
          setLoadError(err instanceof Error ? err.message : String(err))
        }
      }
    }

    void init()

    return () => {
      disposed = true
      resizeObserver?.disconnect()
      plotRef.current?.destroy()
      plotRef.current = null
    }
  }, [hasPoints, height, props.id, props.series, props.syncCrosshair, props.title, themeRevision])

  // Fast-path data update without tearing down canvas
  useEffect(() => {
    if (plotRef.current && hasPoints) {
      plotRef.current.setData(props.data)
    }
  }, [props.data, hasPoints])

  return html`
    <section class=${`uplot-host ${props.className ?? ''}`.trim()} aria-label=${props.title ?? 'Telemetry chart'}>
      ${(props.title || props.subtitle) && html`
        <header class="uplot-header">
          ${props.title && html`<h3 class="uplot-title">${props.title}</h3>`}
          ${props.subtitle && html`<div>${props.subtitle}</div>`}
        </header>
      `}
      ${loadError
        ? html`<div class="dtable-absent" role="status">차트 렌더 오류: ${loadError}</div>`
        : !hasPoints
          ? html`<div class="dtable-absent" role="status">${props.emptyLabel ?? '데이터 없음'}</div>`
          : html`<div ref=${mountRef} class="uplot-mount" />`}
    </section>
  `
}
