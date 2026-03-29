// Keeper trajectory timeline — shows per-turn tool call history
// with args summary, result preview, gate decisions, and duration.
// Fetches from /api/v1/keepers/:name/trajectory on mount + SSE refresh.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { fetchKeeperTrajectory } from '../api/dashboard'
import type { TrajectoryEntry, TrajectoryResponse } from '../api/dashboard'
import { TimeAgo } from './common/time-ago'

// ── State ────────────────────────────────────────────────

const trajectoryData = signal<TrajectoryResponse | null>(null)
const trajectoryLoading = signal(false)
const trajectoryError = signal<string | null>(null)

export async function loadTrajectory(keeperName: string): Promise<void> {
  trajectoryLoading.value = true
  trajectoryError.value = null
  try {
    trajectoryData.value = await fetchKeeperTrajectory(keeperName, TRAJECTORY_DEFAULT_LIMIT)
  } catch (err) {
    trajectoryError.value = err instanceof Error ? err.message : 'fetch failed'
    trajectoryData.value = null
  } finally {
    trajectoryLoading.value = false
  }
}

export function clearTrajectory(): void {
  trajectoryData.value = null
  trajectoryError.value = null
}

// ── Display constants ────────────────────────────────────

const TRAJECTORY_DEFAULT_LIMIT = 50
const ARGS_PREVIEW_MAX_CHARS = 80
const ARGS_VALUE_MAX_CHARS = 30
const ARGS_MAX_KEYS = 3
const RESULT_PREVIEW_MAX_CHARS = 80
const DURATION_FAST_MS = 500
const DURATION_SLOW_MS = 2000

// Tool category → icon/color mapping. Order matters: first match wins.
const TOOL_CATEGORIES: Array<{ match: (n: string) => boolean; icon: string; color: string }> = [
  { match: n => n.includes('bash'),                         icon: '>', color: 'text-[#4ade80]' },
  { match: n => n.includes('edit') || n.includes('fs'),     icon: 'E', color: 'text-[#fbbf24]' },
  { match: n => n.includes('board') || n.includes('social'),icon: 'B', color: 'text-[#a78bfa]' },
  { match: n => n.includes('github'),                       icon: 'G', color: 'text-[#9ad9ff]' },
  { match: n => n.includes('search') || n.includes('read'), icon: 'R', color: 'text-[#60a5fa]' },
]
const DEFAULT_TOOL_STYLE = { icon: 'T', color: 'text-[#94a3b8]' }

// ── Helpers ──────────────────────────────────────────────

function toolCategory(name: string): { icon: string; color: string } {
  return TOOL_CATEGORIES.find(c => c.match(name)) ?? DEFAULT_TOOL_STYLE
}

function durationColor(ms: number): string {
  if (ms < DURATION_FAST_MS) return 'text-[#4ade80]'
  if (ms < DURATION_SLOW_MS) return 'text-[#fbbf24]'
  return 'text-[#ef4444]'
}

function formatArgs(args: Record<string, unknown> | string): string {
  if (typeof args === 'string') {
    return args.length > ARGS_PREVIEW_MAX_CHARS ? args.slice(0, ARGS_PREVIEW_MAX_CHARS) + '...' : args
  }
  const keys = Object.keys(args)
  if (keys.length === 0) return '{}'
  const preview = keys.slice(0, ARGS_MAX_KEYS).map(k => {
    const v = args[k]
    const vs = typeof v === 'string'
      ? (v.length > ARGS_VALUE_MAX_CHARS ? v.slice(0, ARGS_VALUE_MAX_CHARS) + '...' : v)
      : JSON.stringify(v)?.slice(0, ARGS_VALUE_MAX_CHARS) ?? ''
    return `${k}: ${vs}`
  }).join(', ')
  return keys.length > ARGS_MAX_KEYS ? `{${preview}, ...}` : `{${preview}}`
}

function formatResult(result: string | null, error: string | null): string {
  if (error) return `err: ${error.slice(0, RESULT_PREVIEW_MAX_CHARS)}`
  if (!result) return '-'
  return result.length > RESULT_PREVIEW_MAX_CHARS ? result.slice(0, RESULT_PREVIEW_MAX_CHARS) + '...' : result
}

// ── Components ───────────────────────────────────────────

