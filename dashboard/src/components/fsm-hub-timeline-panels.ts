import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect, useMemo, useRef } from 'preact/hooks'
import { DashedNotice } from './common/dashed-notice'

import {
  type CompositeObservation,
  type HoveredSegment,
  type LaneDwell,
  type LaneKey,
  type TopTransition,
  fmtDuration,
  displayState,
} from './fsm-hub-types'
import {
  deriveSwimlaneSegments,
  deriveTimeAxisTicks,
  inferTransitionReason,
  laneTransitionCount,
} from './fsm-hub-derivations'

const FIELD_COLOR: Record<string, string> = {
  KSM: 'text-[var(--accent)]',
  KTC: 'text-[var(--indigo)]',
  KDP: 'text-[var(--indigo)]',
  KCL: 'text-[var(--indigo)]',
  KMC: 'text-[var(--amber-bright)]',
}

const SWIMLANE_LANES: Array<{
  key: LaneKey
  label: string
  short: string
}> = [
  { key: 'phase', label: 'Keeper 생명주기', short: 'KSM' },
  { key: 'turn', label: '턴 주기', short: 'KTC' },
  { key: 'decision', label: '의사결정', short: 'KDP' },
  { key: 'cascade', label: '캐스케이드', short: 'KCL' },
  { key: 'compaction', label: '컨텍스트 압축', short: 'KMC' },
]

const IDLE_LIKE_VALUES = new Set([
  'idle',
  'undecided',
  'accumulating',
  'Stable',
])

const ALARM_VALUES = new Set([
  'Failing',
  'Overflowed',
  'gate_rejected',
  'exhausted',
])

export function swimlaneSegmentColor(value: string): string {
  if (ALARM_VALUES.has(value)) return 'bg-[rgba(239,68,68,0.5)]'
  if (IDLE_LIKE_VALUES.has(value)) return 'bg-[var(--white-7)]'
  if (value === 'Overflowed') return 'bg-[var(--amber-bright-45)]'
  if (value === 'Compacting' || value === 'compacting') return 'bg-[var(--amber-bright-45)]'
  if (value === 'HandingOff') return 'bg-[var(--purple-50)]'
  return 'bg-[var(--indigo-45)]'
}

/** Keyboard navigation across swimlane segments.
    ArrowLeft/Right: move within the same lane.
    ArrowUp/Down: move to the adjacent lane, preserving segment index
    (clamped to the target lane's segment count).
    Home/End: jump to the first/last segment of the current lane. */
function handleSwimlaneKey(
  ev: KeyboardEvent,
  laneIndex: number,
  segIndex: number,
): void {
  const target = ev.currentTarget
  if (!(target instanceof HTMLElement)) return
  const root = target.closest('[data-fsm-swimlane-root]')
  if (!root) return
  const findButton = (ln: number, sg: number): HTMLElement | null =>
    root.querySelector<HTMLElement>(
      `button[data-lane-index="${ln}"][data-seg-index="${sg}"]`,
    )
  const lastSeg = (ln: number): number => {
    const items = root.querySelectorAll<HTMLElement>(`button[data-lane-index="${ln}"]`)
    return items.length - 1
  }
  let nextLane = laneIndex
  let nextSeg = segIndex
  switch (ev.key) {
    case 'ArrowLeft':
      nextSeg = Math.max(0, segIndex - 1)
      break
    case 'ArrowRight':
      nextSeg = Math.min(lastSeg(laneIndex), segIndex + 1)
      break
    case 'ArrowUp':
      nextLane = Math.max(0, laneIndex - 1)
      nextSeg = Math.min(lastSeg(nextLane), segIndex)
      break
    case 'ArrowDown':
      nextLane = Math.min(SWIMLANE_LANES.length - 1, laneIndex + 1)
      nextSeg = Math.min(lastSeg(nextLane), segIndex)
      break
    case 'Home':
      nextSeg = 0
      break
    case 'End':
      nextSeg = lastSeg(laneIndex)
      break
    default:
      return
  }
  if (nextLane === laneIndex && nextSeg === segIndex) return
  ev.preventDefault()
  findButton(nextLane, nextSeg)?.focus()
}

