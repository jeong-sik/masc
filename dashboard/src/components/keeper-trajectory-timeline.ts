// Keeper trajectory timeline — shows per-turn tool call history
// with args summary, result preview, gate decisions, and duration.
// Fetches from /api/v1/keepers/:name/trajectory on mount + SSE refresh.

import { html } from 'htm/preact'
import { signal, useSignal } from '@preact/signals'
import { useEffect, useMemo } from 'preact/hooks'
import { fetchKeeperTrajectory } from '../api/dashboard'
import type { TrajectoryEntry, TrajectoryResponse } from '../api/dashboard'
import { truncate } from '../lib/truncate'
import { TimeAgo } from './common/time-ago'
import { toolCategory, durationColor, formatArgs, prettyArgs, formatDuration, summarizeEntries } from './tool-call-shared'
import { keeperHeartbeats } from '../store'
import type { Keeper } from '../types'

const HEARTBEAT_STALE_MS = 30_000
const OFFLINE_STATUSES = ['offline', 'inactive', 'dead', 'crashed'] as const
const STAT_PILL = 'text-[10px] py-0.5 px-2 rounded-full bg-[var(--white-4)] border border-[var(--white-8)] text-[var(--text-muted)]'

// ── Constants ────────────────────────────────────────────

const TRAJECTORY_DEFAULT_LIMIT = 50

// ── State (per-keeper to avoid cross-keeper corruption) ──

type TrajectoryState = {
  data: TrajectoryResponse | null
  loading: boolean
  error: string | null
}

const trajectoryStates = signal<Record<string, TrajectoryState>>({})

function getState(name: string): TrajectoryState {
  return trajectoryStates.value[name] ?? { data: null, loading: false, error: null }
}

function setState(name: string, patch: Partial<TrajectoryState>): void {
  const prev = getState(name)
  trajectoryStates.value = { ...trajectoryStates.value, [name]: { ...prev, ...patch } }
}

export async function loadTrajectory(keeperName: string): Promise<void> {
  setState(keeperName, { loading: true, error: null })
  try {
    const data = await fetchKeeperTrajectory(keeperName, TRAJECTORY_DEFAULT_LIMIT)
    setState(keeperName, { data, loading: false })
  } catch (err) {
    setState(keeperName, {
      data: null,
      loading: false,
      error: err instanceof Error ? err.message : 'fetch failed',
    })
  }
}

export function clearTrajectory(keeperName: string): void {
  const next = { ...trajectoryStates.value }
  delete next[keeperName]
  trajectoryStates.value = next
}

// ── Helpers ──────────────────────────────────────────────
// toolCategory, durationColor, formatArgs, prettyArgs imported from tool-call-shared

// ── Components ───────────────────────────────────────────

