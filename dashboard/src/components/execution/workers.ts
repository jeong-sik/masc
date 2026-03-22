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
  // When observation state is "offline", override status badge to match
  // so we don't show "가동 중" badge alongside "오프라인" label.
  const effectiveStatus = row.state === 'offline' ? 'offline' : (row.status ?? 'unknown')

  return html`
    <button class="monitor-row rounded-xl p-3.5 ${row.tone} state-${row.state} ${row.state === 'offline' ? 'opacity-35 border-[rgba(85,85,85,0.15)] bg-[rgba(0,0,0,0.08)] hover:opacity-55' : ''}" data-testid=${testId} onClick=${() => openAgentDetail(row.name)}>
      <div class="monitor-row rounded-xl-header">
        <span class="agent-emoji ${row.state === 'offline' ? 'grayscale' : ''}">${row.emoji ?? ''}</span>
        <div class="min-w-0">
          <div class="flex items-center gap-2 flex-wrap">
            <span class="monitor-title">${row.name}</span>
            ${row.korean_name ? html`<span class="monitor-sub">${row.korean_name}</span>` : null}
          </div>
          <div class="monitor-note">${row.note}</div>
        </div>
        <${StatusBadge} status=${effectiveStatus} />
        ${row.state !== 'offline' || effectiveStatus !== 'offline'
          ? html`<span class="monitor-pill ${row.tone} state-${row.state} inline-flex items-center rounded-full px-2 py-[3px] text-[11px] uppercase tracking-[0.06em] ${row.state === 'offline' ? 'bg-[rgba(85,85,85,0.2)] text-[var(--text-dim)] line-through' : ''}">${agentStateLabel(row.state)}</span>`
          : null}
      </div>

      <div class="flex flex-wrap gap-x-3 gap-y-2 mt-2.5 text-[var(--text-muted)] text-[13px]">
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
  const keeper = findKeeperOrFallback(row)
  const onClick = () => {
    openKeeperDetail(keeper)
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
    pipelineStage: keeper.pipeline_stage ?? null,
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