export function SwimlaneTimeline({
  observations,
  now,
  hoveredSegment,
  onHoverSegment,
}: {
  observations: CompositeObservation[]
  now: number
  hoveredSegment: HoveredSegment | null
  onHoverSegment: (seg: HoveredSegment | null) => void
}) {
  if (observations.length === 0) {
    return html`
      <${DashedNotice} borderTone="subtle">
        30초 폴링 사이클에서 관측을 수집중 — 2회 이상 스냅샷이 쌓이면 5개 레인의 시간 흐름이 표시됩니다
      <//>
    `
  }
  const first = observations[0]
  if (!first) return null
  const spanStart = first.ts
  const spanEnd = Math.max(now, observations[observations.length - 1]?.ts ?? now)
  const spanWidth = Math.max(1, spanEnd - spanStart)
  const windowDuration = fmtDuration(Math.max(0, spanEnd - spanStart))
  const ticks = deriveTimeAxisTicks(spanStart, spanEnd)
  const showSeconds = spanWidth < 600
  const absFormatter = new Intl.DateTimeFormat(undefined, {
    hour: '2-digit',
    minute: '2-digit',
    ...(showSeconds ? { second: '2-digit' } : {}),
    hour12: false,
  })
  const fmtAbs = (ts: number) => absFormatter.format(new Date(ts * 1000))
  const laneDensity: Record<string, number> = {}
  let busiestLane = ''
  let busiestCount = 0
  for (const lane of SWIMLANE_LANES) {
    const count = laneTransitionCount(observations, lane.key)
    laneDensity[lane.short] = count
    if (count > busiestCount) {
      busiestLane = lane.short
      busiestCount = count
    }
  }

  return html`
    <div class="rounded border border-[var(--white-8)] bg-[var(--white-2)] p-3" data-fsm-swimlane-root="true">
      <div class="mb-2 flex items-baseline justify-between gap-3 flex-wrap">
        <div class="text-3xs font-semibold uppercase tracking-1 text-[var(--text-muted)]">
          상태 타임라인
        </div>
        <div class="flex items-center gap-1 flex-wrap">
          ${SWIMLANE_LANES.map(lane => {
            const count = laneDensity[lane.short] ?? 0
            const isBusiest = busiestLane === lane.short && count > 0
            return html`
              <span
                class=${`rounded-sm border px-1.5 py-0.5 text-3xs font-mono tabular-nums ${
                  count === 0
                    ? 'text-[var(--text-dim)] border-[var(--white-8)]'
                    : isBusiest
                      ? 'text-[var(--indigo)] border-[var(--indigo-40)] bg-[rgba(129,140,248,0.08)]'
                      : 'text-[var(--text-body)] border-[var(--white-10)]'
                }`}
                title=${`${lane.label} · ${count} transition${count === 1 ? '' : 's'} in this window`}
              >${lane.short} ${count}</span>
            `
          })}
        </div>
        <div class="text-3xs font-mono text-[var(--text-dim)]">
          <span>${fmtAbs(spanStart)}</span>
          <span class="mx-1 text-[var(--text-muted)]">→</span>
          <span>${fmtAbs(spanEnd)}</span>
          · window <span class="text-[var(--text-body)]">${windowDuration}</span>
          · <span class="text-[var(--text-body)]">${observations.length}</span> obs
        </div>
      </div>
      <div class="flex flex-col gap-1.5">
        ${SWIMLANE_LANES.map((lane, laneIndex) => {
          const segments = deriveSwimlaneSegments(observations, lane.key, spanEnd)
          return html`
            <div class="flex items-center gap-2">
              <div class="w-11 shrink-0 text-3xs font-mono font-semibold text-[var(--text-muted)]">
                ${lane.short}
              </div>
              <div class="flex h-4 flex-1 overflow-hidden rounded border border-[var(--white-8)]" role="group" aria-label=${`${lane.label} swimlane with ${segments.length} segments`}>
                ${segments.map((seg, segIndex) => {
                  const pct = ((seg.to - seg.from) / spanWidth) * 100
                  const holdFor = fmtDuration(Math.max(0, seg.to - seg.from))
                  const isHovered =
                    hoveredSegment != null &&
                    hoveredSegment.laneKey === lane.key &&
                    hoveredSegment.from === seg.from &&
                    hoveredSegment.to === seg.to
                  const dimmed = hoveredSegment != null && !isHovered
                  const ariaLabel = `${lane.label}, ${displayState(seg.value)}, ${fmtAbs(seg.from)} ~ ${fmtAbs(seg.to)}, ${holdFor}`
                  return html`
                    <button type="button"
                      data-fsm-swimlane="true"
                      data-lane-key=${lane.key}
                      data-lane-index=${laneIndex}
                      data-seg-index=${segIndex}
                      class=${`${swimlaneSegmentColor(seg.value)} h-full transition-all duration-200 border-r border-[rgba(0,0,0,0.25)] last:border-r-0 cursor-pointer focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent)] focus-visible:ring-inset ${isHovered ? 'ring-1 ring-[var(--accent)] brightness-125' : ''} ${dimmed ? 'opacity-40' : ''}`}
                      style=${`width: ${pct.toFixed(2)}%`}
                      title=${`${lane.label} (${lane.short}) · ${displayState(seg.value)} (${seg.value})\n${fmtAbs(seg.from)} → ${fmtAbs(seg.to)} · ${holdFor}`}
                      aria-label=${ariaLabel}
                      onmouseenter=${() => onHoverSegment({ field: lane.short, laneKey: lane.key, from: seg.from, to: seg.to, value: seg.value })}
                      onmouseleave=${() => onHoverSegment(null)}
                      onfocus=${() => onHoverSegment({ field: lane.short, laneKey: lane.key, from: seg.from, to: seg.to, value: seg.value })}
                      onblur=${() => onHoverSegment(null)}
                      onkeydown=${(ev: KeyboardEvent) => handleSwimlaneKey(ev, laneIndex, segIndex)}
                    ></button>
                  `
                })}
              </div>
            </div>
          `
        })}
      </div>
      ${ticks.length > 0 ? html`
        <div class="mt-1 flex items-center gap-2" aria-hidden="true">
          <div class="w-11 shrink-0"></div>
          <div class="relative flex-1 h-3">
            ${ticks.map(tick => {
              const leftPct = ((tick.ts - spanStart) / spanWidth) * 100
              return html`
                <div
                  class="absolute top-0 flex flex-col items-center text-[var(--text-dim)]"
                  style=${`left: ${leftPct.toFixed(2)}%; transform: translateX(-50%)`}
                >
                  <div class="h-1 w-px bg-[var(--white-10)]"></div>
                  <div class="text-4xs font-mono leading-none mt-0.5">${tick.label}</div>
                </div>
              `
            })}
          </div>
        </div>
      ` : null}
      ${observations.length > 1 ? html`
        <div class="mt-0.5 flex items-center gap-2" aria-hidden="true">
          <div class="w-11 shrink-0 text-4xs text-[var(--text-dim)] text-right">obs</div>
          <div class="relative flex-1 h-2.5">
            ${observations.map((obs, obsIndex) => {
              const leftPct = ((obs.ts - spanStart) / spanWidth) * 100
              const prev = obsIndex > 0 ? observations[obsIndex - 1] : null
              const hasTransition = prev != null && (
                prev.phase !== obs.phase ||
                prev.turn !== obs.turn ||
                prev.decision !== obs.decision ||
                prev.cascade !== obs.cascade ||
                prev.compaction !== obs.compaction
              )
              const dotCls = hasTransition
                ? 'bg-[var(--indigo)] ring-1 ring-[var(--indigo-40)]'
                : 'bg-[var(--white-10)]'
              const changedLanes = prev == null ? [] : [
                ...(prev.phase !== obs.phase ? ['KSM'] : []),
                ...(prev.turn !== obs.turn ? ['KTC'] : []),
                ...(prev.decision !== obs.decision ? ['KDP'] : []),
                ...(prev.cascade !== obs.cascade ? ['KCL'] : []),
                ...(prev.compaction !== obs.compaction ? ['KMC'] : []),
              ]
              const tip = `${fmtAbs(obs.ts)}${changedLanes.length > 0 ? ` · ${changedLanes.join(', ')} changed` : ' · no change'}`
              return html`
                <div
                  class=${`absolute top-1/2 -translate-y-1/2 h-1.5 w-1.5 rounded-full ${dotCls} transition-all duration-200`}
                  style=${`left: ${leftPct.toFixed(2)}%`}
                  title=${tip}
                ></div>
              `
            })}
          </div>
        </div>
      ` : null}
      <div class="mt-2 flex flex-wrap items-center gap-2 text-3xs text-[var(--text-dim)]" aria-label="상태 범례">
        <span class="flex items-center gap-1"><span class="inline-block h-2 w-3 rounded-sm bg-[var(--indigo-45)]" aria-hidden="true"></span>active</span>
        <span class="flex items-center gap-1"><span class="inline-block h-2 w-3 rounded-sm bg-[var(--amber-bright-45)]" aria-hidden="true"></span>compact</span>
        <span class="flex items-center gap-1"><span class="inline-block h-2 w-3 rounded-sm bg-[var(--purple-50)]" aria-hidden="true"></span>handoff</span>
        <span class="flex items-center gap-1"><span class="inline-block h-2 w-3 rounded-sm bg-[rgba(239,68,68,0.5)]" aria-hidden="true"></span>alarm</span>
        <span class="flex items-center gap-1"><span class="inline-block h-2 w-3 rounded-sm border border-[var(--white-8)] bg-[var(--white-3)]" aria-hidden="true"></span>idle</span>
      </div>
    </div>
  `
}

