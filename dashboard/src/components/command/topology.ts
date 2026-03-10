import { html } from 'htm/preact'
import type {
  CommandPlaneAlert,
  CommandPlaneTraceEvent,
  CommandPlaneTreeNode,
} from '../../types'
import { commandPlaneSnapshot } from '../../command-store'
import { PanelSemanticDetails } from '../common/semantic-layer'
import { prettyJson, relativeTime, toneClass, unitKindLabel } from './helpers'

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

export function TraceRow({ event }: { event: CommandPlaneTraceEvent }) {
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

export function TopologySurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${PanelSemanticDetails} panelId="command.topology" compact=${true} />
      </div>
      ${snapshot && snapshot.topology.units.length > 0
        ? html`${snapshot.topology.units.map(node => html`<${TopologyNode} node=${node} />`)}`
        : html`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `
}

export function AlertsSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${PanelSemanticDetails} panelId="command.alerts" compact=${true} />
      </div>
      ${snapshot && snapshot.alerts.alerts.length > 0
        ? html`<div class="command-card-stack">
            ${snapshot.alerts.alerts.map(alert => html`<${AlertCard} alert=${alert} />`)}
          </div>`
        : html`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `
}

export function TraceSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${PanelSemanticDetails} panelId="command.trace" compact=${true} />
      </div>
      ${snapshot && snapshot.traces.events.length > 0
        ? html`<div class="command-trace-stack">
            ${snapshot.traces.events.map(event => html`<${TraceRow} event=${event} />`)}
          </div>`
        : html`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `
}
