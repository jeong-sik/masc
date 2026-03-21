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
    <article class="command-card ${toneClass(decision.status)}">
      <div class="command-card-head">
        <div>
          <strong>${decision.requested_action}</strong>
          <div class="command-card-sub">${decision.scope_type}:${decision.scope_id}</div>
        </div>
        <span class="command-chip ${toneClass(decision.status)}">${controlStatusLabel(decision.status ?? 'pending')}</span>
      </div>
      <div class="command-card-grid">
        <span>결정 ID</span><span>${decision.decision_id}</span>
        <span>요청자</span><span>${decision.requested_by ?? '알 수 없음'}</span>
        <span>출처</span><span>${decision.source ?? 'managed'}</span>
        <span>트레이스</span><span class="mono">${decision.trace_id}</span>
        <span>생성 시각</span><span>${relativeTime(decision.created_at)}</span>
        <span>이유</span><span>${decision.reason ?? '정보 없음'}</span>
      </div>
      ${decision.status === 'pending' && !isLegacy
        ? html`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${actionDisabled(approveKey)} onClick=${() => fire(() => approveCommandPlaneDecision(decision.decision_id))}>
                ${actionDisabled(approveKey) ? '승인 중…' : '승인'}
              </button>
              <button class="control-btn ghost" disabled=${actionDisabled(denyKey)} onClick=${() => fire(() => denyCommandPlaneDecision(decision.decision_id))}>
                ${actionDisabled(denyKey) ? '거부 중…' : '거부'}
              </button>
            </div>
          `
        : null}
      ${isLegacy ? html`<div class="command-card-foot">레거시 operator 승인입니다. 실제 실행은 operator control에서 처리합니다.</div>` : null}
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
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${unit.label}</strong>
          <div class="command-card-sub">${unit.unit_id}</div>
        </div>
        <span class="command-chip ${toneClass(utilization > 100 ? 'bad' : utilization > 70 ? 'warn' : 'ok')}">${utilization}%</span>
      </div>
      <div class="command-card-grid">
        <span>편성</span><span>${row.roster_live ?? 0}/${row.roster_total ?? 0}</span>
        <span>정원</span><span>${row.headcount_cap ?? 0}</span>
        <span>작전</span><span>${row.active_operations ?? 0}/${row.active_operation_cap ?? 0}</span>
        <span>자율성</span><span>${unit.policy?.autonomy_level ?? '정보 없음'}</span>
        <span>동결</span><span>${frozen ? '예' : '아니오'}</span>
        <span>킬 스위치</span><span>${killSwitch ? '켜짐' : '꺼짐'}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${actionDisabled(freezeKey)} onClick=${() => fire(() => toggleCommandPlaneFreeze(unit.unit_id, !frozen))}>
          ${actionDisabled(freezeKey) ? '적용 중…' : frozen ? '동결 해제' : '동결'}
        </button>
        <button class="control-btn ghost" disabled=${actionDisabled(killKey)} onClick=${() => fire(() => toggleCommandPlaneKillSwitch(unit.unit_id, !killSwitch))}>
          ${actionDisabled(killKey) ? '적용 중…' : killSwitch ? '킬 스위치 해제' : '킬 스위치 켜기'}
        </button>
      </div>
    </article>
  `
}

export function ControlSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
        </div>
        <p class="command-section-note">승인과 거부는 즉시 정책 실행 흐름에 영향을 줍니다. 대상을 먼저 확인하세요.</p>
        ${snapshot && snapshot.decisions.decisions.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.decisions.decisions.map(decision => html`<${DecisionCard} decision=${decision} />`)}
            </div>`
          : html`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">유닛 제어</div>
        </div>
        <p class="command-section-note">동결과 킬 스위치는 새 배정과 실행을 막습니다. 운영 중인 유닛에는 신중하게 적용하세요.</p>
        ${snapshot && snapshot.capacity.capacity.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.capacity.capacity.map(row => html`<${CapacityRowCard} row=${row} />`)}
            </div>`
          : html`<div class="empty-state">제어할 용량 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `
}
