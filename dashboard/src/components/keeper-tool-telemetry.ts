// Keeper tool telemetry — per-keeper tool usage statistics panel.
// Uses server-side aggregation (GET /tool-stats) for p95 latency,
// cross-trace aggregation, and hourly timeline sparklines.

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { fetchKeeperToolStats } from '../api/dashboard'
import type { ToolStat, HourlyBucket, ToolStatsResponse } from '../api/dashboard'
import { toolCategory, formatDuration, durationColor } from './tool-call-shared'
import { createManagedAsyncResource, type ManagedAsyncResource } from '../lib/async-state'
import { SectionCap } from './common/section-cap'

// ── Types ─────────────────────────────────────────────

interface TelemetryState {
  tools: ToolStat[]
  timeline: HourlyBucket[]
  totalEntries: number
  windowHours: number
}

/**
 * Pure filter for tool-telemetry rows.
 *
 * - `query` is case-insensitive substring match on `stat.name` OR the
 *   derived category label from `toolCategory(stat.name)` (e.g. "read",
 *   "browser", "masc"). Query is trimmed.
 * - Empty/whitespace-only query returns the input reference unchanged
 *   (zero-allocation fast path).
 * - Does not mutate the input array.
 */
export function filterToolStats(
  rows: readonly ToolStat[],
  query: string,
): readonly ToolStat[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return rows
  return rows.filter(stat => {
    if (stat.name.toLowerCase().includes(needle)) return true
    const label = toolCategory(stat.name).label
    if (label.toLowerCase().includes(needle)) return true
    return false
  })
}

// ── Sparkline ─────────────────────────────────────────

function Sparkline({ buckets, height = 32 }: { buckets: HourlyBucket[]; height?: number }) {
  if (buckets.length === 0) return null

  const maxCount = Math.max(...buckets.map(b => b.call_count), 1)
  const width = buckets.length * 14
  const barW = 10
  const gap = 4

  const bars = buckets.map((b, i) => {
    const barH = Math.max(1, (b.call_count / maxCount) * (height - 4))
    const errH = b.error_count > 0 ? Math.max(1, (b.error_count / maxCount) * (height - 4)) : 0
    const x = i * (barW + gap)
    const y = height - barH
    return html`
      <g key=${i}>
        <rect x=${x} y=${y} width=${barW} height=${barH} rx="1.5"
          fill="var(--accent)" opacity="0.5" />
        ${errH > 0 ? html`
          <rect x=${x} y=${height - errH} width=${barW} height=${errH} rx="1.5"
            fill="var(--bad)" opacity="0.7" />
        ` : null}
      </g>
    `
  })

  // Hour labels — show first, middle, last
  const labelIndices = [0, Math.floor(buckets.length / 2), buckets.length - 1]
    .filter((v, i, a) => a.indexOf(v) === i) // dedupe
  const labels = labelIndices.map(i => {
    const b = buckets[i]
    if (!b) return null
    const label = b.hour.slice(11, 16) // "HH:MM"
    const x = i * (barW + gap) + barW / 2
    return html`
      <text key=${'lbl' + i} x=${x} y=${height + 10} text-anchor="middle"
        fill="var(--text-dim)" font-size="8" font-family="monospace">
        ${label}
      </text>
    `
  })

  return html`
    <svg width=${width} height=${height + 14} class="overflow-visible">
      ${bars}
      ${labels}
    </svg>
  `
}

// ── Bar chart helpers ─────────────────────────────────

