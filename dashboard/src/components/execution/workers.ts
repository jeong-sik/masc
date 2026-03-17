// 실행 표면 — 작업자, 연속성, Lodge 카드

import { html } from 'htm/preact'
import { KeeperCard, type CanonicalKeeperCardModel } from '../common/keeper-card'
import { keeperRuntimeLabel } from '../common/keeper-identity'
import { StatusBadge } from '../common/status-badge'
import { TimeAgo } from '../common/time-ago'
import { openKeeperDetail } from '../keeper-detail'
import { openAgentDetail } from '../agent-detail'
import type {
  DashboardExecutionWorkerSupportBrief,
  DashboardExecutionLodgeTick,
  DashboardExecutionLodgeCheckin,
  DashboardExecutionContinuityBrief,
} from '../../types'
import {
  toneClass,
  statusLabel,
  agentStateLabel,
  signalTruthLabel,
  evidenceSourceLabel,
  continuityStateLabel,
  lodgeOutcomeLabel,
  lodgeActionKindLabel,
  findKeeper,
  MonitorStat,
} from './shared'

export function WorkerSupportRow({
  row,
  testId,
}: {
  row: DashboardExecutionWorkerSupportBrief
  testId: string
}) {
  return html`
    <button class="monitor-row ${row.tone} state-${row.state}" data-testid=${testId} onClick=${() => openAgentDetail(row.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${row.emoji ?? ''}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${row.name}</span>
            ${row.korean_name ? html`<span class="monitor-sub">${row.korean_name}</span>` : null}
          </div>
          <div class="monitor-note">${row.note}</div>
        </div>
        <${StatusBadge} status=${row.status ?? 'unknown'} />
        <span class="monitor-pill ${row.tone} state-${row.state}">${agentStateLabel(row.state)}</span>
      </div>

      <div class="monitor-meta">
        ${row.last_signal_at ? html`<span>신호 <${TimeAgo} timestamp=${row.last_signal_at} /></span>` : html`<span>최근 신호 없음</span>`}
        <span>${signalTruthLabel(row.signal_truth)} · ${evidenceSourceLabel(row.evidence_source)}</span>
        ${typeof row.last_signal_age_sec === 'number' ? html`<span>${row.last_signal_age_sec}s ago</span>` : null}
        <span>${(row.active_task_count ?? 0) > 0 ? `활성 작업 ${row.active_task_count}개` : '활성 작업 없음'}</span>
        ${row.related_session_id ? html`<span>세션 · ${row.related_session_id}</span>` : null}
        ${row.related_operation_id ? html`<span>작전 · ${row.related_operation_id}</span>` : null}
      </div>

      <div class="monitor-focus">${row.focus}</div>
      ${row.recent_output_preview && row.recent_output_preview !== row.focus
        ? html`<div class="monitor-footnote">최근 상세: ${row.recent_output_preview}</div>`
        : null}
    </button>
  `
}

export function ContinuityRow({ row }: { row: DashboardExecutionContinuityBrief }) {
  const onClick = () => {
    const keeper = findKeeper(row.name)
    if (keeper) openKeeperDetail(keeper)
  }
  const runtimeLabel = keeperRuntimeLabel(row.name, row.agent_name)
  const model: CanonicalKeeperCardModel = {
    name: row.name,
    koreanName: row.korean_name ?? null,
    runtimeLabel,
    emoji: row.emoji ?? null,
    tone: row.tone,
    statusRaw: row.status ?? null,
    statusLabel: statusLabel(row.status),
    stateClass: row.state,
    stateLabel: continuityStateLabel(row.state),
    contextRatio: row.context_ratio ?? null,
    note: row.note,
    focus: row.focus,
    lastActivityAt: row.last_signal_at ?? null,
    lastActivityFallback: '최근 활동 없음',
    relatedSessionId: row.related_session_id ?? null,
    continuity: row.continuity ?? null,
    lifecycle: row.lifecycle ?? null,
    summary: row.continuity_summary ?? row.recent_output_preview ?? null,
    recentInput: row.recent_input_preview ?? null,
    recentOutput: row.recent_output_preview ?? null,
    recentTools: row.recent_tool_names ?? [],
    allowedTools: row.allowed_tool_names ?? [],
    routeSummary: row.skill_route_summary ?? null,
    auditSource: row.tool_audit_source ?? null,
    auditAt: row.tool_audit_at ?? null,
    disclosureLabel: '연속성 상세',
  }

  return html`<${KeeperCard}
    variant="execution"
    model=${model}
    onClick=${onClick}
    testId="execution.continuity-card"
  />`
}

