import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { formatTokens } from '../lib/format-number'
import { TextInput } from './common/input'
import { Eyebrow } from './common/eyebrow'
import type { Keeper, KeeperMetricPoint } from '../types'
import {
  ctxSegmentLabel,
  ctxSegmentColor,
  filterCtxCompositionEntries,
} from './keeper-detail-ctx-utils'
import { MutedSpan, DetailRow, DetailCard } from './keeper-detail-kpi'

const SPARKLINE_W = 200
const SPARKLINE_PAD = 2

export const ctxCompositionSearch = signal('')

// ── Context Composition Panel ────────────────────────────

export function CtxCompositionPanel({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const points = series.filter(
    (p: KeeperMetricPoint) => (p.ctx_composition?.display_total_tokens ?? 0) > 0,
  )
  if (points.length === 0) return null

  const latest = points[points.length - 1] ?? null
  const latestComposition = latest?.ctx_composition ?? null
  if (!latestComposition) return null

  const latestTotal = latestComposition.display_total_tokens
  const latestActual = latestComposition.actual_input_tokens
  const latestKnown = latestComposition.estimated_known_tokens
  const latestEntries = Object.entries(latestComposition.segments)
    .filter(([, segment]) => (segment?.estimated_tokens ?? 0) > 0)
    .sort(([, left], [, right]) => (right.estimated_tokens ?? 0) - (left.estimated_tokens ?? 0))
  if (latestEntries.length === 0 || latestTotal <= 0) return null
  const visibleCtxEntries = filterCtxCompositionEntries(latestEntries, ctxCompositionSearch.value)

  const allKeys = Array.from(
    new Set(points.flatMap((point: KeeperMetricPoint) => Object.keys(point.ctx_composition?.segments ?? {}))),
  )
  const sortedKeys = allKeys
    .filter((key) => points.some((point: KeeperMetricPoint) => (point.ctx_composition?.segments?.[key]?.estimated_tokens ?? 0) > 0))
    .sort((left, right) => {
      const rightLatest = latestComposition.segments[right]?.estimated_tokens ?? 0
      const leftLatest = latestComposition.segments[left]?.estimated_tokens ?? 0
      if (rightLatest !== leftLatest) return rightLatest - leftLatest
      return left.localeCompare(right)
    })

  const W = SPARKLINE_W
  const H = 56
  const pad = SPARKLINE_PAD
  const innerW = W - (2 * pad)
  const innerH = H - (2 * pad)
  const barStep = innerW / Math.max(points.length, 1)
  const barWidth = Math.max(3, Math.min(8, barStep - 1))

  const knownRatio = latestTotal > 0 ? latestKnown / latestTotal : 0
  const unattributedTokens = latestComposition.segments.unattributed?.estimated_tokens ?? 0

  return html`
    <div class="mb-5">
      <div class="flex items-center gap-2 mb-2">
        <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">CTX Composition</span>
        <${MutedSpan}>${points.length} snapshots</${MutedSpan}>
      </div>
      <div class="grid grid-cols-1 md:grid-cols-4 gap-3">
        <${DetailCard} class="md:col-span-2">
          <div class="flex items-center justify-between mb-2 gap-3">
            <${Eyebrow}>latest turn input</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${formatTokens(latestTotal)}</span>
          </div>
          <div class="h-3 rounded-[var(--r-0)] overflow-hidden border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] flex">
            ${latestEntries.map(([key, segment]) => {
              const pct = latestTotal > 0 ? (segment.estimated_tokens / latestTotal) * 100 : 0
              return html`<div
                title=${`${ctxSegmentLabel(key)} · ${formatTokens(segment.estimated_tokens)} · ${pct.toFixed(1)}%`}
                style=${`width:${pct}%;background:${ctxSegmentColor(key)};min-width:${pct > 0 ? '1px' : '0'};`}
              ></div>`
            })}
          </div>
          <div class="mt-2 flex flex-wrap gap-2 text-3xs text-[var(--color-fg-disabled)]">
            ${latestActual != null ? html`<span>actual ${formatTokens(latestActual)}</span>` : null}
            <span>known ${formatTokens(latestKnown)}</span>
            <span>${Math.round(knownRatio * 100)}% attributed</span>
            ${unattributedTokens > 0 ? html`<span>residual ${formatTokens(unattributedTokens)}</span>` : null}
          </div>
        <//>

        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>largest bucket</${Eyebrow}>
          <span class="text-sm font-medium text-[var(--color-fg-secondary)]">${ctxSegmentLabel(latestEntries[0]?.[0] ?? 'unknown')}</span>
          <span class="text-3xs font-mono text-[var(--color-fg-disabled)]">
            ${latestEntries[0] ? `${formatTokens(latestEntries[0][1].estimated_tokens)} · ${((latestEntries[0][1].estimated_tokens / latestTotal) * 100).toFixed(1)}%` : '-'}
          </span>
        <//>

        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>residual</${Eyebrow}>
          <span class="text-lg font-mono tabular-nums text-[var(--color-status-warn)]">${formatTokens(unattributedTokens)}</span>
          <${MutedSpan}>tool schema / provider overhead / estimator gap</${MutedSpan}>
        <//>
      </div>

      <div class="mt-3 grid grid-cols-1 md:grid-cols-3 gap-3">
        <${DetailCard} class="md:col-span-2">
          <${DetailRow}>
            <${Eyebrow}>stacked history</${Eyebrow}>
            <${MutedSpan}>${points.length} turns</${MutedSpan}>
          </${DetailRow}>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" role="img" aria-label="컨텍스트 구성 스택 히스토리" style="background:var(--bg-deepest);">
            ${points.map((point: KeeperMetricPoint, index: number) => {
              const comp = point.ctx_composition
              if (!comp || comp.display_total_tokens <= 0) return null
              const x = pad + (index * barStep) + Math.max(0, (barStep - barWidth) / 2)
              let yCursor = H - pad
              return sortedKeys.map((key) => {
                const tokens = comp.segments[key]?.estimated_tokens ?? 0
                if (tokens <= 0) return null
                const height = (tokens / comp.display_total_tokens) * innerH
                yCursor -= height
                return html`<rect
                  x="${x.toFixed(1)}"
                  y="${yCursor.toFixed(1)}"
                  width="${barWidth.toFixed(1)}"
                  height="${Math.max(height, 1).toFixed(1)}"
                  fill="${ctxSegmentColor(key)}"
                  opacity="0.92"
                />`
              })
            })}
          </svg>
        <//>

        <${DetailCard}>
          <div class="flex items-center justify-between gap-2 mb-2">
            <${Eyebrow}>latest breakdown</${Eyebrow}>
            <span class="text-3xs font-mono text-[var(--color-fg-disabled)]">${visibleCtxEntries.length}/${latestEntries.length}</span>
          </div>
          <${TextInput}
            type="search"
            class="mb-2 !px-2 !py-1 !text-2xs"
            value=${ctxCompositionSearch.value}
            placeholder="세그먼트 필터 (예: history, memory)"
            ariaLabel="context composition 세그먼트 필터"
            onInput=${(e: Event) => { ctxCompositionSearch.value = (e.target as HTMLInputElement).value }}
          />
          ${visibleCtxEntries.length === 0 ? html`
            <div class="py-4 text-center text-2xs text-[var(--color-fg-disabled)]">
              필터 결과 없음 (${latestEntries.length} items)
            </div>
          ` : null}
          <div class="flex flex-col gap-1.5">
            ${visibleCtxEntries.map(([key, segment]) => {
              const pct = latestTotal > 0 ? (segment.estimated_tokens / latestTotal) * 100 : 0
              return html`
                <div class="flex items-center justify-between gap-2 text-2xs">
                  <span class="inline-flex items-center gap-2 min-w-0">
                    <span class="inline-block w-2.5 h-2.5 rounded-full shrink-0" style=${`background:${ctxSegmentColor(key)};`}></span>
                    <span class="truncate text-[var(--color-fg-primary)]">${ctxSegmentLabel(key)}</span>
                  </span>
                  <span class="font-mono tabular-nums text-[var(--color-fg-disabled)] whitespace-nowrap">
                    ${pct.toFixed(1)}% · ${formatTokens(segment.estimated_tokens)}
                  </span>
                </div>
              `
            })}
          </div>
        <//>
      </div>
    </div>
  `
}
