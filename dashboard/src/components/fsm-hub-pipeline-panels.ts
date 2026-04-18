import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'

import type { KeeperCompositeSnapshot } from '../api/keeper'

import {
  type CompositeObservation,
  type InsightTone,
  type ObservedLaneSummary,
  type StateEntries,
  fmtDuration,
  displayState,
} from './fsm-hub-types'
import { deriveOperationalInsight } from './fsm-hub-invariant-analysis'
import { deriveObservedLaneSummaries } from './fsm-hub-lane-analysis'
import { deriveSwimlaneSegments } from './fsm-hub-derivations'
import { CytoscapeFsm } from './common/cytoscape-fsm'
import { buildCompositeFsmSpec } from './keeper-fsm-specs'

/**
 * Pure filter for observed lane summaries shown in the Operator Meaning
 * grid (KTC/KDP/KCL/KMC + phase lanes).
 *
 * Case-insensitive substring match on `lane.field`, `lane.label`,
 * `lane.value`, and `lane.meaning` in that order so operators can isolate
 * one sub-FSM by its short code (`KCL`), by its Korean label
 * (`캐스케이드`), by the current state value (`trying`, `idle`), or by a
 * keyword in the explanatory meaning.
 *
 * Empty/whitespace query returns the input reference unchanged so
 * `useMemo` keeps referential equality for the non-filtering path.
 *
 * Input is never mutated.
 */
export function filterObservedLanes(
  lanes: readonly ObservedLaneSummary[],
  query: string,
): readonly ObservedLaneSummary[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return lanes
  return lanes.filter(lane => {
    if (lane.field.toLowerCase().includes(needle)) return true
    if (lane.label.toLowerCase().includes(needle)) return true
    if (lane.value.toLowerCase().includes(needle)) return true
    if (lane.meaning.toLowerCase().includes(needle)) return true
    return false
  })
}

const INSIGHT_BADGE_CLS: Record<InsightTone, string> = {
  ok: 'text-[#22c55e] border-[rgba(34,197,94,0.3)] bg-[rgba(34,197,94,0.08)]',
  info: 'text-[var(--accent)] border-[var(--accent-30)] bg-[var(--accent-10)]',
  warn: 'text-[#f59e0b] border-[rgba(245,158,11,0.3)] bg-[rgba(245,158,11,0.08)]',
  error: 'text-[#ef4444] border-[rgba(239,68,68,0.3)] bg-[rgba(239,68,68,0.08)]',
}

/** Panel-level accent -- border + subtle tinted overlay -- so that the
    overall tone of the current operator insight is visible from the
    peripheral visual field. */
const INSIGHT_PANEL_CLS: Record<InsightTone, string> = {
  ok: 'border-[var(--white-8)] bg-[var(--white-2)]',
  info: 'border-[var(--white-8)] bg-[var(--white-2)]',
  warn: 'border-[rgba(245,158,11,0.45)] bg-[rgba(245,158,11,0.04)] shadow-[0_0_0_1px_rgba(245,158,11,0.15)_inset]',
  error: 'border-[rgba(239,68,68,0.55)] bg-[rgba(239,68,68,0.05)] shadow-[0_0_0_1px_rgba(239,68,68,0.2)_inset]',
}

