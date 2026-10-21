import { html } from 'htm/preact'
import { formatMsCompact, formatTokPerSec } from '../lib/format-number'
import { summarizeMetricSeries } from '../lib/metric-series'
import { ObservedMetricChart } from './common/observed-metric-chart'
import { CopyIdButton } from './common/copy-id-button'
import { Eyebrow } from './common/eyebrow'
import type { Keeper, KeeperMetricPoint } from '../types'
import { MutedSpan, DetailRow, DetailCard } from './keeper-detail-kpi'


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

  const latest = series[series.length - 1] ?? null
  const latestPrompt = latest?.prompt_metrics ?? null
  const latestSegments = Object.entries(latestPrompt?.segments ?? {})
    .sort(([left], [right]) => left.localeCompare(right))
  const promptReadings = series.map(p => ({ ts: p.ts, value: p.prompt_metrics?.total_bytes }))
  const latestTotal = latestPrompt?.total_bytes ?? null
  const latestCacheable = latestPrompt?.cacheable_bytes ?? null
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
            <${Eyebrow}>prompt bytes</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${latestTotal != null ? latestTotal.toLocaleString() : '-'}</span>
          </${DetailRow}>
          <${ObservedMetricChart} label="프롬프트 바이트 추이" formatValue=${(n: number) => `${n.toLocaleString()} bytes`}
            series=${[{ name: 'prompt bytes', color: 'var(--color-status-warn)', readings: promptReadings }]} />
          <div class="mt-1 flex flex-wrap gap-2 text-3xs text-[var(--color-fg-disabled)]">
            <span>latest ${latestTotal != null ? `${latestTotal.toLocaleString()} bytes` : '-'}</span>
            <span>cacheable ${latestCacheable != null ? `${latestCacheable.toLocaleString()} bytes` : '-'}</span>
            ${cacheableRatio != null ? html`<span>${Math.round(cacheableRatio * 100)}% cacheable</span>` : null}
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
              <div class="text-xs">
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
    case 'healthy': return 'var(--color-status-ok)'
    case 'degraded': return 'var(--color-status-warn)'
    case 'unhealthy': return 'var(--color-status-err)'
    default: return 'var(--color-fg-disabled)'
  }
}

export function InferenceTelemetryPanel({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const telemetryPoints = series.filter(
    (p: KeeperMetricPoint) => p.inference_telemetry != null || p.wall_tokens_per_second != null,
  )
  if (telemetryPoints.length === 0) return null

  const readings = (read: (point: KeeperMetricPoint) => number | null | undefined) =>
    series.map(point => ({ ts: point.ts, value: read(point) }))
  const wallReadings = readings(point => point.wall_tokens_per_second)
  const hwReadings = readings(point => point.inference_telemetry?.timings?.predicted_per_second)
  const latencyReadings = readings(point => point.inference_telemetry?.request_latency_ms)
  const ttfrcReadings = readings(point => point.inference_telemetry?.ttfrc_ms)
  const prefillReadings = readings(point => point.inference_telemetry?.prefill_ms)
  const wallSummary = summarizeMetricSeries(wallReadings)
  const hwSummary = summarizeMetricSeries(hwReadings)
  const latencySummary = summarizeMetricSeries(latencyReadings)
  const ttfrcSummary = summarizeMetricSeries(ttfrcReadings)
  const prefillSummary = summarizeMetricSeries(prefillReadings)
  const cacheSummary = summarizeMetricSeries(readings(point => point.inference_telemetry?.timings?.cache_n))
  const reasoningSummary = summarizeMetricSeries(readings(point => point.inference_telemetry?.reasoning_tokens))

  const lastFp = series[series.length - 1]?.inference_telemetry?.system_fingerprint

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
      <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3 v2-monitoring-row">
        ${wallSummary.observed > 0 ? html`
        <${DetailCard}>
          <${DetailRow}>
            <${Eyebrow}>wall tok/s</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--color-status-ok)]">${formatTokPerSec(wallSummary.latest)}</span>
          </${DetailRow}>
          <${ObservedMetricChart} label="Wall TPS 추이" formatValue=${(n: number) => formatTokPerSec(n)}
            series=${[{ name: 'wall tok/s', color: 'var(--color-status-ok)', readings: wallReadings }]} />
          <div class="text-3xs text-[var(--color-fg-disabled)] mt-1">avg ${(wallSummary.sum! / wallSummary.observed).toFixed(1)}</div>
        <//>
        ` : null}

        ${hwSummary.observed > 0 ? html`
        <${DetailCard}>
          <${DetailRow}>
            <${Eyebrow}>hw tok/s</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--color-status-ok)]">${formatTokPerSec(hwSummary.latest)}</span>
          </${DetailRow}>
          <${ObservedMetricChart} label="하드웨어 TPS 추이" formatValue=${(n: number) => formatTokPerSec(n)}
            series=${[{ name: 'hw tok/s', color: 'var(--color-status-ok)', readings: hwReadings }]} />
          <div class="text-3xs text-[var(--color-fg-disabled)] mt-1">avg ${(hwSummary.sum! / hwSummary.observed).toFixed(1)} · decode-only</div>
        <//>
        ` : null}

        ${'' /* request latency */}
        <${DetailCard}>
          <${DetailRow}>
            <${Eyebrow}>API latency</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${formatMsCompact(latencySummary.latest, '미관측')}</span>
          </${DetailRow}>
          <${ObservedMetricChart} label="API 지연 시간 추이" formatValue=${(n: number) => formatMsCompact(n)}
            series=${[{ name: 'API latency', color: 'var(--color-accent-fg)', readings: latencyReadings }]} />
        <//>

        ${'' /* cache hits */}
        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>KV Cache</${Eyebrow}>
          <span class="text-lg font-mono tabular-nums text-[var(--purple)]">${cacheSummary.sum === null ? '미관측' : cacheSummary.sum.toLocaleString()}</span>
          <${MutedSpan}>보존 관측 합계 · ${cacheSummary.observed}/${series.length}건</${MutedSpan}>
        <//>

        ${'' /* reasoning tokens */}
        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>추론</${Eyebrow}>
          <span class="text-lg font-mono tabular-nums text-[var(--color-status-warn)]">${reasoningSummary.sum === null ? '미관측' : reasoningSummary.sum.toLocaleString()}</span>
          <${MutedSpan}>보존 관측 합계 · ${reasoningSummary.observed}/${series.length}건</${MutedSpan}>
        <//>

        ${'' /* TTFT */}
        <${DetailCard}>
          <${DetailRow}>
            <${Eyebrow}>TTFT</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${formatMsCompact(ttfrcSummary.latest, '미관측')}</span>
          </${DetailRow}>
          <${ObservedMetricChart} label="TTFT 추이" formatValue=${(n: number) => formatMsCompact(n)}
            series=${[{ name: 'TTFT', color: 'var(--color-accent-fg)', readings: ttfrcReadings }]} />
        <//>

        ${'' /* prefill */}
        <${DetailCard}>
          <${DetailRow}>
            <${Eyebrow}>prefill</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${formatMsCompact(prefillSummary.latest, '미관측')}</span>
          </${DetailRow}>
          <${ObservedMetricChart} label="Prefill 추이" formatValue=${(n: number) => formatMsCompact(n)}
            series=${[{ name: 'prefill', color: 'var(--color-accent-fg)', readings: prefillReadings }]} />
        <//>
      </div>
    </div>
  `
}
