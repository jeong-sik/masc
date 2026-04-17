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
import { FilterChips } from './common/filter-chips'
import { TextInput } from './common/input'
import { keeperHeartbeats } from '../store'
import { isConnected } from '../sse'
import { TRAJECTORY_HEARTBEAT_STALE_MS, LIVENESS_TICK_MS, CONTEXT_RATIO_CRITICAL, CONTEXT_RATIO_WARN } from '../config/constants'
import type { Keeper } from '../types'
const OFFLINE_STATUSES = ['offline', 'inactive', 'dead', 'crashed'] as const
const STAT_PILL = 'text-[10px] py-0.5 px-2 rounded-full bg-[var(--white-4)] border border-[var(--white-8)] text-[var(--text-muted)]'

// ── Constants ────────────────────────────────────────────

const TRAJECTORY_DEFAULT_LIMIT = 50

// ── Filter state (per-keeper) ────────────────────────────

export type TrajectoryTypeFilter = 'all' | 'tool' | 'thinking'

type TrajectoryFilterState = {
  type: TrajectoryTypeFilter
  search: string
}

const trajectoryFilters = signal<Record<string, TrajectoryFilterState>>({})

function getFilterState(name: string): TrajectoryFilterState {
  return trajectoryFilters.value[name] ?? { type: 'all', search: '' }
}

function setFilterState(name: string, patch: Partial<TrajectoryFilterState>): void {
  const prev = getFilterState(name)
  trajectoryFilters.value = { ...trajectoryFilters.value, [name]: { ...prev, ...patch } }
}

// ── Pure filter (exported for tests) ─────────────────────

export function entryMatchesType(entry: TrajectoryEntry, type: TrajectoryTypeFilter): boolean {
  if (type === 'all') return true
  if (type === 'thinking') return entry.type === 'thinking'
  // 'tool' = anything that isn't a thinking block
  return entry.type !== 'thinking'
}

export function entryMatchesSearch(entry: TrajectoryEntry, search: string): boolean {
  if (!search) return true
  const q = search.toLowerCase()
  if (entry.tool_name && entry.tool_name.toLowerCase().includes(q)) return true
  if (entry.content && entry.content.toLowerCase().includes(q)) return true
  if (entry.args) {
    const argsStr = typeof entry.args === 'string' ? entry.args : JSON.stringify(entry.args)
    if (argsStr.toLowerCase().includes(q)) return true
  }
  return false
}

export function filterTrajectoryEntries(
  entries: TrajectoryEntry[],
  filter: TrajectoryFilterState,
): TrajectoryEntry[] {
  return entries.filter(e => entryMatchesType(e, filter.type) && entryMatchesSearch(e, filter.search))
}

export function countByType(entries: TrajectoryEntry[]): { tool: number; thinking: number } {
  let tool = 0, thinking = 0
  for (const e of entries) {
    if (e.type === 'thinking') thinking += 1
    else tool += 1
  }
  return { tool, thinking }
}

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

function ThinkingEntryRow({ entry }: { entry: TrajectoryEntry }) {
  const expanded = useSignal(false)
  const len = entry.content_length ?? entry.content?.length ?? 0
  const toggle = () => { expanded.value = !expanded.value }
  const hasContent = !entry.redacted && (entry.content?.length ?? 0) > 0

  return html`
    <div class="rounded-lg transition-colors ${expanded.value ? 'bg-[rgba(168,85,247,0.06)]' : ''}" style=${{ animation: 'activityFadeIn 0.3s ease-out' }}>
      <div
        class="group flex items-start gap-3 py-2.5 px-3 ${hasContent ? 'cursor-pointer hover:bg-[rgba(168,85,247,0.06)]' : ''} rounded-lg select-none"
        onClick=${hasContent ? toggle : undefined}
        role=${hasContent ? 'button' : undefined}
        aria-expanded=${hasContent ? expanded.value : undefined}
        tabIndex=${hasContent ? 0 : undefined}
        onKeyDown=${hasContent ? (e: KeyboardEvent) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle() } } : undefined}
      >
        <div class="flex-shrink-0 flex items-center gap-1.5 mt-0.5">
          <span class="text-[10px] text-[var(--text-dim)] w-3 text-center">${hasContent ? (expanded.value ? '\u25BC' : '\u25B6') : ''}</span>
          <div class="size-7 rounded-md bg-[rgba(168,85,247,0.12)] border border-[rgba(168,85,247,0.2)] flex items-center justify-center text-[12px]">\u{1F4AD}</div>
        </div>
        <div class="flex-1 min-w-0 flex items-center gap-2">
          <span class="text-xs font-mono font-medium text-[#a855f7]">${entry.redacted ? 'thinking (redacted)' : 'thinking'}</span>
          <span class="text-[10px] text-[var(--text-dim)]">T${entry.turn}</span>
          ${len > 0 ? html`<span class="text-[10px] px-1.5 py-0.5 rounded bg-[rgba(168,85,247,0.1)] text-[#a855f7]">${len}자</span>` : null}
        </div>
        <div class="flex-shrink-0">
          <${TimeAgo} timestamp=${entry.ts} class="text-[10px] text-[var(--text-dim)]" />
        </div>
      </div>

      ${expanded.value && hasContent ? html`
        <div class="mx-3 mb-3 mt-1 border-l-2 border-[rgba(168,85,247,0.3)] pl-3">
          <div class="text-[10px] font-semibold text-[#a855f7] uppercase tracking-wider mb-1">Thinking Content</div>
          <pre class="m-0 text-[11px] font-mono text-[var(--text-body)] bg-[var(--white-5)] rounded-md p-2 overflow-x-auto max-h-[400px] overflow-y-auto whitespace-pre-wrap break-all">${entry.content}</pre>
        </div>
      ` : null}
    </div>
  `
}

