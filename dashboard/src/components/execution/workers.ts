// 실행 표면 — 작업자, 연속성 카드

import { html } from 'htm/preact'
import { KeeperCard, type CanonicalKeeperCardModel } from '../common/keeper-card'
import { keeperRuntimeLabel } from '../common/keeper-identity'
import { StatusBadge } from '../common/status-badge'
import { TimeAgo } from '../common/time-ago'
import { openKeeperDetail } from '../keeper-detail'
import { openAgentDetail } from '../agent-detail'
import type {
  DashboardExecutionWorkerSupportBrief,
  DashboardExecutionContinuityBrief,
} from '../../types'
import {
  statusLabel,
  agentStateLabel,
  signalTruthLabel,
  evidenceSourceLabel,
  continuityStateLabel,
  findKeeperOrFallback,
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
    openKeeperDetail(findKeeperOrFallback(row))
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

