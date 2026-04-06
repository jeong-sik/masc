// Keeper tool telemetry — per-keeper tool usage statistics panel.
// Aggregates trajectory entries client-side: call count, success rate,
// avg latency, cost breakdown. Horizontal bar charts.

import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { fetchKeeperTrajectory } from '../api/dashboard'
import type { TrajectoryEntry } from '../api/dashboard'
import { toolCategory, formatDuration, durationColor } from './tool-call-shared'

// ── Types ─────────────────────────────────────────────

interface ToolStat {
  name: string
  callCount: number
  successCount: number
  failureCount: number
  totalDurationMs: number
  avgDurationMs: number
  maxDurationMs: number
  totalCostUsd: number
}

interface TelemetryState {
  stats: ToolStat[]
  loading: boolean
  error: string | null
  totalCalls: number
  totalCostUsd: number
}

// ── Aggregation ───────────────────────────────────────

function aggregateToolStats(entries: TrajectoryEntry[]): ToolStat[] {
  const map = new Map<string, {
    callCount: number
    successCount: number
    failureCount: number
    totalDurationMs: number
    maxDurationMs: number
    totalCostUsd: number
  }>()

  for (const e of entries) {
    const existing = map.get(e.tool_name)
    const isFailure = Boolean(e.error) || e.gate?.status === 'reject'
    if (existing) {
      existing.callCount++
      if (isFailure) existing.failureCount++
      else existing.successCount++
      existing.totalDurationMs += e.duration_ms
      existing.maxDurationMs = Math.max(existing.maxDurationMs, e.duration_ms)
      existing.totalCostUsd += e.cost_usd
    } else {
      map.set(e.tool_name, {
        callCount: 1,
        successCount: isFailure ? 0 : 1,
        failureCount: isFailure ? 1 : 0,
        totalDurationMs: e.duration_ms,
        maxDurationMs: e.duration_ms,
        totalCostUsd: e.cost_usd,
      })
    }
  }

  const stats: ToolStat[] = []
  for (const [name, s] of map) {
    stats.push({
      name,
      ...s,
      avgDurationMs: Math.round(s.totalDurationMs / s.callCount),
    })
  }
  stats.sort((a, b) => b.callCount - a.callCount)
  return stats
}

// ── Bar chart helpers ─────────────────────────────────

function SuccessRateBar({ stat }: { stat: ToolStat }) {
  const successPct = stat.callCount > 0 ? (stat.successCount / stat.callCount) * 100 : 100
  const barColor = successPct >= 95 ? 'var(--ok)' : successPct >= 80 ? 'var(--warn)' : 'var(--bad)'

  return html`
    <div class="flex items-center gap-2 w-full">
      <div class="flex-1 h-1.5 rounded-full bg-[var(--white-5)] overflow-hidden">
        <div class="h-full rounded-full transition-all duration-300" style="width: ${successPct}%; background: ${barColor}"></div>
      </div>
      <span class="text-[10px] font-mono w-10 text-right" style="color: ${barColor}">
        ${successPct === 100 ? '100%' : `${successPct.toFixed(0)}%`}
      </span>
    </div>
  `
}

// ── Main component ────────────────────────────────────

interface KeeperToolTelemetryProps {
  keeperName: string
}

