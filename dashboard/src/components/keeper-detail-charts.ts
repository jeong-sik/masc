import { html } from 'htm/preact'
import { formatTokens, isFiniteMetricValue } from '../lib/format-number'
import { SPARKLINE_W, SPARKLINE_H, SPARKLINE_PAD } from '../lib/sparkline-config'
import { ProgressBar } from './common/progress-bar'
import { Eyebrow } from './common/eyebrow'
import type { Keeper, KeeperMetricPoint } from '../types'
import { ctxColor } from './keeper-detail-ctx-utils'
import { MutedSpan, DetailCard, DetailRow } from './keeper-detail-kpi'

// ── Context Chart ────────────────────────────────────────

export function ContextChart({ keeper }: { keeper: Keeper }) {
  const ratio = keeper.context_ratio ?? keeper.context?.context_ratio ?? null
  if (ratio == null) {
    return html`
      <${DetailCard} class="flex items-center gap-3 mb-5">
        <${MutedSpan}>컨텍스트 미관측</${MutedSpan}>
      <//>`
  }
  const pct = ratio * 100
  const color = ctxColor(pct)
  return html`
    <${DetailCard} class="flex items-center gap-3 mb-5">
      <${ProgressBar} pct=${pct} size="md" trackTone="dim" trackClass="flex-1" class=${`bg-[${color}]`} />
      <span class="text-sm font-semibold tabular-nums text-[var(--color-fg-secondary)]">${pct.toFixed(1)}%</span>
    <//>`
}

// ── Token Trend Chart (per-turn input/output tokens) ────

const TOKEN_CHART_W = 200
const TOKEN_CHART_H = 50