export function OperationalMeaningPanel({
  snapshot,
  observations,
  now,
}: {
  snapshot: KeeperCompositeSnapshot
  observations: CompositeObservation[]
  now: number
}) {
  const lanes = deriveObservedLaneSummaries(snapshot, observations, now)
  const insight = deriveOperationalInsight(snapshot, observations, now, lanes)
  const panelCls = INSIGHT_PANEL_CLS[insight.tone]
  const isAlarm = insight.tone === 'warn' || insight.tone === 'error'

  const [query, setQuery] = useState('')
  const visibleLanes = useMemo(
    () => filterObservedLanes(lanes, query),
    [lanes, query],
  )
  const isFiltering = query.trim() !== ''

  return html`
    <div
      class=${`rounded-xl border p-4 transition-colors duration-300 ${panelCls}`}
      role=${isAlarm ? 'alert' : undefined}
      aria-live=${isAlarm ? 'polite' : undefined}
    >
      <div class="flex items-start justify-between gap-3 flex-wrap">
        <div class="min-w-0">
          <div class="text-[10px] font-semibold uppercase tracking-[0.1em] text-[var(--text-muted)]">Operator Meaning</div>
          <div class="mt-1 text-[18px] font-semibold text-[var(--text-strong)]">${insight.headline}</div>
          <div class="mt-1 text-[11px] text-[var(--text-dim)] leading-relaxed">${insight.detail}</div>
        </div>
        <span class=${`rounded-full border px-2.5 py-0.5 text-[10px] font-mono ${INSIGHT_BADGE_CLS[insight.tone]}`}>
          ${insight.tone}
        </span>
      </div>

      <div class="mt-2 text-[10px] text-[var(--text-body)]">
        <span class="font-semibold text-[var(--text-muted)]">Next:</span> ${insight.nextStep}
      </div>

      <div class="mt-2 flex flex-wrap gap-1.5">
        ${insight.evidence.map(item => html`
          <span class="rounded-full border border-[var(--white-8)] px-2 py-0.5 text-[10px] font-mono text-[var(--text-dim)]">
            ${item}
          </span>
        `)}
      </div>

      <div class="mt-4 flex items-center justify-between gap-2">
        <div class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
          관찰 레인
        </div>
        <input
          type="search"
          value=${query}
          placeholder="field / label / state / meaning 필터"
          aria-label="관찰 레인 필터"
          onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
          class="min-w-[160px] max-w-[260px] flex-1 rounded-md border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-[11px] text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)]"
        />
      </div>

      ${isFiltering && visibleLanes.length === 0 && lanes.length > 0
        ? html`<div class="mt-2 py-4 text-center text-[11px] text-[var(--text-dim)]">필터 결과 없음 (${lanes.length} lanes)</div>`
        : html`
          <div class="mt-2 grid gap-2 md:grid-cols-2 xl:grid-cols-5">
            ${visibleLanes.map(lane => html`
              <div class="rounded-lg border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2">
                <div class="flex items-center justify-between gap-2">
                  <span class="text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">${lane.field}</span>
                  <span class=${`rounded-full border px-1.5 py-0.5 text-[8px] font-mono ${INSIGHT_BADGE_CLS[lane.tone]}`}>
                    ${fmtDuration(lane.observedForSec)}
                  </span>
                </div>
                <div class="mt-1 font-mono text-[13px] font-semibold text-[var(--text-strong)]">${lane.value}</div>
                <div class="mt-0.5 text-[10px] text-[var(--text-dim)]">${lane.label}</div>
                <div class="mt-1.5 text-[10px] leading-relaxed text-[var(--text-body)]">${lane.meaning}</div>
                <div class="mt-1 text-[8px] font-mono text-[var(--text-dim)]">
                  ${lane.transitionCount} observed edge${lane.transitionCount === 1 ? '' : 's'}
                </div>
              </div>
            `)}
          </div>
        `}
    </div>
  `
}

const PHASE_BAR_FILL: Record<string, string> = {
  Running: '#22c55e',
  Overflowed: '#f59e0b',
  Compacting: '#f59e0b',
  HandingOff: '#a78bfa',
  Failing: '#ef4444',
  Draining: '#fbbf24',
  Stable: '#71717a',
}

