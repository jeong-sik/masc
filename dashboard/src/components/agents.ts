// Execution surface — session/operation-first execution diagnostics

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { SurfaceSemanticIntro } from './common/semantic-layer'
import { StatusBadge } from './common/status-badge'
import { MitosisRing } from './common/mitosis-ring'
import { TimeAgo } from './common/time-ago'
import { openKeeperDetail } from './keeper-detail'
import { openAgentDetail } from './agent-detail'
import { navigate } from '../router'
import {
  executionSummary,
  executionQueue,
  executionSessionBriefs,
  executionOperationBriefs,
  executionWorkerSupportBriefs,
  executionContinuityBriefs,
  executionOfflineWorkerBriefs,
  keepers,
} from '../store'
import type {
  DashboardExecutionQueueItem,
  DashboardExecutionSessionBrief,
  DashboardExecutionOperationBrief,
  DashboardExecutionWorkerSupportBrief,
  DashboardExecutionContinuityBrief,
  DashboardExecutionHandoff,
  Keeper,
} from '../types'
import {
  createExecutionWorkflowContext,
  workflowCommandParams,
  workflowInterveneParams,
  persistWorkflowContext,
} from '../workflow-context'

const selectedQueueId = signal<string | null>(null)
const selectedSessionId = signal<string | null>(null)
const selectedOperationId = signal<string | null>(null)

function toneClass(tone?: string | null): string {
  if (tone === 'bad' || tone === 'critical' || tone === 'offline') return 'bad'
  if (tone === 'warn' || tone === 'paused' || tone === 'blocked' || tone === 'interrupted') return 'warn'
  return 'ok'
}

function formatContext(value?: number | null): string {
  if (typeof value !== 'number' || Number.isNaN(value)) return '—'
  return `${Math.round(value * 100)}%`
}

function findKeeper(name?: string | null): Keeper | null {
  if (!name) return null
  return keepers.value.find(keeper => keeper.name === name || keeper.agent_name === name) ?? null
}

function agentStateLabel(state: DashboardExecutionWorkerSupportBrief['state']): string {
  switch (state) {
    case 'working': return '작업 중'
    case 'watching': return '대기 중'
    case 'quiet': return '조용함'
    case 'offline': return '오프라인'
  }
}

function continuityStateLabel(state: DashboardExecutionContinuityBrief['state']): string {
  switch (state) {
    case 'critical': return '위험'
    case 'warning': return '주의'
    default: return '정상'
  }
}

function openHandoff(handoff: DashboardExecutionHandoff | null | undefined): void {
  if (!handoff) return
  const context = createExecutionWorkflowContext({
    targetType: handoff.target_type,
    targetId: handoff.target_id,
    focusKind: handoff.focus_kind,
    operationId: handoff.operation_id ?? null,
    commandSurface: handoff.command_surface ?? null,
    sourceLabel: 'Execution 진단',
    summary: handoff.label,
  })
  persistWorkflowContext(context)
  navigate(
    handoff.surface,
    handoff.surface === 'intervene'
      ? workflowInterveneParams(context)
      : workflowCommandParams(context),
  )
}

function MonitorStat({
  label,
  value,
  color,
  caption,
}: {
  label: string
  value: string | number
  color?: string
  caption?: string
}) {
  return html`
    <div class="stat-card">
      <div class="stat-label">${label}</div>
      <div class="stat-value" style=${color ? `color:${color}` : ''}>${value}</div>
      ${caption ? html`<div class="monitor-stat-caption">${caption}</div>` : null}
    </div>
  `
}

function HandoffButtons({
  intervene,
  command,
}: {
  intervene?: DashboardExecutionHandoff | null
  command?: DashboardExecutionHandoff | null
}) {
  return html`
    <div class="control-row">
      ${intervene
        ? html`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${(event: Event) => {
                event.stopPropagation()
                openHandoff(intervene)
              }}
            >
              ${intervene.label}
            </button>
          `
        : null}
      ${command
        ? html`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${(event: Event) => {
                event.stopPropagation()
                openHandoff(command)
              }}
            >
              ${command.label}
            </button>
          `
        : null}
    </div>
  `
}

