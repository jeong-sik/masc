// Keeper tool telemetry — per-keeper tool usage statistics panel.
// Uses server-side aggregation (GET /tool-stats) for p95 latency,
// cross-trace aggregation, and hourly timeline sparklines.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { fetchKeeperToolStats } from '../api/dashboard'
import type { ToolStat, HourlyBucket, ToolStatsResponse, TelemetryFreshnessMetadata } from '../api/dashboard'
import { toolCategory, formatDuration, durationColor } from './tool-call-shared'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { TextInput } from './common/input'
import { SectionCap } from './common/section-cap'
import { formatElapsedCompact } from '../lib/format-time'

// ── Types ─────────────────────────────────────────────

interface TelemetryState extends TelemetryFreshnessMetadata {
  tools: ToolStat[]
  timeline: HourlyBucket[]
  totalEntries: number
  windowHours: number
}

function sourceHealthClass(health?: string | null): string {
  switch ((health ?? '').toLowerCase()) {
    case 'ok':
      return 'text-[var(--color-status-ok)]'
    case 'stale':
    case 'coverage_gap':
    case 'empty':
      return 'text-[var(--color-status-warn)]'
    case 'missing':
      return 'text-[var(--bad-light)]'
    default:
      return 'text-[var(--color-fg-disabled)]'
  }
}

function freshnessText(d: TelemetryFreshnessMetadata): string {
  if (d.stale_reason) return d.stale_reason
  if (typeof d.latest_age_s !== 'number' || !Number.isFinite(d.latest_age_s)) {
    return 'latest n/a'
  }
  return `latest ${formatElapsedCompact(d.latest_age_s)}`
}