function SuccessRateBar({ stat }: { stat: ToolStat }) {
  const successPct = stat.call_count > 0 ? (stat.success_count / stat.call_count) * 100 : 100
  let barColor = 'var(--bad)'
  if (successPct >= 95) {
    barColor = 'var(--ok)'
  } else if (successPct >= 80) {
    barColor = 'var(--warn)'
  }

  return html`
    <div class="flex items-center gap-2 w-full">
      <div class="flex-1 h-1.5 rounded-sm bg-[var(--white-5)] overflow-hidden">
        <div class="h-full rounded-sm transition-all duration-300" style="width: ${successPct}%; background: ${barColor}"></div>
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
  const resourceRef = useRef<ManagedAsyncResource<TelemetryState> | null>(null)
  if (resourceRef.current === null) {
    resourceRef.current = createManagedAsyncResource<TelemetryState>({
      tools: [],
      timeline: [],
      totalEntries: 0,
      windowHours: 24,
    })
  }
  const resource = resourceRef.current
  const [query, setQuery] = useState('')

  useEffect(() => {
    void resource.load(async (signal) => {
      const data: ToolStatsResponse = await fetchKeeperToolStats(keeperName, 24, { signal })
      return {
        tools: data.tools,
        timeline: data.timeline,
        totalEntries: data.total_entries,
        windowHours: data.window_hours,
      }
    })
    return () => {
      resource.cancel()
    }
  }, [keeperName, resource])

  const asyncState = resource.state.value
  const s = asyncState.data ?? {
    tools: [],
    timeline: [],
    totalEntries: 0,
    windowHours: 24,
  }

  // Loading and empty states return null — the section card
  // is only rendered when there is actual telemetry data to show.
  if (asyncState.loading || s.tools.length === 0) return null
  if (asyncState.error) {
    return html`<div class="text-xs text-[var(--bad)] py-2 px-3">텔레메트리 로드 실패: ${asyncState.error}</div>`
  }

  const totalCost = s.tools.reduce((sum, t) => sum + t.total_cost_usd, 0)
  const maxCount = s.tools[0]?.call_count ?? 1

  // Find tools with highest p95
  const slowest = [...s.tools].sort((a, b) => b.p95_duration_ms - a.p95_duration_ms).slice(0, 3)

  // Inline filter — s.tools is typically ≤ 50 rows so O(n) is fine and
  // keeps all hooks above early-return paths.
  const visibleTools = filterToolStats(s.tools, query)
  const trimmedQuery = query.trim()

  return html`
    <div class="p-5 rounded border border-card-border bg-card/40 backdrop-blur-sm shadow-sm transition-[border-color,box-shadow] duration-200 hover:border-accent/30 hover:shadow-sm">
      <div class="text-[11px] font-semibold uppercase tracking-widest text-text-muted mb-4 flex items-center gap-2">
        <span class="w-1.5 h-1.5 rounded-full bg-accent/50"></span>
        도구 텔레메트리
      </div>
      <div class="flex flex-col gap-4">

      ${'' /* Summary row */}
      <div class="flex gap-3 flex-wrap text-[11px]">
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded bg-[var(--white-4)] border border-[var(--white-6)] text-[var(--text-muted)]">
          <span class="font-mono font-medium text-[var(--text-strong)]">${s.tools.length}</span> 도구
        </span>
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded bg-[var(--white-4)] border border-[var(--white-6)] text-[var(--text-muted)]">
          <span class="font-mono font-medium text-[var(--text-strong)]">${s.totalEntries}</span> 호출
        </span>
        ${totalCost > 0 ? html`
          <span class="inline-flex items-center gap-1 px-2 py-1 rounded bg-[var(--accent-12)] border border-[rgba(71,184,255,0.15)] text-[var(--text-muted)]">
            <span class="font-mono font-medium text-[var(--accent)]">$${totalCost.toFixed(3)}</span>
          </span>
        ` : null}
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded bg-[var(--white-4)] border border-[var(--white-6)] text-[var(--text-dim)]">
          ${s.windowHours}h 기간
        </span>
      </div>

      ${'' /* Hourly timeline sparkline */}
      ${s.timeline.length > 1 ? html`
        <div class="flex flex-col gap-1">
          <${SectionCap} tone="dim" weight="semibold" class="mb-1">시간대별 활동<//>
          <div class="overflow-x-auto py-1">
            <${Sparkline} buckets=${s.timeline} height=${28} />
          </div>
        </div>
      ` : null}

      ${'' /* Per-tool bar chart */}
      <div class="flex flex-col gap-1">
        <div class="flex items-center justify-between gap-2 mb-1">
          <${SectionCap} tone="dim" weight="semibold">호출 빈도<//>
          <div class="flex items-center gap-2">
            <input
              type="search"
              value=${query}
              placeholder="도구 검색 (이름/카테고리)"
              aria-label="도구 텔레메트리 검색"
              onInput=${(e: Event) => { setQuery((e.target as HTMLInputElement).value) }}
              class="min-w-[160px] rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-[11px] text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)]"
            />
            <span class="text-[10px] text-[var(--text-muted)] tabular-nums">
              ${trimmedQuery
                ? `${visibleTools.length} / ${s.tools.length}`
                : `${s.tools.length}개`}
            </span>
          </div>
        </div>
        ${visibleTools.length === 0 ? html`
          <div class="text-[11px] text-[var(--text-muted)] py-2 px-2">
            필터 결과 없음 (${s.tools.length} items)
          </div>
        ` : visibleTools.slice(0, 15).map(stat => {
          const cat = toolCategory(stat.name)
          const barWidth = (stat.call_count / maxCount) * 100
          return html`
            <div class="flex items-center gap-2 py-1 group">
              <div class="size-5 rounded flex-shrink-0 bg-[var(--white-5)] flex items-center justify-center text-[10px] font-mono font-bold ${cat.color}">
                ${cat.icon}
              </div>
              <div class="w-28 flex-shrink-0 text-[11px] font-mono text-[var(--text-muted)] truncate" title=${stat.name}>
                ${stat.name.replace(/^(keeper_|masc_)/, '')}
              </div>
              <div class="flex-1 h-3 rounded bg-[var(--white-5)] overflow-hidden">
                <div class="h-full rounded transition-all duration-300"
                  style="width: ${barWidth}%; background: ${stat.failure_count > 0 ? 'var(--warn)' : 'var(--accent)'}; opacity: 0.7">
                </div>
              </div>
              <span class="w-8 text-right text-[11px] font-mono text-[var(--text-muted)]">${stat.call_count}</span>
              <span class="w-14 text-right text-[10px] font-mono ${durationColor(stat.avg_duration_ms)}">
                ${formatDuration(stat.avg_duration_ms)}
              </span>
            </div>
          `
        })}
      </div>

      ${'' /* Success rate table */}
      ${s.tools.some(st => st.failure_count > 0) ? html`
        <div class="flex flex-col gap-1.5">
          <${SectionCap} tone="dim" weight="semibold" class="mb-1">성공률<//>
          ${s.tools.filter(st => st.failure_count > 0).map(stat => html`
            <div class="flex items-center gap-2">
              <span class="w-28 flex-shrink-0 text-[11px] font-mono text-[var(--text-muted)] truncate">
                ${stat.name.replace(/^(keeper_|masc_)/, '')}
              </span>
              <${SuccessRateBar} stat=${stat} />
              <span class="text-[10px] text-[var(--bad)] w-10 text-right">${stat.failure_count}err</span>
            </div>
          `)}
        </div>
      ` : null}

      ${'' /* P95 latency (slowest tools) */}
      ${slowest.length > 0 && slowest[0]!.p95_duration_ms > 500 ? html`
        <div class="flex flex-col gap-1.5">
          <${SectionCap} tone="dim" weight="semibold" class="mb-1">P95 지연 시간<//>
          ${slowest.map(stat => html`
            <div class="flex items-center justify-between py-1 px-2 rounded bg-[var(--white-3)]">
              <span class="text-[11px] font-mono text-[var(--text-muted)]">${stat.name.replace(/^(keeper_|masc_)/, '')}</span>
              <div class="flex items-center gap-3">
                <span class="text-[10px] text-[var(--text-dim)]">avg ${formatDuration(stat.avg_duration_ms)}</span>
                <span class="text-[11px] font-mono font-medium ${durationColor(stat.p95_duration_ms)}">p95 ${formatDuration(stat.p95_duration_ms)}</span>
              </div>
            </div>
          `)}
        </div>
      ` : null}
      </div>
    </div>
  `
}
