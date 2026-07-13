import { html } from 'htm/preact'
import { SectionHeader } from './common/section-header'
import { StatusChip } from './common/status-chip'
import { ProgressBar } from './common/progress-bar'
import type { Keeper } from '../types'
import { MutedSpan, DetailCard } from './keeper-detail-kpi'

// ── Outcomes Ledger ──────────────────────────────────────
//
// Section-4 body for KpiGrid. Renders three rows that answer the
// operator's question "무엇을 했고 실패했고 검증을 통과했나?":
//
//   Row 1 — Success / Failure Ledger
//     Counters pulled from [Keeper_transition_audit] (50-entry ring):
//       ✅ successes.substantive_turns
//       ⚠️ failures.turn_failed
//     Rendered as compact inline counters + a stacked proportion bar.
//     Secondary row lists compactions_ok / handoffs_ok as chips.
//
//   Row 2 — Validator Pass Rate (OAS verdicts)
//     "pass N/M (P%)" with a horizontal progress bar colored by tone,
//     plus up to 3 top failure reasons rendered as muted chips.
//
//   Row 3 — Fault Tolerance Profile
//     Chips for 세대 / 크래시 / 재시작 / 연속 실패 (current).
//
// The conservation law (KeeperOutcomesConservation.tla) is guaranteed
// by the backend rollup, so this component can treat the numbers as
// internally consistent — no client-side reconciliation needed.