export function LodgeTickCard({ tick }: { tick: DashboardExecutionLodgeTick | null }) {
  if (!tick) {
    return html`<div class="empty-state">최근 social activity 기록이 없습니다.</div>`
  }
  return html`
    <div class="monitor-nested-card">
      <div class="stats-grid">
        <${MonitorStat} label="검토" value=${tick.checked ?? 0} color="#22d3ee" />
        <${MonitorStat} label="행동" value=${tick.acted ?? 0} color="#4ade80" />
        <${MonitorStat} label="판단 패스" value=${tick.passed ?? 0} color="#94a3b8" />
        <${MonitorStat} label="시스템 스킵" value=${tick.skipped ?? 0} color="#fbbf24" />
        <${MonitorStat} label="실패" value=${tick.failed ?? 0} color="#fb7185" />
      </div>
      <div class="monitor-meta">
        ${tick.last_tick_at ? html`<span>마지막 tick <${TimeAgo} timestamp=${tick.last_tick_at} /></span>` : html`<span>마지막 tick 없음</span>`}
        ${tick.strategy ? html`<span>전략 · ${tick.strategy}</span>` : null}
        ${tick.queue_depth != null ? html`<span>큐 · ${tick.queue_depth}</span>` : null}
        ${tick.last_pass_reason ? html`<span>대표 패스 이유 · ${tick.last_pass_reason}</span>` : null}
        ${tick.last_system_skip_reason
          ? html`<span>대표 시스템 스킵 이유 · ${tick.last_system_skip_reason}</span>`
          : tick.last_skip_reason
            ? html`<span>대표 시스템 스킵 이유 · ${tick.last_skip_reason}</span>`
            : null}
      </div>
      ${tick.activity_report ? html`<div class="monitor-footnote">${tick.activity_report}</div>` : null}
    </div>
  `
}

export function LodgeCheckinRow({ row }: { row: DashboardExecutionLodgeCheckin }) {
  return html`
    <button
      class="monitor-row ${toneClass(row.outcome === 'failed' ? 'bad' : row.outcome === 'skipped' ? 'warn' : 'ok')}"
      data-testid="execution.lodge-checkin-card"
      onClick=${() => openAgentDetail(row.agent_name)}
    >
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${row.agent_name}</span>
            ${row.worker_name ? html`<span class="monitor-sub">worker · ${row.worker_name}</span>` : null}
          </div>
          <div class="monitor-note">${row.reason ?? row.summary ?? '이유가 기록되지 않았습니다.'}</div>
        </div>
        <span class="monitor-pill ${toneClass(row.outcome === 'failed' ? 'bad' : row.outcome === 'skipped' ? 'warn' : 'ok')}">${lodgeOutcomeLabel(row.outcome)}</span>
      </div>
        <div class="monitor-meta">
        <span>trigger · ${row.trigger ?? 'unknown'}</span>
        ${row.checked_at ? html`<span><${TimeAgo} timestamp=${row.checked_at} /></span>` : null}
        <span>action · ${lodgeActionKindLabel(row.action_kind)}</span>
      </div>
      ${row.summary && row.summary !== row.reason
        ? html`<div class="monitor-focus">${row.summary}</div>`
        : null}
      ${row.failure_reason || row.decision_reason
        ? html`<div class="monitor-footnote">
            ${row.failure_reason ? `실패 이유: ${row.failure_reason}` : `판단 이유: ${row.decision_reason}`}
          </div>`
        : null}
    </button>
  `
}
