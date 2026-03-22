// Agent Profile — FF Character Sheet style full-page view.
// Layout: character plate (portrait + identity + stats) -> detail grid -> history

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
  fetchAgentRelations,
  type AgentTimelineEvent,
  type AgentTimelineResponse,
  type AgentRelationsResponse,
} from '../api'
import { missionSnapshot } from '../mission-store'
import { navigate } from '../router'
import { formatDuration } from './mission-utils'
import type {
  Agent,
  DashboardExecutionContinuityBrief,
  DashboardMissionAgentBrief,
  Keeper,
  Task,
} from '../types'
import { AgentRuntimeStrip } from './agent-monitor/runtime-strip'
import { AgentLiveTimeline } from './agent-monitor/live-timeline'
import { AutonomyMeter } from './keeper-detail-panels'
import { KeeperChatPanel } from './keeper-chat-panel'

const AGENT_NAME_KEY = 'masc_dashboard_agent_name'

type TaskHistoryRow = { taskId: string; text: string }

const loading = signal(false)
const profileError = signal('')
const roomActivity = signal<string[]>([])
const taskHistories = signal<TaskHistoryRow[]>([])
const agentTimeline = signal<AgentTimelineResponse | null>(null)
const agentRelations = signal<AgentRelationsResponse | null>(null)
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
  agentRelations.value = null

  try {
    const [lines, timeline, relations] = await Promise.all([
      fetchRoomMessages(80),
      fetchAgentTimeline(name, 4, 20).catch(() => null),
      fetchAgentRelations(name).catch(() => null),
    ])

    agentRelations.value = relations

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
    showToast(`${target}에게 전송`, 'success')
    void loadProfile(target)
  } catch (err) {
    showToast(err instanceof Error ? err.message : 'Failed', 'error')
  } finally {
    sendingMention.value = false
  }
}

function ctxBarClass(ratio: number | null | undefined): string {
  if (ratio == null) return ''
  const pct = ratio * 100
  if (pct < 50) return ''
  if (pct < 70) return 'warn'
  return 'bad'
}

function timelineEventLabel(type: string): string {
  switch (type) {
    case 'joined': return '참가'
    case 'task_claimed': return '수임'
    case 'task_started': return '시작'
    case 'task_completed': return '완료'
    case 'task_cancelled': return '취소'
    case 'broadcast': return '방송'
    default: return type
  }
}

// --- FF Character Plate ---

