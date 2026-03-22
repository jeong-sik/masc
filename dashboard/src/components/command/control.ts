import { html } from 'htm/preact'
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
    <article class="command-card rounded-xl ${toneClass(decision.status)}">
      <div class="command-card rounded-xl-head">
        <div>
          <strong>${decision.requested_action}</strong>
          <div class="command-card rounded-xl-sub">${decision.scope_type}:${decision.scope_id}</div>
        </div>
        <span class="command-chip rounded-full ${toneClass(decision.status)}">${controlStatusLabel(decision.status ?? 'pending')}</span>
      </div>
      <div class="command-card rounded-xl-grid">
        <span>결정 ID</span><span>${decision.decision_id}</span>
        <span>요청자</span><span>${decision.requested_by ?? '알 수 없음'}</span>
        <span>출처</span><span>${decision.source ?? 'managed'}</span>
        <span>트레이스</span><span class="font-mono">${decision.trace_id}</span>
        <span>생성 시각</span><span>${relativeTime(decision.created_at)}</span>
        <span>이유</span><span>${decision.reason ?? '정보 없음'}</span>
      </div>
      ${decision.status === 'pending' && !isLegacy
        ? html`
            <div class="flex gap-2.5 flex-wrap mt-3">
              <button class="control-btn rounded-lg ghost" disabled=${actionDisabled(approveKey)} onClick=${() => fire(() => approveCommandPlaneDecision(decision.decision_id))}>
                ${actionDisabled(approveKey) ? '승인 중…' : '승인'}
              </button>
              <button class="control-btn rounded-lg ghost" disabled=${actionDisabled(denyKey)} onClick=${() => fire(() => denyCommandPlaneDecision(decision.decision_id))}>
                ${actionDisabled(denyKey) ? '거부 중…' : '거부'}
              </button>
            </div>
          `
        : null}
      ${isLegacy ? html`<div class="command-card rounded-xl-foot">레거시 operator 승인입니다. 실제 실행은 operator control에서 처리합니다.</div>` : null}
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
    <article class="command-card rounded-xl p-3">
      <div class="command-card rounded-xl-head">
        <div>
          <strong>${unit.label}</strong>
          <div class="command-card rounded-xl-sub">${unit.unit_id}</div>
        </div>
        <span class="command-chip rounded-full ${toneClass(utilization > 100 ? 'bad' : utilization > 70 ? 'warn' : 'ok')}">${utilization}%</span>
      </div>
      <div class="command-card rounded-xl-grid">
        <span>편성</span><span>${row.roster_live ?? 0}/${row.roster_total ?? 0}</span>
        <span>정원</span><span>${row.headcount_cap ?? 0}</span>
        <span>작전</span><span>${row.active_operations ?? 0}/${row.active_operation_cap ?? 0}</span>
        <span>자율성</span><span>${unit.policy?.autonomy_level ?? '정보 없음'}</span>
        <span>동결</span><span>${frozen ? '예' : '아니오'}</span>
        <span>킬 스위치</span><span>${killSwitch ? '켜짐' : '꺼짐'}</span>
      </div>
      <div class="flex gap-2.5 flex-wrap mt-3">
        <button class="control-btn rounded-lg ghost" disabled=${actionDisabled(freezeKey)} onClick=${() => fire(() => toggleCommandPlaneFreeze(unit.unit_id, !frozen))}>
          ${actionDisabled(freezeKey) ? '적용 중…' : frozen ? '동결 해제' : '동결'}
        </button>
        <button class="control-btn rounded-lg ghost" disabled=${actionDisabled(killKey)} onClick=${() => fire(() => toggleCommandPlaneKillSwitch(unit.unit_id, !killSwitch))}>
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
      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">승인 대기</div>
        </div>
        ${snapshot && snapshot.decisions.decisions.length > 0
          ? html`<div class="command-card rounded-xl-stack">
              ${snapshot.decisions.decisions.map(decision => html`<${DecisionCard} decision=${decision} />`)}
            </div>`
          : html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">유닛 제어</div>
        </div>
        ${snapshot && snapshot.capacity.capacity.length > 0
          ? html`<div class="command-card rounded-xl-stack">
              ${snapshot.capacity.capacity.map(row => html`<${CapacityRowCard} row=${row} />`)}
            </div>`
          : html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">제어할 용량 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `
}
