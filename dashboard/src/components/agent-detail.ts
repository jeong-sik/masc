// Agent detail overlay — recent room activity + assigned task history + direct mention

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { showToast } from './common/toast'
import { keeperIdentityHint } from './common/keeper-identity'
import {
  agents,
  executionContinuityBriefs,
  keepers,
  tasks,
} from '../store'
import { fetchRoomMessages, fetchTaskHistory, sendBroadcast, fetchAgentTimeline, type AgentTimelineEvent, type AgentTimelineResponse } from '../api'
import { journal } from '../sse'
import { route, navigate } from '../router'
import { missionSnapshot } from '../mission-store'
import { executionWorkerSupportBriefs } from '../store'
import type { JournalEntry } from '../types'
import type {
  Agent,
  DashboardExecutionContinuityBrief,
  DashboardMissionAgentBrief,
  Keeper,
  Task,
} from '../types'

const AGENT_NAME_KEY = 'masc_dashboard_agent_name'

type TaskHistoryRow = {
  taskId: string
  text: string
}

export const selectedAgentName = signal<string | null>(null)
const loading = signal(false)
const detailError = signal('')
const roomActivity = signal<string[]>([])
const taskHistories = signal<TaskHistoryRow[]>([])
const agentTimeline = signal<AgentTimelineResponse | null>(null)
const mentionText = signal('')
const sendingMention = signal(false)

export function openAgentDetail(agentName: string): void {
  selectedAgentName.value = agentName
  void refreshAgentDetail()
}

export function closeAgentDetail(): void {
  selectedAgentName.value = null
  detailError.value = ''
  roomActivity.value = []
  taskHistories.value = []
  agentTimeline.value = null
  mentionText.value = ''
  if (route.value.tab === 'status' && route.value.params.agent) {
    navigate('status', { section: 'agents' })
  }
}

function selectedAgent(): Agent | null {
  const name = selectedAgentName.value
  if (!name) return null
  return agents.value.find(a => a.name === name) ?? null
}

function assignedTasks(agentName: string | null): Task[] {
  if (!agentName) return []
  return tasks.value.filter(t => t.assignee === agentName)
}

function keeperForAgent(agentName: string | null): Keeper | null {
  if (!agentName) return null
  return keepers.value.find(keeper => keeper.agent_name === agentName || keeper.name === agentName) ?? null
}

function missionAgentBrief(agentName: string | null): DashboardMissionAgentBrief | null {
  if (!agentName) return null
  const mission = missionSnapshot.value
  if (!mission) return null
  return mission.agent_briefs.find(brief => brief.agent_name === agentName) ?? null
}

function continuityBriefForAgent(agentName: string | null): DashboardExecutionContinuityBrief | null {
  if (!agentName) return null
  return executionContinuityBriefs.value.find(
    brief => brief.agent_name === agentName || brief.name === agentName,
  ) ?? null
}

async function refreshAgentDetail(): Promise<void> {
  const agentName = selectedAgentName.value
  if (!agentName) return

  loading.value = true
  detailError.value = ''
  roomActivity.value = []
  taskHistories.value = []
  agentTimeline.value = null

  try {
    // Fetch room messages, task histories, and timeline in parallel
    const [lines, timelineResult] = await Promise.all([
      fetchRoomMessages(80),
      fetchAgentTimeline(agentName, 4, 20).catch(() => null),
    ])

    roomActivity.value = lines
      .filter(line => line.includes(agentName))
      .slice(0, 20)

    agentTimeline.value = timelineResult

    const ownedTasks = assignedTasks(agentName).slice(0, 6)
    if (ownedTasks.length === 0) return

    const historyRows = await Promise.all(
      ownedTasks.map(async task => {
        try {
          const text = await fetchTaskHistory(task.id, 25)
          return { taskId: task.id, text: text.trim() }
        } catch (err) {
          const message = err instanceof Error ? err.message : 'history load failed'
          return { taskId: task.id, text: `Failed to load history: ${message}` }
        }
      }),
    )
    taskHistories.value = historyRows
  } catch (err) {
    detailError.value = err instanceof Error ? err.message : 'Failed to load agent detail'
  } finally {
    loading.value = false
  }
}

async function submitMention(): Promise<void> {
  const target = selectedAgentName.value
  const text = mentionText.value.trim()
  if (!target || !text) return

  const sender = localStorage.getItem(AGENT_NAME_KEY)?.trim() || 'dashboard'

  sendingMention.value = true
  try {
    await sendBroadcast(sender, `@${target} ${text}`)
    mentionText.value = ''
    showToast(`Mention sent to ${target}`, 'success')
    void refreshAgentDetail()
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Failed to send mention'
    showToast(msg, 'error')
  } finally {
    sendingMention.value = false
  }
}

function agentJournalEntries(agentName: string | null): JournalEntry[] {
  if (!agentName) return []
  const nameLower = agentName.toLowerCase()
  return journal.value
    .filter((entry: JournalEntry) => {
      const text = entry.text.toLowerCase()
      const agent = entry.agent.toLowerCase()
      return agent === nameLower || text.includes(nameLower) || text.includes(`@${nameLower}`)
    })
    .slice(0, 15)
}