function CharacterPlate({ name }: { name: string }) {
  const agent = findAgent(name)
  const keeper = findKeeper(name)
  const brief = missionBrief(name)
  const contBrief = continuityBrief(name)
  const worker = workerBrief(name)

  const displayName = brief?.display_name ?? keeper?.name ?? name
  const koreanName = agent?.koreanName ?? keeper?.koreanName
  // Keeper heartbeat status takes priority over agent store status
  const headerStatus = keeper?.status ?? agent?.status ?? brief?.status ?? 'unknown'
  const agentEmoji = agent?.emoji ?? keeper?.emoji
  const currentWork = brief?.current_work ?? agent?.current_task ?? null
  const lastSeenAt = agent?.last_seen ?? brief?.last_activity_at ?? null
  const lastActivity = keeper?.last_turn_ago_s ?? brief?.last_activity_age_sec ?? null
  const ctxRatio = keeper?.context_ratio
  const ctxPct = ctxRatio != null ? Math.round(ctxRatio * 100) : null
  const generation = keeper?.generation
  const autonomy = keeper?.autonomy_level
  const model = agent?.model ?? keeper?.model ?? null
  const keeperIdent = keeperIdentityHint(keeper?.name, keeper?.agent_name)
  const signalTruth = brief?.signal_truth
  const continuitySummary =
    compactCopy(contBrief?.continuity_summary)
    ?? compactCopy(contBrief?.skill_route_summary)
    ?? null
  const isKeeper = keeper != null
  const workerState = worker?.state
  const workerFocus = worker?.focus

  const timeline = agentTimeline.value
  const summary = timeline?.summary

  return html`
    <div class="ff-plate">
      <div class="ff-plate__portrait">
        <${AgentAvatar}
          name=${name}
          status=${headerStatus}
          traits=${agent?.traits}
          size="xl"
          currentWork=${currentWork}
          activityAge=${lastActivity}
          signalTruth=${signalTruth}
        />
        ${isKeeper ? html`<div class="text-[9px] font-bold tracking-[1.5px] text-[color:var(--ff-gold)] uppercase text-center">KEEPER</div>` : null}
      </div>

      <div class="ff-plate__info">
        <div class="ff-plate__name-row">
          <h2 class="ff-plate__name">
            ${agentEmoji ? html`<span class="text-[1.4em]">${agentEmoji}</span>` : ''}
            ${displayName}
          </h2>
          ${koreanName ? html`<span class="text-[length:var(--fs-base)] text-[color:var(--text-muted)]">(${koreanName})</span>` : ''}
          ${generation != null ? html`<span class="ff-plate__level">Lv.${generation}</span>` : null}
        </div>

        <div class="ff-plate__badges">
          <${StatusBadge} status=${headerStatus} />
          ${model ? html`<span class="ff-plate__model">${model}</span>` : null}
          ${autonomy ? html`<span class="ff-plate__autonomy">${autonomy}</span>` : null}
          ${signalTruth ? html`<span class="ff-plate__signal ff-plate__signal--${signalTruth}">${signalTruth}</span>` : null}
        </div>

        ${ctxPct != null ? html`
          <div class="ff-plate__bar-row">
            <span class="ff-plate__bar-label">CTX</span>
            <div class="ctx-bar" style="flex:1">
              <div class="ctx-fill ${ctxBarClass(ctxRatio)}" style=${{ width: `${ctxPct}%` }}></div>
            </div>
            <span class="ff-plate__bar-value">${ctxPct}%</span>
          </div>
        ` : null}

        <div class="ff-plate__status-line">
          ${currentWork
            ? html`<span class="text-[length:var(--fs-base)] text-[#c8daf7]">${currentWork}</span>`
            : html`<span class="text-[length:var(--fs-base)] text-[#c8daf7] ff-plate__work--idle">대기 중</span>`
          }
          ${workerState ? html`<span class="ff-plate__worker-state">${workerState}</span>` : null}
          ${workerFocus ? html`<span class="text-[length:var(--fs-xs)] text-[#9ab3de]">${workerFocus}</span>` : null}
        </div>

        ${lastSeenAt || lastActivity != null ? html`
          <div class="ff-plate__meta-line">
            ${lastSeenAt ? html`<span>마지막 확인: <${TimeAgo} timestamp=${lastSeenAt} /></span>` : null}
            ${lastActivity != null ? html`<span>${formatDuration(lastActivity)} 전 활동</span>` : null}
          </div>
        ` : null}

        ${keeperIdent || continuitySummary || brief?.related_session_id ? html`
          <div class="ff-plate__meta-line">
            ${keeperIdent ? html`<span>${keeperIdent}</span>` : null}
            ${brief?.related_session_id ? html`<span>세션 ${brief.related_session_id}</span>` : null}
            ${continuitySummary ? html`<span>${continuitySummary}</span>` : null}
          </div>
        ` : null}
      </div>

      ${isKeeper ? html`
        <div class="ff-plate__stats ff-plate__stats--keeper">
          <div class="ff-stat">
            <span class="ff-stat__value">${ctxPct != null ? `${ctxPct}%` : '—'}</span>
            <span class="text-[length:var(--fs-2xs)] text-[color:var(--ff-gold)] tracking-[0.5px]">CTX</span>
          </div>
          <div class="ff-stat">
            <span class="ff-stat__value">${generation ?? 0}</span>
            <span class="text-[length:var(--fs-2xs)] text-[color:var(--ff-gold)] tracking-[0.5px]">세대</span>
          </div>
          <div class="ff-stat">
            <span class="ff-stat__value">${keeper.turn_count ?? 0}</span>
            <span class="text-[length:var(--fs-2xs)] text-[color:var(--ff-gold)] tracking-[0.5px]">턴</span>
          </div>
          <div class="ff-stat">
            <span class="ff-stat__value">${keeper.autonomous_action_count ?? 0}</span>
            <span class="text-[length:var(--fs-2xs)] text-[color:var(--ff-gold)] tracking-[0.5px]">행동</span>
          </div>
        </div>
      ` : summary ? html`
        <div class="ff-plate__stats">
          <div class="ff-stat">
            <span class="ff-stat__value">${summary.tasks_completed}</span>
            <span class="text-[length:var(--fs-2xs)] text-[color:var(--ff-gold)] tracking-[0.5px]">완료</span>
          </div>
          <div class="ff-stat">
            <span class="ff-stat__value">${summary.tasks_claimed}</span>
            <span class="text-[length:var(--fs-2xs)] text-[color:var(--ff-gold)] tracking-[0.5px]">수임</span>
          </div>
          <div class="ff-stat">
            <span class="ff-stat__value">${summary.messages_sent}</span>
            <span class="text-[length:var(--fs-2xs)] text-[color:var(--ff-gold)] tracking-[0.5px]">메시지</span>
          </div>
          <div class="ff-stat">
            <span class="ff-stat__value">${summary.active_duration_minutes > 0 ? `${Math.round(summary.active_duration_minutes)}m` : '0m'}</span>
            <span class="text-[length:var(--fs-2xs)] text-[color:var(--ff-gold)] tracking-[0.5px]">활동</span>
          </div>
        </div>
      ` : null}
    </div>
  `
}

// --- Main Profile ---

