import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import type {
  CommandPlaneAlert,
  CommandPlaneCapacityRow,
  CommandPlaneDecisionRecord,
  CommandPlaneDetachmentCard,
  CommandPlaneOperationCard,
  CommandPlaneSurface,
  CommandPlaneTraceEvent,
  CommandPlaneTreeNode,
} from '../types'
import {
  approveCommandPlaneDecision,
  commandPlaneActionBusy,
  commandPlaneActionError,
  commandPlaneError,
  commandPlaneLoading,
  commandPlaneSnapshot,
  commandPlaneSurface,
  denyCommandPlaneDecision,
  pauseCommandPlaneOperation,
  recallCommandPlaneOperation,
  refreshCommandPlaneSnapshot,
  resumeCommandPlaneOperation,
  setCommandPlaneSurface,
  toggleCommandPlaneFreeze,
  toggleCommandPlaneKillSwitch,
} from '../command-store'

function prettyJson(value: unknown): string {
  if (value === null || value === undefined) return ''
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}

function relativeTime(iso?: string | null): string {
  if (!iso) return 'n/a'
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return iso
  const deltaSec = Math.max(0, Math.round((Date.now() - ts) / 1000))
  if (deltaSec < 60) return `${deltaSec}s ago`
  if (deltaSec < 3600) return `${Math.round(deltaSec / 60)}m ago`
  if (deltaSec < 86400) return `${Math.round(deltaSec / 3600)}h ago`
  return `${Math.round(deltaSec / 86400)}d ago`
}

function toneClass(tone?: string | null): string {
  if (tone === 'bad') return 'bad'
  if (tone === 'warn' || tone === 'pending') return 'warn'
  return 'ok'
}

function unitKindLabel(kind: string): string {
  switch (kind) {
    case 'company':
      return '중대 / Company'
    case 'platoon':
      return '소대 / Platoon'
    case 'squad':
      return '분대 / Squad'
    case 'agent':
      return '에이전트 / Agent'
    default:
      return kind
  }
}

function actionDisabled(key: string): boolean {
  return commandPlaneActionBusy.value === key
}

async function fire(action: () => Promise<void>) {
  try {
    await action()
  } catch {
    // Error state is already captured in the store.
  }
}

function SummaryCards() {
  const snapshot = commandPlaneSnapshot.value
  const topology = snapshot?.topology.summary
  const ops = snapshot?.operations.summary
  const decisions = snapshot?.decisions.summary
  const alerts = snapshot?.alerts.summary
  return html`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>Units</span><strong>${topology?.total_units ?? 0}</strong><small>${topology?.managed_unit_count ?? 0} managed</small></div>
      <div class="monitor-stat-card"><span>Ops</span><strong>${ops?.active ?? 0}</strong><small>${snapshot?.detachments.summary?.active ?? 0} detachments</small></div>
      <div class="monitor-stat-card"><span>Approvals</span><strong>${decisions?.pending ?? 0}</strong><small>${decisions?.total ?? 0} tracked</small></div>
      <div class="monitor-stat-card"><span>Alerts</span><strong>${alerts?.bad ?? 0}</strong><small>${alerts?.warn ?? 0} warn</small></div>
    </div>
  `
}

function SurfaceTabs() {
  const surfaces: CommandPlaneSurface[] = ['operations', 'topology', 'alerts', 'trace', 'control']
  return html`
    <div class="command-surface-tabs">
      ${surfaces.map(surface => html`
        <button
          class="command-surface-tab ${commandPlaneSurface.value === surface ? 'active' : ''}"
          onClick=${() => setCommandPlaneSurface(surface)}
        >
          ${surface}
        </button>
      `)}
    </div>
  `
}

