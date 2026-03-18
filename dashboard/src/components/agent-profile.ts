// Agent Profile — full-page view for a single agent.
// Reuses data-fetching from agent-detail and renders as a dedicated page
// instead of an overlay modal.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { showToast } from './common/toast'
import { keeperIdentityHint } from './common/keeper-identity'
import { AgentAvatar } from './overview/agent-avatar'
import {
  agents,
  executionContinuityBriefs,
  executionWorkerSupportBriefs,
  keepers,
  tasks,
} from '../store'
import {
  fetchRoomMessages,
  fetchTaskHistory,
  sendBroadcast,
  fetchAgentTimeline,
  type AgentTimelineEvent,
  type AgentTimelineResponse,
} from '../api'
import { journal } from '../sse'
import { missionSnapshot } from '../mission-store'
import { navigate } from '../router'
import { formatDuration } from './mission-utils'
import type { JournalEntry } from '../types'
import type {
  Agent,
  DashboardExecutionContinuityBrief,
  DashboardMissionAgentBrief,
  Keeper,
  Task,
} from '../types'

const AGENT_NAME_KEY = 'masc_dashboard_agent_name'

type TaskHistoryRow = { taskId: string; text: string }

const loading = signal(false)
const profileError = signal('')
const roomActivity = signal<string[]>([])
const taskHistories = signal<TaskHistoryRow[]>([])
const agentTimeline = signal<AgentTimelineResponse | null>(null)
const mentionText = signal('')
const sendingMention = signal(false)

function findAgent(name: string): Agent | null {
  return agents.value.find(a => a.name === name) ?? null
}

function assignedTasks(name: string): Task[] {
  return tasks.value.filter(t => t.assignee === name)
}

function findKeeper(name: string): Keeper | null {
  return keepers.value.find(
    k => k.agent_name === name || k.name === name,
  ) ?? null
}

function missionBrief(name: string): DashboardMissionAgentBrief | null {
  const mission = missionSnapshot.value
  if (!mission) return null
  return mission.agent_briefs.find(b => b.agent_name === name) ?? null
}

function continuityBrief(name: string): DashboardExecutionContinuityBrief | null {
  return executionContinuityBriefs.value.find(
    b => b.agent_name === name || b.name === name,
  ) ?? null
}

function workerBrief(name: string) {
  return executionWorkerSupportBriefs.value.find(w => w.name === name) ?? null
}

function agentJournalEntries(name: string): JournalEntry[] {
  const lower = name.toLowerCase()
  return journal.value
    .filter((e: JournalEntry) => {
      const text = e.text.toLowerCase()
      const agent = e.agent.toLowerCase()
      return agent === lower || text.includes(lower) || text.includes(`@${lower}`)
    })
    .slice(0, 15)
}

function compactCopy(value: string | null | undefined, max = 160): string | null {
  const text = (value ?? '').replace(/\s+/g, ' ').trim()
  if (!text) return null
  return text.length > max ? `${text.slice(0, max - 1)}…` : text
}

async function loadProfile(name: string): Promise<void> {
  loading.value = true
  profileError.value = ''
  roomActivity.value = []
  taskHistories.value = []
  agentTimeline.value = null

  try {
    const [lines, timeline] = await Promise.all([
      fetchRoomMessages(80),
      fetchAgentTimeline(name, 4, 20).catch(() => null),
    ])

    roomActivity.value = lines
      .filter(line => line.includes(name))
      .slice(0, 20)

    agentTimeline.value = timeline

    const owned = assignedTasks(name).slice(0, 6)
    if (owned.length > 0) {
      const rows = await Promise.all(
        owned.map(async task => {
          try {
            const text = await fetchTaskHistory(task.id, 25)
            return { taskId: task.id, text: text.trim() }
          } catch (err) {
            const msg = err instanceof Error ? err.message : 'load failed'
            return { taskId: task.id, text: `Failed: ${msg}` }
          }
        }),
      )
      taskHistories.value = rows
    }
  } catch (err) {
    profileError.value = err instanceof Error ? err.message : 'Failed to load profile'
  } finally {
    loading.value = false
  }
}

async function submitMention(target: string): Promise<void> {
  const text = mentionText.value.trim()
  if (!target || !text) return
  const sender = localStorage.getItem(AGENT_NAME_KEY)?.trim() || 'dashboard'
  sendingMention.value = true
  try {
    await sendBroadcast(sender, `@${target} ${text}`)
    mentionText.value = ''
    showToast(`Mention sent to ${target}`, 'success')
    void loadProfile(target)
  } catch (err) {
    showToast(err instanceof Error ? err.message : 'Failed', 'error')
  } finally {
    sendingMention.value = false
  }
}