function TrajectoryEntryRow({ entry }: { entry: TrajectoryEntry }) {
  if (entry.type === 'thinking') return html`<${ThinkingEntryRow} entry=${entry} />`

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

export function groupByTurn(entries: TrajectoryEntry[]): Map<number, TrajectoryEntry[]> {
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

  const filter = getFilterState(keeperName)
  const typeCounts = useMemo(() => countByType(data.entries), [data.entries])
  const filteredEntries = useMemo(
    () => filterTrajectoryEntries(data.entries, filter),
    [data.entries, filter.type, filter.search],
  )
  const filterActive = filter.type !== 'all' || filter.search !== ''

  const { turns, allSummary, distinctTools } = useMemo(() => {
    const groups = groupByTurn(filteredEntries)
    const sorted = Array.from(groups.entries()).sort(([a], [b]) => b - a)
    const summary = summarizeEntries(filteredEntries)
    const distinct = new Set(filteredEntries.filter(e => e.tool_name).map(e => e.tool_name)).size
    return { turns: sorted, allSummary: summary, distinctTools: distinct }
  }, [filteredEntries])
  // Tick every LIVENESS_TICK_MS so isLive transitions from true→false
  // when heartbeat goes stale while the component is mounted.
  const now = useSignal(Date.now())
  useEffect(() => {
    const id = setInterval(() => { now.value = Date.now() }, LIVENESS_TICK_MS)
    return () => clearInterval(id)
  }, [])
  const lastHb = keeperHeartbeats.value.get(keeperName)
  const isLive = isConnected.value && lastHb != null && (now.value - lastHb) < TRAJECTORY_HEARTBEAT_STALE_MS
  const isOnline = keeper != null && !OFFLINE_STATUSES.includes(keeper.status as typeof OFFLINE_STATUSES[number])
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
            ? html`<span class="text-[10px] font-mono ${contextRatio > CONTEXT_RATIO_CRITICAL ? 'text-[var(--bad)]' : contextRatio > CONTEXT_RATIO_WARN ? 'text-[var(--warn)]' : 'text-[var(--text-dim)]'}">ctx ${(contextRatio * 100).toFixed(0)}%</span>`
            : null}
        </div>
        <span class="text-[10px] text-[var(--text-dim)]">
          ${filterActive
            ? `${filteredEntries.length} / ${data.total_entries} entries`
            : `${data.showing}/${data.total_entries} entries`}
        </span>
      </div>

      ${'' /* Filter bar — type chips + search */}
      <div class="flex flex-wrap gap-2 items-center mb-2 px-1">
        <${FilterChips}
          chips=${[
            { key: 'all' as TrajectoryTypeFilter, label: '전체', count: data.entries.length },
            { key: 'tool' as TrajectoryTypeFilter, label: '도구', count: typeCounts.tool },
            { key: 'thinking' as TrajectoryTypeFilter, label: '사고', count: typeCounts.thinking },
          ]}
          value=${filter.type}
          onChange=${(k: TrajectoryTypeFilter) => setFilterState(keeperName, { type: k })}
          size="sm"
          tone="accent"
        />
        <${TextInput}
          class="max-w-[200px]"
          name="trajectory_search"
          ariaLabel="도구/사고 내용 검색"
          autoComplete="off"
          placeholder="tool·args·content 검색..."
          value=${filter.search}
          onInput=${(e: Event) => setFilterState(keeperName, { search: (e.target as HTMLInputElement).value })}
        />
      </div>

      ${'' /* Summary stats bar */}
      <div class="flex gap-3 flex-wrap mb-2 px-1">
        <span class="${STAT_PILL}">${turns.length} turns</span>
        <span class="${STAT_PILL}">${filteredEntries.length} calls</span>
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

      ${'' /* Filtered empty state */}
      ${filterActive && filteredEntries.length === 0
        ? html`<div class="py-4 text-center text-xs text-[var(--text-muted)]">조건에 맞는 기록이 없습니다.</div>`
        : null}

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
