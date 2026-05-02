import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'

import type { KeeperCompositeSnapshot } from '../api/keeper'
import { nowSecondsSignal, useNowSecondsTicker } from '../lib/now-signal'

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
import { TextInput } from './common/input'
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
  ok: 'text-[var(--emerald)] border-[var(--emerald-30)] bg-[var(--emerald-8)]',
  info: 'text-[var(--color-accent-fg)] border-[var(--accent-30)] bg-[var(--accent-10)]',
  warn: 'text-[var(--warn-fg)] border-[var(--warn-border)] bg-[var(--warn-soft)]',
  error: 'text-[var(--color-status-err)] border-[var(--err-border)] bg-[var(--bad-soft)]',
}

/** Panel-level accent -- border + subtle tinted overlay -- so that the
    overall tone of the current operator insight is visible from the
    peripheral visual field. */
const INSIGHT_PANEL_CLS: Record<InsightTone, string> = {
  ok: 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)]',
  info: 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)]',
  warn: 'border-[var(--warn-border)] bg-[var(--warn-soft)] shadow-[0_0_0_1px_var(--warn-border)_inset]',
  error: 'border-[var(--err-border)] bg-[var(--bad-6)] shadow-[0_0_0_1px_var(--bad-20)_inset]',
}

export function OperationalMeaningPanel({
  snapshot,
  observations,
}: {
  snapshot: KeeperCompositeSnapshot
  observations: CompositeObservation[]
}) {
  useNowSecondsTicker()
  const now = nowSecondsSignal.value
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
      class=${`rounded-[var(--r-1)] border p-4 transition-colors duration-[var(--t-slow)] ${panelCls}`}
      role=${isAlarm ? 'alert' : undefined}
      aria-live=${isAlarm ? 'polite' : undefined}
    >
      <div class="flex items-start justify-between gap-3 flex-wrap">
        <div class="min-w-0">
          <div class="text-3xs font-semibold uppercase tracking-2 text-[var(--color-fg-muted)]">오퍼레이터 의미</div>
          <div class="mt-1 text-xl font-semibold text-[var(--color-fg-secondary)]">${insight.headline}</div>
          <div class="mt-1 text-2xs text-[var(--color-fg-disabled)] leading-relaxed">${insight.detail}</div>
        </div>
        <span class=${`rounded-[var(--r-0)] border px-2.5 py-0.5 text-3xs font-mono ${INSIGHT_BADGE_CLS[insight.tone]}`}>
          ${insight.tone}
        </span>
      </div>

      <div class="mt-2 text-3xs text-[var(--color-fg-primary)]">
        <span class="font-semibold text-[var(--color-fg-muted)]">Next:</span> ${insight.nextStep}
      </div>

      <div class="mt-2 flex flex-wrap gap-1.5">
        ${insight.evidence.map(item => html`
          <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] px-2 py-0.5 text-3xs font-mono text-[var(--color-fg-disabled)]">
            ${item}
          </span>
        `)}
      </div>

      <div class="mt-4 flex items-center justify-between gap-2">
        <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
          관찰 레인
        </div>
        <${TextInput}
          type="search"
          class="min-w-40 max-w-65 flex-1 !px-2 !py-1 !text-2xs"
          value=${query}
          placeholder="field / label / state / meaning 필터"
          ariaLabel="관찰 레인 필터"
          onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
        />
      </div>

      ${isFiltering && visibleLanes.length === 0 && lanes.length > 0
        ? html`<div class="mt-2 py-4 text-center text-2xs text-[var(--color-fg-disabled)]">필터 결과 없음 (${lanes.length} lanes)</div>`
        : html`
          <div class="mt-2 grid gap-2 md:grid-cols-2 xl:grid-cols-5">
            ${visibleLanes.map(lane => html`
              <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
                <div class="flex items-center justify-between gap-2">
                  <span class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${lane.field}</span>
                  <span class=${`rounded-[var(--r-0)] border px-1.5 py-0.5 text-3xs font-mono ${INSIGHT_BADGE_CLS[lane.tone]}`}>
                    ${fmtDuration(lane.observedForSec)}
                  </span>
                </div>
                <div class="mt-1 font-mono text-sm font-semibold text-[var(--color-fg-secondary)]">${lane.value}</div>
                <div class="mt-0.5 text-3xs text-[var(--color-fg-disabled)]">${lane.label}</div>
                <div class="mt-1.5 text-3xs leading-relaxed text-[var(--color-fg-primary)]">${lane.meaning}</div>
                <div class="mt-1 text-3xs font-mono text-[var(--color-fg-disabled)]">
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
  Running: 'var(--emerald)',
  Overflowed: 'var(--amber-bright)',
  Compacting: 'var(--amber-bright)',
  HandingOff: 'var(--purple)',
  Failing: 'var(--color-status-err)',
  Draining: 'var(--color-status-warn)',
  Stable: 'var(--color-fg-muted)',
}

function PhaseSparkline({
  observations,
}: {
  observations: CompositeObservation[]
}) {
  useNowSecondsTicker()
  const now = nowSecondsSignal.value
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
    const fill = PHASE_BAR_FILL[seg.value] ?? 'var(--color-accent-fg)'
    const barX = x
    x += w + gap
    const isLast = i === segments.length - 1
    return { x: barX, w, fill, phase: seg.value, dur, isLast }
  })

  return html`
    <div class="mt-2 flex items-center gap-2">
      <span class="text-3xs text-[var(--color-fg-disabled)]">phase</span>
      <svg
        width=${W} height=${H}
        viewBox=${`0 0 ${W} ${H}`}
        class="shrink-0"
        role="img"
        aria-label="단계 지속시간 스파크라인"
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
  idle: '다음 heartbeat cycle 까지 턴 시작 대기 중',
  prompting: '컨텍스트와 도구로 LLM 프롬프트 구성 중',
  executing: 'LLM 이 응답 생성 또는 도구 호출 중',
  compacting: '컨텍스트를 윈도우 안에 맞도록 압축 중',
  finalizing: '턴 후 정리: checkpoint 저장, 메트릭 발송',
  // KDP (Decision Pipeline)
  undecided: '아직 결정 없음 — 턴 시작 대기 중',
  guard_ok: '모든 safety guard 통과, 도구 실행으로 진행',
  gate_rejected: 'safety gate 가 행동 차단 (비용, deny list 등)',
  tool_policy_selected: '도구 목록 적용됨, 도구 필터링 완료',
  // KCL (Cascade)
  selecting: 'cascade 목록에서 최적 provider 선택 중',
  trying: '선택된 provider 로 inference 시도 중',
  done: 'Provider 가 정상 응답함',
  exhausted: 'cascade 의 모든 provider 실패',
  // KMC (Compaction)
  accumulating: '메시지 수집 중; 컨텍스트 아직 가득 차지 않음',
  // KSM (Phase) — used in Hero
  Running: '키퍼가 활성 상태로 턴 실행 중',
  Overflowed: '프롬프트가 provider 컨텍스트 윈도우 초과; 복구 대기',
  Compacting: '토큰 예산 회수를 위해 컨텍스트 압축 중',
  HandingOff: '다음 generation 으로 상태 이관 중',
  Failing: '에러 발생, 재시도 또는 복구 진행',
  Draining: '종료 전 현재 작업 마무리 중',
  Stable: '활성 턴 사이클 밖; idle terminal 또는 비활성 parent phase 가 여기로 collapse',
  running: '원시 키퍼 phase: runtime 이 활성 상태로 턴 실행 중',
  failing: '원시 키퍼 phase: 복구 / 재시도 처리 중',
  overflowed: '원시 키퍼 phase: provider 컨텍스트 overflow 압축 또는 clear 필요',
  handing_off: '원시 키퍼 phase: 상태 handoff 진행 중',
  draining: '원시 키퍼 phase: 종료 진행 중',
  offline: '원시 키퍼 phase: 키퍼가 아직 시작되지 않음',
  paused: '원시 키퍼 phase: 운영자 pause 또는 재시도 한계',
  stopped: '원시 키퍼 phase: clean terminal stop',
  crashed: '원시 키퍼 phase: crash, 재시작 또는 조사 필요',
  restarting: '원시 키퍼 phase: supervisor 재시작 흐름 활성',
  dead: '원시 키퍼 phase: 재시작 예산 소진',
}

export function HeroPhase({
  snapshot,
  observations,
  phaseSince,
}: {
  snapshot: KeeperCompositeSnapshot
  phaseLog?: string[]
  observations: CompositeObservation[]
  phaseSince: number | null
}) {
  useNowSecondsTicker()
  const now = nowSecondsSignal.value
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
    Running: 'text-[var(--color-status-ok)]',
    Overflowed: 'text-[var(--color-status-warn)]',
    Compacting: 'text-[var(--color-status-warn)]',
    HandingOff: 'text-[var(--color-accent-fg)]',
    Failing: 'text-[var(--bad-light)]',
    Stable: 'text-[var(--color-fg-disabled)]',
  }
  const color = phaseColor[snapshot.phase] ?? 'text-[var(--color-accent-fg)]'
  const heldFor = phaseSince != null ? fmtDuration(Math.max(0, now - phaseSince)) : null
  const collapsedSource = snapshot.phase === 'Stable' ? snapshot.collapsed_from : null
  const collapsedSourceLabel = collapsedSource
    ? `${displayState(collapsedSource)} (${collapsedSource})`
    : null
  const title = collapsedSource
    ? `${STATE_DESCRIPTIONS[snapshot.phase] ?? snapshot.phase}\nCollapsed from raw keeper phase: ${collapsedSource}\n${STATE_DESCRIPTIONS[collapsedSource] ?? collapsedSource}`
    : (STATE_DESCRIPTIONS[snapshot.phase] ?? snapshot.phase)
  const ariaLabel = [
    `Keeper 상태: ${displayState(snapshot.phase)}`,
    collapsedSourceLabel ? `collapsed from ${collapsedSourceLabel}` : null,
    heldFor,
  ].filter(Boolean).join(', ')

  return html`
    <div class=${`rounded-[var(--r-1)] border p-5 transition-[background-color,border-color,box-shadow] duration-[var(--t-xslow)] ${flash ? 'border-[var(--color-accent-fg)] bg-[var(--accent-6)] shadow-[0_0_16px_var(--accent-20)]' : 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)]'}`}
      role="status" aria-live="polite" aria-label=${ariaLabel}
      title=${title}
    >
      <div class="flex items-baseline justify-between">
        <div>
          <div class="text-3xs font-semibold tracking-[0.06em] text-[var(--color-fg-muted)]" id="ksm-label">Keeper 생명주기 <span class="font-mono text-3xs text-[var(--color-fg-disabled)]">KSM</span></div>
          <div class=${`mt-1 font-mono text-[32px] font-bold tracking-tight ${color}`} aria-labelledby="ksm-label">
            ${displayState(snapshot.phase)}
          </div>
          <div class="mt-0.5 text-3xs font-mono text-[var(--color-fg-disabled)]">${snapshot.phase}</div>
          ${collapsedSourceLabel ? html`
            <div class="mt-1 text-3xs font-mono text-[var(--color-fg-disabled)]">
              collapsed from <span class="text-[var(--color-fg-primary)]">${collapsedSourceLabel}</span>
            </div>
          ` : null}
          ${heldFor ? html`
            <div class="mt-1 text-3xs font-mono text-[var(--color-fg-disabled)]" aria-hidden="true">
              유지 <span class="text-[var(--color-fg-primary)]">${heldFor}</span>
            </div>
          ` : null}
        </div>
        ${flash ? html`<span class="text-3xs text-[var(--color-accent-fg)] animate-pulse font-mono" aria-live="assertive">상태 변경</span>` : null}
      </div>
      <${PhaseSparkline} observations=${observations} />
    </div>
  `
}

export function PipelineStep({
  label,
  shortLabel,
  value,
  isLast,
  sinceTs,
  limited,
}: {
  label: string
  shortLabel: string
  value: string
  isLast?: boolean
  sinceTs: number | null
  /** When true, this lane has limited observability — only a subset of
      states are derivable from the registry. Shown as a subtle indicator. */
  limited?: boolean
}) {
  useNowSecondsTicker()
  const now = nowSecondsSignal.value
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
    ? 'border-[var(--color-accent-fg)] shadow-[0_0_8px_rgb(var(--info-glow)/0.35)]'
    : isActive
      ? 'border-[var(--info-border)] shadow-[0_0_6px_rgb(var(--info-glow)/0.15)]'
      : 'border-[var(--color-border-default)]'
  const bgCls = isActive && !flash
    ? 'bg-[var(--indigo-4)]'
    : 'bg-[var(--color-bg-surface)]'
  const activePulse = isActive && !flash ? 'animate-pulse' : ''

  const connectorCls = isActive
    ? 'border-t border-dashed border-[var(--indigo-50)] animate-[marching-ants_1s_linear_infinite]'
    : 'border-t border-[var(--color-border-default)]'

  const heldFor = sinceTs != null ? fmtDuration(Math.max(0, now - sinceTs)) : null
  const stalenessCls = (() => {
    if (!heldFor || sinceTs == null) return 'text-[var(--color-fg-disabled)]'
    const ageSec = now - sinceTs
    if (!isActive) {
      // idle 상태에서도 장기 대기를 시각적으로 구분
      if (ageSec > 600) return 'text-[var(--color-fg-muted)]'
      return 'text-[var(--color-fg-disabled)]'
    }
    if (ageSec > 60) return 'text-[var(--amber-bright)]'
    if (ageSec > 20) return 'text-[var(--yellow-bright)]'
    return 'text-[var(--indigo)]'
  })()

  return html`
    <div class="flex items-center gap-0 flex-1 min-w-0" role="listitem" aria-label=${`${label}: ${displayState(value)}${limited ? ' (관찰 제한)' : ''}${heldFor ? `, ${heldFor}` : ''}`}
      title=${`${label} (${shortLabel}): ${value} → ${displayState(value)}${heldFor ? ` · ${heldFor}` : ''}${limited ? '\n⚠ 관찰 제한: 일부 상태만 registry에서 파생 가능 (#7122)' : ''}\n${STATE_DESCRIPTIONS[value] ?? ''}`}
    >
      <div class=${`flex-1 rounded-[var(--r-1)] border px-3 py-2 transition-[background-color,border-color,opacity] duration-[var(--t-xslow)] ${borderCls} ${bgCls} ${limited && !isActive ? 'opacity-60' : ''}`}>
        <div class="flex items-center justify-between gap-1.5">
          <div class="flex items-center gap-1.5 min-w-0">
            ${isActive ? html`<span class="h-1.5 w-1.5 rounded-full bg-[var(--indigo)] ${activePulse} shrink-0"></span>` : null}
            <span class="text-3xs font-semibold tracking-[0.04em] text-[var(--color-fg-muted)]">${label}</span>
            ${limited ? html`<span class="text-3xs font-mono text-[var(--color-fg-disabled)] border border-[var(--color-border-default)] rounded-[var(--r-1)] px-1" title="Event_bus 구독 미구현으로 일부 상태만 관찰 가능">제한</span>` : null}
          </div>
          ${heldFor ? html`
            <span class=${`text-3xs font-mono tabular-nums ${stalenessCls}`} aria-hidden="true">${heldFor}</span>
          ` : null}
        </div>
        <div class=${`mt-0.5 font-mono text-sm font-semibold ${isActive ? 'text-[var(--color-fg-secondary)]' : 'text-[var(--color-fg-muted)]'} ${flash ? 'animate-pulse' : ''}`}>
          ${displayState(value)}
        </div>
        <div class="text-3xs font-mono text-[var(--color-fg-disabled)] mt-0.5">${shortLabel} · ${value}</div>
      </div>
      ${!isLast ? html`<div class=${`hidden md:block w-5 shrink-0 ${connectorCls}`}></div>` : null}
    </div>
  `
}

export function TurnPipelineStrip({
  snapshot,
  stateEntries,
}: {
  snapshot: KeeperCompositeSnapshot
  stateEntries: StateEntries | null
}) {
  // Pure pass-through wrapper: each PipelineStep child subscribes to
  // nowSecondsSignal independently, so this component itself never reads
  // the signal and is not re-rendered by 5 s ticks.
  return html`
    <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
      <div class="mb-2 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
        턴 파이프라인
      </div>
      <div class="flex flex-col gap-1 md:flex-row md:gap-0 md:items-stretch" role="list" aria-label="턴 파이프라인 단계">
        <${PipelineStep} shortLabel="KTC" label="턴 주기" value=${snapshot.turn_phase} sinceTs=${stateEntries?.turn ?? null} />
        <${PipelineStep} shortLabel="KDP" label="의사결정" value=${snapshot.decision.stage} sinceTs=${stateEntries?.decision ?? null} limited />
        <${PipelineStep} shortLabel="KCL" label="캐스케이드" value=${snapshot.cascade.state} sinceTs=${stateEntries?.cascade ?? null} limited />
        <${PipelineStep} shortLabel="KMC" label="컨텍스트 압축" value=${snapshot.compaction.stage} sinceTs=${stateEntries?.compaction ?? null} isLast />
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