export function TokenTrendChart({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const points = series.filter(
    (p: KeeperMetricPoint) => p.inference_telemetry?.timings != null,
  )
  if (points.length < 2) return null

  const inputTokens = points.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.timings?.prompt_n ?? 0,
  )
  const outputTokens = points.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.timings?.predicted_n ?? 0,
  )
  const totalPerTurn = inputTokens.map((inp, i) => inp + (outputTokens[i] ?? 0))
  const maxVal = Math.max(...totalPerTurn, 1)

  const W = TOKEN_CHART_W, H = TOKEN_CHART_H, pad = 2
  const n = points.length

  const inputLine = inputTokens.map((v, i) => {
    const x = pad + (i / (n - 1)) * (W - 2 * pad)
    const y = H - pad - (v / maxVal) * (H - 2 * pad)
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')

  const outputLine = outputTokens.map((v, i) => {
    const x = pad + (i / (n - 1)) * (W - 2 * pad)
    const y = H - pad - (v / maxVal) * (H - 2 * pad)
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')

  const lastInput = inputTokens[inputTokens.length - 1] ?? 0
  const lastOutput = outputTokens[outputTokens.length - 1] ?? 0
  const avgRatio = inputTokens.reduce((a, b) => a + b, 0) / Math.max(outputTokens.reduce((a, b) => a + b, 0), 1)

  return html`
    <div class="mb-5 v2-monitoring-panel">
      <div class="flex items-center gap-2 mb-2">
        <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">턴 토큰 추세</span>
        <${MutedSpan}>${points.length} turns</${MutedSpan}>
      </div>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-3 v2-monitoring-row">
        ${'' /* Dual-line chart: input (cyan) + output (green) */}
        <${DetailCard} class="md:col-span-2">
          <div class="flex items-center gap-4 mb-1.5">
            <span class="flex items-center gap-1 text-3xs text-[var(--color-fg-muted)]">
              <span class="inline-block w-2.5 h-0.5 rounded-[var(--r-1)] bg-[var(--cyan)]"></span> input
              <span class="font-mono text-[var(--cyan)]">${formatTokens(lastInput)}</span>
            </span>
            <span class="flex items-center gap-1 text-3xs text-[var(--color-fg-muted)]">
              <span class="inline-block w-2.5 h-0.5 rounded-[var(--r-1)] bg-[var(--color-status-ok)]"></span> output
              <span class="font-mono text-[var(--good)]">${formatTokens(lastOutput)}</span>
            </span>
          </div>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" role="img" aria-label="입출력 토큰 추이" style="background:var(--bg-deepest);">
            ${inputLine ? html`<polyline points="${inputLine}" fill="none" stroke="var(--cyan)" stroke-width="1.5" opacity="0.8"/>` : null}
            ${outputLine ? html`<polyline points="${outputLine}" fill="none" stroke="var(--color-status-ok)" stroke-width="1.5" opacity="0.8"/>` : null}
          </svg>
        <//>

        ${'' /* Input/Output ratio */}
        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>In/Out 비율</${Eyebrow}>
          <span class="text-lg font-mono tabular-nums text-[var(--color-accent-fg)]">${avgRatio.toFixed(1)}x</span>
          <${MutedSpan}>${avgRatio > 10 ? '프롬프트 비대 주의' : avgRatio > 5 ? '프롬프트 무거움' : '정상 범위'}</${MutedSpan}>
        <//>
      </div>
    </div>
  `
}

// ── Sparkline helpers ────────────────────────────────────


export function miniSparkline(
  data: Array<number | null | undefined>,
  maxOverride?: number,
): string {
  const W = SPARKLINE_W, H = SPARKLINE_H, pad = SPARKLINE_PAD
  const n = data.length
  const points = data
    .map((value, index) => ({ value, index }))
    .filter((point): point is { value: number; index: number } =>
      isFiniteMetricValue(point.value),
    )
  if (points.length < 2) return ''
  const maxVal = maxOverride ?? Math.max(...points.map(point => point.value), 1)
  return points.map(({ value, index }) => {
    const x = pad + (index / Math.max(n - 1, 1)) * (W - 2 * pad)
    const y = H - pad - (value / maxVal) * (H - 2 * pad)
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')
}

// ── Metrics Charts (Latency + Cost + Model) ─────────────

export function MetricsCharts({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  if (series.length < 2) return null

  const latencySeries = series.map((p: KeeperMetricPoint) => p.latency_ms)
  const costs = series.map((p: KeeperMetricPoint) => p.cost_usd ?? 0)
  const W = SPARKLINE_W, H = SPARKLINE_H

  const lastLatency = latencySeries[latencySeries.length - 1] ?? null
  const totalCost = costs.reduce((a: number, b: number) => a + b, 0)

  const latencyLine = miniSparkline(latencySeries)
  const costLine = miniSparkline(costs)

  return html`
    <div class="grid grid-cols-1 md:grid-cols-2 gap-3 mb-5 v2-monitoring-row">
      ${'' /* Latency */}
      <${DetailCard}>
        <${DetailRow}>
          <${Eyebrow}>지연 시간</${Eyebrow}>
          <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${isFiniteMetricValue(lastLatency) && lastLatency > 0 ? `${(lastLatency / 1000).toFixed(1)}s` : '-'}</span>
        </${DetailRow}>
        <svg aria-hidden="true" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" style="background:var(--bg-deepest);">
          ${latencyLine ? html`<polyline points="${latencyLine}" fill="none" stroke="var(--sky-400)" stroke-width="1.5"/>` : null}
        </svg>
      <//>

      ${'' /* Cost */}
      <${DetailCard}>
        <${DetailRow}>
          <${Eyebrow}>비용</${Eyebrow}>
          <span class="text-xs font-mono tabular-nums text-[var(--purple)]">$${totalCost.toFixed(4)}</span>
        </${DetailRow}>
        <svg aria-hidden="true" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" style="background:var(--bg-deepest);">
          ${costLine ? html`<polyline points="${costLine}" fill="none" stroke="var(--purple)" stroke-width="1.5"/>` : null}
        </svg>
      <//>
    </div>
  `
}
