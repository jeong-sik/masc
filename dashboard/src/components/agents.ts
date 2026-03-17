// 실행 표면 — 세션/작전 중심 실행 진단

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { KeeperCard, type CanonicalKeeperCardModel } from './common/keeper-card'
import { RoomTruthStrip } from './common/room-truth-strip'
import { keeperRuntimeLabel } from './common/keeper-identity'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { openKeeperDetail } from './keeper-detail'
import { openAgentDetail } from './agent-detail'
import { navigate } from '../router'
import {
  executionQueue,
  executionSessionBriefs,
  executionOperationBriefs,
  executionWorkerSupportBriefs,
  executionLodgeTick,
  executionLodgeCheckins,
  executionContinuityBriefs,
  executionOfflineWorkerBriefs,
  keepers,
} from '../store'
import type {
  DashboardExecutionQueueItem,
  DashboardExecutionSessionBrief,
  DashboardExecutionOperationBrief,
  DashboardExecutionWorkerSupportBrief,
  DashboardExecutionLodgeTick,
  DashboardExecutionLodgeCheckin,
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

const TERMINAL_STATUSES = new Set(['completed', 'interrupted', 'failed', 'cancelled'])

function isTerminalStatus(status?: string | null): boolean {
  return TERMINAL_STATUSES.has((status ?? '').trim().toLowerCase())
}

function partitionByTerminal<T>(items: T[], getStatus: (item: T) => string | null | undefined): [active: T[], terminal: T[]] {
  const active: T[] = []
  const terminal: T[] = []
  for (const item of items) {
    ;(isTerminalStatus(getStatus(item)) ? terminal : active).push(item)
  }
  return [active, terminal]
}

function toneClass(tone?: string | null): string {
  if (tone === 'bad' || tone === 'critical' || tone === 'offline') return 'bad'
  if (tone === 'warn' || tone === 'paused' || tone === 'blocked' || tone === 'interrupted') return 'warn'
  return 'ok'
}

function statusLabel(value?: string | null): string {
  const normalized = (value ?? '').trim().toLowerCase()
  switch (normalized) {
    case 'ok':
    case 'healthy':
    case 'green':
      return '안정'
    case 'active':
    case 'running':
      return '진행 중'
    case 'paused':
      return '일시정지'
    case 'blocked':
      return '막힘'
    case 'completed':
      return '완료'
    case 'interrupted':
      return '중단됨'
    case 'failed':
      return '실패'
    case 'cancelled':
      return '취소됨'
    case 'warn':
      return '주의'
    case 'bad':
    case 'critical':
      return '위험'
    case 'offline':
      return '오프라인'
    case 'idle':
    case 'quiet':
      return '대기'
    case 'unknown':
    case '':
      return '확인 필요'
    default:
      return value?.trim() || '확인 필요'
  }
}

function queueKindLabel(kind: DashboardExecutionQueueItem['kind']): string {
  return kind === 'session' ? '세션' : '작전'
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

function signalTruthLabel(value?: DashboardExecutionWorkerSupportBrief['signal_truth'] | null): string {
  switch (value) {
    case 'live': return '최근 신호(≤5m)'
    case 'stale': return '오래된 신호(>5m)'
    case 'absent': return 'signal 없음'
    default: return value ?? 'signal 미상'
  }
}

function evidenceSourceLabel(value?: DashboardExecutionWorkerSupportBrief['evidence_source'] | null): string {
  switch (value) {
    case 'message': return '최근 출력'
    case 'presence': return 'presence/하트비트'
    case 'none': return '근거 없음'
    default: return value ?? '근거 미상'
  }
}

function continuityStateLabel(state: DashboardExecutionContinuityBrief['state']): string {
  switch (state) {
    case 'critical': return '위험'
    case 'warning': return '주의'
    default: return '정상'
  }
}

function lodgeOutcomeLabel(outcome: DashboardExecutionLodgeCheckin['outcome']): string {
  switch (outcome) {
    case 'acted': return '행동'
    case 'passed': return '판단 패스'
    case 'skipped': return '시스템 스킵'
    case 'failed': return '실패'
    default: return outcome
  }
}

function lodgeActionKindLabel(value?: DashboardExecutionLodgeCheckin['action_kind'] | null): string {
  switch (value) {
    case 'post': return 'post'
    case 'comment': return 'comment'
    case 'vote': return 'vote'
    case 'none':
    case null:
    case undefined:
      return '없음'
    default:
      return value
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
    sourceLabel: '실행 진단',
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
  const terminal = isTerminalStatus(item.status)
  return html`
    <button
      class="mission-card-select ${selected ? 'active' : ''} ${terminal ? 'terminated' : ''}"
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
        <span class="command-chip ${terminal ? 'muted' : toneClass(item.severity)}">${statusLabel(item.status ?? item.severity)}</span>
      </div>
      <div class="mission-card-meta">
        <span>${queueKindLabel(item.kind)}</span>
        ${item.linked_operation_id ? html`<span>연결 작전 · ${item.linked_operation_id}</span>` : null}
        ${item.last_seen_at ? html`<span><${TimeAgo} timestamp=${item.last_seen_at} /></span>` : null}
      </div>
      <${HandoffButtons}
        intervene=${terminal ? null : item.intervene_handoff}
        command=${item.command_handoff}
      />
    </button>
  `
}

function ExecutionQueueBody({ queueRows }: { queueRows: DashboardExecutionQueueItem[] }) {
  const [activeItems, terminalItems] = partitionByTerminal(queueRows, item => item.status)
  const hasActive = activeItems.length > 0
  const hasTerminal = terminalItems.length > 0

  return html`
    <div class="monitor-section-head">
      <h2 class="monitor-headline">개입이 필요한 실행</h2>
      <p class="monitor-subheadline">진행 중인 세션과 작전 중 막힌 항목을 보여줍니다.${hasTerminal ? ' 종료된 항목은 하단에 접혀 있습니다.' : ''}</p>
    </div>
    <div class="monitor-alert-list">
      ${hasActive
        ? activeItems.map(item => html`<${QueueCard} key=${item.id} item=${item} selected=${selectedQueueId.value === item.id} />`)
        : html`<div class="empty-state">지금은 개입이 필요한 실행이 없습니다.</div>`}
    </div>
    ${hasTerminal
      ? html`
          <details class="runtime-collapsible" data-testid="execution.queue-terminal">
            <summary class="runtime-summary">종료된 항목 ${terminalItems.length}건</summary>
            <div class="monitor-alert-list">
              ${terminalItems.map(item => html`<${QueueCard} key=${item.id} item=${item} selected=${selectedQueueId.value === item.id} />`)}
            </div>
          </details>
        `
      : null}
  `
}

function SessionCard({ brief, selected }: { brief: DashboardExecutionSessionBrief; selected: boolean }) {
  const terminal = isTerminalStatus(brief.status)
  const liveCount = brief.active_count ?? 0
  const seenCount = brief.seen_count ?? liveCount
  const plannedCount = brief.planned_count ?? brief.member_names.length
  return html`
    <button
      class="mission-card-select ${selected ? 'active' : ''} ${terminal ? 'terminated' : ''}"
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
        <span class="command-chip ${terminal ? 'muted' : toneClass(brief.health ?? brief.status)}">${statusLabel(brief.status)}</span>
      </div>
      <div class="mission-card-meta">
        <span>건강도 · ${statusLabel(brief.health ?? 'ok')}</span>
        <span>live ${liveCount} · seen ${seenCount} · planned ${plannedCount}</span>
        ${brief.linked_operation_id ? html`<span>연결 작전 · ${brief.linked_operation_id}</span>` : null}
        ${brief.last_activity_at ? html`<span><${TimeAgo} timestamp=${brief.last_activity_at} /></span>` : null}
      </div>
      ${brief.runtime_blocker
        ? html`<div class="mission-card-detail">${brief.runtime_blocker}</div>`
        : brief.last_activity_summary
          ? html`<div class="mission-card-detail">${brief.last_activity_summary}</div>`
          : null}
      <div class="monitor-footnote">
        ${brief.worker_gap_summary ?? `관측 기준 · ${brief.counts_basis ?? 'recent_turns'}`}
      </div>
      <${HandoffButtons}
        intervene=${terminal ? null : brief.intervene_handoff}
        command=${brief.command_handoff}
      />
    </button>
  `
}

function SessionBriefsBody({ sessionRows }: { sessionRows: DashboardExecutionSessionBrief[] }) {
  const [activeSessions, terminalSessions] = partitionByTerminal(sessionRows, row => row.status)
  const hasActive = activeSessions.length > 0
  const hasTerminal = terminalSessions.length > 0

  return html`
    <div class="monitor-section-head">
      <h2 class="monitor-headline">영향받는 세션</h2>
      <p class="monitor-subheadline">대기열에서 고른 실행이 어떤 세션 목표와 실행 막힘을 갖는지 요약합니다.</p>
    </div>
    <div class="monitor-list">
      ${hasActive
        ? activeSessions.map(row => html`<${SessionCard} key=${row.session_id} brief=${row} selected=${selectedSessionId.value === row.session_id} />`)
        : html`<div class="empty-state">${hasTerminal ? '진행 중인 세션이 없습니다.' : '선택된 실행과 연결된 세션이 없습니다.'}</div>`}
    </div>
    ${hasTerminal
      ? html`
          <details class="runtime-collapsible" data-testid="execution.sessions-terminal">
            <summary class="runtime-summary">종료된 세션 ${terminalSessions.length}건</summary>
            <div class="monitor-list">
              ${terminalSessions.map(row => html`<${SessionCard} key=${row.session_id} brief=${row} selected=${selectedSessionId.value === row.session_id} />`)}
            </div>
          </details>
        `
      : null}
  `
}

function OperationCard({ brief, selected }: { brief: DashboardExecutionOperationBrief; selected: boolean }) {
  const terminal = isTerminalStatus(brief.status)
  return html`
    <button
      class="mission-card-select ${selected ? 'active' : ''} ${terminal ? 'terminated' : ''}"
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
        <span class="command-chip ${terminal ? 'muted' : toneClass(brief.blocker_summary ? 'warn' : brief.status)}">${statusLabel(brief.status)}</span>
      </div>
      <div class="mission-card-meta">
        ${brief.stage ? html`<span>단계 · ${brief.stage}</span>` : null}
        ${brief.linked_session_id ? html`<span>세션 · ${brief.linked_session_id}</span>` : null}
        ${brief.updated_at ? html`<span><${TimeAgo} timestamp=${brief.updated_at} /></span>` : null}
      </div>
      ${brief.blocker_summary ? html`<div class="mission-card-detail">${brief.blocker_summary}</div>` : null}
      ${brief.next_tool ? html`<div class="monitor-footnote">다음 도구 · ${brief.next_tool}</div>` : null}
      <${HandoffButtons} command=${brief.command_handoff} />
    </button>
  `
}

function OperationBriefsBody({ operationRows }: { operationRows: DashboardExecutionOperationBrief[] }) {
  const [activeOps, terminalOps] = partitionByTerminal(operationRows, row => row.status)
  const hasActive = activeOps.length > 0
  const hasTerminal = terminalOps.length > 0

  return html`
    <div class="monitor-section-head">
      <h2 class="monitor-headline">영향받는 작전</h2>
      <p class="monitor-subheadline">지휘 평면 작전의 막힘과 다음 도구만 얇게 보여주고, 자세한 근거는 원인 화면으로 넘깁니다.</p>
    </div>
    <div class="monitor-list">
      ${hasActive
        ? activeOps.map(row => html`<${OperationCard} key=${row.operation_id} brief=${row} selected=${selectedOperationId.value === row.operation_id} />`)
        : html`<div class="empty-state">${hasTerminal ? '진행 중인 작전이 없습니다.' : '선택된 실행과 연결된 작전이 없습니다.'}</div>`}
    </div>
    ${hasTerminal
      ? html`
          <details class="runtime-collapsible" data-testid="execution.operations-terminal">
            <summary class="runtime-summary">종료된 작전 ${terminalOps.length}건</summary>
            <div class="monitor-list">
              ${terminalOps.map(row => html`<${OperationCard} key=${row.operation_id} brief=${row} selected=${selectedOperationId.value === row.operation_id} />`)}
            </div>
          </details>
        `
      : null}
  `
}

function LodgeTickCard({ tick }: { tick: DashboardExecutionLodgeTick | null }) {
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

function LodgeCheckinRow({ row }: { row: DashboardExecutionLodgeCheckin }) {
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

function ContinuityRow({ row }: { row: DashboardExecutionContinuityBrief }) {
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

export function Execution() {
  const queueRows = executionQueue.value
  const sessionRowsAll = executionSessionBriefs.value
  const operationRowsAll = executionOperationBriefs.value
  const workerSupportAll = executionWorkerSupportBriefs.value
  const lodgeTick = executionLodgeTick.value
  const lodgeCheckinsAll = executionLodgeCheckins.value
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

  const lodgeCheckins =
    activeSessionId
      ? lodgeCheckinsAll.filter(item =>
          sessionRows.some(row => row.member_names.includes(item.agent_name)))
      : lodgeCheckinsAll

  const offlineRows =
    activeSessionId || activeOperationId
      ? offlineRowsAll.filter(item =>
          (activeSessionId ? item.related_session_id === activeSessionId : false)
          || (activeOperationId ? item.related_operation_id === activeOperationId : false)
          || item.tone !== 'ok')
      : offlineRowsAll

  return html`
    <div class="agents-monitor">
      <${RoomTruthStrip} />
      <${Card}
        title="실행 대기열"
        class="section"
        semanticId="execution.queue"
        testId="execution.queue"
      >
        <${ExecutionQueueBody} queueRows=${queueRows} />
      <//>

      <div class="agents-workbench">
        <${Card}
          title="영향받는 세션"
          class="section"
          semanticId="execution.sessions"
          testId="execution.session-briefs"
        >
          <${SessionBriefsBody} sessionRows=${sessionRows} />
        <//>

        <${Card}
          title="영향받는 작전"
          class="section"
          semanticId="execution.operations"
          testId="execution.operation-briefs"
        >
          <${OperationBriefsBody} operationRows=${operationRows} />
        <//>

        <${Card}
          title="Social Activity"
          class="section"
          semanticId="execution.lodge"
          testId="execution.lodge-checkins"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Social Activity</h2>
            <p class="monitor-subheadline">최근 public-square 이벤트에서 어떤 keeper가 행동했고, 어떤 keeper가 판단상 패스했으며, 어떤 경우가 시스템에 의해 스킵됐는지 먼저 보여줍니다.</p>
          </div>
          <${LodgeTickCard} tick=${lodgeTick} />
          <div class="monitor-list">
            ${lodgeCheckins.length === 0
              ? html`<div class="empty-state">최근 social activity 기록이 없습니다.</div>`
              : lodgeCheckins.map(row => html`<${LodgeCheckinRow} key=${`${row.agent_name}-${row.checked_at ?? row.outcome}`} row=${row} />`)}
          </div>
        <//>

        <${Card}
          title="작업 인력"
          class="section"
          semanticId="execution.worker_support"
          testId="execution.worker-support"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">지원 작업자</h2>
            <p class="monitor-subheadline">선택된 세션이나 작전에 연결된 작업자만 보이고, 전체 작업자 벽은 첫 화면을 차지하지 않게 합니다.</p>
          </div>
          <div class="monitor-list">
            ${workerSupportRows.length === 0
              ? html`<div class="empty-state">연결된 작업자가 없습니다.</div>`
              : workerSupportRows.map(row => html`<${WorkerSupportRow} key=${row.name} row=${row} testId="execution.worker-card" />`)}
          </div>
        <//>

        <${Card}
          title="연속성"
          class="section"
          semanticId="execution.continuity"
          testId="execution.continuity"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">키퍼 연속성 요약</h2>
            <p class="monitor-subheadline">카드 제목은 keeper 이름이고, keeper-*-agent 형태의 runtime agent는 보조 라벨로만 표시합니다.</p>
          </div>
          <div class="monitor-list">
            ${continuityRows.length === 0
              ? html`<div class="empty-state">지금은 연속성 경고가 없습니다.</div>`
              : continuityRows.map(row => html`<${ContinuityRow} key=${row.name} row=${row} />`)}
          </div>
        <//>

        <${Card}
          title="오프라인 인력"
          class="section"
          semanticId="execution.offline"
          testId="execution.offline-workers"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">오프라인 작업자</h2>
            <p class="monitor-subheadline">빠진 작업자는 하단 보조 면으로 분리해 활성 실행 판단을 방해하지 않게 유지합니다.</p>
          </div>
          <div class="monitor-list">
            ${offlineRows.length === 0
              ? html`<div class="empty-state">지금은 오프라인 작업자가 없습니다.</div>`
              : offlineRows.map(row => html`<${WorkerSupportRow} key=${row.name} row=${row} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `
}

export const Agents = Execution
