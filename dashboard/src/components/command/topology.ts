import { html } from 'htm/preact'
import type {
  CommandPlaneAlert,
  CommandPlaneTraceEvent,
  CommandPlaneTreeNode,
} from '../../types'
import { commandPlaneSnapshot } from '../../command-store'
import { alertBorderTone, prettyJson, relativeTime, toneClass, unitKindLabel } from './helpers'

function topologySourceLabel(source?: string) {
  switch (source) {
    case 'explicit':
      return '실제 관리 단위'
    case 'hybrid':
      return '관리 단위 + 자동 보강'
    case 'auto':
      return '자동 투영'
    default:
      return '출처 미상'
  }
}

function topologySourceTone(source?: string) {
  switch (source) {
    case 'explicit':
      return 'ok'
    case 'hybrid':
      return 'warn'
    case 'auto':
      return 'warn'
    default:
      return 'warn'
  }
}

function topologySourceExplanation(source?: string) {
  switch (source) {
    case 'explicit':
      return '지금 보이는 유닛은 실제로 정의된 지휘면 관리 단위입니다.'
    case 'hybrid':
      return '일부는 실제 관리 단위이고, 비어 있는 부분은 실시간 에이전트 편성을 보고 자동 보강한 구조입니다.'
    case 'auto':
      return '이 화면은 실시간 에이전트 편성을 지휘면 모양으로 자동 투영한 것입니다. 실제 명령 체계와 1:1로 같다고 보면 안 됩니다.'
    default:
      return '이 화면은 관리 토폴로지와 실효 토폴로지가 섞여 있을 수 있습니다.'
  }
}

function nodeRealitySummary(node: CommandPlaneTreeNode) {
  const source = node.unit.source ?? 'unknown'
  if (source === 'explicit') {
    return node.active_operation_count && node.active_operation_count > 0
      ? '실제 관리 단위이며 연결된 작전이 있습니다.'
      : '실제 관리 단위이지만 현재 연결된 작전은 없습니다.'
  }
  if (source === 'hybrid') {
    return node.active_operation_count && node.active_operation_count > 0
      ? '관리 단위를 기반으로 자동 보강된 구조이며 일부 작전이 연결돼 있습니다.'
      : '관리 단위를 기반으로 자동 보강된 구조이며 현재 실행 연결은 약합니다.'
  }
  return node.active_operation_count && node.active_operation_count > 0
    ? '자동 생성된 구조이지만 이 노드에 연결된 작전 흔적은 있습니다.'
    : '자동 생성된 구조이며 현재 실행 연결은 없습니다.'
}