function PhaseSparkline({
  observations,
  now,
}: {
  observations: CompositeObservation[]
  now: number
}) {
  const segments = useMemo(
    () => deriveSwimlaneSegments(observations, 'phase', now),
    [observations, now],
  )
  if (segments.length < 2) return null

  const W = 120
  const H = 16
  const gap = 1
  const totalDuration = segments.reduce((s, seg) => s + Math.max(0, seg.to - seg.from), 0)
  if (totalDuration <= 0) return null

  let x = 0
  const bars = segments.map((seg, i) => {
    const dur = Math.max(0, seg.to - seg.from)
    const w = Math.max(1, (dur / totalDuration) * (W - (segments.length - 1) * gap))
    const fill = PHASE_BAR_FILL[seg.value] ?? '#47b8ff'
    const barX = x
    x += w + gap
    const isLast = i === segments.length - 1
    return { x: barX, w, fill, phase: seg.value, dur, isLast }
  })

  return html`
    <div class="mt-2 flex items-center gap-2">
      <span class="text-[8px] text-[var(--text-dim)]">phase</span>
      <svg
        width=${W} height=${H}
        viewBox=${`0 0 ${W} ${H}`}
        class="shrink-0"
        role="img"
        aria-label="Phase duration sparkline"
      >
        ${bars.map((b) => html`
          <rect
            x=${b.x} y=${0} width=${b.w} height=${H}
            fill=${b.fill}
            opacity=${b.isLast ? 1 : 0.7}
            rx=${1}
          >
            <title>${displayState(b.phase)} ${fmtDuration(b.dur)}</title>
          </rect>
        `)}
      </svg>
    </div>
  `
}

/** Human-readable descriptions for sub-FSM states.
    Shown as native title tooltips on hover. */
const STATE_DESCRIPTIONS: Record<string, string> = {
  // KTC (Turn Cycle)
  idle: 'Waiting for the next heartbeat cycle to start a turn',
  prompting: 'Building the LLM prompt with context and tools',
  executing: 'LLM is generating a response or calling tools',
  compacting: 'Compressing context to fit within the window',
  finalizing: 'Post-turn cleanup: checkpoint save, metrics emit',
  // KDP (Decision Pipeline)
  undecided: 'No decision made yet — waiting for the turn to start',
  guard_ok: 'All safety guards passed, proceeding to tool execution',
  gate_rejected: 'A safety gate blocked the action (cost, deny list, etc.)',
  tool_policy_selected: 'Tool policy has been applied, tools filtered',
  // KCL (Cascade)
  selecting: 'Choosing the best provider from the cascade list',
  trying: 'Attempting inference with the selected provider',
  done: 'Provider responded successfully',
  exhausted: 'All providers in the cascade failed',
  // KMC (Compaction)
  accumulating: 'Collecting messages; context not yet full',
  // KSM (Phase) — used in Hero
  Running: 'Keeper is actively running turns',
  Overflowed: 'Prompt overflowed the provider context window; recovery is pending',
  Compacting: 'Compacting context to reclaim token budget',
  HandingOff: 'Transferring state to the next generation',
  Failing: 'Experiencing errors, will retry or recover',
  Draining: 'Finishing current work before shutdown',
  Stable: 'Outside the active turn cycle; idle terminal or quiescent parent phases collapse here',
}

