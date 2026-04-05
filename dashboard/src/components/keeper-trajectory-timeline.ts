// Keeper trajectory timeline — shows per-turn tool call history
// with args summary, result preview, gate decisions, and duration.
// Fetches from /api/v1/keepers/:name/trajectory on mount + SSE refresh.

import { html } from 'htm/preact'
import { signal, useSignal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { fetchKeeperTrajectory } from '../api/dashboard'
import type { TrajectoryEntry, TrajectoryResponse } from '../api/dashboard'
import { truncate } from '../lib/truncate'
import { TimeAgo } from './common/time-ago'
import { toolCategory, durationColor, formatArgs, prettyArgs } from './tool-call-shared'

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
  const gateRejected = entry.gate.status === 'reject'
  const cat = toolCategory(entry.tool_name)
  const toggle = () => { expanded.value = !expanded.value }

  return html`
    <div class="rounded-lg transition-colors ${gateRejected ? 'opacity-50' : ''} ${expanded.value ? 'bg-[var(--white-3)]' : ''}">
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
            <span class="text-xs font-mono font-medium ${cat.color}">${entry.tool_name}</span>
            <span class="text-[10px] text-[var(--text-dim)]">T${entry.turn}R${entry.round}</span>
            ${entry.cost_usd > 0
              ? html`<span class="text-[10px] px-1.5 py-0.5 rounded bg-[var(--accent-12)] text-[var(--accent)]">$${entry.cost_usd.toFixed(4)}</span>`
              : null}
            ${gateRejected
              ? html`<span class="text-[10px] px-1.5 py-0.5 rounded bg-[var(--bad-10)] text-[var(--bad)]">거부: ${truncate(entry.gate.reason ?? '', 40)}</span>`
              : null}
            ${entry.error
              ? html`<span class="text-[10px] px-1.5 py-0.5 rounded bg-[var(--bad-10)] text-[var(--bad)]">오류</span>`
              : null}
          </div>

          ${'' /* Args preview (collapsed) */}
          ${!expanded.value ? html`
            <div class="mt-1 text-[11px] text-[var(--text-muted)] font-mono truncate max-w-full">
              ${formatArgs(entry.args)}
            </div>
          ` : null}
        </div>

        ${'' /* Duration + timestamp */}
        <div class="flex-shrink-0 flex flex-col items-end gap-0.5">
          <span class="text-[11px] font-mono ${durationColor(entry.duration_ms)}">${entry.duration_ms}ms</span>
          <${TimeAgo} timestamp=${entry.ts} class="text-[10px] text-[var(--text-dim)]" />
        </div>
      </div>

      ${'' /* Expanded detail panel */}
      ${expanded.value ? html`
        <div class="mx-3 mb-3 mt-1 flex flex-col gap-2 border-l-2 border-[var(--white-8)] pl-3">
          ${'' /* Full args */}
          <div>
            <div class="text-[10px] font-semibold text-[var(--text-muted)] uppercase tracking-wider mb-1">Arguments</div>
            <pre class="m-0 text-[11px] font-mono text-[var(--text-body)] bg-[var(--white-5)] rounded-md p-2 overflow-x-auto max-h-[300px] overflow-y-auto whitespace-pre-wrap break-all">${prettyArgs(entry.args)}</pre>
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
          ${gateRejected && entry.gate.reason ? html`
            <div>
              <div class="text-[10px] font-semibold text-[var(--warn)] uppercase tracking-wider mb-1">Gate Rejection</div>
              <div class="text-[11px] font-mono text-[var(--warn)] bg-[var(--warn-10)] rounded-md p-2">${entry.gate.reason}</div>
            </div>
          ` : null}

          ${'' /* Metadata row */}
          <div class="flex gap-4 flex-wrap text-[10px] text-[var(--text-dim)]">
            ${entry.cost_usd > 0 ? html`<span>Cost: $${entry.cost_usd.toFixed(6)}</span>` : null}
            <span>Duration: ${entry.duration_ms}ms</span>
            <span>Turn ${entry.turn}, Round ${entry.round}</span>
            <span class="font-mono">${entry.ts_iso ?? new Date(entry.ts * 1000).toISOString()}</span>
          </div>
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

export function KeeperTrajectoryTimeline({ keeperName }: { keeperName: string }) {
  useEffect(() => {
    void loadTrajectory(keeperName)
    return () => clearTrajectory(keeperName)
  }, [keeperName])

  const state = getState(keeperName)

  if (state.loading) {
    return html`<div class="text-xs text-[var(--text-muted)] py-4 text-center">궤적 로딩 중...</div>`
  }

  if (state.error) {
    return html`<div class="text-xs text-[var(--bad)] py-4 text-center">${state.error}</div>`
  }

  const data = state.data
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
