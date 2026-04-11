import { html } from 'htm/preact'
import { CARD_STANDARD } from '../common/card'
import { EmptyState } from '../common/empty-state'
import { StatusChip } from '../common/status-chip'
import type {
  CommandPlaneCapacityRow,
  CommandPlaneDecisionRecord,
} from '../../types'
import {
  approveCommandPlaneDecision,
  commandPlaneSnapshot,
  denyCommandPlaneDecision,
  toggleCommandPlaneFreeze,
  toggleCommandPlaneKillSwitch,
} from '../../command-store'
import { actionDisabled, fire, relativeTime, toneClass } from './helpers'

function controlStatusLabel(value?: string | null): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'pending':
      return '대기 중'
    case 'approved':
      return '승인됨'
    case 'denied':
      return '거부됨'
    case 'executed':
      return '실행됨'
    case 'active':
      return '가동 중'
    default:
      return value?.trim() || '확인 필요'
  }
}

function DecisionCard({ decision }: { decision: CommandPlaneDecisionRecord }) {
  const approveKey = `approve:${decision.decision_id}`
  const denyKey = `deny:${decision.decision_id}`
  const isLegacy = decision.source === 'projected_operator'
  return html`
    <article class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] ${toneClass(decision.status)}">
      <div class="flex justify-between items-start gap-3 mb-2">
        <div>
          <strong class="text-[13px] font-semibold text-[var(--text-strong)]">${decision.requested_action}</strong>
          <div class="text-[11px] text-[var(--text-muted)] mt-0.5">${decision.scope_type}:${decision.scope_id}</div>
        </div>
        <${StatusChip} label=${controlStatusLabel(decision.status ?? 'pending')} tone=${toneClass(decision.status)} />
      </div>
      <div class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1.5 text-[12px] mt-2">
        <span class="text-[var(--text-muted)]">결정 ID</span><span class="text-[var(--text-body)]">${decision.decision_id}</span>
        <span class="text-[var(--text-muted)]">요청자</span><span class="text-[var(--text-body)]">${decision.requested_by ?? '알 수 없음'}</span>
        <span class="text-[var(--text-muted)]">출처</span><span class="text-[var(--text-body)]">${decision.source ?? 'managed'}</span>
        <span class="text-[var(--text-muted)]">트레이스</span><span class="font-mono text-[var(--text-body)]">${decision.trace_id}</span>
        <span class="text-[var(--text-muted)]">생성 시각</span><span class="text-[var(--text-body)]">${relativeTime(decision.created_at)}</span>
        <span class="text-[var(--text-muted)]">이유</span><span class="text-[var(--text-body)]">${decision.reason ?? '정보 없음'}</span>
      </div>
      ${decision.status === 'pending' && !isLegacy
        ? html`
            <div class="flex gap-3 flex-wrap mt-3">
              <button type="button" class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]" disabled=${actionDisabled(approveKey)} onClick=${() => fire(() => approveCommandPlaneDecision(decision.decision_id))}>
                ${actionDisabled(approveKey) ? '승인 중…' : '승인'}
              </button>
              <button type="button" class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]" disabled=${actionDisabled(denyKey)} onClick=${() => fire(() => denyCommandPlaneDecision(decision.decision_id))}>
                ${actionDisabled(denyKey) ? '거부 중…' : '거부'}
              </button>
            </div>
          `
        : null}
      ${isLegacy ? html`<div class="mt-2 text-[12px] text-[var(--text-muted)] border-t border-[var(--white-4)] pt-2">레거시 operator 승인입니다. 실제 실행은 operator control에서 처리합니다.</div>` : null}
    </article>
  `
}

function CapacityRowCard({ row }: { row: CommandPlaneCapacityRow }) {
  const unit = row.unit
  const freezeKey = `freeze:${unit.unit_id}`
  const killKey = `kill:${unit.unit_id}`
  const frozen = !!unit.policy?.frozen
  const killSwitch = !!unit.policy?.kill_switch
  const utilization = Math.round((row.utilization ?? 0) * 100)
  return html`
    <article class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
      <div class="flex justify-between items-start gap-3 mb-2">
        <div>
          <strong class="text-[13px] font-semibold text-[var(--text-strong)]">${unit.label}</strong>
          <div class="text-[11px] text-[var(--text-muted)] mt-0.5">${unit.unit_id}</div>
        </div>
        <${StatusChip} label=${`${utilization}%`} tone=${toneClass(utilization > 100 ? 'bad' : utilization > 70 ? 'warn' : 'ok')} />
      </div>
      <div class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1.5 text-[12px] mt-2">
        <span class="text-[var(--text-muted)]">편성</span><span class="text-[var(--text-body)]">${row.roster_live ?? 0}/${row.roster_total ?? 0}</span>
        <span class="text-[var(--text-muted)]">정원</span><span class="text-[var(--text-body)]">${row.headcount_cap ?? 0}</span>
        <span class="text-[var(--text-muted)]">작전</span><span class="text-[var(--text-body)]">${row.active_operations ?? 0}/${row.active_operation_cap ?? 0}</span>
        <span class="text-[var(--text-muted)]">동결</span><span class="text-[var(--text-body)]">${frozen ? '예' : '아니오'}</span>
        <span class="text-[var(--text-muted)]">킬 스위치</span><span class="text-[var(--text-body)]">${killSwitch ? '켜짐' : '꺼짐'}</span>
      </div>
      <div class="flex gap-3 flex-wrap mt-3">
        <button type="button" class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]" disabled=${actionDisabled(freezeKey)} onClick=${() => fire(() => toggleCommandPlaneFreeze(unit.unit_id, !frozen))}>
          ${actionDisabled(freezeKey) ? '적용 중…' : frozen ? '동결 해제' : '동결'}
        </button>
        <button type="button" class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]" disabled=${actionDisabled(killKey)} onClick=${() => fire(() => toggleCommandPlaneKillSwitch(unit.unit_id, !killSwitch))}>
          ${actionDisabled(killKey) ? '적용 중…' : killSwitch ? '킬 스위치 해제' : '킬 스위치 켜기'}
        </button>
      </div>
    </article>
  `
}

export function ControlSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
      <section class="${CARD_STANDARD} min-h-[240px]">
        <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider pb-2 border-b border-[var(--card-border)] mb-3">승인 대기</h3>
        ${snapshot && snapshot.decisions.decisions.length > 0
          ? html`<div class="flex flex-col gap-3">
              ${snapshot.decisions.decisions.map(decision => html`<${DecisionCard} decision=${decision} />`)}
            </div>`
          : html`<${EmptyState} message="지금 승인 대기 항목은 없습니다." compact />`}
      </section>

      <section class="${CARD_STANDARD} min-h-[240px]">
        <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider pb-2 border-b border-[var(--card-border)] mb-3">유닛 제어</h3>
        ${snapshot && snapshot.capacity.capacity.length > 0
          ? html`<div class="flex flex-col gap-3">
              ${snapshot.capacity.capacity.map(row => html`<${CapacityRowCard} row=${row} />`)}
            </div>`
          : html`<${EmptyState} message="제어할 용량 행이 아직 없습니다." compact />`}
      </section>
    </div>
  `
}