export function HeroPhase({
  snapshot,
  observations,
  phaseSince,
  now,
}: {
  snapshot: KeeperCompositeSnapshot
  phaseLog?: string[]
  observations: CompositeObservation[]
  phaseSince: number | null
  now: number
}) {
  const prevRef = useRef(snapshot.phase)
  const [flash, setFlash] = useState(false)
  useEffect(() => {
    if (prevRef.current !== snapshot.phase) {
      prevRef.current = snapshot.phase
      setFlash(true)
      const id = setTimeout(() => setFlash(false), 2000)
      return () => clearTimeout(id)
    }
    return undefined
  }, [snapshot.phase])

  const phaseColor: Record<string, string> = {
    Running: 'text-[var(--ok)]',
    Overflowed: 'text-[var(--warn)]',
    Compacting: 'text-[var(--warn)]',
    HandingOff: 'text-violet-400',
    Failing: 'text-[var(--bad-light)]',
    Stable: 'text-[var(--text-dim)]',
  }
  const color = phaseColor[snapshot.phase] ?? 'text-[var(--accent)]'
  const heldFor = phaseSince != null ? fmtDuration(Math.max(0, now - phaseSince)) : null

  return html`
    <div class=${`rounded-xl border p-5 transition-all duration-700 ${flash ? 'border-[var(--accent)] bg-[rgba(71,184,255,0.06)] shadow-[0_0_16px_rgba(71,184,255,0.2)]' : 'border-[var(--white-8)] bg-[var(--white-2)]'}`}
      role="status" aria-live="polite" aria-label=${`Keeper 상태: ${displayState(snapshot.phase)}${heldFor ? `, ${heldFor}` : ''}`}
      title=${STATE_DESCRIPTIONS[snapshot.phase] ?? snapshot.phase}
    >
      <div class="flex items-baseline justify-between">
        <div>
          <div class="text-[10px] font-semibold tracking-[0.06em] text-[var(--text-muted)]" id="ksm-label">Keeper 생명주기 <span class="font-mono text-[8px] text-[var(--text-dim)]">KSM</span></div>
          <div class=${`mt-1 font-mono text-[32px] font-bold tracking-tight ${color}`} aria-labelledby="ksm-label">
            ${displayState(snapshot.phase)}
          </div>
          <div class="mt-0.5 text-[10px] font-mono text-[var(--text-dim)]">${snapshot.phase}</div>
          ${heldFor ? html`
            <div class="mt-1 text-[10px] font-mono text-[var(--text-dim)]" aria-hidden="true">
              유지 <span class="text-[var(--text-body)]">${heldFor}</span>
            </div>
          ` : null}
        </div>
        ${flash ? html`<span class="text-[10px] text-[var(--accent)] animate-pulse font-mono" aria-live="assertive">상태 변경</span>` : null}
      </div>
      <${PhaseSparkline} observations=${observations} now=${now} />
    </div>
  `
}

export function PipelineStep({
  label,
  shortLabel,
  value,
  isLast,
  sinceTs,
  now,
  limited,
}: {
  label: string
  shortLabel: string
  value: string
  isLast?: boolean
  sinceTs: number | null
  now: number
  /** When true, this lane has limited observability — only a subset of
      states are derivable from the registry. Shown as a subtle indicator. */
  limited?: boolean
}) {
  const prevRef = useRef(value)
  const [flash, setFlash] = useState(false)
  useEffect(() => {
    if (prevRef.current !== value) {
      prevRef.current = value
      setFlash(true)
      const id = setTimeout(() => setFlash(false), 1200)
      return () => clearTimeout(id)
    }
    return undefined
  }, [value])

  const isActive = value !== 'idle' && value !== 'undecided' && value !== 'accumulating'
  const borderCls = flash
    ? 'border-[var(--accent)] shadow-[0_0_8px_rgba(71,184,255,0.35)]'
    : isActive
      ? 'border-[rgba(129,140,248,0.5)] shadow-[0_0_6px_rgba(129,140,248,0.15)]'
      : 'border-[var(--white-8)]'
  const bgCls = isActive && !flash
    ? 'bg-[rgba(129,140,248,0.04)]'
    : 'bg-[var(--white-2)]'
  const activePulse = isActive && !flash ? 'animate-pulse' : ''

  const connectorCls = isActive
    ? 'border-t border-dashed border-[rgba(129,140,248,0.5)] animate-[marching-ants_1s_linear_infinite]'
    : 'border-t border-[var(--white-10)]'

  const heldFor = sinceTs != null ? fmtDuration(Math.max(0, now - sinceTs)) : null
  const stalenessCls = (() => {
    if (!heldFor || sinceTs == null) return 'text-[var(--text-dim)]'
    const ageSec = now - sinceTs
    if (!isActive) {
      // idle 상태에서도 장기 대기를 시각적으로 구분
      if (ageSec > 600) return 'text-[var(--text-muted)]'
      return 'text-[var(--text-dim)]'
    }
    if (ageSec > 60) return 'text-[#f59e0b]'
    if (ageSec > 20) return 'text-[#facc15]'
    return 'text-[#818cf8]'
  })()

  return html`
    <div class="flex items-center gap-0 flex-1 min-w-0" role="listitem" aria-label=${`${label}: ${displayState(value)}${limited ? ' (관찰 제한)' : ''}${heldFor ? `, ${heldFor}` : ''}`}
      title=${`${label} (${shortLabel}): ${value} → ${displayState(value)}${heldFor ? ` · ${heldFor}` : ''}${limited ? '\n⚠ 관찰 제한: 일부 상태만 registry에서 파생 가능 (#7122)' : ''}\n${STATE_DESCRIPTIONS[value] ?? ''}`}
    >
      <div class=${`flex-1 rounded-lg border px-3 py-2 transition-all duration-500 ${borderCls} ${bgCls} ${limited && !isActive ? 'opacity-60' : ''}`}>
        <div class="flex items-center justify-between gap-1.5">
          <div class="flex items-center gap-1.5 min-w-0">
            ${isActive ? html`<span class="h-1.5 w-1.5 rounded-full bg-[#818cf8] ${activePulse} shrink-0"></span>` : null}
            <span class="text-[10px] font-semibold tracking-[0.04em] text-[var(--text-muted)]">${label}</span>
            ${limited ? html`<span class="text-[7px] font-mono text-[var(--text-dim)] border border-[var(--white-10)] rounded px-1" title="Event_bus 구독 미구현으로 일부 상태만 관찰 가능">제한</span>` : null}
          </div>
          ${heldFor ? html`
            <span class=${`text-[10px] font-mono tabular-nums ${stalenessCls}`} aria-hidden="true">${heldFor}</span>
          ` : null}
        </div>
        <div class=${`mt-0.5 font-mono text-[13px] font-semibold ${isActive ? 'text-[var(--text-strong)]' : 'text-[var(--text-muted)]'} ${flash ? 'animate-pulse' : ''}`}>
          ${displayState(value)}
        </div>
        <div class="text-[8px] font-mono text-[var(--text-dim)] mt-0.5">${shortLabel} · ${value}</div>
      </div>
      ${!isLast ? html`<div class=${`hidden md:block w-5 shrink-0 ${connectorCls}`}></div>` : null}
    </div>
  `
}