function TrajectoryEntryRow({ entry }: { entry: TrajectoryEntry }) {
  const expanded = useSignal(false)
  const gateRejected = entry.gate?.status === 'reject'
  const cat = toolCategory(entry.tool_name ?? 'unknown')
  const toggle = () => { expanded.value = !expanded.value }

  return html`
    <div class="rounded-lg transition-colors ${gateRejected ? 'opacity-50' : ''} ${expanded.value ? 'bg-[var(--white-3)]' : ''}" style=${{ animation: 'activityFadeIn 0.3s ease-out' }}>
      <div
        class="group flex items-start gap-3 py-2.5 px-3 cursor-pointer hover:bg-[var(--white-3)] rounded-lg select-none"
        onClick=${toggle}
        role="button"
        aria-expanded=${expanded.value}
        tabIndex=${0}
        onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle() } }}
      >
        ${'' /* Expand indicator + Tool icon */}
        <div class="flex-shrink-0 flex items-center gap-1.5 mt-0.5">
          <span class="text-[10px] text-[var(--text-dim)] w-3 text-center">${expanded.value ? '\u25BC' : '\u25B6'}</span>
          <div class="size-7 rounded-md bg-[var(--white-5)] border border-[var(--white-8)] flex items-center justify-center text-[11px] font-mono font-bold ${cat.color}">
            ${cat.icon}
          </div>
        </div>

        ${'' /* Content */}
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2 flex-wrap">
            <span class="text-xs font-mono font-medium ${cat.color}" title=${entry.tool_name ?? ''}>${entry.tool_name ?? 'unknown'}</span>
            <span class="text-[10px] px-1 py-0.5 rounded bg-[var(--white-5)] text-[var(--text-dim)]">${cat.label}</span>
            <span class="text-[10px] text-[var(--text-dim)]">T${entry.turn}R${entry.round ?? 0}</span>
            ${(entry.cost_usd ?? 0) > 0
              ? html`<span class="text-[10px] px-1.5 py-0.5 rounded bg-[var(--accent-12)] text-[var(--accent)]">$${(entry.cost_usd ?? 0).toFixed(4)}</span>`
              : null}
            ${gateRejected
              ? html`<span class="text-[10px] px-1.5 py-0.5 rounded bg-[var(--bad-10)] text-[var(--bad)]">거부: ${truncate(entry.gate?.reason ?? '', 40)}</span>`
              : null}
            ${entry.error
              ? html`<span class="text-[10px] px-1.5 py-0.5 rounded bg-[var(--bad-10)] text-[var(--bad)]">오류</span>`
              : !gateRejected
                ? html`<span class="text-[10px] px-1.5 py-0.5 rounded bg-[rgba(52,211,153,0.1)] text-[var(--ok)]">완료</span>`
                : null}
          </div>

          ${'' /* Args preview (collapsed) */}
          ${!expanded.value ? html`
            <div class="mt-1 text-[11px] text-[var(--text-muted)] font-mono truncate max-w-full">
              ${formatArgs(entry.args ?? {})}
            </div>
          ` : null}
        </div>

        ${'' /* Duration + timestamp */}
        <div class="flex-shrink-0 flex flex-col items-end gap-0.5">
          <span class="text-[11px] font-mono ${durationColor(entry.duration_ms ?? 0)}">${formatDuration(entry.duration_ms ?? 0)}</span>
          <${TimeAgo} timestamp=${entry.ts} class="text-[10px] text-[var(--text-dim)]" />
        </div>
      </div>

      ${'' /* Expanded detail panel */}
      ${expanded.value ? html`
        <div class="mx-3 mb-3 mt-1 flex flex-col gap-2 border-l-2 border-[var(--white-8)] pl-3">
          ${'' /* Full args */}
          <div>
            <div class="text-[10px] font-semibold text-[var(--text-muted)] uppercase tracking-wider mb-1">Arguments</div>
            <pre class="m-0 text-[11px] font-mono text-[var(--text-body)] bg-[var(--white-5)] rounded-md p-2 overflow-x-auto max-h-[300px] overflow-y-auto whitespace-pre-wrap break-all">${prettyArgs(entry.args ?? {})}</pre>
          </div>

          ${'' /* Result */}
          ${entry.result != null ? html`
            <div>
              <div class="text-[10px] font-semibold text-[var(--text-muted)] uppercase tracking-wider mb-1">Result</div>
              <pre class="m-0 text-[11px] font-mono text-[var(--text-body)] bg-[var(--white-5)] rounded-md p-2 overflow-x-auto max-h-[300px] overflow-y-auto whitespace-pre-wrap break-all">${entry.result}</pre>
            </div>
          ` : null}

          ${'' /* Error detail */}
          ${entry.error ? html`
            <div>
              <div class="text-[10px] font-semibold text-[var(--bad)] uppercase tracking-wider mb-1">Error</div>
              <pre class="m-0 text-[11px] font-mono text-[var(--bad)] bg-[var(--bad-10)] rounded-md p-2 overflow-x-auto max-h-[200px] overflow-y-auto whitespace-pre-wrap break-all">${entry.error}</pre>
            </div>
          ` : null}

          ${'' /* Gate detail */}
          ${gateRejected && entry.gate?.reason ? html`
            <div>
              <div class="text-[10px] font-semibold text-[var(--warn)] uppercase tracking-wider mb-1">Gate Rejection</div>
              <div class="text-[11px] font-mono text-[var(--warn)] bg-[var(--warn-10)] rounded-md p-2">${entry.gate?.reason}</div>
            </div>
          ` : null}

          ${'' /* Metadata row */}
          <div class="flex gap-4 flex-wrap text-[10px] text-[var(--text-dim)]">
            ${(entry.cost_usd ?? 0) > 0 ? html`<span>Cost: $${(entry.cost_usd ?? 0).toFixed(6)}</span>` : null}
            <span>Duration: ${entry.duration_ms ?? 0}ms</span>
            <span>Turn ${entry.turn}, Round ${entry.round ?? 0}</span>
            <span class="font-mono">${entry.ts_iso ?? new Date(entry.ts * 1000).toISOString()}</span>
          </div>
        </div>
      ` : null}
    </div>
  `
}

