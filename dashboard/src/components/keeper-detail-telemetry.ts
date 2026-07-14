import { html } from 'htm/preact'
import { formatTokens, isFiniteMetricValue } from '../lib/format-number'
import { SPARKLINE_W, SPARKLINE_H, SPARKLINE_PAD } from '../lib/sparkline-config'
import { CopyIdButton } from './common/copy-id-button'
import { Eyebrow } from './common/eyebrow'
import type { Keeper, KeeperMetricPoint } from '../types'
import { MutedSpan, DetailRow, DetailCard } from './keeper-detail-kpi'


function miniSparkline(
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

function formatFingerprint(value: string | null | undefined): string {
  if (!value) return '-'
  return value.length > 16 ? `${value.slice(0, 16)}…` : value
}

function formatSegmentLabel(key: string): string {
  return key.replace(/[_-]+/g, ' ')
}

// ── Prompt Telemetry Panel ───────────────────────────────

export function PromptTelemetryPanel({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const promptPoints = series.filter(
    (p: KeeperMetricPoint) => p.prompt_metrics != null || p.prompt_fingerprint != null,
  )
  if (promptPoints.length === 0) return null

  const latest = promptPoints[promptPoints.length - 1] ?? null
  const latestPrompt = latest?.prompt_metrics ?? null
  const latestSegments = Object.entries(latestPrompt?.segments ?? {})
    .sort(([left], [right]) => left.localeCompare(right))
  const promptTotals = promptPoints.map(
    (p: KeeperMetricPoint) => p.prompt_metrics?.estimated_total_tokens ?? 0,
  )
  const latestTotal = latestPrompt?.estimated_total_tokens ?? null
  const latestCacheable = latestPrompt?.estimated_cacheable_tokens ?? null
  const cacheableRatio =
    latestTotal && latestCacheable != null && latestTotal > 0
      ? latestCacheable / latestTotal
      : null

  const fingerprints = promptPoints
    .map((p: KeeperMetricPoint) => p.prompt_fingerprint ?? p.prompt_metrics?.fingerprint ?? null)
    .filter((value): value is string => Boolean(value))
  const uniqueFingerprintCount = new Set(fingerprints).size
  let fingerprintTransitions = 0
  let lastFingerprint: string | null = null
  for (const current of fingerprints) {
    if (lastFingerprint != null && current !== lastFingerprint) fingerprintTransitions += 1
    lastFingerprint = current
  }

  const W = SPARKLINE_W, H = SPARKLINE_H
  const totalLine = miniSparkline(promptTotals)

  return html`
    <div class="mb-5 v2-monitoring-panel">
      <div class="flex items-center gap-2 mb-2">
        <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">프롬프트 핑거프린트</span>
        <${MutedSpan}>${promptPoints.length}개 스냅샷</${MutedSpan}>
        ${latest?.prompt_fingerprint
          ? html`<span class="inline-flex items-center gap-1">
              <span class="text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-disabled)] font-mono" title=${latest.prompt_fingerprint}>${formatFingerprint(latest.prompt_fingerprint)}</span>
              <${CopyIdButton} value=${latest.prompt_fingerprint} label="fingerprint" size=${10} />
            </span>`
          : null}
      </div>
      <div class="grid grid-cols-1 md:grid-cols-4 gap-3 v2-monitoring-row">
        <${DetailCard} class="md:col-span-2">
          <${DetailRow}>
            <${Eyebrow}>estimated prompt tokens</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${latestTotal != null ? formatTokens(latestTotal) : '-'}</span>
          </${DetailRow}>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" role="img" aria-label="프롬프트 토큰 추이" style="background:var(--bg-deepest);">
            ${totalLine ? html`<polyline points="${totalLine}" fill="none" stroke="var(--amber-bright)" stroke-width="1.5"/>` : null}
          </svg>
          <div class="mt-1 flex flex-wrap gap-2 text-3xs text-[var(--color-fg-disabled)]">
            <span>latest ${latestTotal != null ? formatTokens(latestTotal) : '-'}</span>
            <span>cacheable ${latestCacheable != null ? formatTokens(latestCacheable) : '-'}</span>
            ${cacheableRatio != null ? html`<span>${Math.round(cacheableRatio * 100)}% cacheable</span>` : null}
            ${latest?.runtime_strategy
              ? html`<span>strategy ${latest.runtime_strategy}</span>`
              : null}
          </div>
        <//>

        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>fingerprint revisions</${Eyebrow}>
          <span class="text-lg font-mono tabular-nums text-[var(--color-status-warn)]">${fingerprintTransitions}</span>
          <${MutedSpan}>${uniqueFingerprintCount} unique</${MutedSpan}>
        <//>

        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>latest fingerprint</${Eyebrow}>
          <div class="flex items-center gap-1.5">
            <span class="text-sm font-mono break-all text-[var(--color-fg-secondary)]" title=${latest?.prompt_fingerprint ?? ''}>${latest?.prompt_fingerprint ? formatFingerprint(latest.prompt_fingerprint) : '-'}</span>
            ${latest?.prompt_fingerprint ? html`<${CopyIdButton} value=${latest.prompt_fingerprint} label="fingerprint" size=${12} />` : null}
          </div>
          <${MutedSpan}>${latestSegments.length} segments</${MutedSpan}>
        <//>
      </div>

      ${latestSegments.length > 0 ? html`
        <div class="mt-3 grid grid-cols-1 md:grid-cols-2 gap-3 v2-monitoring-row">
          ${latestSegments.map(([segmentKey, segment]) => html`
            <${DetailCard}>
              <div class="flex items-center justify-between gap-2 mb-2">
                <${Eyebrow}>${formatSegmentLabel(segmentKey)}</${Eyebrow}>
                <span class="inline-flex items-center gap-1">
                  <span class="text-3xs font-mono text-[var(--color-fg-disabled)]" title=${segment.fingerprint ?? ''}>${formatFingerprint(segment.fingerprint)}</span>
                  ${segment.fingerprint ? html`<${CopyIdButton} value=${segment.fingerprint} label="segment fingerprint" size=${10} />` : null}
                </span>
              </div>
              <div class="grid grid-cols-2 gap-2 text-xs">
                <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-2 v2-monitoring-card">
                  <${Eyebrow} tone="disabled">tokens</${Eyebrow}>
                  <div class="mt-1 font-mono tabular-nums text-[var(--color-accent-fg)]">${formatTokens(segment.estimated_tokens)}</div>
                </div>
                <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-2 v2-monitoring-card">
                  <${Eyebrow} tone="disabled">bytes</${Eyebrow}>
                  <div class="mt-1 font-mono tabular-nums text-[var(--color-fg-secondary)]">${segment.bytes.toLocaleString()}</div>
                </div>
              </div>
            <//>
          `)}
        </div>
      ` : null}
    </div>
  `
}

// ── Inference Telemetry Panel ────────────────────────────

function healthStatusColor(status: string | undefined): string {
  switch (status) {
    case 'healthy': return 'var(--good)'
    case 'degraded': return 'var(--amber-bright)'
    case 'unhealthy': return 'var(--color-status-bad)'
    default: return 'var(--color-fg-disabled)'
  }
}

export function InferenceTelemetryPanel({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const telemetryPoints = series.filter(
    (p: KeeperMetricPoint) => p.inference_telemetry != null || p.wall_tokens_per_second != null,
  )
  if (telemetryPoints.length === 0) return null

  const wallTokPerSec = telemetryPoints
    .map((p: KeeperMetricPoint) => p.wall_tokens_per_second)
    .filter((value): value is number => value != null)
  const hwTokPerSec = telemetryPoints
    .map((p: KeeperMetricPoint) => p.inference_telemetry?.timings?.predicted_per_second)
    .filter((value): value is number => value != null)
  const latencySeries = telemetryPoints.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.request_latency_ms ?? null,
  )
  const cacheNs = telemetryPoints.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.timings?.cache_n ?? 0,
  )
  const reasoningTokens = telemetryPoints.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.reasoning_tokens ?? 0,
  )
  const ttfrcSeries = telemetryPoints.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.ttfrc_ms ?? null,
  )
  const prefillSeries = telemetryPoints.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.prefill_ms ?? null,
  )

  const W = SPARKLINE_W, H = SPARKLINE_H
  const lastWallTps = wallTokPerSec[wallTokPerSec.length - 1] ?? 0
  const avgWallTps =
    wallTokPerSec.length > 0
      ? wallTokPerSec.reduce((a, b) => a + b, 0) / wallTokPerSec.length
      : 0
  const lastHwTps = hwTokPerSec[hwTokPerSec.length - 1] ?? 0
  const avgHwTps =
    hwTokPerSec.length > 0
      ? hwTokPerSec.reduce((a, b) => a + b, 0) / hwTokPerSec.length
      : 0
  const lastLatency = latencySeries[latencySeries.length - 1] ?? null
  const totalCacheN = cacheNs.reduce((a, b) => a + b, 0)
  const totalReasoning = reasoningTokens.reduce((a, b) => a + b, 0)

  const wallTpsLine = wallTokPerSec.length > 1 ? miniSparkline(wallTokPerSec) : ''
  const hwTpsLine = hwTokPerSec.length > 1 ? miniSparkline(hwTokPerSec) : ''
  const latencyLine = miniSparkline(latencySeries)
  const ttfrcLine = miniSparkline(ttfrcSeries)
  const prefillLine = miniSparkline(prefillSeries)

  const lastTtfrc = ttfrcSeries.filter(isFiniteMetricValue)[ttfrcSeries.filter(isFiniteMetricValue).length - 1] ?? null
  const lastPrefill = prefillSeries.filter(isFiniteMetricValue)[prefillSeries.filter(isFiniteMetricValue).length - 1] ?? null

  const lastFp = telemetryPoints[telemetryPoints.length - 1]?.inference_telemetry?.system_fingerprint

  const providerHealth = keeper.provider_health

  return html`
    <div class="mb-5 v2-monitoring-panel">
      <div class="flex items-center gap-2 mb-2">
        <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">추론 텔레메트리</span>
        <${MutedSpan}>${telemetryPoints.length}개 지점</${MutedSpan}>
        ${lastFp ? html`<span class="text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-disabled)] font-mono">${lastFp}</span>` : null}
        ${providerHealth ? html`
          <span class="ml-auto inline-flex items-center gap-1.5 text-2xs px-2 py-0.5 rounded-full border" style=${`border-color:${healthStatusColor(providerHealth.status)}33;background:${healthStatusColor(providerHealth.status)}11;color:${healthStatusColor(providerHealth.status)}`}>
            <span class="inline-block w-1.5 h-1.5 rounded-full" style=${`background:${healthStatusColor(providerHealth.status)}`}></span>
            runtime — ${providerHealth.status}
          </span>
        ` : null}
      </div>
      <div class="grid grid-cols-2 md:grid-cols-7 gap-3 v2-monitoring-row">
        ${wallTokPerSec.length > 0 ? html`
        <${DetailCard}>
          <${DetailRow}>
            <${Eyebrow}>wall tok/s</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--good)]">${lastWallTps.toFixed(1)}</span>
          </${DetailRow}>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" role="img" aria-label="Wall TPS 추이" style="background:var(--bg-deepest);">
            ${wallTpsLine ? html`<polyline points="${wallTpsLine}" fill="none" stroke="var(--color-status-ok)" stroke-width="1.5"/>` : null}
          </svg>
          <div class="text-3xs text-[var(--color-fg-disabled)] mt-1">avg ${avgWallTps.toFixed(1)}</div>
        <//>
        ` : null}

        ${hwTokPerSec.length > 0 ? html`
        <${DetailCard}>
          <${DetailRow}>
            <${Eyebrow}>hw tok/s</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--good)]">${lastHwTps.toFixed(1)}</span>
          </${DetailRow}>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" role="img" aria-label="하드웨어 TPS 추이" style="background:var(--bg-deepest);">
            ${hwTpsLine ? html`<polyline points="${hwTpsLine}" fill="none" stroke="var(--color-status-ok)" stroke-width="1.5"/>` : null}
          </svg>
          <div class="text-3xs text-[var(--color-fg-disabled)] mt-1">avg ${avgHwTps.toFixed(1)} · decode-only</div>
        <//>
        ` : null}

        ${'' /* request latency */}
        <${DetailCard}>
          <${DetailRow}>
            <${Eyebrow}>API latency</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${isFiniteMetricValue(lastLatency) && lastLatency > 0 ? `${(lastLatency / 1000).toFixed(1)}s` : '-'}</span>
          </${DetailRow}>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" role="img" aria-label="API 지연 시간 추이" style="background:var(--bg-deepest);">
            ${latencyLine ? html`<polyline points="${latencyLine}" fill="none" stroke="var(--sky-400)" stroke-width="1.5"/>` : null}
          </svg>
        <//>

        ${'' /* cache hits */}
        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>KV Cache</${Eyebrow}>
          <span class="text-lg font-mono tabular-nums text-[var(--purple)]">${totalCacheN > 0 ? totalCacheN.toLocaleString() : '-'}</span>
          <${MutedSpan}>cumulative tokens</${MutedSpan}>
        <//>

        ${'' /* reasoning tokens */}
        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>추론</${Eyebrow}>
          <span class="text-lg font-mono tabular-nums text-[var(--color-status-warn)]">${totalReasoning > 0 ? totalReasoning.toLocaleString() : '-'}</span>
          <${MutedSpan}>total tokens</${MutedSpan}>
        <//>

        ${'' /* TTFT */}
        <${DetailCard}>
          <${DetailRow}>
            <${Eyebrow}>TTFT</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${lastTtfrc != null ? `${(lastTtfrc / 1000).toFixed(1)}s` : '-'}</span>
          </${DetailRow}>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" role="img" aria-label="TTFT 추이" style="background:var(--bg-deepest);">
            ${ttfrcLine ? html`<polyline points="${ttfrcLine}" fill="none" stroke="var(--sky-400)" stroke-width="1.5"/>` : null}
          </svg>
        <//>

        ${'' /* prefill */}
        <${DetailCard}>
          <${DetailRow}>
            <${Eyebrow}>prefill</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${lastPrefill != null ? `${(lastPrefill / 1000).toFixed(1)}s` : '-'}</span>
          </${DetailRow}>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" role="img" aria-label="Prefill 추이" style="background:var(--bg-deepest);">
            ${prefillLine ? html`<polyline points="${prefillLine}" fill="none" stroke="var(--sky-400)" stroke-width="1.5"/>` : null}
          </svg>
        <//>
      </div>
    </div>
  `
}