function workerBriefForAgent(agentName: string | null) {
  if (!agentName) return null
  return executionWorkerSupportBriefs.value.find(w => w.name === agentName) ?? null
}

function journalKindIcon(entry: JournalEntry): string {
  if (entry.kind === 'board') return 'B'
  if (entry.kind === 'tasks') return 'T'
  if (entry.kind === 'keepers') return 'K'
  return 'S'
}

function TaskSummary({ task }: { task: Task }) {
  return html`
    <div class="agent-detail-task">
      <span class="pill">${task.id}</span>
      <span class="agent-detail-task-title">${task.title}</span>
      <${StatusBadge} status=${task.status} />
    </div>
  `
}

function TaskHistoryPanel({ row }: { row: TaskHistoryRow }) {
  return html`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${row.taskId}</span>
      </div>
      <pre class="agent-history-pre">${row.text || 'No task history yet'}</pre>
    </div>
  `
}

function compactCopy(value: string | null | undefined, max = 160): string | null {
  const text = (value ?? '').replace(/\s+/g, ' ').trim()
  if (!text) return null
  return text.length > max ? `${text.slice(0, max - 1)}…` : text
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
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${(e: Event) => {
        if ((e.target as HTMLElement).classList.contains('agent-detail-overlay')) closeAgentDetail()
      }}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${agentEmoji ? html`<span style="font-size:2rem">${agentEmoji}</span>` : ''}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${displayName}
                  ${koreanName ? html`<span style="font-size:0.75em;color:#888">(${koreanName})</span>` : ''}
                  ${secondaryLabel ? html`<span class="mono" style="font-size:0.75em;color:#888">${secondaryLabel}</span>` : ''}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  <${StatusBadge} status=${headerStatus} />
                  ${isArchivedParticipant ? html`<span class="pill">archived session participant</span>` : null}
                  ${agent?.model ? html`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${agent.model}</span>` : ''}
                  ${!agent && missionBrief?.archived_reason
                    ? html`<span style="font-size:0.75rem;color:#888">${missionBrief.archived_reason}</span>`
                    : null}
                  ${signalTruth ? html`<span class="pill">signal · ${signalTruth}</span>` : null}
                  ${evidenceSource ? html`<span class="pill">source · ${evidenceSource}</span>` : null}
                </div>
              </div>
            </div>
            <div class="agent-detail-sub">
              ${agent?.current_task || missionBrief?.current_work
                ? html`<span>Task: ${agent?.current_task ?? missionBrief?.current_work}</span>`
                : null}
              ${lastSeenAt ? html`<span>Last seen: <${TimeAgo} timestamp=${lastSeenAt} /></span>` : null}
            </div>
            ${keeper || continuitySummary || missionBrief?.related_session_id
              ? html`
                  <div class="agent-detail-sub">
                    ${keeper
                      ? html`<span>Linked keeper: ${keeper.name}${keeperIdentity ? ` · ${keeperIdentity}` : ''}</span>`
                      : null}
                    ${missionBrief?.related_session_id ? html`<span>Session: ${missionBrief.related_session_id}</span>` : null}
                    ${continuitySummary ? html`<span>${continuitySummary}</span>` : null}
                  </div>
                `
              : null}
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${() => { void refreshAgentDetail() }} disabled=${loading.value}>
              ${loading.value ? '새로고침 중...' : '새로고침'}
            </button>
            <button class="control-btn ghost" onClick=${closeAgentDetail}>닫기</button>
          </div>
        </div>

        ${detailError.value ? html`<div class="council-error">${detailError.value}</div>` : null}

        <div class="agent-detail-grid">
          <${Card} title="할당된 작업">
            ${ownedTasks.length === 0
              ? html`<div class="empty-state">할당된 작업이 없습니다</div>`
              : html`<div class="agent-detail-task-list">${ownedTasks.map(t => html`<${TaskSummary} key=${t.id} task=${t} />`)}</div>`}
          <//>

          <${Card} title="최근 활동">
            ${lines.length === 0
              ? html`<div class="empty-state">최근 활동 기록이 없습니다</div>`
              : html`<div class="agent-activity-list">${lines.map((line: string, idx: number) => html`<div key=${idx} class="agent-activity-line">${line}</div>`)}</div>`}
          <//>
        </div>

        <${AgentJournalStream} agentName=${agentName} />
        <${AgentTimelineSection} />
        <${AgentWorkerBrief} agentName=${agentName} />
        <${Card} title="작업 이력">
          ${taskHistories.value.length === 0
            ? html`<div class="empty-state">작업 이력이 없습니다</div>`
            : html`<div class="agent-history-list">${taskHistories.value.map((row: TaskHistoryRow) => html`<${TaskHistoryPanel} key=${row.taskId} row=${row} />`)}</div>`}
        <//>

        <${Card} title="직접 멘션">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@멘션 메시지"
              value=${mentionText.value}
              onInput=${(e: Event) => { mentionText.value = (e.target as HTMLInputElement).value }}
              onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') void submitMention() }}
              disabled=${sendingMention.value}
            />
            <button
              class="control-btn"
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

function AgentJournalStream({ agentName }: { agentName: string }) {
  const entries = agentJournalEntries(agentName)

  return html`
    <${Card} title="실시간 활동 스트림">
      ${entries.length === 0
        ? html`<div class="empty-state">관련 이벤트 없음</div>`
        : html`
            <div class="agent-journal-stream">
              ${entries.map((entry: JournalEntry, idx: number) => html`
                <div class="agent-journal-entry" key=${idx}>
                  <span class="agent-journal-kind">${journalKindIcon(entry)}</span>
                  <span class="agent-journal-type">${entry.eventType}</span>
                  <span class="agent-journal-text">${compactCopy(entry.text, 120) ?? ''}</span>
                  ${entry.timestamp ? html`<${TimeAgo} timestamp=${entry.timestamp} />` : null}
                </div>
              `)}
            </div>
          `}
    <//>
  `
}

function timelineEventIcon(type: string): string {
  if (type === 'joined') return 'J'
  if (type.startsWith('task_')) return 'T'
  if (type === 'broadcast') return 'M'
  return 'E'
}

function timelineEventLabel(type: string): string {
  switch (type) {
    case 'joined': return '참가'
    case 'task_claimed': return '태스크 수임'
    case 'task_started': return '태스크 시작'
    case 'task_completed': return '태스크 완료'
    case 'task_cancelled': return '태스크 취소'
    case 'broadcast': return '브로드캐스트'
    default: return type
  }
}

function AgentTimelineSection() {
  const timeline = agentTimeline.value
  if (!timeline) return null

  const events = timeline.events ?? []
  const summary = timeline.summary

  return html`
    <${Card} title="활동 타임라인 (${summary?.total_events ?? 0} events)">
      ${summary ? html`
        <div class="agent-timeline-summary">
          ${summary.tasks_completed > 0 ? html`<span class="pill">완료 ${summary.tasks_completed}</span>` : null}
          ${summary.tasks_claimed > 0 ? html`<span class="pill">수임 ${summary.tasks_claimed}</span>` : null}
          ${summary.messages_sent > 0 ? html`<span class="pill">메시지 ${summary.messages_sent}</span>` : null}
          ${summary.active_duration_minutes > 0 ? html`<span class="pill">${Math.round(summary.active_duration_minutes)}분 활동</span>` : null}
        </div>
      ` : null}
      ${events.length === 0
        ? html`<div class="empty-state">타임라인 이벤트 없음</div>`
        : html`
            <div class="agent-timeline-list">
              ${events.map((evt: AgentTimelineEvent, idx: number) => {
                const detail = evt.detail as Record<string, string | undefined>
                const title = detail.title ?? detail.content ?? ''
                return html`
                  <div class="agent-timeline-event" key=${idx}>
                    <span class="agent-journal-kind">${timelineEventIcon(evt.type)}</span>
                    <span class="agent-timeline-type">${timelineEventLabel(evt.type)}</span>
                    ${title ? html`<span class="agent-timeline-detail">${compactCopy(title, 80)}</span>` : null}
                    ${evt.ts ? html`<${TimeAgo} timestamp=${evt.ts} />` : null}
                  </div>
                `
              })}
            </div>
          `}
    <//>
  `
}

function AgentWorkerBrief({ agentName }: { agentName: string }) {
  const worker = workerBriefForAgent(agentName)
  if (!worker) return null

  return html`
    <${Card} title="Worker Status">
      <div class="agent-worker-brief">
        <div class="agent-worker-brief__row">
          <span class="agent-worker-brief__label">State</span>
          <${StatusBadge} status=${worker.state} />
        </div>
        ${worker.focus ? html`
          <div class="agent-worker-brief__row">
            <span class="agent-worker-brief__label">Focus</span>
            <span>${worker.focus}</span>
          </div>
        ` : null}
        ${worker.recent_output_preview ? html`
          <div class="agent-worker-brief__row">
            <span class="agent-worker-brief__label">Output</span>
            <span class="agent-worker-brief__preview">${compactCopy(worker.recent_output_preview, 200)}</span>
          </div>
        ` : null}
        ${worker.related_session_id ? html`
          <div class="agent-worker-brief__row">
            <span class="agent-worker-brief__label">Session</span>
            <span class="mono" style="font-size: 11px">${worker.related_session_id}</span>
          </div>
        ` : null}
        ${worker.last_signal_at ? html`
          <div class="agent-worker-brief__row">
            <span class="agent-worker-brief__label">Signal</span>
            <${TimeAgo} timestamp=${worker.last_signal_at} />
            ${worker.signal_truth ? html`<span class="pill">${worker.signal_truth}</span>` : null}
          </div>
        ` : null}
      </div>
    <//>
  `
}