function FreshnessLine({ data }: { data: TelemetryFreshnessMetadata }) {
  return html`
    <div class="text-3xs text-[var(--color-fg-disabled)]">
      <span class="font-mono">${data.source ?? 'trajectory_tool_call'}</span>
      <span class="mx-1">·</span>
      <span class="font-mono ${sourceHealthClass(data.health)}">${data.health ?? 'unknown'}</span>
      <span class="mx-1">·</span>
      <span>${freshnessText(data)}</span>
      ${typeof data.entry_count === 'number' ? html`
        <span class="mx-1">·</span>
        <span>${data.entry_count.toLocaleString()} rows</span>
      ` : null}
    </div>
  `
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
          fill="var(--color-accent-fg)" opacity="0.5" />
        ${errH > 0 ? html`
          <rect x=${x} y=${height - errH} width=${barW} height=${errH} rx="1.5"
            fill="var(--color-status-err)" opacity="0.7" />
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
        fill="var(--color-fg-disabled)" font-size="8" font-family="monospace">
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
  let barColor = 'var(--color-status-err)'
  if (successPct >= 95) {
    barColor = 'var(--color-status-ok)'
  } else if (successPct >= 80) {
    barColor = 'var(--color-status-warn)'
  }

  return html`
    <div class="flex items-center gap-2 w-full">
      <div class="flex-1 h-1.5 rounded-sm bg-[var(--white-5)] overflow-hidden">
        <div class="h-full rounded-sm transition-all duration-300" style="width: ${successPct}%; background: ${barColor}"></div>
      </div>
      <span class="text-3xs font-mono w-10 text-right" style="color: ${barColor}">
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
  const resource = useManagedAsyncResource<TelemetryState>({
    tools: [],
    timeline: [],
    totalEntries: 0,
    windowHours: 24,
  })
  const [query, setQuery] = useState('')

  useEffect(() => {
    void resource.load(async (signal) => {
      const data: ToolStatsResponse = await fetchKeeperToolStats(keeperName, 24, { signal })
      return {
        source: data.source,
        producer: data.producer,
        durable_store: data.durable_store,
        dashboard_surface: data.dashboard_surface,
        freshness_slo_s: data.freshness_slo_s,
        latest_ts_unix: data.latest_ts_unix,
        latest_ts_iso: data.latest_ts_iso,
        latest_age_s: data.latest_age_s,
        health: data.health,
        stale_reason: data.stale_reason,
        entry_count: data.entry_count,
        exists: data.exists,
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

  // Loading stays quiet; an empty result still renders source freshness so
  // operators can distinguish no calls from a broken trajectory lane.
  if (asyncState.loading) return null
  if (asyncState.error) {
    return html`<div class="text-xs text-[var(--color-status-err)] py-2 px-3">텔레메트리 로드 실패: ${asyncState.error}</div>`
  }

  if (s.tools.length === 0) {
    return html`
      <div class="p-4 rounded border border-[var(--color-border-default)] bg-card/30">
        <div class="text-xs text-[var(--color-fg-muted)]">도구 텔레메트리 데이터 없음</div>
        <${FreshnessLine} data=${s} />
      </div>
    `
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
      <div class="text-2xs font-semibold uppercase tracking-widest text-text-muted mb-4 flex items-center gap-2">
        <span class="w-1.5 h-1.5 rounded-full bg-accent/50"></span>
        도구 텔레메트리
      </div>
      <div class="flex flex-col gap-4">

      ${'' /* Summary row */}
      <div class="flex gap-3 flex-wrap text-2xs">
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded bg-[var(--white-4)] border border-[var(--white-6)] text-[var(--color-fg-muted)]">
          <span class="font-mono font-medium text-[var(--color-fg-secondary)]">${s.tools.length}</span> 도구
        </span>
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded bg-[var(--white-4)] border border-[var(--white-6)] text-[var(--color-fg-muted)]">
          <span class="font-mono font-medium text-[var(--color-fg-secondary)]">${s.totalEntries}</span> 호출
        </span>
        ${totalCost > 0 ? html`
          <span class="inline-flex items-center gap-1 px-2 py-1 rounded bg-[var(--accent-12)] border border-[var(--accent-15)] text-[var(--color-fg-muted)]">
            <span class="font-mono font-medium text-[var(--color-accent-fg)]">$${totalCost.toFixed(3)}</span>
          </span>
        ` : null}
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded bg-[var(--white-4)] border border-[var(--white-6)] text-[var(--color-fg-disabled)]">
          ${s.windowHours}h 기간
        </span>
      </div>
      <${FreshnessLine} data=${s} />

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
            <${TextInput}
              type="search"
              class="min-w-40 !px-2 !py-1 !text-2xs"
              value=${query}
              placeholder="도구 검색 (이름/카테고리)"
              ariaLabel="도구 텔레메트리 검색"
              onInput=${(e: Event) => { setQuery((e.target as HTMLInputElement).value) }}
            />
            <span class="text-3xs text-[var(--color-fg-muted)] tabular-nums">
              ${trimmedQuery
                ? `${visibleTools.length} / ${s.tools.length}`
                : `${s.tools.length}개`}
            </span>
          </div>
        </div>
        ${visibleTools.length === 0 ? html`
          <div class="text-2xs text-[var(--color-fg-muted)] py-2 px-2">
            필터 결과 없음 (${s.tools.length} items)
          </div>
        ` : visibleTools.slice(0, 15).map(stat => {
          const cat = toolCategory(stat.name)
          const barWidth = (stat.call_count / maxCount) * 100
          return html`
            <div class="flex items-center gap-2 py-1 group">
              <div class="size-5 rounded flex-shrink-0 bg-[var(--white-5)] flex items-center justify-center text-3xs font-mono font-bold ${cat.color}">
                ${cat.icon}
              </div>
              <div class="w-28 flex-shrink-0 text-2xs font-mono text-[var(--color-fg-muted)] truncate" title=${stat.name}>
                ${stat.name.replace(/^(keeper_|masc_)/, '')}
              </div>
              <div class="flex-1 h-3 rounded bg-[var(--white-5)] overflow-hidden">
                <div class="h-full rounded transition-all duration-300"
                  style="width: ${barWidth}%; background: ${stat.failure_count > 0 ? 'var(--color-status-warn)' : 'var(--color-accent-fg)'}; opacity: 0.7">
                </div>
              </div>
              <span class="w-8 text-right text-2xs font-mono text-[var(--color-fg-muted)]">${stat.call_count}</span>
              <span class="w-14 text-right text-3xs font-mono ${durationColor(stat.avg_duration_ms)}">
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
              <span class="w-28 flex-shrink-0 text-2xs font-mono text-[var(--color-fg-muted)] truncate">
                ${stat.name.replace(/^(keeper_|masc_)/, '')}
              </span>
              <${SuccessRateBar} stat=${stat} />
              <span class="text-3xs text-[var(--color-status-err)] w-10 text-right">${stat.failure_count}err</span>
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
              <span class="text-2xs font-mono text-[var(--color-fg-muted)]">${stat.name.replace(/^(keeper_|masc_)/, '')}</span>
              <div class="flex items-center gap-3">
                <span class="text-3xs text-[var(--color-fg-disabled)]">avg ${formatDuration(stat.avg_duration_ms)}</span>
                <span class="text-2xs font-mono font-medium ${durationColor(stat.p95_duration_ms)}">p95 ${formatDuration(stat.p95_duration_ms)}</span>
              </div>
            </div>
          `)}
        </div>
      ` : null}
      </div>
    </div>
  `
}
