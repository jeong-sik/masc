import { html } from 'htm/preact'
import { formatTokens, formatMsCompact } from '../lib/format-number'
import { pairedTokenRatio, summarizeMetricSeries } from '../lib/metric-series'
import { ProgressBar } from './common/progress-bar'
import { Eyebrow } from './common/eyebrow'
import { ObservedMetricChart } from './common/observed-metric-chart'
import type { Keeper } from '../types'
import { ctxColor } from './keeper-detail-ctx-utils'
import { MutedSpan, DetailCard, DetailRow } from './keeper-detail-kpi'

function costLabel(value: number): string {
  return `$${value !== 0 && value < 0.0001 ? value.toPrecision(3) : value.toFixed(4)}`
}

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

export function TokenTrendChart({ keeper }: { keeper: Keeper }) {
  const points = keeper.metrics_series ?? []
  if (points.length === 0) return null
  const ratio = pairedTokenRatio(points)
  return html`
    <div class="mb-5 v2-monitoring-panel">
      <div class="flex items-center gap-2 mb-2">
        <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">턴 토큰 추세</span>
        <${MutedSpan}>${points.length} retained snapshots<//>
      </div>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-3 v2-monitoring-row">
        <${DetailCard} class="md:col-span-2">
          <${ObservedMetricChart} label="입출력 토큰 추이" formatValue=${(n: number) => `${formatTokens(n)} tokens`}
            series=${[
              { name: 'input', color: 'var(--color-accent-fg)', readings: points.map(p => ({ ts: p.ts, value: p.input_tokens })) },
              { name: 'output', color: 'var(--color-status-ok)', dashed: true, readings: points.map(p => ({ ts: p.ts, value: p.output_tokens })) },
            ]} />
        <//>
        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>In/Out 비율<//>
          <span class="text-lg font-mono tabular-nums text-[var(--color-accent-fg)]">${ratio.kind === 'observed' ? `${ratio.value.toFixed(1)}x` : '미정'}</span>
          <${MutedSpan}>${ratio.kind === 'unobserved' ? '양쪽 토큰을 관측한 표본 없음'
            : ratio.kind === 'zero_output' ? `출력 토큰 0 · 양쪽 관측 ${ratio.samples}건`
              : `양쪽 토큰 관측 ${ratio.samples}/${points.length}건`}<//>
        <//>
      </div>
    </div>`
}

export function MetricsCharts({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  if (series.length === 0) return null
  const latency = series.map(p => ({ ts: p.ts, value: p.latency_ms }))
  const costs = series.map(p => ({ ts: p.ts, value: p.cost_usd }))
  const latencySummary = summarizeMetricSeries(latency)
  const costSummary = summarizeMetricSeries(costs)
  return html`
    <div class="grid grid-cols-1 md:grid-cols-2 gap-3 mb-5 v2-monitoring-row">
      <${DetailCard}>
        <${DetailRow}><${Eyebrow}>턴 지연 시간<//>
          <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${formatMsCompact(latencySummary.latest, '미관측')}</span>
        <//>
        <${ObservedMetricChart} label="턴 지연 시간" formatValue=${(n: number) => formatMsCompact(n)}
          series=${[{ name: 'latency', color: 'var(--color-accent-fg)', readings: latency }]} />
      <//>
      <${DetailCard}>
        <${DetailRow}><${Eyebrow}>${costSummary.missing > 0 ? '일부 관측 비용 합계 (USD)' : '보존 관측 비용 합계 (USD)'}<//>
          <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${costSummary.sum === null ? '미관측' : costLabel(costSummary.sum)}</span>
        <//>
        <${ObservedMetricChart} label="관측별 비용 (USD)" formatValue=${costLabel}
          series=${[{ name: 'cost', color: 'var(--color-accent-fg)', readings: costs }]} />
      <//>
    </div>`
}