function TopologyNode({ node, depth = 0 }: { node: CommandPlaneTreeNode; depth?: number }) {
  const rosterLive = node.roster_live ?? 0
  const rosterTotal = node.roster_total ?? node.unit.roster.length
  const activeOps = node.active_operation_count ?? 0
  const policy = node.unit.policy
  return html`
    <div class="command-tree-node depth-${Math.min(depth, 3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${node.unit.label}</strong>
            <span class="command-chip">${unitKindLabel(node.unit.kind)}</span>
            <span class="command-chip ${toneClass(node.health)}">${node.health ?? 'ok'}</span>
            ${policy?.frozen ? html`<span class="command-chip warn">frozen</span>` : null}
            ${policy?.kill_switch ? html`<span class="command-chip bad">kill-switch</span>` : null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${node.unit.unit_id}</span>
            <span>Leader ${node.unit.leader_id ?? 'unassigned'} / ${node.leader_status ?? 'unknown'}</span>
            <span>Roster ${rosterLive}/${rosterTotal}</span>
            <span>Ops ${activeOps}</span>
            <span>Autonomy ${policy?.autonomy_level ?? 'n/a'}</span>
          </div>
          ${node.reasons && node.reasons.length > 0
            ? html`<div class="command-tag-row">
                ${node.reasons.map(reason => html`<span class="command-tag warn">${reason}</span>`)}
              </div>`
            : null}
        </div>
      </div>
      ${node.children.length > 0
        ? html`<div class="command-tree-children">
            ${node.children.map(child => html`<${TopologyNode} node=${child} depth=${depth + 1} />`)}
          </div>`
        : null}
    </div>
  `
}