function TopologyNode({ node, depth = 0 }: { node: CommandPlaneTreeNode; depth?: number }) {
  const rosterLive = node.roster_live ?? 0
  const rosterTotal = node.roster_total ?? node.unit.roster.length
  const activeOps = node.active_operation_count ?? 0
  const policy = node.unit.policy
  const source = node.unit.source ?? 'unknown'
  const connectionLabel = activeOps > 0 ? `${activeOps}개 작전 연결` : '실행 연결 없음'
  return html`
    <div class="command-tree-node rounded-xl depth-${Math.min(depth, 3)} ${depth <= 2 ? 'border-[rgba(248,113,113,0.3)]' : ''}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${node.unit.label}</strong>
            <span class="command-chip rounded-full">${unitKindLabel(node.unit.kind)}</span>
            <span class="command-chip rounded-full ${toneClass(node.health)}">${node.health ?? 'ok'}</span>
            <span class="command-chip rounded-full ${topologySourceTone(source)}">${topologySourceLabel(source)}</span>
            <span class="command-chip rounded-full ${activeOps > 0 ? 'ok' : 'warn'}">${connectionLabel}</span>
            ${policy?.frozen ? html`<span class="command-chip rounded-full warn">동결됨</span>` : null}
            ${policy?.kill_switch ? html`<span class="command-chip rounded-full bad">킬 스위치</span>` : null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${node.unit.unit_id}</span>
            <span>리더 ${node.unit.leader_id ?? '미지정'} / ${node.leader_status ?? '확인 필요'}</span>
            <span>편성 ${rosterLive}/${rosterTotal}</span>
            <span>작전 ${activeOps}</span>
            <span>자율성 ${policy?.autonomy_level ?? '정보 없음'}</span>
          </div>
          <div class="command-card rounded-xl-sub">${nodeRealitySummary(node)}</div>
          ${node.reasons && node.reasons.length > 0
            ? html`<div class="command-tag rounded-full-row">
                ${node.reasons.map(reason => html`<span class="command-tag rounded-full warn">${reason}</span>`)}
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
    <article class="command-alert ${toneClass(alert.severity)} ${alertBorderTone(toneClass(alert.severity))}">
      <div class="command-card rounded-xl-head">
        <strong>${alert.title ?? alert.kind ?? alert.alert_id}</strong>
        <span class="command-chip rounded-full ${toneClass(alert.severity)}">${alert.severity ?? 'warn'}</span>
      </div>
      <div class="command-alert-meta">
        <span>${alert.scope_type ?? '범위'}:${alert.scope_id ?? '정보 없음'}</span>
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
          <span class="command-chip rounded-full">${event.source ?? 'control_plane'}</span>
          <span class="command-chip rounded-full">${relativeTime(event.timestamp)}</span>
        </div>
        <div class="command-card rounded-xl-sub">
          ${event.operation_id ?? event.trace_id}
          ${event.unit_id ? ` · ${event.unit_id}` : ''}
          ${event.actor ? ` · ${event.actor}` : ''}
        </div>
      </div>
      <pre class="m-0 p-3 rounded-[10px] bg-[rgba(9,12,20,0.75)] text-[rgba(224,242,254,0.92)] text-[length:var(--fs-sm)] leading-[1.45] max-h-[220px] overflow-auto whitespace-pre-wrap break-words [overflow-wrap:anywhere]">${prettyJson(event.detail)}</pre>
    </article>
  `
}

export function TopologySurface() {
  const snapshot = commandPlaneSnapshot.value
  const topology = snapshot?.topology
  const source = topology?.source
  const summary = topology?.summary
  const managedUnits = summary?.managed_unit_count ?? 0
  const activeOps = summary?.active_operation_count ?? 0
  return html`
    <section class="card rounded-xl min-h-[240px]">
      <div class="card rounded-xl-title-row">
        <div class="card rounded-xl-title">지휘 계층</div>
      </div>
      ${snapshot
        ? html`
            <div class="command-topology-explainer rounded-xl">
              <div class="command-tree-title-row">
                <span class="command-chip rounded-full ${topologySourceTone(source)}">${topologySourceLabel(source)}</span>
                <span class="command-chip rounded-full">관리 유닛 ${managedUnits}</span>
                <span class="command-chip rounded-full ${activeOps > 0 ? 'ok' : 'warn'}">활성 작전 ${activeOps}</span>
              </div>
              <p>${topologySourceExplanation(source)}</p>
            </div>
          `
        : null}
      ${snapshot && snapshot.topology.units.length > 0
        ? html`${snapshot.topology.units.map(node => html`<${TopologyNode} node=${node} />`)}`
        : html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">지금은 실시간 에이전트나 관리 유닛 기준으로 그릴 지휘 계층이 없습니다.</div>`}
    </section>
  `
}

export function AlertsSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <section class="card rounded-xl min-h-[240px]">
      <div class="card rounded-xl-title-row">
        <div class="card rounded-xl-title">경보</div>
      </div>
      ${snapshot && snapshot.alerts.alerts.length > 0
        ? html`<div class="command-card rounded-xl-stack">
            ${snapshot.alerts.alerts.map(alert => html`<${AlertCard} alert=${alert} />`)}
          </div>`
        : html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">지금 올라온 지휘면 경보는 없습니다.</div>`}
    </section>
  `
}

export function TraceSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <section class="card rounded-xl min-h-[240px]">
      <div class="card rounded-xl-title-row">
        <div class="card rounded-xl-title">최근 트레이스</div>
      </div>
      ${snapshot && snapshot.traces.events.length > 0
        ? html`<div class="command-trace-stack">
            ${snapshot.traces.events.map(event => html`<${TraceRow} event=${event} />`)}
          </div>`
        : html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">최근 트레이스 이벤트가 없습니다.</div>`}
    </section>
  `
}