function QueueCard({ item, selected }: { item: DashboardExecutionQueueItem; selected: boolean }) {
  return html`
    <button
      class="mission-card-select ${selected ? 'active' : ''}"
      data-testid="execution.queue-card"
      onClick=${() => {
        selectedQueueId.value = selected ? null : item.id
        selectedSessionId.value = null
        selectedOperationId.value = null
      }}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${item.kind === 'session' ? item.target_id : item.linked_session_id ?? item.target_id}</div>
          <div class="mission-card-title">${item.summary}</div>
        </div>
        <span class="command-chip ${toneClass(item.severity)}">${item.status ?? item.severity}</span>
      </div>
      <div class="mission-card-meta">
        <span>${item.kind}</span>
        ${item.linked_operation_id ? html`<span>linked op · ${item.linked_operation_id}</span>` : null}
        ${item.last_seen_at ? html`<span><${TimeAgo} timestamp=${item.last_seen_at} /></span>` : null}
      </div>
      <${HandoffButtons} intervene=${item.intervene_handoff} command=${item.command_handoff} />
    </button>
  `
}

function SessionCard({ brief, selected }: { brief: DashboardExecutionSessionBrief; selected: boolean }) {
  return html`
    <button
      class="mission-card-select ${selected ? 'active' : ''}"
      data-testid="execution.session-card"
      onClick=${() => {
        selectedSessionId.value = selected ? null : brief.session_id
        selectedOperationId.value = null
      }}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${brief.session_id}${brief.room ? ` · ${brief.room}` : ''}</div>
          <div class="mission-card-title">${brief.goal}</div>
        </div>
        <span class="command-chip ${toneClass(brief.health ?? brief.status)}">${brief.status ?? 'unknown'}</span>
      </div>
      <div class="mission-card-meta">
        <span>health · ${brief.health ?? 'ok'}</span>
        ${brief.linked_operation_id ? html`<span>op · ${brief.linked_operation_id}</span>` : null}
        ${brief.last_activity_at ? html`<span><${TimeAgo} timestamp=${brief.last_activity_at} /></span>` : null}
      </div>
      ${brief.runtime_blocker
        ? html`<div class="mission-card-detail">${brief.runtime_blocker}</div>`
        : brief.last_activity_summary
          ? html`<div class="mission-card-detail">${brief.last_activity_summary}</div>`
          : null}
      ${brief.worker_gap_summary ? html`<div class="monitor-footnote">${brief.worker_gap_summary}</div>` : null}
      <${HandoffButtons} intervene=${brief.intervene_handoff} command=${brief.command_handoff} />
    </button>
  `
}

function OperationCard({ brief, selected }: { brief: DashboardExecutionOperationBrief; selected: boolean }) {
  return html`
    <button
      class="mission-card-select ${selected ? 'active' : ''}"
      data-testid="execution.operation-card"
      onClick=${() => {
        selectedOperationId.value = selected ? null : brief.operation_id
        selectedSessionId.value = brief.linked_session_id ?? null
      }}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${brief.operation_id}${brief.assigned_unit_label ? ` · ${brief.assigned_unit_label}` : ''}</div>
          <div class="mission-card-title">${brief.objective}</div>
        </div>
        <span class="command-chip ${toneClass(brief.blocker_summary ? 'warn' : brief.status)}">${brief.status ?? 'unknown'}</span>
      </div>
      <div class="mission-card-meta">
        ${brief.stage ? html`<span>stage · ${brief.stage}</span>` : null}
        ${brief.linked_session_id ? html`<span>session · ${brief.linked_session_id}</span>` : null}
        ${brief.updated_at ? html`<span><${TimeAgo} timestamp=${brief.updated_at} /></span>` : null}
      </div>
      ${brief.blocker_summary ? html`<div class="mission-card-detail">${brief.blocker_summary}</div>` : null}
      ${brief.next_tool ? html`<div class="monitor-footnote">next tool · ${brief.next_tool}</div>` : null}
      <${HandoffButtons} command=${brief.command_handoff} />
    </button>
  `
}