function pressureClass(ratio: number | null | undefined): string {
  if (ratio == null) return ''
  const pct = ratio * 100
  if (pct < 50) return 'pressure--ok'
  if (pct < 70) return 'pressure--amber'
  if (pct < 85) return 'pressure--orange'
  return 'pressure--red'
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

function journalKindIcon(entry: JournalEntry): string {
  if (entry.kind === 'board') return 'B'
  if (entry.kind === 'tasks') return 'T'
  if (entry.kind === 'keepers') return 'K'
  return 'S'
}

export function AgentProfile({ name }: { name: string }) {
  useEffect(() => {
    void loadProfile(name)
  }, [name])

  const agent = findAgent(name)
  const keeper = findKeeper(name)
  const brief = missionBrief(name)
  const contBrief = continuityBrief(name)
  const worker = workerBrief(name)
  const owned = assignedTasks(name)
  const lines = roomActivity.value
  const timeline = agentTimeline.value

  const displayName = brief?.display_name ?? keeper?.name ?? name
  const secondaryLabel = displayName !== name ? name : null
  const headerStatus = agent?.status ?? brief?.status ?? 'unknown'
  const lastSeenAt = agent?.last_seen ?? brief?.last_activity_at ?? null
  const agentEmoji = agent?.emoji ?? keeper?.emoji
  const koreanName = agent?.koreanName ?? keeper?.koreanName
  const currentWork = keeper?.current_work ?? brief?.current_work ?? agent?.current_task ?? null
  const ctxRatio = keeper?.context_ratio
  const ctxPct = ctxRatio != null ? Math.round(ctxRatio * 100) : null
  const keeperIdent = keeperIdentityHint(keeper?.name, keeper?.agent_name)
  const continuitySummary =
    compactCopy(contBrief?.continuity_summary)
    ?? compactCopy(contBrief?.skill_route_summary)
    ?? null
  const lastActivity = keeper?.last_turn_ago_s ?? brief?.last_turn_ago_s ?? null

  const journalEntries = agentJournalEntries(name)

  return html`
    <div class="agent-profile">
      <div class="agent-profile__back">
        <button class="control-btn ghost" onClick=${() => navigate('agents')}>
          ← 목록으로
        </button>
        <button
          class="control-btn ghost"
          onClick=${() => { void loadProfile(name) }}
          disabled=${loading.value}
        >
          ${loading.value ? '새로고침 중...' : '새로고침'}
        </button>
      </div>

      ${profileError.value ? html`<div class="council-error">${profileError.value}</div>` : null}

      <div class="agent-profile__header">
        <div class="agent-profile__avatar">
          <${AgentAvatar}
            name=${name}
            status=${headerStatus}
            traits=${agent?.traits}
            size="xl"
            currentWork=${currentWork}
            activityAge=${lastActivity}
          />
        </div>
        <div class="agent-profile__identity">
          <h2 class="agent-profile__name">
            ${agentEmoji ? html`<span style="font-size:1.5em;margin-right:8px">${agentEmoji}</span>` : ''}
            ${displayName}
            ${koreanName ? html`<span class="agent-profile__korean">(${koreanName})</span>` : ''}
            ${secondaryLabel ? html`<span class="mono agent-profile__secondary">${secondaryLabel}</span>` : ''}
          </h2>
          <div class="agent-profile__badges">
            <${StatusBadge} status=${headerStatus} />
            ${keeper ? html`<span class="pill">keeper</span>` : null}
            ${keeper?.generation != null ? html`<span class="pill">G${keeper.generation}</span>` : null}
            ${agent?.model ? html`<span class="mono pill">${agent.model}</span>` : ''}
            ${brief?.signal_truth ? html`<span class="pill">signal · ${brief.signal_truth}</span>` : null}
          </div>
          <div class="agent-profile__meta">
            ${currentWork ? html`<span>작업: ${currentWork}</span>` : html`<span class="text-muted">작업 없음</span>`}
            ${lastSeenAt ? html`<span>마지막: <${TimeAgo} timestamp=${lastSeenAt} /></span>` : null}
            ${lastActivity != null ? html`<span>${formatDuration(lastActivity)} 전 활동</span>` : null}
          </div>
          ${keeper && keeperIdent ? html`<div class="agent-profile__meta"><span>Keeper: ${keeper.name}${keeperIdent ? ` · ${keeperIdent}` : ''}</span></div>` : null}
          ${continuitySummary ? html`<div class="agent-profile__meta"><span>${continuitySummary}</span></div>` : null}
          ${brief?.related_session_id ? html`<div class="agent-profile__meta"><span>Session: ${brief.related_session_id}</span></div>` : null}
        </div>
      </div>

      ${keeper && ctxPct != null ? html`
        <div class="agent-profile__ctx-section">
          <div class="agent-profile__ctx-label">Context ${ctxPct}%</div>
          <div class="roster-card__gauge-track" style="max-width:400px">
            <div class="roster-card__gauge-bar ${pressureClass(ctxRatio)}" style=${{ width: `${ctxPct}%` }} />
          </div>
          ${keeper?.autonomy_level ? html`<span class="pill">autonomy: ${keeper.autonomy_level}</span>` : null}
        </div>
      ` : null}

      <div class="agent-profile__grid">
        <${Card} title="할당된 태스크 (${owned.length})">
          ${owned.length === 0
            ? html`<div class="empty-state">할당된 태스크 없음</div>`
            : html`<div class="agent-detail-task-list">${owned.map(t => html`
                <div class="agent-detail-task" key=${t.id}>
                  <span class="pill">${t.id}</span>
                  <span class="agent-detail-task-title">${t.title}</span>
                  <${StatusBadge} status=${t.status} />
                </div>
              `)}</div>`}
        <//>

        ${worker ? html`
          <${Card} title="Worker 상태">
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
                  <span class="mono">${compactCopy(worker.recent_output_preview, 120)}</span>
                </div>
              ` : null}
            </div>
          <//>
        ` : null}

        <${Card} title="최근 Room 활동">
          ${lines.length === 0
            ? html`<div class="empty-state">관련 활동 없음</div>`
            : html`<div class="agent-activity-list">${lines.map((line: string, idx: number) =>
                html`<div key=${idx} class="agent-activity-line">${line}</div>`)}</div>`}
        <//>

        <${Card} title="실시간 이벤트 (${journalEntries.length})">
          ${journalEntries.length === 0
            ? html`<div class="empty-state">관련 이벤트 없음</div>`
            : html`<div class="agent-journal-stream">${journalEntries.map((entry: JournalEntry, idx: number) => html`
                <div class="agent-journal-entry" key=${idx}>
                  <span class="agent-journal-kind">${journalKindIcon(entry)}</span>
                  <span class="agent-journal-type">${entry.eventType}</span>
                  <span class="agent-journal-text">${compactCopy(entry.text, 120) ?? ''}</span>
                  ${entry.timestamp ? html`<${TimeAgo} timestamp=${entry.timestamp} />` : null}
                </div>
              `)}</div>`}
        <//>

        ${timeline ? html`
          <${Card} title="타임라인 (${timeline.summary?.total_events ?? 0})">
            ${timeline.summary ? html`
              <div class="agent-timeline-summary">
                ${timeline.summary.tasks_completed > 0 ? html`<span class="pill">완료 ${timeline.summary.tasks_completed}</span>` : null}
                ${timeline.summary.tasks_claimed > 0 ? html`<span class="pill">수임 ${timeline.summary.tasks_claimed}</span>` : null}
                ${timeline.summary.messages_sent > 0 ? html`<span class="pill">메시지 ${timeline.summary.messages_sent}</span>` : null}
                ${timeline.summary.active_duration_minutes > 0 ? html`<span class="pill">${Math.round(timeline.summary.active_duration_minutes)}분 활동</span>` : null}
              </div>
            ` : null}
            ${(timeline.events ?? []).length === 0
              ? html`<div class="empty-state">타임라인 이벤트 없음</div>`
              : html`<div class="agent-timeline-list">${(timeline.events ?? []).map((evt: AgentTimelineEvent, idx: number) => {
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
                })}</div>`}
          <//>
        ` : null}

        <${Card} title="태스크 이력">
          ${taskHistories.value.length === 0
            ? html`<div class="empty-state">태스크 이력 없음</div>`
            : html`<div class="agent-history-list">${taskHistories.value.map((row: TaskHistoryRow) => html`
                <div class="agent-history-row" key=${row.taskId}>
                  <div class="agent-history-head"><span class="pill">${row.taskId}</span></div>
                  <pre class="agent-history-pre">${row.text || 'No history yet'}</pre>
                </div>
              `)}</div>`}
        <//>

        <${Card} title="@mention 보내기">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="메시지 입력..."
              value=${mentionText.value}
              onInput=${(e: Event) => { mentionText.value = (e.target as HTMLInputElement).value }}
              onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') void submitMention(name) }}
              disabled=${sendingMention.value}
            />
            <button
              class="control-btn"
              onClick=${() => { void submitMention(name) }}
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
