// Keeper detail sub-components — KPIs, charts, field dictionary,
// equipment, relationships, traits
// Redesigned: individual KPI cards, clean table, proper spacing.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { formatPct, formatTokens } from '../lib/format-number'
import { TextInput } from './common/input'
import type { Keeper, KeeperMetricPoint } from '../types'

// ── Context pressure thresholds (shared across KPIs, charts) ─
const CTX_CRITICAL_PCT = 85
const CTX_WARN_PCT = 70
const CTX_COLOR_CRITICAL = '#ef4444'
const CTX_COLOR_WARN = '#f59e0b'
const CTX_COLOR_OK = '#22c55e'

function ctxColor(pct: number): string {
  return pct > CTX_CRITICAL_PCT ? CTX_COLOR_CRITICAL : pct > CTX_WARN_PCT ? CTX_COLOR_WARN : CTX_COLOR_OK
}

// ── Utility functions ────────────────────────────────────

export function autonomyHint(count: number | undefined, proactiveEnabled: boolean | undefined): string | undefined {
  if ((count ?? 0) === 0) return proactiveEnabled ? '활성 · 미발동' : '자율 비활성'
  return undefined
}


// ── KPI Card ─────────────────────────────────────────────

type KpiTone = 'default' | 'ok' | 'warn' | 'bad'

const KPI_TONE: Record<KpiTone, string> = {
  default: 'border-[var(--card-border)] bg-[var(--white-3)]',
  ok: 'border-[rgba(74,222,128,0.2)] bg-[rgba(74,222,128,0.06)]',
  warn: 'border-[rgba(251,191,36,0.2)] bg-[rgba(251,191,36,0.06)]',
  bad: 'border-[var(--bad-20)] bg-[rgba(239,68,68,0.06)]',
}

const KPI_VALUE_TONE: Record<KpiTone, string> = {
  default: 'text-[var(--text-strong)]',
  ok: 'text-[var(--ok)]',
  warn: 'text-[var(--warn)]',
  bad: 'text-[var(--bad)]',
}

const KPI_ICON: Record<string, string> = {
  '세대': '🔄',
  '턴': '↻',
  '컨텍스트': '📊',
  '활동': '⚡',
  '토큰': '🔤',
  '인계': '🤝',
  '압축': '📦',
  '비용 (USD)': '💰',
}

function KpiCard({ label, value, hint, tone = 'default', progress }: {
  label: string
  value: string | number
  hint?: string
  tone?: KpiTone
  /** 0-100 progress bar */
  progress?: number
}) {
  const icon = KPI_ICON[label] ?? ''
  return html`
    <div class="p-3.5 rounded-xl border ${KPI_TONE[tone]} flex flex-col gap-1.5 transition-colors">
      <div class="flex items-center justify-between">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">${label}</span>
        ${icon ? html`<span class="text-[11px] opacity-60">${icon}</span>` : null}
      </div>
      <div class="text-2xl font-bold ${KPI_VALUE_TONE[tone]} tabular-nums leading-none">${value}</div>
      ${progress != null ? html`
        <div class="w-full h-1 bg-[var(--white-6)] rounded-full overflow-hidden mt-0.5">
          <div class="h-full rounded-full transition-all duration-500" style="width:${Math.min(progress, 100)}%;background:${ctxColor(progress)}"></div>
        </div>
      ` : null}
      ${hint ? html`<div class="text-[10px] text-[var(--text-dim)] leading-snug">${hint}</div>` : null}
    </div>
  `
}

// ── Operational Health ───────────────────────────────────