export function TurnPipelineStrip({
  snapshot,
  stateEntries,
  now,
}: {
  snapshot: KeeperCompositeSnapshot
  stateEntries: StateEntries | null
  now: number
}) {
  return html`
    <div class="rounded-xl border border-[var(--white-8)] bg-[var(--white-2)] p-3">
      <div class="mb-2 text-[10px] font-semibold uppercase tracking-[0.08em] text-[var(--text-muted)]">
        턴 파이프라인
      </div>
      <div class="flex flex-col gap-1 md:flex-row md:gap-0 md:items-stretch" role="list" aria-label="턴 파이프라인 단계">
        <${PipelineStep} shortLabel="KTC" label="턴 주기" value=${snapshot.turn_phase} sinceTs=${stateEntries?.turn ?? null} now=${now} />
        <${PipelineStep} shortLabel="KDP" label="의사결정" value=${snapshot.decision.stage} sinceTs=${stateEntries?.decision ?? null} now=${now} limited />
        <${PipelineStep} shortLabel="KCL" label="캐스케이드" value=${snapshot.cascade.state} sinceTs=${stateEntries?.cascade ?? null} now=${now} limited />
        <${PipelineStep} shortLabel="KMC" label="컨텍스트 압축" value=${snapshot.compaction.stage} sinceTs=${stateEntries?.compaction ?? null} now=${now} isLast />
      </div>
    </div>
  `
}

export function CompositeGraphPanel({ snapshot }: { snapshot: KeeperCompositeSnapshot }) {
  const spec = useMemo(() => buildCompositeFsmSpec({
    phase: snapshot.phase,
    turnPhase: snapshot.turn_phase,
    decisionStage: snapshot.decision.stage,
    cascadeState: snapshot.cascade.state,
    compactionStage: snapshot.compaction.stage,
  }), [
    snapshot.phase,
    snapshot.turn_phase,
    snapshot.decision.stage,
    snapshot.cascade.state,
    snapshot.compaction.stage,
  ])

  return html`<${CytoscapeFsm} spec=${spec} height="320px" />`
}
