// Agent detail overlay — main component composing sub-panels
// Sub-components: agent-detail-state, agent-detail-timeline, agent-detail-journal, agent-detail-worker

import { html } from 'htm/preact'
import { Card } from './common/card'
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
    <div class="flex items-center gap-2 border border-[var(--card-border)] bg-[var(--white-3)] px-2.5 py-2 rounded-lg">
      <span class="text-[length:var(--fs-2xs)] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">${task.id}</span>
      <span class="flex-1 text-[#d7e7ff]">${task.title}</span>
      <${StatusBadge} status=${task.status} />
    </div>
  `
}

function TaskHistoryPanel({ row }: { row: TaskHistoryRow }) {
  return html`
    <div class="border border-[var(--card-border)] rounded-[10px] bg-[var(--white-2)] p-2.5">
      <div class="mb-2">
        <span class="text-[length:var(--fs-2xs)] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">${row.taskId}</span>
      </div>
      <pre class="m-0 whitespace-pre-wrap text-[length:var(--fs-sm)] leading-[1.5] text-[#cfe0ff] font-[family-name:'IBM_Plex_Mono','Fira_Code',monospace]">${row.text || 'No task history yet'}</pre>
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
      class="agent-detail-overlay fixed inset-0 z-[var(--z-overlay-agent,3030)] bg-black/64 backdrop-blur-[4px] isolate flex items-center justify-center p-5"
      data-testid="agent-detail-overlay"
      onClick=${(e: Event) => {
        if ((e.target as HTMLElement).classList.contains('agent-detail-overlay')) closeAgentDetail()
      }}
    >
      <div class="w-[min(1020px,100%)] max-h-[90vh] overflow-y-auto rounded-[14px] border border-[var(--border-slate-30)] bg-[rgba(16,25,45,0.95)] p-[18px]">
        <div class="flex justify-between gap-3 mb-3.5">
          <div class="flex flex-col gap-2 flex-1">
            <div class="flex items-center gap-3">
              ${agentEmoji ? html`<span class="text-[2rem]">${agentEmoji}</span>` : ''}
              <div>
                <h2 class="m-0 flex items-baseline gap-2 text-[var(--text-strong)] text-xl">
                  ${displayName}
                  ${koreanName ? html`<span class="text-xs text-[var(--text-dim)]">(${koreanName})</span>` : ''}
                  ${secondaryLabel ? html`<span class="font-mono" class="text-xs text-[var(--text-dim)]">${secondaryLabel}</span>` : ''}
                </h2>
                <div class="flex items-center gap-2 mt-1 flex-wrap">
                  <${StatusBadge} status=${headerStatus} />
                  ${isArchivedParticipant ? html`<span class="text-[length:var(--fs-2xs)] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">archived session participant</span>` : null}
                  ${agent?.model ? html`<span class="font-mono" class="text-xs bg-[#2a2a4a] px-1.5 py-0.5 rounded">${agent.model}</span>` : ''}
                  ${!agent && missionBrief?.archived_reason
                    ? html`<span class="text-xs text-[var(--text-dim)]">${missionBrief.archived_reason}</span>`
                    : null}
                  ${signalTruth ? html`<span class="text-[length:var(--fs-2xs)] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">signal · ${signalTruth}</span>` : null}
                  ${evidenceSource ? html`<span class="text-[length:var(--fs-2xs)] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">source · ${evidenceSource}</span>` : null}
                </div>
              </div>
            </div>
            <div class="mt-1.5 flex gap-2 flex-wrap text-[#9ab3de] text-[length:var(--fs-sm)]">
              ${agent?.current_task || missionBrief?.current_work
                ? html`<span>Task: ${agent?.current_task ?? missionBrief?.current_work}</span>`
                : null}
              ${lastSeenAt ? html`<span>Last seen: <${TimeAgo} timestamp=${lastSeenAt} /></span>` : null}
            </div>
            ${keeper || continuitySummary || missionBrief?.related_session_id
              ? html`
                  <div class="mt-1.5 flex gap-2 flex-wrap text-[#9ab3de] text-[length:var(--fs-sm)]">
                    ${keeper
                      ? html`<span>Linked keeper: ${keeper.name}${keeperIdentity ? ` · ${keeperIdentity}` : ''}</span>`
                      : null}
                    ${missionBrief?.related_session_id ? html`<span>Session: ${missionBrief.related_session_id}</span>` : null}
                    ${continuitySummary ? html`<span>${continuitySummary}</span>` : null}
                  </div>
                `
              : null}
          </div>
          <div class="flex gap-2">
            <button class="control-btn rounded-lg ghost" onClick=${() => { void refreshAgentDetail() }} disabled=${loading.value}>
              ${loading.value ? '새로고침 중...' : '새로고침'}
            </button>
            <button class="control-btn rounded-lg ghost" onClick=${closeAgentDetail}>닫기</button>
          </div>
        </div>

        ${detailError.value ? html`<div class="council-error rounded-lg">${detailError.value}</div>` : null}

        <div class="grid grid-cols-2 gap-3 mb-3">
          <${Card} title="할당된 작업">
            ${ownedTasks.length === 0
              ? html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">할당된 작업이 없습니다</div>`
              : html`<div class="flex flex-col gap-2">${ownedTasks.map(t => html`<${TaskSummary} key=${t.id} task=${t} />`)}</div>`}
          <//>

          <${Card} title="최근 활동">
            ${lines.length === 0
              ? html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">최근 활동 기록이 없습니다</div>`
              : html`<div class="max-h-[210px] overflow-y-auto flex flex-col gap-1.5">${lines.map((line: string, idx: number) => html`<div key=${idx} class="border border-[var(--card-border)] bg-[var(--white-3)] px-2.5 py-2 font-[family-name:'IBM_Plex_Mono','Fira_Code',monospace] text-[length:var(--fs-sm)] text-[#c8daf7] leading-[1.4] rounded-lg">${line}</div>`)}</div>`}
          <//>
        </div>

        <${AgentJournalStream} agentName=${agentName} />
        <${AgentTimelineSection} />
        <${AgentWorkerBrief} agentName=${agentName} />
        <${Card} title="작업 이력">
          ${taskHistories.value.length === 0
            ? html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">작업 이력이 없습니다</div>`
            : html`<div class="flex flex-col gap-2.5">${taskHistories.value.map((row: TaskHistoryRow) => html`<${TaskHistoryPanel} key=${row.taskId} row=${row} />`)}</div>`}
        <//>

        <${Card} title="직접 멘션">
          <div class="grid grid-cols-[1fr_auto] gap-2">
            <input
              class="control-input rounded-lg"
              type="text"
              placeholder="@멘션 메시지"
              value=${mentionText.value}
              onInput=${(e: Event) => { mentionText.value = (e.target as HTMLInputElement).value }}
              onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') void submitMention() }}
              disabled=${sendingMention.value}
            />
            <button
              class="control-btn rounded-lg"
              onClick=${() => { void submitMention() }}
              disabled=${sendingMention.value || mentionText.value.trim() === ''}
            >
              ${sendingMention.value ? '전송 중...' : '전송'}
            </button>
          </div>
        <//>
      </div>
    </div>
  `
}