function OperationalHealth({ keeper }: { keeper: Keeper }) {
  const mw = keeper.metrics_window
  const hb = keeper.last_heartbeat
  const compSavedRatio = mw?.compaction_saved_ratio
  const avgSaved = mw?.avg_compaction_saved_tokens
  const dropRatio = mw?.memory_compaction_drop_ratio
  const lastCompAgo = keeper.last_compaction_ago_s

  const hbTone: KpiTone = !hb ? 'default' : 'ok'
  const compTone: KpiTone = compSavedRatio == null ? 'default'
    : compSavedRatio >= 0.4 ? 'ok' : compSavedRatio >= 0.2 ? 'warn' : 'bad'
  const dropTone: KpiTone = dropRatio == null ? 'default'
    : dropRatio <= 0.1 ? 'ok' : dropRatio <= 0.3 ? 'warn' : 'bad'

  const hasAny = hb || compSavedRatio != null || dropRatio != null || lastCompAgo != null
  if (!hasAny) return null

  return html`
    <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-2)] p-3">
      <div class="mb-2 text-[10px] font-semibold tracking-[0.08em] uppercase text-[var(--text-muted)]">운영 건강도</div>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
        ${hb ? html`
          <div class="p-2 rounded-lg border ${KPI_TONE[hbTone]} flex flex-col gap-0.5">
            <span class="text-[9px] uppercase tracking-wider text-[var(--text-muted)]">Heartbeat</span>
            <span class="text-xs font-mono ${KPI_VALUE_TONE[hbTone]}">${hb.replace('T', ' ').slice(0, 19)}</span>
          </div>
        ` : null}
        ${compSavedRatio != null ? html`
          <div class="p-2 rounded-lg border ${KPI_TONE[compTone]} flex flex-col gap-0.5">
            <span class="text-[9px] uppercase tracking-wider text-[var(--text-muted)]">압축 절감률</span>
            <span class="text-sm font-mono tabular-nums ${KPI_VALUE_TONE[compTone]}">${(compSavedRatio * 100).toFixed(1)}%</span>
            ${avgSaved != null ? html`<span class="text-[9px] text-[var(--text-dim)]">avg ${formatTokens(avgSaved)} saved</span>` : null}
          </div>
        ` : null}
        ${dropRatio != null ? html`
          <div class="p-2 rounded-lg border ${KPI_TONE[dropTone]} flex flex-col gap-0.5">
            <span class="text-[9px] uppercase tracking-wider text-[var(--text-muted)]">메모리 손실률</span>
            <span class="text-sm font-mono tabular-nums ${KPI_VALUE_TONE[dropTone]}">${(dropRatio * 100).toFixed(1)}%</span>
          </div>
        ` : null}
        ${lastCompAgo != null ? html`
          <div class="p-2 rounded-lg border ${KPI_TONE['default']} flex flex-col gap-0.5">
            <span class="text-[9px] uppercase tracking-wider text-[var(--text-muted)]">마지막 압축</span>
            <span class="text-xs font-mono text-[var(--text-strong)]">${formatDuration(lastCompAgo)} 전</span>
          </div>
        ` : null}
      </div>
    </div>
  `
}

// ── KPI Grid ─────────────────────────────────────────────

