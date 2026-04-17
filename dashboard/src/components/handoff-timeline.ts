// LT-18: A2A Event Timeline Panel.
//
// Multi-entity event sequence view. Rows are keepers; columns are time.
// Companion to FleetFsmMatrix — matrix shows intra-entity orthogonal
// FSM state, this panel shows inter-entity temporal relationships.
//
// Data source: OAS event_bus SSE relay (oas_sse_bridge.ml) which emits
// agent_started/completed/failed, turn_started/completed, tool_called/
// completed, handoff_requested/completed, context_compact_started/
// context_compacted, context_overflow_imminent. Shipped via
// /api/v1/dashboard/telemetry with source="oas_event".
//
// Design references:
//  - Jaeger distributed-trace waterfall (entity row × time chip).
//  - Bach et al. 2013 — small multiples beat animation for discrete
//    state-change comprehension. This panel is juxtaposed with (not
//    replacing) FleetFsmMatrix.
//  - Harel 1987 orthogonal regions (matrix axes) × sequence diagram
//    (this panel) = dual perspective on the same state space:
//    matrix = "what state is entity E in?",
//    timeline = "which events happened across entities, and when?".
//
// MVP scope: lifecycle chips per keeper row on a shared time axis.
// Handoff arrow overlay (from_agent → to_agent) is out of scope for
// this first iteration — the data flows through but renders as chips
// on the relevant rows. Next iteration can add SVG arc overlays.

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { fetchTelemetry, type TelemetryEntry } from '../api/dashboard'

export type A2aEventKind = 'lifecycle' | 'failure' | 'tool' | 'handoff' | 'context' | 'unknown'

export const A2A_EVENT_TYPES = [
  'agent_started',
  'agent_completed',
  'agent_failed',
  'turn_started',
  'turn_completed',
  'tool_called',
  'tool_completed',
  'handoff_requested',
  'handoff_completed',
  'context_compact_started',
  'context_compacted',
  'context_overflow_imminent',
] as const

export function kindOfEventType(eventType: string): A2aEventKind {
  if (eventType === 'agent_failed') return 'failure'
  if (eventType.startsWith('tool_')) return 'tool'
  if (eventType.startsWith('handoff_')) return 'handoff'
  if (eventType.startsWith('context_')) return 'context'
  if (eventType.startsWith('agent_') || eventType.startsWith('turn_')) return 'lifecycle'
  return 'unknown'
}

export const CHIP_CLASS_BY_KIND: Record<A2aEventKind, string> = {
  lifecycle: 'bg-emerald-400',
  failure: 'bg-red-400',
  tool: 'bg-sky-400',
  handoff: 'bg-orange-400',
  context: 'bg-purple-400',
  unknown: 'bg-zinc-500',
}

export interface TimelineChip {
  ts: number
  eventType: string
  kind: A2aEventKind
  taskId?: string
  peerAgent?: string
}

export interface TimelineRow {
  keeper: string
  chips: TimelineChip[]
}