export function isTransitionInSegment(
  entry: { ts: number; field: string },
  segment: HoveredSegment | null,
): boolean {
  if (!segment) return false
  if (entry.field !== segment.field) return false
  return entry.ts >= segment.from && entry.ts <= segment.to
}

export type TransitionHistoryEntry = {
  ts: number
  from: string
  to: string
  field: string
}

/**
 * Pure filter for transition history entries shown in the Transition
 * History trail.
 *
 * Case-insensitive substring match on `entry.field`, `entry.from`, and
 * `entry.to` in that order so operators can isolate one lane (e.g.
 * `KCL`), or every transition that landed on / departed from a specific
 * state (e.g. `trying`, `idle`, `Overflowed`).
 *
 * Empty/whitespace query returns the input reference unchanged so
 * `useMemo` keeps referential equality for the non-filtering path.
 *
 * Input is never mutated.
 */
export function filterTransitionHistory(
  history: readonly TransitionHistoryEntry[],
  query: string,
): readonly TransitionHistoryEntry[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return history
  return history.filter(entry => {
    if (entry.field.toLowerCase().includes(needle)) return true
    if (entry.from.toLowerCase().includes(needle)) return true
    if (entry.to.toLowerCase().includes(needle)) return true
    return false
  })
}

export function TransitionTrail({
  history,
  now,
  hoveredSegment,
}: {
  history: TransitionHistoryEntry[]
  now: number
  hoveredSegment: HoveredSegment | null
}) {
  const scrollRef = useRef<HTMLDivElement | null>(null)
  const query = useSignal('')
  const visibleHistory = useMemo(
    () => filterTransitionHistory(history, query.value),
    [history, query.value],
  )
  const isFiltering = query.value.trim() !== ''
  const firstMatchIndex = useMemo(() => {
    if (!hoveredSegment) return -1
    return visibleHistory.findIndex(entry => isTransitionInSegment(entry, hoveredSegment))
  }, [visibleHistory, hoveredSegment])

  useEffect(() => {
    if (firstMatchIndex < 0) return
    const container = scrollRef.current
    if (!container) return
    const target = container.querySelector<HTMLElement>(`[data-trail-index="${firstMatchIndex}"]`)
    if (!target) return
    target.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
  }, [firstMatchIndex])

  if (history.length === 0) {
    return html`
      <${DashedNotice} borderTone="subtle">
        아직 상태 전이가 관측되지 않았습니다 — 키퍼가 턴을 시작하거나 phase가 변경되면 자동으로 기록됩니다
      <//>
    `
  }

  return html`
    <div class="rounded border border-[var(--white-8)] bg-[var(--white-2)] px-3 py-2">
      <div class="mb-1.5 flex items-center justify-between gap-2">
        <div class="text-3xs font-semibold uppercase tracking-1 text-[var(--text-muted)]">
          Transition History (${isFiltering ? `${visibleHistory.length}/${history.length}` : history.length})
        </div>
        <input
          type="search"
          value=${query.value}
          placeholder="field / from / to 필터"
          aria-label="전이 이력 필터"
          onInput=${(e: Event) => { query.value = (e.target as HTMLInputElement).value }}
          class="min-w-30 max-w-50 flex-1 rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-0.5 text-3xs text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)]"
        />
      </div>
      ${isFiltering && visibleHistory.length === 0
        ? html`<div class="py-3 text-center text-3xs text-[var(--text-dim)]" role="status">필터 결과 없음 (${history.length} items)</div>`
        : html`
      <div ref=${scrollRef} class="flex flex-col gap-0.5 max-h-30 overflow-y-auto custom-scrollbar">
        ${visibleHistory.map((entry, trailIndex) => {
          const ago = fmtDuration(Math.max(0, now - entry.ts))
          const color = FIELD_COLOR[entry.field] ?? 'text-[var(--text-body)]'
          const inSegment = isTransitionInSegment(entry, hoveredSegment)
          const dimmed = hoveredSegment != null && !inSegment
          const rowCls = inSegment
            ? 'bg-[var(--accent-10)] ring-1 ring-[var(--accent-30)] rounded px-1'
            : ''
          const reason = inferTransitionReason(entry.field, entry.from, entry.to)
          const tooltip = reason
            ? `${entry.field}: ${entry.from} → ${entry.to}\n${reason}`
            : `${entry.field}: ${entry.from} → ${entry.to}`
          return html`
            <div
              data-trail-index=${trailIndex}
              title=${tooltip}
              class=${`flex items-center gap-2 text-3xs font-mono leading-tight transition-opacity duration-150 cursor-help ${dimmed ? 'opacity-40' : ''} ${rowCls}`}
            >
              <span class="w-[52px] shrink-0 text-right text-[var(--text-dim)]">${ago} ago</span>
              <span class=${`w-[28px] shrink-0 font-semibold ${color}`}>${entry.field}</span>
              <span class="text-[var(--text-dim)]">${entry.from}</span>
              <span class="text-[var(--text-muted)]">→</span>
              <span class="text-[var(--text-strong)]">${entry.to}</span>
              ${reason ? html`<span class="ml-1 text-4xs text-[var(--text-dim)] opacity-50">ⓘ</span>` : null}
            </div>
          `
        })}
      </div>
        `}
    </div>
  `
}

