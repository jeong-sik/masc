// 실행 표면 — 세션 카드 및 본문

import { html } from 'htm/preact'
import { TimeAgo } from '../common/time-ago'
import type { DashboardExecutionSessionBrief } from '../../types'
import {
  selectedSessionId,
  selectedOperationId,
  isTerminalStatus,
  partitionByTerminal,
  toneClass,
  statusLabel,
  HandoffButtons,
} from './shared'

export function SessionCard({ brief, selected }: { brief: DashboardExecutionSessionBrief; selected: boolean }) {
  const terminal = isTerminalStatus(brief.status)
  const liveCount = brief.active_count ?? 0
  const seenCount = brief.seen_count ?? liveCount
  const plannedCount = brief.planned_count ?? brief.member_names.length
  return html`
    <button
      class="w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer ${selected ? 'active' : ''} ${terminal ? 'terminated' : ''}"
      data-testid="execution.session-card"
      onClick=${() => {
        selectedSessionId.value = selected ? null : brief.session_id
        selectedOperationId.value = null
      }}
    >
      <div class="flex justify-between gap-2 items-start flex-wrap">
        <div>
          <div class="text-[rgba(255,255,255,0.52)] text-[length:var(--fs-sm)]">${brief.session_id}${brief.room ? ` · ${brief.room}` : ''}</div>
          <div class="mission-card rounded-xl-title">${brief.goal}</div>
        </div>
        <span class="cmd-chip rounded-full ${terminal ? 'muted' : toneClass(brief.health ?? brief.status)}">${statusLabel(brief.status)}</span>
      </div>
      <div class="mission-card rounded-xl-meta">
        <span>건강도 · ${statusLabel(brief.health ?? 'ok')}</span>
        <span>live ${liveCount} · seen ${seenCount} · planned ${plannedCount}</span>
        ${brief.linked_operation_id ? html`<span>연결 작전 · ${brief.linked_operation_id}</span>` : null}
        ${brief.last_activity_at ? html`<span><${TimeAgo} timestamp=${brief.last_activity_at} /></span>` : null}
      </div>
      ${brief.runtime_blocker
        ? html`<div class="mission-card rounded-xl-detail">${brief.runtime_blocker}</div>`
        : brief.last_activity_summary
          ? html`<div class="mission-card rounded-xl-detail">${brief.last_activity_summary}</div>`
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

export function SessionBriefsBody({ sessionRows }: { sessionRows: DashboardExecutionSessionBrief[] }) {
  const [activeSessions, terminalSessions] = partitionByTerminal(sessionRows, row => row.status)
  const hasActive = activeSessions.length > 0
  const hasTerminal = terminalSessions.length > 0

  return html`
    <div class="mb-3.5">
      <h2 class="monitor-headline">영향받는 세션</h2>
      <p class="monitor-subheadline">대기열에서 고른 실행이 어떤 세션 목표와 실행 막힘을 갖는지 요약합니다.</p>
    </div>
    <div class="flex flex-col gap-2.5">
      ${hasActive
        ? activeSessions.map(row => html`<${SessionCard} key=${row.session_id} brief=${row} selected=${selectedSessionId.value === row.session_id} />`)
        : html`<div class="empty-state">${hasTerminal ? '진행 중인 세션이 없습니다.' : '선택된 실행과 연결된 세션이 없습니다.'}</div>`}
    </div>
    ${hasTerminal
      ? html`
          <details class="mt-1" data-testid="execution.sessions-terminal">
            <summary class="runtime-summary">종료된 세션 ${terminalSessions.length}건</summary>
            <div class="flex flex-col gap-2.5">
              ${terminalSessions.map(row => html`<${SessionCard} key=${row.session_id} brief=${row} selected=${selectedSessionId.value === row.session_id} />`)}
            </div>
          </details>
        `
      : null}
  `
}