export function KeeperToolTelemetry({ keeperName }: KeeperToolTelemetryProps) {
  const state = useSignal<TelemetryState>({
    stats: [], loading: false, error: null, totalCalls: 0, totalCostUsd: 0,
  })

  useEffect(() => {
    state.value = { ...state.value, loading: true, error: null }
    void (async () => {
      try {
        const data = await fetchKeeperTrajectory(keeperName, 200)
        const stats = aggregateToolStats(data.entries)
        const totalCalls = data.entries.length
        const totalCostUsd = data.entries.reduce((sum, e) => sum + e.cost_usd, 0)
        state.value = { stats, loading: false, error: null, totalCalls, totalCostUsd }
      } catch (err) {
        state.value = {
          stats: [], loading: false,
          error: err instanceof Error ? err.message : 'fetch failed',
          totalCalls: 0, totalCostUsd: 0,
        }
      }
    })()
  }, [keeperName])

  const s = state.value

  if (s.loading) {
    return html`
      <div class="flex flex-col gap-2 py-3" style="animation: loadingPulse 1.5s ease-in-out infinite">
        ${[1, 2, 3].map(i => html`
          <div key=${i} class="flex items-center gap-3 py-2 px-3">
            <div class="size-5 rounded bg-[var(--white-8)]"></div>
            <div class="flex-1 h-2 rounded bg-[var(--white-5)]"></div>
            <div class="w-10 h-2 rounded bg-[var(--white-5)]"></div>
          </div>
        `)}
      </div>
    `
  }

  if (s.error) {
    return html`<div class="text-xs text-[var(--bad)] py-3 text-center">${s.error}</div>`
  }

  if (s.stats.length === 0) {
    return html`<div class="text-xs text-[var(--text-muted)] py-3 text-center italic">도구 호출 데이터 없음</div>`
  }

  const maxCount = s.stats[0]?.callCount ?? 1

  // Find slowest 3 calls
  const slowest = useMemo(() =>
    [...s.stats].sort((a, b) => b.maxDurationMs - a.maxDurationMs).slice(0, 3),
    [s.stats],
  )

  return html`
    <div class="flex flex-col gap-4">

      ${'' /* Summary row */}
      <div class="flex gap-3 flex-wrap text-[11px]">
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded-md bg-[var(--white-4)] border border-[var(--white-6)] text-[var(--text-muted)]">
          <span class="font-mono font-medium text-[var(--text-strong)]">${s.stats.length}</span> 도구
        </span>
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded-md bg-[var(--white-4)] border border-[var(--white-6)] text-[var(--text-muted)]">
          <span class="font-mono font-medium text-[var(--text-strong)]">${s.totalCalls}</span> 호출
        </span>
        ${s.totalCostUsd > 0 ? html`
          <span class="inline-flex items-center gap-1 px-2 py-1 rounded-md bg-[var(--accent-12)] border border-[rgba(71,184,255,0.15)] text-[var(--text-muted)]">
            <span class="font-mono font-medium text-[var(--accent)]">$${s.totalCostUsd.toFixed(3)}</span>
          </span>
        ` : null}
      </div>

      ${'' /* Per-tool bar chart */}
      <div class="flex flex-col gap-1">
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-dim)] mb-1">호출 빈도</div>
        ${s.stats.slice(0, 15).map(stat => {
          const cat = toolCategory(stat.name)
          const barWidth = (stat.callCount / maxCount) * 100
          return html`
            <div class="flex items-center gap-2 py-1 group">
              <div class="size-5 rounded flex-shrink-0 bg-[var(--white-5)] flex items-center justify-center text-[9px] font-mono font-bold ${cat.color}">
                ${cat.icon}
              </div>
              <div class="w-28 flex-shrink-0 text-[11px] font-mono text-[var(--text-muted)] truncate" title=${stat.name}>
                ${stat.name.replace(/^(keeper_|masc_)/, '')}
              </div>
              <div class="flex-1 h-3 rounded bg-[var(--white-5)] overflow-hidden">
                <div class="h-full rounded transition-all duration-300 ${stat.failureCount > 0 ? '' : ''}"
                  style="width: ${barWidth}%; background: ${stat.failureCount > 0 ? 'var(--warn)' : 'var(--accent)'}; opacity: 0.7">
                </div>
              </div>
              <span class="w-8 text-right text-[11px] font-mono text-[var(--text-muted)]">${stat.callCount}</span>
              <span class="w-14 text-right text-[10px] font-mono ${durationColor(stat.avgDurationMs)}">
                ${formatDuration(stat.avgDurationMs)}
              </span>
            </div>
          `
        })}
      </div>

      ${'' /* Success rate table */}
      ${s.stats.some(st => st.failureCount > 0) ? html`
        <div class="flex flex-col gap-1.5">
          <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-dim)] mb-1">성공률</div>
          ${s.stats.filter(st => st.failureCount > 0).map(stat => html`
            <div class="flex items-center gap-2">
              <span class="w-28 flex-shrink-0 text-[11px] font-mono text-[var(--text-muted)] truncate">
                ${stat.name.replace(/^(keeper_|masc_)/, '')}
              </span>
              <${SuccessRateBar} stat=${stat} />
              <span class="text-[10px] text-[var(--bad)] w-10 text-right">${stat.failureCount}err</span>
            </div>
          `)}
        </div>
      ` : null}

      ${'' /* Slowest calls */}
      ${slowest.length > 0 && (slowest[0]?.maxDurationMs ?? 0) > 500 ? html`
        <div class="flex flex-col gap-1.5">
          <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-dim)] mb-1">최대 소요 시간</div>
          ${slowest.map(stat => html`
            <div class="flex items-center justify-between py-1 px-2 rounded bg-[var(--white-3)]">
              <span class="text-[11px] font-mono text-[var(--text-muted)]">${stat.name.replace(/^(keeper_|masc_)/, '')}</span>
              <span class="text-[11px] font-mono font-medium ${durationColor(stat.maxDurationMs)}">${formatDuration(stat.maxDurationMs)}</span>
            </div>
          `)}
        </div>
      ` : null}
    </div>
  `
}