function OperationCard({ card }: { card: CommandPlaneOperationCard }) {
  const op = card.operation
  const pauseKey = `pause:${op.operation_id}`
  const resumeKey = `resume:${op.operation_id}`
  const recallKey = `recall:${op.operation_id}`
  return html`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${op.objective}</strong>
          <div class="command-card-sub">${op.operation_id}</div>
        </div>
        <span class="command-chip ${toneClass(op.status === 'active' ? 'ok' : op.status === 'paused' ? 'warn' : op.status === 'failed' ? 'bad' : 'ok')}">${op.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${card.assigned_unit_label ?? op.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${op.trace_id}</span>
        <span>Autonomy</span><span>${op.autonomy_level ?? 'n/a'}</span>
        <span>Budget</span><span>${op.budget_class ?? 'standard'}</span>
        <span>Source</span><span>${op.source ?? 'managed'}</span>
        <span>Updated</span><span>${relativeTime(op.updated_at)}</span>
      </div>
      ${op.checkpoint_ref
        ? html`<div class="command-card-foot">Checkpoint ${op.checkpoint_ref}</div>`
        : null}
      <div class="command-action-row">
        ${op.source === 'managed' && op.status === 'active'
          ? html`
              <button class="control-btn ghost" disabled=${actionDisabled(pauseKey)} onClick=${() => fire(() => pauseCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(pauseKey) ? 'Pausing…' : 'Pause'}
              </button>
              <button class="control-btn ghost" disabled=${actionDisabled(recallKey)} onClick=${() => fire(() => recallCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(recallKey) ? 'Recalling…' : 'Recall'}
              </button>
            `
          : null}
        ${op.source === 'managed' && op.status === 'paused'
          ? html`
              <button class="control-btn ghost" disabled=${actionDisabled(resumeKey)} onClick=${() => fire(() => resumeCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(resumeKey) ? 'Resuming…' : 'Resume'}
              </button>
            `
          : null}
      </div>
    </article>
  `
}

function DetachmentCard({ card }: { card: CommandPlaneDetachmentCard }) {
  const detachment = card.detachment
  return html`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${detachment.detachment_id}</strong>
          <div class="command-card-sub">${card.operation?.objective ?? detachment.operation_id}</div>
        </div>
        <span class="command-chip ${toneClass(detachment.status)}">${detachment.status ?? 'active'}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${card.assigned_unit_label ?? detachment.assigned_unit_id}</span>
        <span>Leader</span><span>${detachment.leader_id ?? 'unassigned'}</span>
        <span>Roster</span><span>${detachment.roster.length}</span>
        <span>Session</span><span>${detachment.session_id ?? 'none'}</span>
        <span>Updated</span><span>${relativeTime(detachment.updated_at)}</span>
      </div>
    </article>
  `
}

function AlertCard({ alert }: { alert: CommandPlaneAlert }) {
  return html`
    <article class="command-alert ${toneClass(alert.severity)}">
      <div class="command-card-head">
        <strong>${alert.title ?? alert.kind ?? alert.alert_id}</strong>
        <span class="command-chip ${toneClass(alert.severity)}">${alert.severity ?? 'warn'}</span>
      </div>
      <div class="command-alert-meta">
        <span>${alert.scope_type ?? 'scope'}:${alert.scope_id ?? 'n/a'}</span>
        <span>${relativeTime(alert.timestamp)}</span>
      </div>
      ${alert.detail ? html`<p>${alert.detail}</p>` : null}
    </article>
  `
}

function TraceRow({ event }: { event: CommandPlaneTraceEvent }) {
  return html`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${event.event_type}</strong>
          <span class="command-chip">${event.source ?? 'control_plane'}</span>
          <span class="command-chip">${relativeTime(event.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${event.operation_id ?? event.trace_id}
          ${event.unit_id ? ` · ${event.unit_id}` : ''}
          ${event.actor ? ` · ${event.actor}` : ''}
        </div>
      </div>
      <pre class="command-trace-detail">${prettyJson(event.detail)}</pre>
    </article>
  `
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

function OperationsSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${snapshot && snapshot.operations.operations.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.operations.operations.map(card => html`<${OperationCard} card=${card} />`)}
            </div>`
          : html`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${snapshot && snapshot.detachments.detachments.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.detachments.detachments.map(card => html`<${DetachmentCard} card=${card} />`)}
            </div>`
          : html`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `
}

function TopologySurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <section class="card command-section">
      <div class="card-title">Topology</div>
      ${snapshot && snapshot.topology.units.length > 0
        ? html`${snapshot.topology.units.map(node => html`<${TopologyNode} node=${node} />`)}`
        : html`<div class="empty-state">No command topology projected yet.</div>`}
    </section>
  `
}

function AlertsSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <section class="card command-section">
      <div class="card-title">Alerts</div>
      ${snapshot && snapshot.alerts.alerts.length > 0
        ? html`<div class="command-card-stack">
            ${snapshot.alerts.alerts.map(alert => html`<${AlertCard} alert=${alert} />`)}
          </div>`
        : html`<div class="empty-state">No command-plane alerts right now.</div>`}
    </section>
  `
}

function TraceSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <section class="card command-section">
      <div class="card-title">Trace</div>
      ${snapshot && snapshot.traces.events.length > 0
        ? html`<div class="command-trace-stack">
            ${snapshot.traces.events.map(event => html`<${TraceRow} event=${event} />`)}
          </div>`
        : html`<div class="empty-state">No recent trace events.</div>`}
    </section>
  `
}

function ControlSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Approval Queue</div>
        ${snapshot && snapshot.decisions.decisions.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.decisions.decisions.map(decision => html`<${DecisionCard} decision=${decision} />`)}
            </div>`
          : html`<div class="empty-state">No approval queue items.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit Controls</div>
        ${snapshot && snapshot.capacity.capacity.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.capacity.capacity.map(row => html`<${CapacityRowCard} row=${row} />`)}
            </div>`
          : html`<div class="empty-state">No capacity rows projected.</div>`}
      </section>
    </div>
  `
}

function SurfaceBody() {
  switch (commandPlaneSurface.value) {
    case 'topology':
      return html`<${TopologySurface} />`
    case 'alerts':
      return html`<${AlertsSurface} />`
    case 'trace':
      return html`<${TraceSurface} />`
    case 'control':
      return html`<${ControlSurface} />`
    case 'operations':
    default:
      return html`<${OperationsSurface} />`
  }
}

export function Command() {
  useEffect(() => {
    void refreshCommandPlaneSnapshot()
  }, [])

  return html`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>Command Plane</h2>
          <p>Operations-first command surface for company → platoon → squad → agent orchestration, approvals, alerts, and traceability.</p>
        </div>
        <div class="panel-actions">
          <button class="control-btn ghost" onClick=${() => { void refreshCommandPlaneSnapshot() }} disabled=${commandPlaneLoading.value}>
            ${commandPlaneLoading.value ? 'Refreshing…' : 'Refresh'}
          </button>
        </div>
      </div>

      ${commandPlaneError.value
        ? html`<div class="empty-state error">${commandPlaneError.value}</div>`
        : null}
      ${commandPlaneActionError.value
        ? html`<div class="empty-state error">${commandPlaneActionError.value}</div>`
        : null}

      <${SummaryCards} />
      <${SurfaceTabs} />
      <${SurfaceBody} />
    </section>
  `
}