export function OutcomesLedger({ keeper, outcomes }: {
  keeper: Keeper
  outcomes: NonNullable<Keeper['outcomes']>
}) {
  const { successes, failures, validation, observed_turns } = outcomes
  const ledgerTotal = successes.substantive_turns + failures.turn_failed
  const pctSuccess = ledgerTotal > 0 ? (successes.substantive_turns / ledgerTotal) * 100 : 0
  const pctFail    = ledgerTotal > 0 ? (failures.turn_failed        / ledgerTotal) * 100 : 0

  const verdicts = validation.oas_verdicts
  const verdictTotal = verdicts.pass + verdicts.fail + verdicts.unknown
  const passRatePct = verdictTotal > 0 ? Math.round((verdicts.pass / verdictTotal) * 100) : null
  const passBarColor =
    passRatePct == null ? 'var(--color-fg-disabled)'
    : passRatePct >= 90 ? 'var(--color-status-ok)'
    : passRatePct >= 70 ? 'var(--color-status-warn)'
    : 'var(--color-status-err)'

  return html`
    <div class="flex flex-col gap-3 v2-monitoring-panel">
      ${'' /* Row 1 — Success / Failure Ledger */}
      <${DetailCard} class="px-3 py-2">
        <div class="flex items-baseline justify-between gap-2 mb-1.5">
          <${SectionHeader} size="xs">성공/실패 (최근 ${observed_turns}턴)</${SectionHeader}>
          <${MutedSpan}>${ledgerTotal > 0 ? `합계 ${ledgerTotal}` : '관측 없음'}</${MutedSpan}>
        </div>
        <div class="flex items-center gap-3 text-xs">
          <span class="tabular-nums"><span class="text-[var(--color-status-ok)]">✅</span> ${successes.substantive_turns} 성공</span>
          <span class="tabular-nums"><span class="text-[var(--color-status-warn)]">⚠️</span> ${failures.turn_failed} 실패</span>
        </div>
        <div class="mt-2 w-full h-1.5 bg-[var(--color-bg-hover)] rounded-[var(--r-0)] overflow-hidden flex" aria-label="성공/실패 비율 바">
          <div class="h-full bg-[var(--color-status-ok)]" style="width:${pctSuccess}%" title=${`성공 ${Math.round(pctSuccess)}%`}></div>
          <div class="h-full bg-[var(--color-status-warn)]" style="width:${pctFail}%" title=${`실패 ${Math.round(pctFail)}%`}></div>
        </div>
        ${(successes.compactions_ok > 0 || successes.handoffs_ok > 0 || failures.compaction_failed > 0 || failures.handoff_failed > 0) ? html`
          <div class="mt-2 flex flex-wrap gap-1.5 text-3xs">
            ${successes.compactions_ok > 0 ? html`<${StatusChip} tone="ok" uppercase=${false}>압축 ${successes.compactions_ok}<//>` : null}
            ${failures.compaction_failed > 0 ? html`<${StatusChip} tone="bad" uppercase=${false}>압축 실패 ${failures.compaction_failed}<//>` : null}
            ${successes.handoffs_ok > 0 ? html`<${StatusChip} tone="ok" uppercase=${false}>인계 ${successes.handoffs_ok}<//>` : null}
            ${failures.handoff_failed > 0 ? html`<${StatusChip} tone="bad" uppercase=${false}>인계 실패 ${failures.handoff_failed}<//>` : null}
          </div>
        ` : null}
      <//>

      ${'' /* Row 2 — Validator Pass Rate */}
      <${DetailCard} class="px-3 py-2">
        <div class="flex items-baseline justify-between gap-2 mb-1.5">
          <${SectionHeader} size="xs">검증자 (OAS verdict)</${SectionHeader}>
          <${MutedSpan}>
            ${verdictTotal > 0 ? `${verdicts.pass}/${verdictTotal} pass` : 'verdict 없음'}
          </${MutedSpan}>
        </div>
        ${verdictTotal > 0 ? html`
          <div class="flex items-center gap-2">
            <${ProgressBar} pct=${passRatePct} size="sm" trackTone="dim" trackClass="flex-1" class=${`bg-[${passBarColor}]`} />
            <span class="shrink-0 text-sm font-semibold tabular-nums" style="color:${passBarColor}">${passRatePct}%</span>
          </div>
          ${verdicts.top_failure_reasons.length > 0 ? html`
            <div class="mt-2 flex flex-wrap gap-1.5 text-3xs">
              <span class="text-[var(--color-fg-disabled)]">주요 실패 원인:</span>
              ${verdicts.top_failure_reasons.map(reason => html`
                <span class="px-2 py-0.5 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] font-mono text-[var(--color-fg-primary)]">${reason}</span>
              `)}
            </div>
          ` : null}
          ${validation.cdal_gate ? html`
            <div class="mt-2 flex flex-wrap gap-3 text-2xs text-[var(--color-fg-primary)]">
              <span class="tabular-nums">Contract pass <span class="font-semibold text-[var(--color-status-ok)]">${validation.cdal_gate.pass}</span></span>
              <span class="tabular-nums">reject <span class="font-semibold text-[var(--color-status-err)]">${validation.cdal_gate.reject}</span></span>
              ${validation.cdal_gate.pending_verification > 0 ? html`
                <span class="tabular-nums">검증 대기 <span class="font-semibold text-[var(--color-status-warn)]">${validation.cdal_gate.pending_verification}</span></span>
              ` : null}
            </div>
          ` : null}
        ` : html`
          <div class="text-2xs text-[var(--color-fg-disabled)] leading-snug">
            이 키퍼에 대해 기록된 OAS verdict가 아직 없습니다.
          </div>
        `}
      <//>

      ${'' /* Row 3 — Fault Tolerance Profile */}
      <${DetailCard} class="px-3 py-2">
        <div class="flex items-baseline justify-between gap-2 mb-1.5">
          <${SectionHeader} size="xs">회복력</${SectionHeader}>
          <${MutedSpan}>supervisor 이력</${MutedSpan}>
        </div>
        <div class="flex flex-wrap gap-1.5 text-2xs">
          <span class="px-2 py-0.5 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] tabular-nums">세대 ${keeper.generation ?? '-'}</span>
          <span class=${`px-2 py-0.5 rounded-[var(--r-0)] tabular-nums ${failures.crashes > 0 ? 'border border-[var(--bad-20)] bg-[var(--bad-6)] text-[var(--color-status-err)]' : 'border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-primary)]'}`}>크래시 ${failures.crashes}회</span>
          <span class=${`px-2 py-0.5 rounded-[var(--r-0)] tabular-nums ${failures.restarts > 0 ? 'border border-[var(--warn-20)] bg-[var(--warn-8)] text-[var(--color-status-warn)]' : 'border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-primary)]'}`}>재시작 ${failures.restarts}회</span>
          ${failures.consecutive_fail_current > 0 ? html`
            <span class="px-2 py-0.5 rounded-[var(--r-0)] border border-[var(--warn-20)] bg-[var(--warn-8)] text-[var(--color-status-warn)] tabular-nums">연속 실패 ${failures.consecutive_fail_current}</span>
          ` : null}
        </div>
      <//>
    <//>
  `
}
