// 실행 표면 — 작전 카드 및 본문

import { html } from 'htm/preact'
import { EmptyState } from '../common/empty-state'
import { TimeAgo } from '../common/time-ago'
import type { DashboardExecutionOperationBrief } from '../../types'
import {
  selectedSessionId,
  selectedOperationId,
  isTerminalStatus,
  partitionByTerminal,
  toneClass,
  statusLabel,
  HandoffButtons,
} from './shared'

export function OperationCard({ brief, selected }: { brief: DashboardExecutionOperationBrief; selected: boolean }) {
  const terminal = isTerminalStatus(brief.status)
  return html`
    <button
      class="w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer ${selected ? 'active' : ''} ${terminal ? 'terminated' : ''}"
      data-testid="execution.operation-card"
      onClick=${() => {
        selectedOperationId.value = selected ? null : brief.operation_id
        selectedSessionId.value = brief.linked_session_id ?? null
      }}
    >
      <div class="flex justify-between gap-2 items-start flex-wrap">
        <div>
          <div class="text-[rgba(255,255,255,0.52)] text-[length:var(--fs-sm)]">${brief.operation_id}${brief.assigned_unit_label ? ` · ${brief.assigned_unit_label}` : ''}</div>
          <div class="mission-card rounded-xl-title">${brief.objective}</div>
        </div>
        <span class="cmd-chip rounded-full ${terminal ? 'muted' : toneClass(brief.blocker_summary ? 'warn' : brief.status)}">${statusLabel(brief.status)}</span>
      </div>
      <div class="mission-card rounded-xl-meta">
        ${brief.stage ? html`<span>단계 · ${brief.stage}</span>` : null}
        ${brief.linked_session_id ? html`<span>세션 · ${brief.linked_session_id}</span>` : null}
        ${brief.updated_at ? html`<span><${TimeAgo} timestamp=${brief.updated_at} /></span>` : null}
      </div>
      ${brief.blocker_summary ? html`<div class="mission-card rounded-xl-detail">${brief.blocker_summary}</div>` : null}
      ${brief.next_tool ? html`<div class="monitor-footnote">다음 도구 · ${brief.next_tool}</div>` : null}
      <${HandoffButtons} command=${brief.command_handoff} />
    </button>
  `
}

export function OperationBriefsBody({ operationRows }: { operationRows: DashboardExecutionOperationBrief[] }) {
  const [activeOps, terminalOps] = partitionByTerminal(operationRows, row => row.status)
  const hasActive = activeOps.length > 0
  const hasTerminal = terminalOps.length > 0

  return html`
    <div class="mb-3.5">
      <h2 class="monitor-headline">영향받는 작전</h2>
      <p class="monitor-subheadline">지휘 평면 작전의 막힘과 다음 도구만 얇게 보여주고, 자세한 근거는 원인 화면으로 넘깁니다.</p>
    </div>
    <div class="flex flex-col gap-3">
      ${hasActive
        ? activeOps.map(row => html`<${OperationCard} key=${row.operation_id} brief=${row} selected=${selectedOperationId.value === row.operation_id} />`)
        : html`<${EmptyState} message=${hasTerminal ? '진행 중인 작전이 없습니다.' : '선택된 실행과 연결된 작전이 없습니다.'} compact />`}
    </div>
    ${hasTerminal
      ? html`
          <details class="mt-1" data-testid="execution.operations-terminal">
            <summary class="runtime-summary">종료된 작전 ${terminalOps.length}건</summary>
            <div class="flex flex-col gap-3">
              ${terminalOps.map(row => html`<${OperationCard} key=${row.operation_id} brief=${row} selected=${selectedOperationId.value === row.operation_id} />`)}
            </div>
          </details>
        `
      : null}
  `
}