/** Top-N transition frequency ranking. Surfaces the (from → to) pairs the
    keeper takes most often inside the in-memory observation window — useful
    for spotting churn (e.g. KCL idle ↔ trying repeating means cascade is
    flapping) and for confirming the keeper exercises every lane it owns. */
export function TopTransitionsPanel({
  transitions,
  hoveredSegment,
}: {
  transitions: TopTransition[]
  hoveredSegment: HoveredSegment | null
}) {
  if (transitions.length === 0) {
    return html`
      <${DashedNotice} borderTone="subtle">
        반복되는 전이가 없습니다 — 관측이 더 쌓이거나 lane 변화가 발생하면 표시됩니다
      <//>
    `
  }

  const maxCount = transitions[0]?.count ?? 1

  return html`
    <div class="rounded border border-[var(--white-8)] bg-[var(--white-2)] px-3 py-2">
      <div class="mb-1.5 text-3xs font-semibold uppercase tracking-1 text-[var(--text-muted)]">
        Top Transitions (${transitions.length})
      </div>
      <div class="flex flex-col gap-0.5">
        ${transitions.map((entry) => {
          const color = FIELD_COLOR[entry.field] ?? 'text-[var(--text-body)]'
          const matchesHover =
            hoveredSegment != null && hoveredSegment.field === entry.field
          const dimmed = hoveredSegment != null && !matchesHover
          const widthPct = Math.max(4, Math.round((entry.count / maxCount) * 100))
          const rowCls = matchesHover
            ? 'bg-[var(--accent-10)] ring-1 ring-[var(--accent-30)] rounded px-1'
            : ''
          return html`
            <div
              class=${`flex items-center gap-2 text-3xs font-mono leading-tight transition-opacity duration-150 ${dimmed ? 'opacity-40' : ''} ${rowCls}`}
              title=${`${entry.field}: ${entry.from} → ${entry.to} (관측 ${entry.count}회)`}
            >
              <span class=${`w-[28px] shrink-0 font-semibold ${color}`}>${entry.field}</span>
              <span class="text-[var(--text-dim)]">${displayState(entry.from)}</span>
              <span class="text-[var(--text-muted)]">→</span>
              <span class="text-[var(--text-strong)]">${displayState(entry.to)}</span>
              <span class="ml-auto flex items-center gap-1.5 shrink-0">
                <span class="h-1 w-12 rounded-sm bg-[var(--white-8)] overflow-hidden"
                  role="progressbar"
                  aria-valuenow=${entry.count}
                  aria-valuemin="0"
                  aria-valuemax=${maxCount}
                  aria-label=${`${entry.state} ${entry.count}회`}
                >
                  <span
                    class="block h-full bg-[var(--accent)]"
                    style=${`width: ${widthPct}%`}
                  ></span>
                </span>
                <span class="w-[18px] text-right text-[var(--text-dim)]">${entry.count}</span>
              </span>
            </div>
          `
        })}
      </div>
    </div>
  `
}