function entryTimestampMs(entry: TelemetryEntry): number | null {
  const rawUnix = entry.ts_unix ?? entry.ts ?? entry.timestamp
  if (typeof rawUnix === 'number' && Number.isFinite(rawUnix)) {
    return rawUnix < 1e12 ? rawUnix * 1000 : rawUnix
  }
  if (typeof entry.ts_iso === 'string') {
    const parsed = Date.parse(entry.ts_iso)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

function stringField(entry: TelemetryEntry, key: string): string | undefined {
  const v = entry[key]
  return typeof v === 'string' && v.length > 0 ? v : undefined
}

// Pure deriver — separated from the component so it can be structurally
// unit-tested without rendering. Groups A2A events by keeper within the
// given window and returns rows sorted by first-event time.
export function deriveTimelineRows(
  entries: readonly TelemetryEntry[],
  windowStart: number,
  windowEnd: number,
): TimelineRow[] {
  if (windowEnd <= windowStart) return []
  const byKeeper = new Map<string, TimelineChip[]>()
  for (const entry of entries) {
    if (entry.source !== 'oas_event') continue
    const eventType = stringField(entry, 'event_type')
    if (!eventType) continue
    if (!(A2A_EVENT_TYPES as ReadonlyArray<string>).includes(eventType)) continue
    const ts = entryTimestampMs(entry)
    if (ts === null || ts < windowStart || ts > windowEnd) continue
    const keeper = stringField(entry, 'agent_name') ?? stringField(entry, 'keeper_name')
    if (!keeper) continue
    const chip: TimelineChip = {
      ts,
      eventType,
      kind: kindOfEventType(eventType),
      taskId: stringField(entry, 'task_id'),
      peerAgent:
        stringField(entry, 'to_agent') ??
        stringField(entry, 'from_agent'),
    }
    const list = byKeeper.get(keeper)
    if (list) list.push(chip)
    else byKeeper.set(keeper, [chip])
  }
  const rows: TimelineRow[] = []
  for (const [keeper, chips] of byKeeper) {
    chips.sort((a, b) => a.ts - b.ts)
    rows.push({ keeper, chips })
  }
  rows.sort((a, b) => {
    const aFirst = a.chips[0]?.ts ?? Number.POSITIVE_INFINITY
    const bFirst = b.chips[0]?.ts ?? Number.POSITIVE_INFINITY
    return aFirst - bFirst || a.keeper.localeCompare(b.keeper)
  })
  return rows
}

interface Props {
  windowMs?: number
  pollMs?: number
  maxEntries?: number
  onSelectKeeper?: (name: string) => void
  selectedKeeper?: string | null
}

export function HandoffTimeline({
  windowMs = 5 * 60 * 1000,
  pollMs = 5000,
  maxEntries = 500,
  onSelectKeeper,
  selectedKeeper = null,
}: Props = {}) {
  const [entries, setEntries] = useState<TelemetryEntry[]>([])
  const [error, setError] = useState<string | null>(null)
  const [now, setNow] = useState<number>(() => Date.now())
  const latestRequestId = useRef(0)

  useEffect(() => {
    let cancelled = false
    const controller = new AbortController()
    async function tick() {
      const requestId = ++latestRequestId.current
      try {
        const res = await fetchTelemetry({
          source: 'oas_event',
          n: maxEntries,
          signal: controller.signal,
        })
        if (cancelled || requestId !== latestRequestId.current) return
        setEntries(res.entries)
        setNow(Date.now())
        setError(null)
      } catch (e) {
        if (cancelled) return
        if ((e as Error).name === 'AbortError') return
        setError(e instanceof Error ? e.message : String(e))
      }
    }
    tick()
    const id = window.setInterval(tick, pollMs)
    return () => {
      cancelled = true
      controller.abort()
      window.clearInterval(id)
    }
  }, [pollMs, maxEntries])

  const windowEnd = now
  const windowStart = now - windowMs
  const rows = deriveTimelineRows(entries, windowStart, windowEnd)
  const span = windowEnd - windowStart

  return html`
    <section class="rounded-xl border border-card-border bg-card-bg p-4 flex flex-col gap-3">
      <header class="flex items-baseline justify-between">
        <div>
          <h3 class="text-sm font-semibold text-text">A2A Event Timeline</h3>
          <p class="text-[11px] text-text-muted">
            OAS event_bus → SSE relay. 최근 ${Math.round(windowMs / 1000 / 60)}분, keeper당 row.
          </p>
        </div>
        <div class="flex gap-2 text-[10px] text-text-muted">
          <span class="flex items-center gap-1">
            <span class="w-2 h-2 rounded-full bg-emerald-400"></span>lifecycle
          </span>
          <span class="flex items-center gap-1">
            <span class="w-2 h-2 rounded-full bg-sky-400"></span>tool
          </span>
          <span class="flex items-center gap-1">
            <span class="w-2 h-2 rounded-full bg-orange-400"></span>handoff
          </span>
          <span class="flex items-center gap-1">
            <span class="w-2 h-2 rounded-full bg-purple-400"></span>context
          </span>
          <span class="flex items-center gap-1">
            <span class="w-2 h-2 rounded-full bg-red-400"></span>failure
          </span>
        </div>
      </header>
      ${error !== null
        ? html`<p class="text-[11px] text-red-400">오류: ${error}</p>`
        : rows.length === 0
          ? html`<p class="text-[11px] text-text-dim">이 시간 범위에 A2A 이벤트 없음.</p>`
          : html`
              <div class="flex flex-col gap-1">
                ${rows.map(row => {
                  const isSelected = selectedKeeper === row.keeper
                  const labelCls = isSelected
                    ? 'text-text ring-1 ring-accent bg-accent/10'
                    : 'text-text-muted hover:text-text hover:bg-bg-1/60'
                  const clickable = typeof onSelectKeeper === 'function'
                  const rowLabelCls =
                    `w-32 shrink-0 truncate text-[11px] font-mono rounded px-1 ${labelCls}` +
                    (clickable ? ' cursor-pointer' : '')
                  return html`
                  <div class="flex items-center gap-3">
                    <div
                      class=${rowLabelCls}
                      title=${row.keeper}
                      onClick=${() => onSelectKeeper?.(row.keeper)}
                    >
                      ${row.keeper}
                    </div>
                    <div class="relative flex-1 h-6 rounded-md bg-bg-1/40 border border-card-border/50">
                      ${row.chips.map(chip => {
                        const pct = ((chip.ts - windowStart) / span) * 100
                        const cls = CHIP_CLASS_BY_KIND[chip.kind]
                        const peer = chip.peerAgent ? ` · ${chip.peerAgent}` : ''
                        const task = chip.taskId ? ` · ${chip.taskId}` : ''
                        return html`
                          <span
                            class="absolute top-1 bottom-1 w-[2px] ${cls} hover:w-1 transition-all cursor-default"
                            style=${`left: ${pct}%;`}
                            title=${`${new Date(chip.ts).toLocaleTimeString()} · ${chip.eventType}${peer}${task}`}
                          ></span>
                        `
                      })}
                    </div>
                  </div>
                `
                })}
              </div>
            `}
    </section>
  `
}
