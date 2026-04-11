// Agent detail overlay — main component composing sub-panels
// Sub-components: agent-detail-state, agent-detail-timeline, agent-detail-journal, agent-detail-worker

import { html } from 'htm/preact'
import { useRef } from 'preact/hooks'
import { Card } from './common/card'
import { EmptyState, ErrorState } from './common/feedback-state'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { resolveUnifiedStatus } from '../lib/unified-status'
import { ActionButton } from './common/button'
import { TextInput } from './common/input'
import { keeperIdentityHint } from './common/keeper-identity'
import { AgentJournalStream } from './agent-detail-journal'
import { AgentSessionReport } from './agent-detail-session-report'
import { AgentTimelineSection } from './agent-detail-timeline'
import { AgentWorkerBrief } from './agent-detail-worker'
import { CollapsibleSection } from './common/collapsible'
import { SessionTraceView } from './session-trace/session-trace-view'
import {
  selectedAgentName,
  loading,
  detailError,
  namespaceActivity,
  taskHistories,
  mentionText,
  sendingMention,
  selectedAgent,
  assignedTasks,
  keeperForAgent,
  missionAgentBrief,
  continuityBriefForAgent,
  closeAgentDetail,
  refreshAgentDetail,
  submitMention,
  setKeeperRedirect,
  agentFitness,
  type TaskHistoryRow,
} from './agent-detail-state'
import { openKeeperDetail } from './keeper-detail'
import { trimText } from '../lib/truncate'
import type { Task } from '../types'
import { DialogOverlay } from './common/dialog'

// Re-export public API for external consumers
export { selectedAgentName, openAgentDetail, closeAgentDetail } from './agent-detail-state'

// Wire keeper redirect: keeper-linked agents open the keeper detail overlay
setKeeperRedirect((agentName: string) => {
  const keeper = keeperForAgent(agentName)
  if (keeper) {
    openKeeperDetail(keeper)
    return true
  }
  return false
})

function TaskSummary({ task }: { task: Task }) {
  return html`
    <div class="flex items-center gap-3 border border-card-border bg-card/40 hover:bg-card/60 transition-colors px-3 py-2.5 rounded-xl shadow-sm">
      <span class="text-[10px] font-medium py-1 px-2.5 border border-accent/20 bg-[var(--accent-10)] text-accent whitespace-nowrap rounded-md shadow-sm">${task.id}</span>
      <span class="flex-1 text-[13px] text-text-strong font-medium truncate">${task.title}</span>
      <${StatusBadge} status=${task.status} />
    </div>
  `
}

function TaskHistoryPanel({ row }: { row: TaskHistoryRow }) {
  return html`
    <div class="border border-card-border rounded-xl bg-card/40 p-4 shadow-sm hover:border-accent/30 transition-colors group">
      <div class="mb-3">
        <span class="text-[10px] font-medium py-1 px-2.5 border border-accent/20 bg-[var(--accent-10)] text-accent whitespace-nowrap rounded-md shadow-sm group-hover:bg-accent/20 transition-colors">${row.taskId}</span>
      </div>
      <pre class="m-0 whitespace-pre-wrap text-[12px] leading-relaxed text-text-body font-mono opacity-90">${row.text || '작업 이력 없음'}</pre>
    </div>
  `
}