const BAR_COLOR: Record<string, string> = {
  KSM: 'bg-[var(--accent)]',
  KTC: 'bg-[var(--indigo)]',
  KDP: 'bg-[var(--indigo)]',
  KCL: 'bg-[var(--indigo)]',
  KMC: 'bg-[var(--amber-bright)]',
}

export function DwellHistogramPanel({
  histograms,
  hoveredSegment,
}: {
  histograms: LaneDwell[]
  hoveredSegment: HoveredSegment | null
}) {
  if (histograms.length === 0) {
    return html`
      <${DashedNotice} borderTone="subtle">
        관측 데이터가 아직 없습니다 — 키퍼가 상태를 유지하면 체류 시간이 표시됩니다
      <//>
    `
  }

  return html`
    <div class="rounded border border-[var(--white-8)] bg-[var(--white-2)] px-3 py-2">
      <div class="mb-1.5 text-3xs font-semibold uppercase tracking-1 text-[var(--text-muted)]">
        State Dwell Time
      </div>
      <div class="flex flex-col gap-2">
        ${histograms.map((lane) => {
          const matchesHover = hoveredSegment != null && hoveredSegment.field === lane.field
          const dimmed = hoveredSegment != null && !matchesHover
          const color = FIELD_COLOR[lane.field] ?? 'text-[var(--text-body)]'
          const barColor = BAR_COLOR[lane.field] ?? 'bg-[var(--accent)]'
          return html`
            <div class=${`transition-opacity duration-150 ${dimmed ? 'opacity-40' : ''}`}>
              <div class="flex items-center gap-1.5 mb-0.5">
                <span class=${`text-3xs font-semibold ${color}`}>${lane.field}</span>
                <span class="text-3xs text-[var(--text-dim)]">${fmtDuration(lane.totalSeconds)}</span>
              </div>
              <div class="flex flex-col gap-px">
                ${lane.entries.map((entry) => {
                  const highlighted = hoveredSegment != null
                    && hoveredSegment.field === lane.field
                    && hoveredSegment.value === entry.value
                  const rowCls = highlighted
                    ? 'bg-[var(--accent-10)] ring-1 ring-[var(--accent-30)] rounded px-0.5'
                    : ''
                  return html`
                    <div
                      class=${`flex items-center gap-1.5 text-3xs font-mono leading-tight ${rowCls}`}
                      title=${`${displayState(entry.value)}: ${fmtDuration(entry.seconds)} (${entry.pct.toFixed(1)}%)`}
                    >
                      <span class="w-15 shrink-0 text-[var(--text-body)] truncate" title=${displayState(entry.value)}>${displayState(entry.value)}</span>
                      <span class="flex-1 h-1.5 rounded-sm bg-[var(--white-8)] overflow-hidden" role="progressbar" aria-valuenow=${Math.round(entry.pct)} aria-valuemin=${0} aria-valuemax=${100} aria-label=${`${displayState(entry.value)} 체류 비율`}>
                        <span
                          class=${`block h-full ${barColor}`}
                          style=${`width: ${Math.max(2, entry.pct)}%`}
                        ></span>
                      </span>
                      <span class="w-9 shrink-0 text-right text-3xs text-[var(--text-dim)]">${entry.pct.toFixed(0)}%</span>
                    </div>
                  `
                })}
              </div>
            </div>
          `
        })}
      </div>
    </div>
  `
}