export function AgentProfile({ name }: { name: string }) {
  useEffect(() => {
    void loadProfile(name)
  }, [name])

  const owned = assignedTasks(name)
  const lines = roomActivity.value
  const timeline = agentTimeline.value
  const keeper = findKeeper(name)
  const isKeeper = keeper != null

  return html`
    <div class="ff-profile ${isKeeper ? 'ff-profile--keeper' : ''}">
      <div class="ff-profile__toolbar">
        <button class="control-btn ghost" onClick=${() => navigate('status', { section: 'agents' })}>← 목록</button>
        <button class="control-btn ghost" onClick=${() => { void loadProfile(name) }} disabled=${loading.value}>
          ${loading.value ? '...' : '새로고침'}
        </button>
      </div>

      ${profileError.value ? html`<div class="council-error">${profileError.value}</div>` : null}

      <${CharacterPlate} name=${name} />

      <${AgentRuntimeStrip} name=${name} />

      ${isKeeper && keeper ? html`
        <div class="ff-profile__keeper-panels">
          <${AutonomyMeter} keeper=${keeper} />
        </div>
      ` : null}

      <div class="ff-profile__grid">
        ${!isKeeper ? html`
        <${Card} title="태스크 (${owned.length})" class="ff-card">
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
        ` : null}

        ${(() => {
          const rel = agentRelations.value
          if (!rel) return null
          const collabs = rel.collaborators ?? []
          const interests = rel.interests ?? []
          const hasData = collabs.length > 0 || interests.length > 0
          if (!hasData) return null
          return html`
            <${Card} title="관계 (${collabs.length})" class="ff-card">
              ${collabs.length > 0 ? html`
                <div class="ff-relations-list">
                  ${collabs.map(c => html`
                    <div class="ff-relation-row" key=${c.name}
                      onClick=${() => navigate('status', { section: 'agents', agent: c.name })}
                      style="cursor:pointer;"
                    >
                      <span class="ff-relation-name">${c.name}</span>
                      <span class="ff-relation-count">${c.collaborations}회</span>
                      ${c.last_collab ? html`<span class="ff-relation-time"><${TimeAgo} timestamp=${c.last_collab} /></span>` : null}
                    </div>
                  `)}
                </div>
              ` : null}
              ${interests.length > 0 ? html`
                <div class="ff-interests" class="mt-2">
                  <span class="ff-interests-label">관심사</span>
                  <div class="ff-interests-tags">
                    ${interests.slice(0, 12).map(t => html`<span class="ff-interest-tag" key=${t}>${t}</span>`)}
                    ${interests.length > 12 ? html`<span class="ff-interest-tag">+${interests.length - 12}</span>` : null}
                  </div>
                </div>
              ` : null}
            <//>
          `
        })()}

        <${Card} title="타임라인" class="ff-card">
          ${!timeline || (timeline.events ?? []).length === 0
            ? html`<div class="empty-state">이벤트 없음</div>`
            : html`<div class="agent-timeline-list">${(timeline.events ?? []).map((evt: AgentTimelineEvent, idx: number) => {
                const detail = evt.detail as Record<string, string | undefined>
                const title = detail.title ?? detail.content ?? ''
                return html`
                  <div class="agent-timeline-event" key=${idx}>
                    <span class="ff-event-type">${timelineEventLabel(evt.type)}</span>
                    ${title ? html`<span class="ff-event-detail">${compactCopy(title, 80)}</span>` : null}
                    ${evt.ts ? html`<${TimeAgo} timestamp=${evt.ts} />` : null}
                  </div>
                `
              })}</div>`}
        <//>

        <${Card} title="실시간" class="ff-card">
          <${AgentLiveTimeline} name=${name} />
        <//>

        <${Card} title="Room 활동" class="ff-card">
          ${lines.length === 0
            ? html`<div class="empty-state">관련 활동 없음</div>`
            : html`<div class="agent-activity-list">${lines.map((line: string, idx: number) =>
                html`<div key=${idx} class="agent-activity-line">${line}</div>`)}</div>`}
        <//>

        ${taskHistories.value.length > 0 ? html`
          <${Card} title="태스크 이력" class="ff-card col-span-full">
            <div class="agent-history-list">${taskHistories.value.map((row: TaskHistoryRow) => html`
              <div class="agent-history-row" key=${row.taskId}>
                <div class="mb-2"><span class="pill">${row.taskId}</span></div>
                <pre class="agent-history-pre">${row.text || 'No history yet'}</pre>
              </div>
            `)}</div>
          <//>
        ` : null}
      </div>

      ${isKeeper ? html`
        <${KeeperChatPanel} name=${name} />
      ` : html`
        <div class="ff-profile__mention">
          <span class="ff-profile__mention-label">@${name}</span>
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
            ${sendingMention.value ? '...' : '전송'}
          </button>
        </div>
      `}
    </div>
  `
}
