// 실행 표면 — 공용 유틸리티, 시그널, 라벨 함수

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { navigate } from '../../router'
import { keepers } from '../../store'
import {
  createExecutionWorkflowContext,
  workflowCommandParams,
  workflowInterveneParams,
  persistWorkflowContext,
} from '../../workflow-context'
import { toneClass } from '../../lib/tone'
import { statusLabel } from '../../lib/status-label'
import type {
  DashboardExecutionHandoff,
  DashboardExecutionWorkerSupportBrief,
  DashboardExecutionContinuityBrief,
  DashboardExecutionLodgeCheckin,
  DashboardExecutionQueueItem,
  Keeper,
} from '../../types'

export const selectedQueueId = signal<string | null>(null)
export const selectedSessionId = signal<string | null>(null)
export const selectedOperationId = signal<string | null>(null)

export const TERMINAL_STATUSES = new Set(['completed', 'interrupted', 'failed', 'cancelled'])

export function isTerminalStatus(status?: string | null): boolean {
  return TERMINAL_STATUSES.has((status ?? '').trim().toLowerCase())
}

export function partitionByTerminal<T>(items: T[], getStatus: (item: T) => string | null | undefined): [active: T[], terminal: T[]] {
  const active: T[] = []
  const terminal: T[] = []
  for (const item of items) {
    ;(isTerminalStatus(getStatus(item)) ? terminal : active).push(item)
  }
  return [active, terminal]
}

export { toneClass, statusLabel }

export function queueKindLabel(kind: DashboardExecutionQueueItem['kind']): string {
  return kind === 'session' ? '세션' : '작전'
}

export function findKeeper(name?: string | null): Keeper | null {
  if (!name) return null
  return keepers.value.find(keeper => keeper.name === name || keeper.agent_name === name) ?? null
}

export function agentStateLabel(state: DashboardExecutionWorkerSupportBrief['state']): string {
  switch (state) {
    case 'working': return '작업 중'
    case 'watching': return '대기 중'
    case 'quiet': return '조용함'
    case 'offline': return '오프라인'
  }
}

export function signalTruthLabel(value?: DashboardExecutionWorkerSupportBrief['signal_truth'] | null): string {
  switch (value) {
    case 'live': return '최근 신호(≤5m)'
    case 'stale': return '오래된 신호(>5m)'
    case 'absent': return 'signal 없음'
    default: return value ?? 'signal 미상'
  }
}

export function evidenceSourceLabel(value?: DashboardExecutionWorkerSupportBrief['evidence_source'] | null): string {
  switch (value) {
    case 'message': return '최근 출력'
    case 'presence': return 'presence/하트비트'
    case 'none': return '근거 없음'
    default: return value ?? '근거 미상'
  }
}

export function continuityStateLabel(state: DashboardExecutionContinuityBrief['state']): string {
  switch (state) {
    case 'critical': return '위험'
    case 'warning': return '주의'
    default: return '정상'
  }
}

export function lodgeOutcomeLabel(outcome: DashboardExecutionLodgeCheckin['outcome']): string {
  switch (outcome) {
    case 'acted': return '행동'
    case 'passed': return '판단 패스'
    case 'skipped': return '시스템 스킵'
    case 'failed': return '실패'
    default: return outcome
  }
}

export function lodgeActionKindLabel(value?: DashboardExecutionLodgeCheckin['action_kind'] | null): string {
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

export function openHandoff(handoff: DashboardExecutionHandoff | null | undefined): void {
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

export function MonitorStat({
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

export function HandoffButtons({
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
