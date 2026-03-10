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
import { PanelSemanticDetails } from '../common/semantic-layer'
import { actionDisabled, fire, relativeTime, toneClass } from './helpers'

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
        <span class="command-chip ${toneClass(decision.status)}">${decision.status ?? 'pending'}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${decision.decision_id}</span>
        <span>By</span><span>${decision.requested_by ?? 'unknown'}</span>
        <span>Source</span><span>${decision.source ?? 'managed'}</span>
        <span>Trace</span><span class="mono">${decision.trace_id}</span>
        <span>Created</span><span>${relativeTime(decision.created_at)}</span>
        <span>Reason</span><span>${decision.reason ?? 'n/a'}</span>
      </div>
      ${decision.status === 'pending' && !isLegacy
        ? html`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${actionDisabled(approveKey)} onClick=${() => fire(() => approveCommandPlaneDecision(decision.decision_id))}>
                ${actionDisabled(approveKey) ? 'Approving…' : 'Approve'}
              </button>
              <button class="control-btn ghost" disabled=${actionDisabled(denyKey)} onClick=${() => fire(() => denyCommandPlaneDecision(decision.decision_id))}>
                ${actionDisabled(denyKey) ? 'Denying…' : 'Deny'}
              </button>
            </div>
          `
        : null}
      ${isLegacy ? html`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>` : null}
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
        <span>Roster</span><span>${row.roster_live ?? 0}/${row.roster_total ?? 0}</span>
        <span>Headcount Cap</span><span>${row.headcount_cap ?? 0}</span>
        <span>Ops</span><span>${row.active_operations ?? 0}/${row.active_operation_cap ?? 0}</span>
        <span>Autonomy</span><span>${unit.policy?.autonomy_level ?? 'n/a'}</span>
        <span>Frozen</span><span>${frozen ? 'yes' : 'no'}</span>
        <span>Kill Switch</span><span>${killSwitch ? 'on' : 'off'}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${actionDisabled(freezeKey)} onClick=${() => fire(() => toggleCommandPlaneFreeze(unit.unit_id, !frozen))}>
          ${actionDisabled(freezeKey) ? 'Applying…' : frozen ? 'Unfreeze' : 'Freeze'}
        </button>
        <button class="control-btn ghost" disabled=${actionDisabled(killKey)} onClick=${() => fire(() => toggleCommandPlaneKillSwitch(unit.unit_id, !killSwitch))}>
          ${actionDisabled(killKey) ? 'Applying…' : killSwitch ? 'Clear Kill Switch' : 'Enable Kill Switch'}
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
          <${PanelSemanticDetails} panelId="command.control" compact=${true} />
        </div>
        ${snapshot && snapshot.decisions.decisions.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.decisions.decisions.map(decision => html`<${DecisionCard} decision=${decision} />`)}
            </div>`
          : html`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${PanelSemanticDetails} panelId="command.control" compact=${true} />
        </div>
        ${snapshot && snapshot.capacity.capacity.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.capacity.capacity.map(row => html`<${CapacityRowCard} row=${row} />`)}
            </div>`
          : html`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `
}