export function KpiGrid({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const lastPt = series[series.length - 1] as KeeperMetricPoint | undefined
  const latestCost =
    lastPt && Number.isFinite(lastPt.cost_usd)
      ? `$${lastPt.cost_usd.toFixed(4)}`
      : null

  const ctxPct = keeper.context_ratio != null ? Math.round(keeper.context_ratio * 100) : null
  const ctxTone: KpiTone = ctxPct == null ? 'default' : ctxPct > CTX_CRITICAL_PCT ? 'bad' : ctxPct > CTX_WARN_PCT ? 'warn' : ctxPct > 0 ? 'ok' : 'default'
  const ctxHint = ctxPct != null && ctxPct > CTX_WARN_PCT ? '한계 접근 중' : undefined

  // Provider-model call statistics from metrics_series
  const modelCounts: Record<string, number> = {}
  for (const pt of series) {
    if (pt.model_used) {
      modelCounts[pt.model_used] = (modelCounts[pt.model_used] ?? 0) + 1
    }
  }
  const modelEntries = Object.entries(modelCounts).sort((a, b) => b[1] - a[1])
  const totalCalls = modelEntries.reduce((s, [, c]) => s + c, 0)

  return html`
    <div class="flex flex-col gap-3 mb-5">
      ${'' /* Primary KPIs — 3 cols (activityLevel removed) */}
      <div class="grid grid-cols-3 gap-3">
        <${KpiCard}
          label="세대"
          value=${keeper.generation ?? '-'}
          hint="승계 횟수"
        />
        <${KpiCard}
          label="턴"
          value=${keeper.turn_count ?? '-'}
          hint="총 루프 회차"
        />
        <${KpiCard}
          label="컨텍스트"
          value=${ctxPct != null ? `${ctxPct}%` : '-'}
          hint=${ctxHint}
          tone=${ctxTone}
          progress=${ctxPct ?? undefined}
        />
      </div>
      ${'' /* Model usage distribution */}
      ${totalCalls > 0 ? html`
        <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-2)] p-3">
          <div class="mb-2 text-[10px] font-semibold tracking-[0.08em] uppercase text-[var(--text-muted)]">모델 호출 분포</div>
          <div class="flex flex-col gap-1.5">
            ${modelEntries.slice(0, 4).map(([model, count]) => {
              const pct = Math.round((count / totalCalls) * 100)
              return html`
                <div class="flex items-center gap-2 text-xs">
                  <span class="shrink-0 w-[140px] truncate font-mono text-[11px] text-[var(--accent)]" title=${model}>${model}</span>
                  <div class="flex-1 h-1.5 bg-[var(--white-6)] rounded-full overflow-hidden">
                    <div class="h-full rounded-full bg-[var(--accent)]" style="width:${pct}%"></div>
                  </div>
                  <span class="shrink-0 w-10 text-right text-[var(--text-muted)]">${count}회</span>
                </div>
              `
            })}
          </div>
          ${modelEntries.length > 4 ? html`
            <div class="mt-1 text-[10px] text-[var(--text-muted)]">외 ${modelEntries.length - 4}개 모델</div>
          ` : null}
        </div>
      ` : null}
      ${'' /* Secondary KPIs — 3-4 cols, smaller feel */}
      <div class="grid grid-cols-3 sm:grid-cols-4 gap-2">
        <${KpiCard}
          label="토큰"
          value=${formatTokens(keeper.context_tokens)}
          hint=${keeper.context_max ? `/ ${formatTokens(keeper.context_max)}` : undefined}
        />
        <${KpiCard}
          label="인계"
          value=${keeper.handoff_count_total ?? '-'}
          hint=${(keeper.handoff_count_total ?? 0) === 0 ? '첫 인계 후 표시' : undefined}
        />
        <${KpiCard}
          label="압축"
          value=${keeper.compaction_count ?? '-'}
          hint=${(keeper.compaction_count ?? 0) === 0 ? '첫 압축 후 표시' : undefined}
        />
        ${latestCost
          ? html`<${KpiCard} label="비용 (USD)" value=${latestCost} />`
          : null}
      </div>
      ${'' /* Operational Health — heartbeat + compaction quality */}
      <${OperationalHealth} keeper=${keeper} />
      ${'' /* Autonomy KPIs — always visible for keeper context */}
      <div class="grid grid-cols-4 gap-2">
        <${KpiCard}
          label="자율 행동"
          value=${keeper.autonomous_action_count ?? 0}
          hint=${keeper.last_proactive_ago_s != null
            ? `${formatDuration(keeper.last_proactive_ago_s)} 전${keeper.last_proactive_reason ? ' · ' + keeper.last_proactive_reason : ''}`
            : autonomyHint(keeper.autonomous_action_count, keeper.proactive_enabled) ?? '행동 횟수'}
        />
        <${KpiCard}
          label="자율 턴"
          value=${keeper.autonomous_turn_count ?? 0}
          hint=${keeper.autonomous_text_turn_count != null ? `텍스트 ${keeper.autonomous_text_turn_count} / 도구 ${keeper.autonomous_tool_turn_count ?? 0}` : autonomyHint(keeper.autonomous_turn_count, keeper.proactive_enabled) ?? '미발동'}
        />
        <${KpiCard}
          label="보드 반응"
          value=${keeper.board_reactive_turn_count ?? 0}
          hint="게시판 반응 턴"
        />
        <${KpiCard}
          label="비활동"
          value=${keeper.noop_turn_count ?? 0}
          hint="아무 작업 없는 턴"
        />
      </div>
    </div>
  `
}

function formatDuration(sec: number): string {
  if (sec < 60) return `${sec}초`
  if (sec < 3600) return `${Math.floor(sec / 60)}분`
  return `${Math.floor(sec / 3600)}시간 ${Math.floor((sec % 3600) / 60)}분`
}

// ── Context Chart ────────────────────────────────────────