function WorkerSupportRow({
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
        <span>${(row.active_task_count ?? 0) > 0 ? `활성 작업 ${row.active_task_count}개` : '활성 작업 없음'}</span>
        ${row.related_session_id ? html`<span>session · ${row.related_session_id}</span>` : null}
        ${row.related_operation_id ? html`<span>op · ${row.related_operation_id}</span>` : null}
      </div>

      <div class="monitor-focus">${row.focus}</div>
      ${row.recent_output_preview && row.recent_output_preview !== row.focus
        ? html`<div class="monitor-footnote">최근 상세: ${row.recent_output_preview}</div>`
        : null}
    </button>
  `
}

function ContinuityRow({ row }: { row: DashboardExecutionContinuityBrief }) {
  const onClick = () => {
    const keeper = findKeeper(row.name)
    if (keeper) openKeeperDetail(keeper)
  }

  return html`
    <button class="monitor-row ${row.tone} state-${row.state}" data-testid="execution.continuity-card" onClick=${onClick}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${row.emoji ?? ''}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${row.name}</span>
            ${row.korean_name ? html`<span class="monitor-sub">${row.korean_name}</span>` : null}
          </div>
          <div class="monitor-note">${row.note}</div>
        </div>
        <${MitosisRing} ratio=${row.context_ratio ?? 0} size=${34} stroke=${4} />
        <${StatusBadge} status=${row.status ?? 'unknown'} />
        <span class="monitor-pill ${row.tone}">${continuityStateLabel(row.state)}</span>
      </div>

      <div class="monitor-meta">
        ${row.last_signal_at ? html`<span>최근 활동 <${TimeAgo} timestamp=${row.last_signal_at} /></span>` : html`<span>최근 활동 없음</span>`}
        ${row.related_session_id ? html`<span>session · ${row.related_session_id}</span>` : null}
        ${row.continuity ? html`<span>${row.continuity}</span>` : null}
        ${row.lifecycle ? html`<span>라이프사이클 ${row.lifecycle}</span>` : null}
        <span>컨텍스트 ${formatContext(row.context_ratio)}</span>
      </div>

      <div class="monitor-focus">${row.focus}</div>
      ${row.skill_reason ? html`<div class="monitor-footnote">연속성 이유: ${row.skill_reason}</div>` : null}
    </button>
  `
}

export function Execution() {
  const summary = executionSummary.value
  const queueRows = executionQueue.value
  const sessionRowsAll = executionSessionBriefs.value
  const operationRowsAll = executionOperationBriefs.value
  const workerSupportAll = executionWorkerSupportBriefs.value
  const continuityAll = executionContinuityBriefs.value
  const offlineRowsAll = executionOfflineWorkerBriefs.value

  if (selectedQueueId.value && !queueRows.some(item => item.id === selectedQueueId.value)) {
    selectedQueueId.value = null
  }
  if (selectedSessionId.value && !sessionRowsAll.some(item => item.session_id === selectedSessionId.value)) {
    selectedSessionId.value = null
  }
  if (selectedOperationId.value && !operationRowsAll.some(item => item.operation_id === selectedOperationId.value)) {
    selectedOperationId.value = null
  }

  const activeQueue = selectedQueueId.value
    ? queueRows.find(item => item.id === selectedQueueId.value) ?? null
    : null

  const activeSessionId = (() => {
    if (selectedSessionId.value) return selectedSessionId.value
    if (!activeQueue) return null
    if (activeQueue.kind === 'session') return activeQueue.target_id
    return activeQueue.linked_session_id ?? null
  })()

  const activeOperationId = (() => {
    if (selectedOperationId.value) return selectedOperationId.value
    if (!activeQueue) return null
    if (activeQueue.kind === 'operation') return activeQueue.target_id
    return activeQueue.linked_operation_id ?? null
  })()

  const sessionRows =
    activeSessionId
      ? sessionRowsAll.filter(item => item.session_id === activeSessionId)
      : activeOperationId
        ? sessionRowsAll.filter(item => item.linked_operation_id === activeOperationId)
        : sessionRowsAll

  const operationRows =
    activeOperationId
      ? operationRowsAll.filter(item => item.operation_id === activeOperationId)
      : activeSessionId
        ? operationRowsAll.filter(item => item.linked_session_id === activeSessionId || item.operation_id === sessionRows[0]?.linked_operation_id)
        : operationRowsAll

  const workerSupportRows =
    activeSessionId || activeOperationId
      ? workerSupportAll.filter(item =>
          (activeSessionId ? item.related_session_id === activeSessionId : false)
          || (activeOperationId ? item.related_operation_id === activeOperationId : false))
      : workerSupportAll

  const continuityRows =
    activeSessionId
      ? continuityAll.filter(item => item.related_session_id === activeSessionId || item.tone !== 'ok')
      : continuityAll

  const offlineRows =
    activeSessionId || activeOperationId
      ? offlineRowsAll.filter(item =>
          (activeSessionId ? item.related_session_id === activeSessionId : false)
          || (activeOperationId ? item.related_operation_id === activeOperationId : false)
          || item.tone !== 'ok')
      : offlineRowsAll

  return html`
    <div class="agents-monitor">
      <${SurfaceSemanticIntro} surfaceId="execution" />
      <div class="stats-grid">
        <${MonitorStat} label="활성 세션" value=${summary?.active_sessions ?? sessionRowsAll.length} color="#4ade80" caption="실행 관점의 session" />
        <${MonitorStat} label="막힌 세션" value=${summary?.blocked_sessions ?? sessionRowsAll.filter(item => toneClass(item.health ?? item.status) !== 'ok').length} color="#fbbf24" caption="개입 후보 session" />
        <${MonitorStat} label="활성 작전" value=${summary?.active_operations ?? operationRowsAll.length} color="#22d3ee" caption="command-plane operation" />
        <${MonitorStat} label="막힌 작전" value=${summary?.blocked_operations ?? operationRowsAll.filter(item => item.blocker_summary).length} color="#fb7185" caption="원인 분석이 필요한 작전" />
        <${MonitorStat} label="worker 경고" value=${summary?.worker_alerts ?? workerSupportAll.filter(item => item.tone !== 'ok').length} color="#fb7185" caption="supporting worker pressure" />
        <${MonitorStat} label="연속성 경고" value=${summary?.continuity_alerts ?? continuityAll.filter(item => item.tone !== 'ok').length} color="#fb7185" caption="keeper continuity pressure" />
      </div>

      <${Card}
        title="Execution Queue"
        class="section"
        semanticId="execution.queue"
        testId="execution.queue"
      >
        <div class="monitor-section-head">
          <h2 class="monitor-headline">지금 막힌 실행과 다음 handoff</h2>
          <p class="monitor-subheadline">session과 operation을 한 queue로 보고, 어디를 먼저 Intervene/Command로 넘길지 판단합니다.</p>
        </div>
        <div class="monitor-alert-list">
          ${queueRows.length === 0
            ? html`<div class="empty-state">지금은 막힌 실행이 없습니다</div>`
            : queueRows.map(item => html`<${QueueCard} key=${item.id} item=${item} selected=${selectedQueueId.value === item.id} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${Card}
          title="Affected Sessions"
          class="section"
          semanticId="execution.sessions"
          testId="execution.session-briefs"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">영향받는 session</h2>
            <p class="monitor-subheadline">queue에서 고른 실행이 어떤 session 목표와 runtime blocker를 갖는지 요약합니다.</p>
          </div>
          <div class="monitor-list">
            ${sessionRows.length === 0
              ? html`<div class="empty-state">선택된 실행과 연결된 session이 없습니다</div>`
              : sessionRows.map(row => html`<${SessionCard} key=${row.session_id} brief=${row} selected=${selectedSessionId.value === row.session_id} />`)}
          </div>
        <//>

        <${Card}
          title="Affected Operations"
          class="section"
          semanticId="execution.operations"
          testId="execution.operation-briefs"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">영향받는 작전</h2>
            <p class="monitor-subheadline">command-plane operation의 blocker와 next tool을 얇게 보여주고, deep truth는 Command로 넘깁니다.</p>
          </div>
          <div class="monitor-list">
            ${operationRows.length === 0
              ? html`<div class="empty-state">선택된 실행과 연결된 operation이 없습니다</div>`
              : operationRows.map(row => html`<${OperationCard} key=${row.operation_id} brief=${row} selected=${selectedOperationId.value === row.operation_id} />`)}
          </div>
        <//>

        <${Card}
          title="Worker Support"
          class="section"
          semanticId="execution.worker_support"
          testId="execution.worker-support"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">지원 worker</h2>
            <p class="monitor-subheadline">선택된 session/operation에 연결된 worker만 보이고, 전체 worker wall은 더 이상 첫 화면을 차지하지 않습니다.</p>
          </div>
          <div class="monitor-list">
            ${workerSupportRows.length === 0
              ? html`<div class="empty-state">연결된 worker가 없습니다</div>`
              : workerSupportRows.map(row => html`<${WorkerSupportRow} key=${row.name} row=${row} testId="execution.worker-card" />`)}
          </div>
        <//>

        <${Card}
          title="Continuity"
          class="section"
          semanticId="execution.continuity"
          testId="execution.continuity"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">연속성 보조 lane</h2>
            <p class="monitor-subheadline">keeper continuity는 supporting lane으로만 남기고, unhealthy keeper 위주로 노출합니다.</p>
          </div>
          <div class="monitor-list">
            ${continuityRows.length === 0
              ? html`<div class="empty-state">지금은 연속성 경고가 없습니다</div>`
              : continuityRows.map(row => html`<${ContinuityRow} key=${row.name} row=${row} />`)}
          </div>
        <//>

        <${Card}
          title="Offline Workers"
          class="section"
          semanticId="execution.offline"
          testId="execution.offline-workers"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">오프라인 worker</h2>
            <p class="monitor-subheadline">빠진 worker는 하단 lane으로 분리해 활성 실행 판단을 방해하지 않게 유지합니다.</p>
          </div>
          <div class="monitor-list">
            ${offlineRows.length === 0
              ? html`<div class="empty-state">지금은 오프라인 worker가 없습니다</div>`
              : offlineRows.map(row => html`<${WorkerSupportRow} key=${row.name} row=${row} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `
}

export const Agents = Execution