function TrajectoryEntryRow({ entry }: { entry: TrajectoryEntry }) {
  const gateRejected = entry.gate.status === 'reject'
  const cat = toolCategory(entry.tool_name)
  return html`
    <div class="group flex items-start gap-3 py-2.5 px-3 rounded-lg hover:bg-[var(--white-3)] transition-colors ${gateRejected ? 'opacity-50' : ''}">
      ${'' /* Tool icon */}
      <div class="flex-shrink-0 mt-0.5 size-7 rounded-md bg-[var(--white-5)] border border-[var(--white-8)] flex items-center justify-center text-[11px] font-mono font-bold ${cat.color}">
        ${cat.icon}
      </div>

      ${'' /* Content */}
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="text-xs font-mono font-medium ${cat.color}">${entry.tool_name}</span>
          <span class="text-[10px] text-[var(--text-dim)]">T${entry.turn}R${entry.round}</span>
          ${gateRejected
            ? html`<span class="text-[10px] px-1.5 py-0.5 rounded bg-[rgba(239,68,68,0.1)] text-[#ef4444]">거부: ${entry.gate.reason ?? ''}</span>`
            : null}
          ${entry.error
            ? html`<span class="text-[10px] px-1.5 py-0.5 rounded bg-[rgba(239,68,68,0.1)] text-[#ef4444]">오류</span>`
            : null}
        </div>

        ${'' /* Args */}
        <div class="mt-1 text-[11px] text-[var(--text-muted)] font-mono truncate max-w-full" title=${typeof entry.args === 'string' ? entry.args : JSON.stringify(entry.args)}>
          ${formatArgs(entry.args)}
        </div>

        ${'' /* Result preview (on hover/expand) */}
        <div class="mt-0.5 text-[11px] text-[var(--text-dim)] font-mono truncate max-w-full hidden group-hover:block">
          ${formatResult(entry.result, entry.error)}
        </div>
      </div>

      ${'' /* Duration + timestamp */}
      <div class="flex-shrink-0 flex flex-col items-end gap-0.5">
        <span class="text-[11px] font-mono ${durationColor(entry.duration_ms)}">${entry.duration_ms}ms</span>
        <${TimeAgo} timestamp=${entry.ts} class="text-[10px] text-[var(--text-dim)]" />
      </div>
    </div>
  `
}

// Group entries by turn number
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

export function KeeperTrajectoryTimeline({ keeperName }: { keeperName: string }) {
  useEffect(() => {
    void loadTrajectory(keeperName)
    return () => clearTrajectory()
  }, [keeperName])

  if (trajectoryLoading.value) {
    return html`<div class="text-xs text-[var(--text-muted)] py-4 text-center">궤적 로딩 중...</div>`
  }

  if (trajectoryError.value) {
    return html`<div class="text-xs text-[#ef4444] py-4 text-center">${trajectoryError.value}</div>`
  }

  const data = trajectoryData.value
  if (!data || data.entries.length === 0) {
    return html`<div class="text-xs text-[var(--text-muted)] py-4 text-center">이 세션에 기록된 도구 호출이 없습니다.</div>`
  }

  const turnGroups = groupByTurn(data.entries)
  const turns = Array.from(turnGroups.entries()).sort(([a], [b]) => b - a)

  return html`
    <div class="flex flex-col gap-1">
      ${'' /* Header */}
      <div class="flex items-center justify-between mb-2">
        <div class="flex items-center gap-2">
          <span class="text-[10px] font-mono text-[var(--text-dim)]">trace: ${data.trace_id.slice(0, 8)}</span>
          <span class="text-[10px] text-[var(--text-dim)]">gen ${data.generation}</span>
        </div>
        <span class="text-[10px] text-[var(--text-dim)]">
          ${data.showing}/${data.total_entries} entries
        </span>
      </div>

      ${'' /* Turn groups */}
      ${turns.map(([turnNum, entries]) => html`
        <div class="mb-2">
          <div class="flex items-center gap-2 mb-1">
            <div class="text-[10px] font-semibold text-[var(--text-muted)] uppercase tracking-wider">Turn ${turnNum}</div>
            <div class="flex-1 h-px bg-[var(--border-slate-12)]"></div>
            <div class="text-[10px] text-[var(--text-dim)]">${entries.length} call${entries.length > 1 ? 's' : ''}</div>
          </div>
          ${entries.map((e: TrajectoryEntry) => html`<${TrajectoryEntryRow} entry=${e} />`)}
        </div>
      `)}
    </div>
  `
}
