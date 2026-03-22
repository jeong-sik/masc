// 실행 표면 — 대기열 카드 및 본문

import { html } from 'htm/preact'
import { EmptyState } from '../common/feedback-state'
import { TimeAgo } from '../common/time-ago'
import type { DashboardExecutionQueueItem } from '../../types'
import {
  selectedQueueId,
  selectedSessionId,
  selectedOperationId,
  isTerminalStatus,
  partitionByTerminal,
  toneClass,
  statusLabel,
  queueKindLabel,
  HandoffButtons,
} from './shared'

export function QueueCard({ item, selected }: { item: DashboardExecutionQueueItem; selected: boolean }) {
  const terminal = isTerminalStatus(item.status)
  return html`
    <button
      class="w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer ${selected ? 'active' : ''} ${terminal ? 'terminated' : ''}"
      data-testid="execution.queue-card"
      onClick=${() => {
        selectedQueueId.value = selected ? null : item.id
        selectedSessionId.value = null
        selectedOperationId.value = null
      }}
    >
      <div class="flex justify-between gap-2 items-start flex-wrap">
        <div>
          <div class="text-[rgba(255,255,255,0.52)] text-[13px]">${item.kind === 'session' ? item.target_id : item.linked_session_id ?? item.target_id}</div>
          <div class="mission-card rounded-xl-title">${item.summary}</div>
        </div>
        <span class="rounded-full ${terminal ? 'muted' : toneClass(item.severity)}">${statusLabel(item.status ?? item.severity)}</span>
      </div>
      <div class="mission-card rounded-xl-meta">
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

export function ExecutionQueueBody({ queueRows }: { queueRows: DashboardExecutionQueueItem[] }) {
  const [activeItems, terminalItems] = partitionByTerminal(queueRows, item => item.status)
  const hasActive = activeItems.length > 0
  const hasTerminal = terminalItems.length > 0

  return html`
    <div class="mb-3.5">
      <h2 class="monitor-headline">개입이 필요한 실행</h2>
      <p class="monitor-subheadline">진행 중인 세션과 작전 중 막힌 항목을 보여줍니다.${hasTerminal ? ' 종료된 항목은 하단에 접혀 있습니다.' : ''}</p>
    </div>
    <div class="flex flex-col gap-2.5">
      ${hasActive
        ? activeItems.map(item => html`<${QueueCard} key=${item.id} item=${item} selected=${selectedQueueId.value === item.id} />`)
        : html`<${EmptyState}>지금은 개입이 필요한 실행이 없습니다.<//>`}
    </div>
    ${hasTerminal
      ? html`
          <details class="mt-1" data-testid="execution.queue-terminal">
            <summary class="runtime-summary">종료된 항목 ${terminalItems.length}건</summary>
            <div class="flex flex-col gap-2.5">
              ${terminalItems.map(item => html`<${QueueCard} key=${item.id} item=${item} selected=${selectedQueueId.value === item.id} />`)}
            </div>
          </details>
        `
      : null}
  `
}
