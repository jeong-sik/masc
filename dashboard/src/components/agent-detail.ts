// Agent detail overlay — main component composing sub-panels
// Sub-components: agent-detail-state, agent-detail-timeline, agent-detail-journal, agent-detail-worker

import { html } from 'htm/preact'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { keeperIdentityHint } from './common/keeper-identity'
import { AgentJournalStream } from './agent-detail-journal'
import { AgentTimelineSection } from './agent-detail-timeline'
import { AgentWorkerBrief } from './agent-detail-worker'
import {
  selectedAgentName,
  loading,
  detailError,
  roomActivity,
  taskHistories,
  mentionText,
  sendingMention,
  selectedAgent,
  assignedTasks,
  keeperForAgent,
  missionAgentBrief,
  continuityBriefForAgent,
  compactCopy,
  closeAgentDetail,
  refreshAgentDetail,
  submitMention,
  type TaskHistoryRow,
} from './agent-detail-state'
import type { Task } from '../types'

// Re-export public API for external consumers
export { selectedAgentName, openAgentDetail, closeAgentDetail } from './agent-detail-state'

function TaskSummary({ task }: { task: Task }) {
  return html`
    <div class="flex items-center gap-3 border border-card-border bg-card/40 hover:bg-card/60 transition-colors px-3 py-2.5 rounded-xl shadow-sm">
      <span class="text-[10px] font-medium py-1 px-2.5 border border-accent/20 bg-accent/10 text-accent whitespace-nowrap rounded-md shadow-sm">${task.id}</span>
      <span class="flex-1 text-[13px] text-text-strong font-medium truncate">${task.title}</span>
      <${StatusBadge} status=${task.status} />
    </div>
  `
}

function TaskHistoryPanel({ row }: { row: TaskHistoryRow }) {
  return html`
    <div class="border border-card-border rounded-xl bg-card/40 p-4 shadow-sm hover:border-accent/30 transition-colors group">
      <div class="mb-3">
        <span class="text-[10px] font-medium py-1 px-2.5 border border-accent/20 bg-accent/10 text-accent whitespace-nowrap rounded-md shadow-sm group-hover:bg-accent/20 transition-colors">${row.taskId}</span>
      </div>
      <pre class="m-0 whitespace-pre-wrap text-[12px] leading-relaxed text-text-body font-mono opacity-90">${row.text || 'No task history yet'}</pre>
    </div>
  `
}