export function ContextChart({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  if (series.length < 2) {
    const pct = ((keeper.context_ratio ?? keeper.context?.context_ratio ?? 0) * 100)
    const color = ctxColor(pct)
    return html`
      <div class="flex items-center gap-3 mb-5 p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
        <div class="flex-1 h-2 bg-[var(--white-6)] rounded-full overflow-hidden">
          <div class="h-full rounded-full transition-all duration-300" style="width:${pct.toFixed(1)}%;background:${color}"></div>
        </div>
        <span class="text-sm font-semibold tabular-nums text-[var(--text-strong)]">${pct.toFixed(1)}%</span>
      </div>`
  }

  const W = 200, H = 60, pad = 2
  const n = series.length
  const pts = series.map((p: KeeperMetricPoint, i: number) => {
    const x = pad + (i / (n - 1)) * (W - 2 * pad)
    const y = H - pad - (p.context_ratio ?? 0) * (H - 2 * pad)
    return { x, y, p }
  })
  const polyline = pts.map(({ x, y }) => `${x.toFixed(1)},${y.toFixed(1)}`).join(' ')
  const lastRatio = ((series[series.length - 1] as KeeperMetricPoint)?.context_ratio ?? 0) * 100
  const lineColor = ctxColor(lastRatio)

  return html`
    <div class="flex items-center gap-3 mb-5 p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
      <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded" style="background:#0b1220;">
        <line x1="${pad}" y1="${(H - pad - 0.5 * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - 0.5 * (H - 2 * pad)).toFixed(1)}" stroke="#444" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${pad}" y1="${(H - pad - (CTX_WARN_PCT / 100) * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - (CTX_WARN_PCT / 100) * (H - 2 * pad)).toFixed(1)}" stroke="#444" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${pad}" y1="${(H - pad - (CTX_CRITICAL_PCT / 100) * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - (CTX_CRITICAL_PCT / 100) * (H - 2 * pad)).toFixed(1)}" stroke="${CTX_COLOR_WARN}" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${pts.filter(({ p }) => p.is_handoff).map(({ x }) => html`
          <line x1="${x.toFixed(1)}" y1="${pad}" x2="${x.toFixed(1)}" y2="${H - pad}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${polyline}" fill="none" stroke="${lineColor}" stroke-width="1.5"/>
        ${pts.filter(({ p }) => p.is_compaction).map(({ x, y, p }) => {
          const trigger = p.compaction_trigger ?? 'unknown'
          const saved = p.compaction_saved_tokens ?? 0
          const tip = saved > 0 ? `${trigger} · ${formatTokens(saved)} saved` : trigger
          return html`
            <circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="3" fill="#a855f7" style="cursor:pointer">
              <title>${tip}</title>
            </circle>
          `
        })}
      </svg>
      <span class="text-sm font-semibold tabular-nums text-[var(--text-strong)]">${lastRatio.toFixed(1)}%</span>
    </div>`
}

// ── Metrics Charts (Latency + Cost + Model) ─────────────

const SPARKLINE_W = 200
const SPARKLINE_H = 40
const SPARKLINE_PAD = 2
const MODEL_NAME_MAX_LEN = 20

function miniSparkline(
  data: number[],
  maxOverride?: number,
): string {
  const W = SPARKLINE_W, H = SPARKLINE_H, pad = SPARKLINE_PAD
  const n = data.length
  if (n < 2) return ''
  const maxVal = maxOverride ?? Math.max(...data, 1)
  return data.map((v, i) => {
    const x = pad + (i / (n - 1)) * (W - 2 * pad)
    const y = H - pad - (v / maxVal) * (H - 2 * pad)
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')
}

export function InferenceTelemetryPanel({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const telemetryPoints = series.filter(
    (p: KeeperMetricPoint) => p.inference_telemetry?.timings?.predicted_per_second != null,
  )
  if (telemetryPoints.length === 0) return null

  const tokPerSec = telemetryPoints.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.timings?.predicted_per_second ?? 0,
  )
  const latencies = telemetryPoints.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.request_latency_ms ?? 0,
  )
  const cacheNs = telemetryPoints.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.timings?.cache_n ?? 0,
  )
  const reasoningTokens = telemetryPoints.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.reasoning_tokens ?? 0,
  )

  const W = SPARKLINE_W, H = SPARKLINE_H
  const lastTps = tokPerSec[tokPerSec.length - 1] ?? 0
  const avgTps = tokPerSec.reduce((a, b) => a + b, 0) / tokPerSec.length
  const lastLatency = latencies[latencies.length - 1] ?? 0
  const totalCacheN = cacheNs.reduce((a, b) => a + b, 0)
  const totalReasoning = reasoningTokens.reduce((a, b) => a + b, 0)

  const tpsLine = miniSparkline(tokPerSec)
  const latencyLine = miniSparkline(latencies)

  const lastFp = telemetryPoints[telemetryPoints.length - 1]?.inference_telemetry?.system_fingerprint

  return html`
    <div class="mb-5">
      <div class="flex items-center gap-2 mb-2">
        <span class="text-[11px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">Inference Telemetry</span>
        <span class="text-[10px] text-[var(--text-dim)]">${telemetryPoints.length} points</span>
        ${lastFp ? html`<span class="text-[9px] px-1.5 py-0.5 rounded bg-[var(--white-5)] text-[var(--text-dim)] font-mono">${lastFp}</span>` : null}
      </div>
      <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
        ${'' /* tok/s sparkline */}
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="flex items-center justify-between mb-1.5">
            <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">tok/s</span>
            <span class="text-xs font-mono tabular-nums text-[var(--good)]">${lastTps.toFixed(1)}</span>
          </div>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded w-full" style="background:#0b1220;">
            ${tpsLine ? html`<polyline points="${tpsLine}" fill="none" stroke="#4ade80" stroke-width="1.5"/>` : null}
          </svg>
          <div class="text-[9px] text-[var(--text-dim)] mt-1">avg ${avgTps.toFixed(1)}</div>
        </div>

        ${'' /* request latency */}
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="flex items-center justify-between mb-1.5">
            <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">API latency</span>
            <span class="text-xs font-mono tabular-nums text-[var(--accent)]">${lastLatency > 0 ? `${(lastLatency / 1000).toFixed(1)}s` : '-'}</span>
          </div>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded w-full" style="background:#0b1220;">
            ${latencyLine ? html`<polyline points="${latencyLine}" fill="none" stroke="#9ad9ff" stroke-width="1.5"/>` : null}
          </svg>
        </div>

        ${'' /* cache hits */}
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col justify-between">
          <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">KV Cache</span>
          <span class="text-lg font-mono tabular-nums text-[var(--purple)]">${totalCacheN > 0 ? totalCacheN.toLocaleString() : '-'}</span>
          <span class="text-[9px] text-[var(--text-dim)]">cumulative tokens</span>
        </div>

        ${'' /* reasoning tokens */}
        <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col justify-between">
          <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">Reasoning</span>
          <span class="text-lg font-mono tabular-nums text-[var(--warn)]">${totalReasoning > 0 ? totalReasoning.toLocaleString() : '-'}</span>
          <span class="text-[9px] text-[var(--text-dim)]">total tokens</span>
        </div>
      </div>
    </div>
  `
}

export function MetricsCharts({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  if (series.length < 2) return null

  const latencies = series.map((p: KeeperMetricPoint) => p.latency_ms ?? 0)
  const costs = series.map((p: KeeperMetricPoint) => p.cost_usd ?? 0)
  const W = SPARKLINE_W, H = SPARKLINE_H

  const lastLatency = latencies[latencies.length - 1] ?? 0
  const totalCost = costs.reduce((a: number, b: number) => a + b, 0)

  const modelSwitches: { index: number; model: string }[] = []
  for (let i = 1; i < series.length; i++) {
    if ((series[i] as KeeperMetricPoint).model_used !== (series[i - 1] as KeeperMetricPoint).model_used) {
      modelSwitches.push({ index: i, model: (series[i] as KeeperMetricPoint).model_used })
    }
  }

  const latencyLine = miniSparkline(latencies)
  const costLine = miniSparkline(costs)

  return html`
    <div class="grid grid-cols-1 md:grid-cols-2 gap-3 mb-5">
      ${'' /* Latency */}
      <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
        <div class="flex items-center justify-between mb-1.5">
          <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">지연 시간</span>
          <span class="text-xs font-mono tabular-nums text-[var(--accent)]">${lastLatency > 0 ? `${(lastLatency / 1000).toFixed(1)}s` : '-'}</span>
        </div>
        <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded w-full" style="background:#0b1220;">
          ${latencyLine ? html`<polyline points="${latencyLine}" fill="none" stroke="#9ad9ff" stroke-width="1.5"/>` : null}
        </svg>
      </div>

      ${'' /* Cost */}
      <div class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
        <div class="flex items-center justify-between mb-1.5">
          <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">비용</span>
          <span class="text-xs font-mono tabular-nums text-[var(--purple)]">$${totalCost.toFixed(4)}</span>
        </div>
        <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded w-full" style="background:#0b1220;">
          ${costLine ? html`<polyline points="${costLine}" fill="none" stroke="#a78bfa" stroke-width="1.5"/>` : null}
        </svg>
      </div>

      ${'' /* Model timeline */}
      ${modelSwitches.length > 0 ? html`
        <div class="md:col-span-2 p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="flex items-center justify-between mb-1.5">
            <span class="text-[10px] uppercase tracking-wider text-[var(--text-muted)]">모델 전환</span>
            <span class="text-[10px] text-[var(--text-dim)]">${modelSwitches.length}회</span>
          </div>
          <div class="flex flex-wrap gap-1.5">
            ${modelSwitches.map(s => html`
              <span class="text-[10px] px-2 py-0.5 rounded-full bg-[var(--warn-10)] text-[var(--warn)] border border-[var(--warn-20)] font-mono">
                T${s.index} -> ${s.model.length > MODEL_NAME_MAX_LEN ? s.model.slice(0, MODEL_NAME_MAX_LEN) + '...' : s.model}
              </span>
            `)}
          </div>
        </div>
      ` : null}
    </div>
  `
}

// ── Raw Data (Debug) ─────────────────────────────────────
// Collapsed-by-default debug dump of all keeper fields.
// Primary display is handled by Header, KpiGrid, Profile, and Config sections.

const fieldSearch = signal('')

export function RawDataDebug({ keeper }: { keeper: Keeper }) {
  const filter = fieldSearch.value.toLowerCase()

  const fields: { title: string; key: string; value: string }[] = [
    { title: 'Name', key: 'name', value: keeper.name },
    { title: 'Emoji', key: 'emoji', value: keeper.emoji ?? '-' },
    { title: 'Korean', key: 'koreanName', value: keeper.koreanName ?? '-' },
    { title: 'Model', key: 'model', value: keeper.model ?? '-' },
    { title: 'Status', key: 'status', value: keeper.status },
    { title: 'Primary', key: 'primaryValue', value: keeper.primaryValue ?? '-' },
    { title: 'Gen', key: 'generation', value: String(keeper.generation ?? '-') },
    { title: 'Turns', key: 'turn_count', value: String(keeper.turn_count ?? '-') },
    { title: 'Context', key: 'context_ratio', value: formatPct(keeper.context_ratio) },
    { title: 'Heartbeat', key: 'last_heartbeat', value: keeper.last_heartbeat ?? '-' },
    { title: 'Traits', key: 'traits', value: keeper.traits?.join(', ') || '-' },
    { title: 'Interests', key: 'interests', value: keeper.interests?.join(', ') || '-' },
  ]

  // Extra fields from keeper object
  const extras: { title: string; value: string; mono?: boolean }[] = []
  if (keeper.trace_id) extras.push({ title: 'Trace ID', value: keeper.trace_id, mono: true })
  if (keeper.agent_name) extras.push({ title: 'Agent', value: keeper.agent_name })
  if (keeper.primary_model) extras.push({ title: 'Primary Model', value: keeper.primary_model, mono: true })
  if (keeper.active_model) extras.push({ title: 'Active Model', value: keeper.active_model, mono: true })
  if (keeper.next_model_hint) extras.push({ title: 'Next Model Hint', value: keeper.next_model_hint, mono: true })
  if (keeper.skill_primary) extras.push({ title: 'Skill (Primary)', value: keeper.skill_primary })
  if (keeper.skill_secondary?.length) extras.push({ title: 'Skill (Secondary)', value: keeper.skill_secondary.join(', ') })
  if (keeper.skill_reason) extras.push({ title: 'Skill Reason', value: keeper.skill_reason })
  if (keeper.context_source) extras.push({ title: 'Context Source', value: keeper.context_source })
  if (keeper.context_tokens != null) extras.push({ title: 'Context Tokens', value: formatTokens(keeper.context_tokens) })
  if (keeper.context_max != null) extras.push({ title: 'Context Max', value: formatTokens(keeper.context_max) })
  if (keeper.memory_recent_note) extras.push({ title: 'Memory Note', value: keeper.memory_recent_note })
  if (keeper.k2k_count != null) extras.push({ title: 'K2K Count', value: String(keeper.k2k_count) })
  if (keeper.conversation_tail_count != null) extras.push({ title: 'Conv Tail', value: String(keeper.conversation_tail_count) })
  if (keeper.handoff_count_total != null) extras.push({ title: 'Total Handoffs', value: String(keeper.handoff_count_total) })
  if (keeper.compaction_count != null) extras.push({ title: 'Compactions', value: String(keeper.compaction_count) })
  if (keeper.last_compaction_saved_tokens != null) extras.push({ title: 'Last Compact Saved', value: formatTokens(keeper.last_compaction_saved_tokens) })
  if (keeper.context?.message_count != null) extras.push({ title: 'Message Count', value: String(keeper.context.message_count) })
  if (keeper.context?.has_checkpoint != null) extras.push({ title: 'Has Checkpoint', value: keeper.context.has_checkpoint ? 'Yes' : 'No' })

  const filtered = filter
    ? fields.filter(f => f.title.toLowerCase().includes(filter) || f.key.includes(filter) || f.value.toLowerCase().includes(filter))
    : fields

  return html`
    <div class="max-h-[460px] overflow-y-auto">
      <${TextInput}
        placeholder="필드 검색..."
        value=${fieldSearch.value}
        onInput=${(e: Event) => { fieldSearch.value = (e.target as HTMLInputElement).value }}
      />
      <div class="flex flex-col">
        ${filtered.map((f, i) => html`
          <div class="grid grid-cols-[100px_80px_1fr] gap-2 py-2 px-2 text-xs rounded-md ${i % 2 === 0 ? 'bg-[var(--white-2)]' : ''}">
            <span class="font-semibold text-[var(--text-body)] truncate">${f.title}</span>
            <span class="font-mono text-[var(--cyan)] text-[11px] truncate">${f.key}</span>
            <span class="text-right text-[var(--text-body)] truncate">${f.value}</span>
          </div>
        `)}
        ${extras.map((f, i) => html`
          <div class="grid grid-cols-[100px_1fr] gap-2 py-2 px-2 text-xs rounded-md ${(filtered.length + i) % 2 === 0 ? 'bg-[var(--white-2)]' : ''}">
            <span class="font-semibold text-[var(--text-body)] truncate">${f.title}</span>
            <span class="text-right text-[var(--text-body)] truncate ${f.mono ? 'font-mono' : ''}">${f.value}</span>
          </div>
        `)}
      </div>
    </div>
  `
}

// ── Equipment, Relationships, Traits ───────────────

export function EquipmentList({ items }: { items: string[] }) {
  if (items.length === 0) return html`<div class="py-2 px-3 text-xs text-[var(--text-muted)] italic">장비 없음</div>`

  return html`
    <div class="flex flex-col gap-1.5">
      ${items.map((item, i) => html`
        <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
          <span class="text-xs text-[var(--text-body)]">${item}</span>
          <span class="text-[10px] text-[var(--cyan)] font-mono">#${i + 1}</span>
        </div>
      `)}
    </div>
  `
}

export function RelationshipList({ rels }: { rels: Record<string, string> }) {
  const entries = Object.entries(rels)
  if (entries.length === 0) return html`<div class="py-2 px-3 text-xs text-[var(--text-muted)] italic">관계 없음</div>`

  return html`
    <div class="max-h-[220px] overflow-y-auto flex flex-col gap-1.5">
      ${entries.map(([name, relation]) => html`
        <div class="flex items-center gap-2 py-2 px-3 bg-[var(--white-3)] rounded-lg">
          <span class="inline-flex items-center py-0.5 px-2 rounded-full text-[11px] font-medium bg-[var(--accent-12)] text-[var(--accent)] border border-[var(--accent-30)]">${name}</span>
          <span class="text-[11px] text-[var(--text-muted)] font-mono">${relation}</span>
        </div>
      `)}
    </div>
  `
}

export function TraitsList({ traits, label }: { traits: string[]; label: string }) {
  if (traits.length === 0) return null

  return html`
    <div class="mb-3">
      <div class="text-[10px] text-[var(--text-muted)] uppercase tracking-wider font-semibold mb-2">${label}</div>
      <div class="flex flex-wrap gap-1.5">
        ${traits.map(t => html`<span class="inline-flex items-center py-0.5 px-2.5 rounded-full text-[11px] font-medium bg-[var(--accent-12)] text-[var(--accent)] border border-[var(--accent-30)]">${t}</span>`)}
      </div>
    </div>
  `
}