export function AgentDetailOverlay() {
  const agentName = selectedAgentName.value
  if (!agentName) return null
  const closeButtonRef = useRef<HTMLButtonElement>(null)

  const agent = selectedAgent()
  const keeper = keeperForAgent(agentName)
  const continuityBrief = continuityBriefForAgent(agentName)
  const missionBrief = missionAgentBrief(agentName)
  const ownedTasks = assignedTasks(agentName)
  const lines = namespaceActivity.value
  const displayName = missionBrief?.display_name ?? keeper?.name ?? agentName
  const secondaryLabel = displayName !== agentName ? agentName : null
  const unified = resolveUnifiedStatus(keeper?.status, agent?.status, missionBrief?.signal_truth)
  const isArchivedParticipant = !agent && missionBrief?.is_live === false
  const lastSeenAt =
    agent?.last_seen
    ?? missionBrief?.last_activity_at
    ?? null
  const agentEmoji = agent?.emoji ?? keeper?.emoji
  const rawKoreanName = agent?.koreanName ?? keeper?.koreanName
  // Don't show koreanName if it's actually an agent runtime name, not Korean text
  const koreanName = rawKoreanName && rawKoreanName !== agentName && rawKoreanName !== displayName
    ? rawKoreanName : null
  const continuitySummary =
    trimText(continuityBrief?.continuity_summary, 160)
    ?? trimText(continuityBrief?.skill_route_summary, 160)
    ?? null
  const keeperIdentity = keeperIdentityHint(keeper?.name, keeper?.agent_name)
  // Skip secondaryLabel when keeperIdentity already shows the agent runtime name
  const showSecondaryLabel = secondaryLabel && !keeperIdentity
  const titleId = `agent-detail-title-${agentName}`

  return html`
    <${DialogOverlay}
      labelledBy=${titleId}
      onClose=${closeAgentDetail}
      initialFocusRef=${closeButtonRef}
      overlayClass="agent-detail-overlay fixed inset-0 z-[60] bg-black/60 backdrop-blur-sm isolate flex items-center justify-center p-6 animate-in fade-in duration-200"
      panelClass="w-[min(1080px,100%)] max-h-[90vh] overflow-y-auto rounded-2xl border border-card-border bg-bg-1/95 backdrop-blur-2xl shadow-2xl shadow-black/50 ring-1 ring-white/5"
    >
      <div class="p-6 flex flex-col gap-5">
        <div class="flex justify-between items-start gap-4">
          <div class="flex flex-col gap-3 flex-1">
            <div class="flex items-center gap-4">
              ${agentEmoji ? html`<div class="size-12 rounded-xl bg-white/5 border border-white/10 flex items-center justify-center text-3xl shadow-inner">${agentEmoji}</div>` : ''}
              <div>
                <h2 id=${titleId} class="m-0 flex items-baseline gap-3 text-text-strong text-2xl font-bold tracking-tight">
                  ${displayName}
                  ${koreanName ? html`<span class="text-sm text-text-dim font-medium tracking-normal">(${koreanName})</span>` : ''}
                  ${showSecondaryLabel ? html`<span class="font-mono text-xs text-text-dim bg-white/5 px-2 py-0.5 rounded-md">${secondaryLabel}</span>` : ''}
                </h2>
                <div class="flex items-center gap-2 mt-2 flex-wrap">
                  <${StatusBadge} status=${unified.canonical} />
                  ${unified.description !== unified.label ? html`<span class="text-[10px] font-medium py-1 px-2 border border-white/10 bg-white/5 text-text-muted whitespace-nowrap rounded-md" title=${unified.description}>${unified.description}</span>` : null}
                  ${isArchivedParticipant ? html`<span class="text-[10px] font-medium py-1 px-2 border border-accent/20 bg-[var(--accent-10)] text-accent whitespace-nowrap rounded-md shadow-sm">이전 세션 참여자</span>` : null}
                  ${agent?.model ? html`<span class="font-mono text-[10px] font-medium bg-white/10 border border-white/5 px-2 py-1 rounded-md text-text-muted shadow-sm">${agent.model}</span>` : ''}
                  ${!agent && missionBrief?.archived_reason
                    ? html`<span class="text-xs text-text-dim italic">${missionBrief.archived_reason}</span>`
                    : null}
                </div>
              </div>
            </div>
            <div class="mt-2 flex gap-3 flex-wrap text-text-muted text-[13px] font-medium">
              ${agent?.current_task || missionBrief?.current_work
                ? html`<span class="bg-card/40 px-3 py-1.5 rounded-lg border border-card-border shadow-sm">태스크: <span class="text-text-strong">${agent?.current_task ?? missionBrief?.current_work}</span></span>`
                : null}
              ${lastSeenAt ? html`<span class="bg-card/40 px-3 py-1.5 rounded-lg border border-card-border shadow-sm">마지막 확인: <span class="text-text-strong"><${TimeAgo} timestamp=${lastSeenAt} /></span></span>` : null}
            </div>
            ${keeper || continuitySummary || missionBrief?.related_session_id
              ? html`
                  <div class="mt-1 flex gap-3 flex-wrap text-text-muted text-[13px] font-medium">
                    ${keeper
                      ? html`<span class="flex items-center gap-1.5">연결된 키퍼: <strong class="text-text-strong">${keeper.name}</strong>${keeperIdentity ? html`<span class="text-text-dim text-xs">· ${keeperIdentity}</span>` : ''}</span>`
                      : null}
                    ${missionBrief?.related_session_id ? html`<span class="flex items-center gap-1.5">세션: <strong class="font-mono text-text-strong text-xs bg-white/5 px-1.5 rounded">${missionBrief.related_session_id}</strong></span>` : null}
                    ${continuitySummary ? html`<span class="text-accent/90 bg-[var(--accent-10)] px-2 py-0.5 rounded-md border border-accent/10">${continuitySummary}</span>` : null}
                  </div>
                `
              : null}
          </div>
          <div class="flex gap-2 shrink-0">
            <${ActionButton}
              variant="ghost"
              size="lg"
              class="px-4 py-2 text-[13px] rounded-xl bg-card/60 shadow-sm"
              onClick=${() => { void refreshAgentDetail() }}
              disabled=${loading.value}
            >
              ${loading.value ? '새로고침 중...' : '새로고침'}
            <//>
            <button
              ref=${closeButtonRef}
              type="button"
              class="px-4 py-2 text-[13px] font-semibold rounded-xl border border-transparent bg-white/10 text-text-strong hover:bg-white/20 transition-colors duration-200 shadow-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[rgba(71,184,255,0.45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--bg-1)]"
              onClick=${closeAgentDetail}
            >
              닫기
            </button>
          </div>
        </div>

        ${detailError.value ? html`<${ErrorState} message=${detailError.value} />` : null}

        <${AgentSessionReport} agentName=${agentName} />

        <${CollapsibleSection} title="활동 추적" badge=${html`<span class="text-[10px] text-[var(--text-dim)] font-normal ml-1">통합 타임라인</span>`}>
          <${SessionTraceView} agentName=${agentName} isKeeper=${!!keeper} />
        <//>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
          <${Card} title="할당된 작업">
            ${ownedTasks.length === 0
              ? html`<div class="h-full min-h-[120px]"><${EmptyState} message="할당된 작업이 없습니다" compact /></div>`
              : html`<div class="flex flex-col gap-3">${ownedTasks.map(t => html`<${TaskSummary} key=${t.id} task=${t} />`)}</div>`}
          <//>

          <${Card} title="최근 활동">
            ${lines.length === 0
              ? html`<div class="h-full min-h-[120px]"><${EmptyState} message="최근 활동 메시지가 없습니다" compact /></div>`
              : html`<div class="max-h-[240px] overflow-y-auto flex flex-col gap-2 pr-1 custom-scrollbar">${lines.map((line: string, idx: number) => html`<div key=${idx} class="border border-card-border bg-card/40 px-3 py-2.5 font-mono text-[12px] text-text-body leading-relaxed rounded-xl shadow-sm hover:bg-card/60 transition-colors">${line}</div>`)}</div>`}
          <//>
        </div>

        <div class="flex flex-col gap-5">
          <${AgentJournalStream} agentName=${agentName} />
          <${AgentTimelineSection} />
          <${AgentWorkerBrief} agentName=${agentName} />
          ${agentFitness.value ? html`
            <${Card} title="적합도 (7일)">
              <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
                ${[
                  ['완료율', agentFitness.value.completion_rate],
                  ['신뢰도', agentFitness.value.reliability_score],
                  ['속도', agentFitness.value.speed_score],
                  ['종합', agentFitness.value.overall_fitness],
                ].map(([label, val]) => html`
                  <div class="rounded-xl border border-card-border/50 bg-card/30 p-3 text-center">
                    <div class="text-[10px] font-semibold uppercase tracking-wider text-text-muted mb-1">${label}</div>
                    <div class="text-lg font-bold ${(val as number) >= 0.7 ? 'text-ok' : (val as number) >= 0.4 ? 'text-[var(--warn)]' : 'text-bad'}">${val != null ? ((val as number) * 100).toFixed(0) + '%' : '-'}</div>
                  </div>
                `)}
              </div>
            <//>
          ` : null}

          <${Card} title="작업 이력">
            ${taskHistories.value.length === 0
              ? html`<${EmptyState} message="작업 이력이 없습니다" compact />`
              : html`<div class="flex flex-col gap-3">${taskHistories.value.map((row: TaskHistoryRow) => html`<${TaskHistoryPanel} key=${row.taskId} row=${row} />`)}</div>`}
          <//>

          <${Card} title="직접 멘션">
            <div class="grid grid-cols-[1fr_auto] gap-3">
              <${TextInput}
                class="px-4 py-2.5 rounded-xl bg-card/60 text-text-strong text-[13px] placeholder:text-text-dim shadow-inner"
                value=${mentionText.value}
                name="agent_direct_mention"
                ariaLabel="직접 멘션 메시지"
                autoComplete="off"
                placeholder="@멘션 메시지 입력…"
                onInput=${(e: Event) => { mentionText.value = (e.target as HTMLInputElement).value }}
                onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') void submitMention() }}
                disabled=${sendingMention.value}
              />
              <${ActionButton}
                variant="primary"
                size="lg"
                class="px-5 py-2.5 text-[13px] shadow-md shadow-accent/20"
                onClick=${() => { void submitMention() }}
                disabled=${sendingMention.value || mentionText.value.trim() === ''}
              >
                ${sendingMention.value ? '전송 중...' : '전송하기'}
              <//>
            </div>
          <//>
        </div>
      </div>
    <//>
  `
}