function TrajectoryEmptyState({ keeper }: { keeper?: Keeper }) {
  const isOffline = keeper && OFFLINE_STATUSES.includes(keeper.status as typeof OFFLINE_STATUSES[number])
  const toolNames = keeper?.recent_tool_names ?? keeper?.latest_tool_names ?? []
  const toolCount = keeper?.latest_tool_call_count ?? 0
  const generation = keeper?.generation ?? 0

  return html`
    <div class="py-4 flex flex-col items-center gap-3">
      <div class="text-xs text-[var(--text-muted)] text-center">
        ${isOffline
          ? '키퍼가 오프라인입니다. 기동하면 도구 호출 내역이 기록됩니다.'
          : generation === 0
            ? '아직 시작되지 않은 키퍼입니다.'
            : '현재 세대에서 기록된 도구 호출이 없습니다.'}
      </div>
      ${toolNames.length > 0 ? html`
        <div class="w-full max-w-md">
          <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-dim)] mb-1.5">이전 사용 도구</div>
          <div class="flex flex-wrap gap-1.5">
            ${toolNames.map((name: string) => html`
              <span class="inline-flex items-center text-[11px] font-mono px-2 py-0.5 rounded-md bg-[var(--white-4)] border border-[var(--white-6)] text-[var(--text-muted)]">${name}</span>
            `)}
          </div>
          ${toolCount > 0 ? html`
            <div class="text-[10px] text-[var(--text-dim)] mt-1.5">누적 호출 ${toolCount}회</div>
          ` : null}
        </div>
      ` : null}
    </div>
  `
}

function groupByTurn(entries: TrajectoryEntry[]): Map<number, TrajectoryEntry[]> {
  const groups = new Map<number, TrajectoryEntry[]>()
  for (const e of entries) {
    const existing = groups.get(e.turn)
    if (existing) {
      existing.push(e)
    } else {
      groups.set(e.turn, [e])
    }
  }
  return groups
}

