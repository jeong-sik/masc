// Divergent conditions — active observables that are inconsistent with
// the current FSM phase, surfaced as amber chips in the Agent Modal.
//
// Why this matters: [Keeper_state_machine.conditions] holds 16 booleans
// (RFC-0002 §4) that together drive the phase transition function. When
// the keeper is healthy, conditions are consistent with the phase —
// e.g. [phase=Running ∧ heartbeat_healthy=true]. A *divergence* is a
// condition observed in a state the phase hasn't yet acknowledged,
// e.g. [phase=Running ∧ context_handoff_needed=true]: the observer can
// see the signal, but the FSM hasn't transitioned to HandingOff yet.
//
// Showing all 16 booleans is noise; showing none hides the "why aren't
// we transitioning?" signal. The middle ground is to surface only the
// divergent ones, annotated with a ko-language reason.
//
// The liveness invariant that justifies each divergence rule (phase
// MUST eventually transition under fairness) is proved in
// [specs/keeper-state-machine/KeeperConditionsGovernPhase.tla] — planned
// to land as PR 6a alongside this UI.

import { html } from 'htm/preact'
import type { Keeper, KeeperConditions, KeeperPhase } from '../types'

type DivergenceFn = (value: boolean, phase: KeeperPhase | null | undefined) => string | null

export const isOperating = (p: KeeperPhase | null | undefined): boolean =>
  p === 'Running' || p === 'Failing' || p === 'Overflowed'

export const isTerminated = (p: KeeperPhase | null | undefined): boolean =>
  p === 'Stopped' || p === 'Dead' || p === 'Crashed'

/** Rule table — each entry returns a ko-language reason when divergent,
 *  null when the condition is consistent with (or expected by) the phase. */
const DIVERGENCE_RULES: Partial<Record<keyof KeeperConditions, DivergenceFn>> = {
  context_handoff_needed: (v, p) =>
    v && (p === 'Running' || p === 'Failing')
      ? '핸드오프 필요 신호가 있지만 아직 HandingOff/Compacting으로 전환 전'
      : null,

  context_overflow: (v, p) =>
    v && p !== 'Overflowed' && !isTerminated(p)
      ? '컨텍스트 overflow 감지됨 (phase 미반영)'
      : null,

  compact_retry_exhausted: (v, p) =>
    v && p !== 'Failing' && !isTerminated(p)
      ? '압축 재시도 소진 — Failing phase로 전환 필요'
      : null,

  stop_requested: (v, p) =>
    v && p !== 'Draining' && !isTerminated(p)
      ? '정지 요청됐으나 Draining 미진입'
      : null,

  operator_paused: (v, p) =>
    v && p !== 'Paused'
      ? '오퍼레이터가 pause했으나 Paused phase 미반영'
      : null,

  guardrail_triggered: (v, p) =>
    v && p !== 'Paused' && p !== 'Failing' && !isTerminated(p)
      ? '가드레일 발동 (격리 phase 미전환)'
      : null,

  turn_healthy: (v, p) =>
    !v && p !== 'Failing' && !isTerminated(p)
      ? '턴 실패 누적 — Failing phase 기대'
      : null,

  heartbeat_healthy: (v, p) =>
    !v && isOperating(p)
      ? '하트비트 불건전 (운영 phase 중)'
      : null,

  fiber_alive: (v, p) =>
    !v && p !== 'Offline' && !isTerminated(p)
      ? '파이버 죽음 (Offline도 종료도 아님)'
      : null,

  restart_budget_remaining: (v, p) =>
    !v && !isTerminated(p)
      ? '재시작 예산 소진 (Dead phase 기대)'
      : null,
}

interface Divergence {
  field: keyof KeeperConditions
  value: boolean
  reason: string
}

export function computeDivergences(
  conditions: KeeperConditions,
  phase: KeeperPhase | null | undefined,
): Divergence[] {
  const out: Divergence[] = []
  for (const [field, fn] of Object.entries(DIVERGENCE_RULES) as Array<[
    keyof KeeperConditions,
    DivergenceFn,
  ]>) {
    const v = conditions[field]
    const reason = fn(v, phase)
    if (reason != null) out.push({ field, value: v, reason })
  }
  return out
}

/** Section wrapper for the Agent Modal. Renders nothing when [keeper.conditions]
 *  is unset or every condition is consistent with the phase. */
export function KeeperConditionsDivergent({ keeper }: { keeper: Keeper }) {
  if (!keeper.conditions) return null
  const divs = computeDivergences(keeper.conditions, keeper.phase)
  const [first, ...rest] = divs
  if (!first) return null

  return html`
    <section class="rounded-[var(--r-1)] border border-[var(--warn-24)] bg-[var(--warn-soft)] p-3 mb-3" aria-label="조건-Phase 불일치 경고">
      <header class="mb-2 flex items-baseline justify-between gap-2">
        <h3 class="text-2xs font-semibold tracking-[var(--track-caps)] uppercase text-[var(--color-status-warn)]">
          ⚠️ 조건-Phase 불일치
        </h3>
        <span class="text-3xs text-[var(--color-fg-disabled)]">phase가 아직 반응하지 않은 관측 신호</span>
      </header>
      <div class="flex flex-wrap gap-1.5">
        ${divs.map(d => html`
          <span
            class="px-2 py-0.5 rounded-[var(--r-0)] border border-[var(--warn-border)] bg-[var(--warn-soft)] text-[var(--color-status-warn)] text-2xs font-mono tabular-nums"
            title=${d.reason}
          >
            ${d.field}=${String(d.value)}
          </span>
        `)}
      </div>
      <div class="mt-2 text-3xs text-[var(--color-fg-disabled)] leading-snug">
        ${first.reason}${rest.length > 0 ? ` (외 ${rest.length}건, 칩 hover로 확인)` : ''}
      </div>
    </section>
  `
}