export function AgentDetailOverlay() {
  const agentName = selectedAgentName.value
  if (!agentName) return null

  const agent = selectedAgent()
  const keeper = keeperForAgent(agentName)
  const continuityBrief = continuityBriefForAgent(agentName)
  const missionBrief = missionAgentBrief(agentName)
  const ownedTasks = assignedTasks(agentName)
  const lines = roomActivity.value
  const displayName = missionBrief?.display_name ?? keeper?.name ?? agentName
  const secondaryLabel = displayName !== agentName ? agentName : null
  const headerStatus = agent?.status ?? missionBrief?.status ?? 'unknown'
  const isArchivedParticipant = !agent && missionBrief?.is_live === false
  const lastSeenAt =
    agent?.last_seen
    ?? missionBrief?.last_activity_at
    ?? null
  const signalTruth =
    missionBrief?.signal_truth === 'live'
      ? 'live'
      : missionBrief?.signal_truth === 'stale'
        ? 'stale'
        : missionBrief?.signal_truth === 'archived'
          ? 'archived'
          : missionBrief?.signal_truth === 'unknown'
            ? 'unknown'
            : null
  const evidenceSource = missionBrief?.evidence_source ?? null
  const agentEmoji = agent?.emoji ?? keeper?.emoji
  const koreanName = agent?.koreanName ?? keeper?.koreanName
  const continuitySummary =
    compactCopy(continuityBrief?.continuity_summary)
    ?? compactCopy(continuityBrief?.skill_route_summary)
    ?? null
  const keeperIdentity = keeperIdentityHint(keeper?.name, keeper?.agent_name)

  return html`
    <div
      class="agent-detail-overlay fixed inset-0 z-[60] bg-black/60 backdrop-blur-sm isolate flex items-center justify-center p-6 animate-in fade-in duration-200"
      data-testid="agent-detail-overlay"
      onClick=${(e: Event) => {
        if ((e.target as HTMLElement).classList.contains('agent-detail-overlay')) closeAgentDetail()
      }}
    >
      <div class="w-[min(1080px,100%)] max-h-[90vh] overflow-y-auto rounded-2xl border border-card-border bg-bg-1/95 backdrop-blur-2xl p-6 shadow-2xl shadow-black/50 ring-1 ring-white/5">
        <div class="flex justify-between items-start gap-4 mb-6">
          <div class="flex flex-col gap-3 flex-1">
            <div class="flex items-center gap-4">
              ${agentEmoji ? html`<div class="size-12 rounded-xl bg-white/5 border border-white/10 flex items-center justify-center text-3xl shadow-inner">${agentEmoji}</div>` : ''}
              <div>
                <h2 class="m-0 flex items-baseline gap-2.5 text-text-strong text-2xl font-bold tracking-tight">
                  ${displayName}
                  ${koreanName ? html`<span class="text-sm text-text-dim font-medium tracking-normal">(${koreanName})</span>` : ''}
                  ${secondaryLabel ? html`<span class="font-mono text-xs text-text-dim bg-white/5 px-2 py-0.5 rounded-md">${secondaryLabel}</span>` : ''}
                </h2>
                <div class="flex items-center gap-2 mt-2 flex-wrap">
                  <${StatusBadge} status=${headerStatus} />
                  ${isArchivedParticipant ? html`<span class="text-[10px] font-medium py-1 px-2 border border-accent/20 bg-accent/10 text-accent whitespace-nowrap rounded-md shadow-sm">archived session participant</span>` : null}
                  ${agent?.model ? html`<span class="font-mono text-[10px] font-medium bg-white/10 border border-white/5 px-2 py-1 rounded-md text-text-muted shadow-sm">${agent.model}</span>` : ''}
                  ${!agent && missionBrief?.archived_reason
                    ? html`<span class="text-xs text-text-dim italic">${missionBrief.archived_reason}</span>`
                    : null}
                  ${signalTruth ? html`<span class="text-[10px] font-medium py-1 px-2 border border-accent/20 bg-accent/10 text-accent whitespace-nowrap rounded-md shadow-sm">signal · ${signalTruth}</span>` : null}
                  ${evidenceSource ? html`<span class="text-[10px] font-medium py-1 px-2 border border-accent/20 bg-accent/10 text-accent whitespace-nowrap rounded-md shadow-sm">source · ${evidenceSource}</span>` : null}
                </div>
              </div>
            </div>
            <div class="mt-2 flex gap-3 flex-wrap text-text-muted text-[13px] font-medium">
              ${agent?.current_task || missionBrief?.current_work
                ? html`<span class="bg-card/40 px-3 py-1.5 rounded-lg border border-card-border shadow-sm">Task: <span class="text-text-strong">${agent?.current_task ?? missionBrief?.current_work}</span></span>`
                : null}
              ${lastSeenAt ? html`<span class="bg-card/40 px-3 py-1.5 rounded-lg border border-card-border shadow-sm">Last seen: <span class="text-text-strong"><${TimeAgo} timestamp=${lastSeenAt} /></span></span>` : null}
            </div>
            ${keeper || continuitySummary || missionBrief?.related_session_id
              ? html`
                  <div class="mt-1 flex gap-3 flex-wrap text-text-muted text-[13px] font-medium">
                    ${keeper
                      ? html`<span class="flex items-center gap-1.5">Linked keeper: <strong class="text-text-strong">${keeper.name}</strong>${keeperIdentity ? html`<span class="text-text-dim text-xs">· ${keeperIdentity}</span>` : ''}</span>`
                      : null}
                    ${missionBrief?.related_session_id ? html`<span class="flex items-center gap-1.5">Session: <strong class="font-mono text-text-strong text-xs bg-white/5 px-1.5 rounded">${missionBrief.related_session_id}</strong></span>` : null}
                    ${continuitySummary ? html`<span class="text-accent/90 bg-accent/10 px-2 py-0.5 rounded-md border border-accent/10">${continuitySummary}</span>` : null}
                  </div>
                `
              : null}
          </div>
          <div class="flex gap-2 shrink-0">
            <button class="px-4 py-2 text-[13px] font-semibold rounded-xl border border-card-border bg-card/60 text-text-body hover:bg-white/10 hover:text-text-strong transition-all duration-200 shadow-sm disabled:opacity-50 disabled:cursor-not-allowed" onClick=${() => { void refreshAgentDetail() }} disabled=${loading.value}>
              ${loading.value ? '새로고침 중...' : '새로고침'}
            </button>
            <button class="px-4 py-2 text-[13px] font-semibold rounded-xl border border-transparent bg-white/10 text-text-strong hover:bg-white/20 transition-all duration-200 shadow-sm" onClick=${closeAgentDetail}>닫기</button>
          </div>
        </div>

        ${detailError.value ? html`<div class="p-4 mb-4 text-bad border border-bad/30 rounded-xl bg-bad/10 shadow-sm font-medium text-sm">${detailError.value}</div>` : null}

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-5">
          <${Card} title="할당된 작업">
            ${ownedTasks.length === 0
              ? html`<div class="h-full min-h-[120px]"><${EmptyState} message="할당된 작업이 없습니다" compact /></div>`
              : html`<div class="flex flex-col gap-2.5">${ownedTasks.map(t => html`<${TaskSummary} key=${t.id} task=${t} />`)}</div>`}
          <//>

          <${Card} title="최근 활동">
            ${lines.length === 0
              ? html`<div class="h-full min-h-[120px]"><${EmptyState} message="최근 활동 기록이 없습니다" compact /></div>`
              : html`<div class="max-h-[240px] overflow-y-auto flex flex-col gap-2 pr-1 custom-scrollbar">${lines.map((line: string, idx: number) => html`<div key=${idx} class="border border-card-border bg-card/40 px-3 py-2.5 font-mono text-[12px] text-text-body leading-relaxed rounded-xl shadow-sm hover:bg-card/60 transition-colors">${line}</div>`)}</div>`}
          <//>
        </div>

        <div class="flex flex-col gap-5">
          <${AgentJournalStream} agentName=${agentName} />
          <${AgentTimelineSection} />
          <${AgentWorkerBrief} agentName=${agentName} />
          <${Card} title="작업 이력">
            ${taskHistories.value.length === 0
              ? html`<${EmptyState} message="작업 이력이 없습니다" compact />`
              : html`<div class="flex flex-col gap-3">${taskHistories.value.map((row: TaskHistoryRow) => html`<${TaskHistoryPanel} key=${row.taskId} row=${row} />`)}</div>`}
          <//>

          <${Card} title="직접 멘션">
            <div class="grid grid-cols-[1fr_auto] gap-3">
              <input
                class="w-full px-4 py-2.5 rounded-xl border border-card-border bg-card/60 text-text-strong text-[13px] placeholder:text-text-dim focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/50 transition-all duration-200 shadow-inner"
                type="text"
                placeholder="@멘션 메시지 입력..."
                value=${mentionText.value}
                onInput=${(e: Event) => { mentionText.value = (e.target as HTMLInputElement).value }}
                onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') void submitMention() }}
                disabled=${sendingMention.value}
              />
              <button
                class="px-5 py-2.5 text-[13px] font-semibold rounded-xl border border-transparent bg-accent text-bg-0 hover:bg-accent/90 transition-all duration-200 shadow-md shadow-accent/20 disabled:opacity-50 disabled:cursor-not-allowed"
                onClick=${() => { void submitMention() }}
                disabled=${sendingMention.value || mentionText.value.trim() === ''}
              >
                ${sendingMention.value ? '전송 중...' : '전송하기'}
              </button>
            </div>
          <//>
        </div>
      </div>
    </div>
  `
}