export function KeeperTrajectoryTimeline({ keeperName, keeper }: { keeperName: string; keeper?: Keeper }) {
  useEffect(() => {
    void loadTrajectory(keeperName)
    return () => clearTrajectory(keeperName)
  }, [keeperName])

  const state = getState(keeperName)

  if (state.loading) {
    return html`
      <div class="flex flex-col gap-2 py-3" style=${{ animation: 'loadingPulse 1.5s ease-in-out infinite' }}>
        ${[1, 2, 3].map(i => html`
          <div key=${i} class="flex items-center gap-3 py-2.5 px-3 rounded-lg">
            <div class="size-7 rounded-md bg-[var(--white-8)]"></div>
            <div class="flex-1 flex flex-col gap-1.5">
              <div class="h-3 w-32 rounded bg-[var(--white-8)]"></div>
              <div class="h-2.5 w-48 rounded bg-[var(--white-5)]"></div>
            </div>
            <div class="h-3 w-12 rounded bg-[var(--white-5)]"></div>
          </div>
        `)}
      </div>
    `
  }

  if (state.error) {
    return html`<div class="text-xs text-[var(--bad)] py-4 text-center">${state.error}</div>`
  }

  const data = state.data
  if (!data || data.entries.length === 0) {
    return html`<${TrajectoryEmptyState} keeper=${keeper} />`
  }

  const { turns, allSummary, distinctTools } = useMemo(() => {
    const groups = groupByTurn(data.entries)
    const sorted = Array.from(groups.entries()).sort(([a], [b]) => b - a)
    const summary = summarizeEntries(data.entries)
    const distinct = new Set(data.entries.filter(e => e.tool_name).map(e => e.tool_name)).size
    return { turns: sorted, allSummary: summary, distinctTools: distinct }
  }, [data.entries])
  const lastHb = keeperHeartbeats.value.get(keeperName)
  const isLive = lastHb != null && (Date.now() - lastHb) < HEARTBEAT_STALE_MS
  const isOnline = keeper && !OFFLINE_STATUSES.includes(keeper.status as typeof OFFLINE_STATUSES[number])
  const contextRatio = keeper?.context_ratio

  return html`
    <div class="flex flex-col gap-1">
      ${'' /* Header */}
      <div class="flex items-center justify-between mb-2">
        <div class="flex items-center gap-2">
          ${isLive
            ? html`<span class="inline-flex items-center gap-1 text-[10px] text-[var(--ok)]">
                <span class="inline-block size-1.5 rounded-full bg-[var(--ok)] animate-pulse"></span>
                live
              </span>`
            : isOnline
              ? html`<span class="text-[10px] text-[var(--text-dim)]">online</span>`
              : null}
          <span class="text-[10px] font-mono text-[var(--text-dim)]">trace: ${data.trace_id.slice(0, 8)}</span>
          <span class="text-[10px] text-[var(--text-dim)]">gen ${data.generation}</span>
          ${contextRatio != null
            ? html`<span class="text-[10px] font-mono ${contextRatio > 0.8 ? 'text-[var(--bad)]' : contextRatio > 0.6 ? 'text-[var(--warn)]' : 'text-[var(--text-dim)]'}">ctx ${(contextRatio * 100).toFixed(0)}%</span>`
            : null}
        </div>
        <span class="text-[10px] text-[var(--text-dim)]">
          ${data.showing}/${data.total_entries} entries
        </span>
      </div>

      ${'' /* Summary stats bar */}
      <div class="flex gap-3 flex-wrap mb-2 px-1">
        <span class="${STAT_PILL}">${turns.length} turns</span>
        <span class="${STAT_PILL}">${data.entries.length} calls</span>
        <span class="${STAT_PILL}">${distinctTools} tools</span>
        <span class="${STAT_PILL} font-mono ${durationColor(allSummary.totalMs)}">${formatDuration(allSummary.totalMs)}</span>
        ${allSummary.errorCount > 0
          ? html`<span class="text-[10px] py-0.5 px-2 rounded-full bg-[var(--bad-10)] border border-[rgba(239,68,68,0.2)] text-[var(--bad)]">${allSummary.errorCount} err</span>`
          : html`<span class="text-[10px] py-0.5 px-2 rounded-full bg-[rgba(52,211,153,0.08)] border border-[rgba(52,211,153,0.15)] text-[var(--ok)]">all ok</span>`}
      </div>

      ${'' /* Live processing indicator */}
      ${isLive ? html`
        <div class="flex items-center gap-2 px-3 py-2 mb-2 rounded-lg bg-[rgba(52,211,153,0.06)] border border-[rgba(52,211,153,0.15)]" style=${{ animation: 'pulse 2s ease-in-out infinite' }}>
          <span class="inline-block size-2 rounded-full bg-[var(--ok)] animate-pulse"></span>
          <span class="text-[11px] text-[var(--ok)]">도구 호출 스트리밍 중...</span>
          <span class="flex-1"></span>
          <span class="text-[10px] text-[var(--text-dim)] font-mono">SSE</span>
        </div>
      ` : null}

      ${'' /* Turn groups */}
      ${turns.map(([turnNum, entries]) => {
        const summary = summarizeEntries(entries)
        return html`
          <div class="mb-3">
            <div class="flex items-center gap-2 mb-1.5 px-1">
              <div class="text-[10px] font-semibold text-[var(--text-muted)] uppercase tracking-wider">Turn ${turnNum}</div>
              <div class="flex-1 h-px bg-[var(--border-slate-12)]"></div>
              <div class="flex items-center gap-2 text-[10px] text-[var(--text-dim)]">
                ${summary.errorCount > 0
                  ? html`<span class="text-[var(--bad)]">${summary.errorCount} err</span>`
                  : null}
                <span>${summary.successCount}/${entries.length}</span>
                <span class="font-mono ${durationColor(summary.totalMs)}">${formatDuration(summary.totalMs)}</span>
              </div>
            </div>
            ${entries.map((e: TrajectoryEntry) => html`<${TrajectoryEntryRow} entry=${e} />`)}
          </div>
        `
      })}
    </div>
  `
}
