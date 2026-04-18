// Agent Profile — FF Character Sheet style full-page view.
// Layout: character plate (portrait + identity + stats) -> detail grid -> history

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { createAsyncResource } from '../lib/async-state'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { showToast } from './common/toast'
import { keeperIdentityHint } from './common/keeper-identity'
import { EmptyState } from './common/empty-state'
import { ActionButton } from './common/button'
import { TextInput } from './common/input'
import { StatGrid } from './common/stat-tile'
import { formatTokens } from '../lib/format-number'
import { findKeeper } from '../lib/keeper-utils'
import { autonomyHint } from './keeper-detail-panels'
import { AgentAvatar } from './overview/agent-avatar'
import {
  agents,
  executionContinuityBriefs,
  executionWorkerSupportBriefs,
  tasks,
} from '../store'
import {
  fetchRoomMessages,
  fetchTaskHistory,
  sendBroadcast,
  fetchAgentTimeline,
  fetchAgentRelations,
  currentDashboardActor,
  type AgentTimelineEvent,
  type AgentTimelineResponse,
  type AgentRelationsResponse,
} from '../api'
import { missionSnapshot } from '../mission-store'
import { navigate } from '../router'
import { formatDuration } from './mission-utils'
import { trimText } from '../lib/truncate'
import type {
  Agent,
  DashboardExecutionContinuityBrief,
  DashboardMissionAgentBrief,
  Keeper,
  Task,
} from '../types'
import { AgentRuntimeStrip } from './agent-monitor/runtime-strip'
import { AgentLiveTimeline } from './agent-monitor/live-timeline'
import { KeeperChatPanel } from './keeper-chat-panel'

type TaskHistoryRow = { taskId: string; text: string }

interface ProfileData {
  roomActivity: string[]
  taskHistories: TaskHistoryRow[]
  agentTimeline: AgentTimelineResponse | null
  agentRelations: AgentRelationsResponse | null
}

const profileResource = createAsyncResource<ProfileData>()
let profileLoadedName = ''
const mentionText = signal('')
const sendingMention = signal(false)
const activityQuery = signal('')

/**
 * Pure filter for the "프로젝트 활동" (roomActivity) string list.
 *
 * Case-insensitive substring match on the full line. `fetchRoomMessages`
 * returns rendered lines that already embed actor/target/text, so a
 * substring pass is enough to isolate all lines mentioning a particular
 * actor, task id, or keyword.
 *
 * Empty/whitespace query returns the input reference unchanged so the
 * non-filtering render path preserves referential identity (no new
 * array allocation).
 *
 * Input is never mutated; caller may pass a readonly array.
 */
export function filterRoomActivity(
  lines: readonly string[],
  query: string,
): readonly string[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return lines
  return lines.filter(line => line.toLowerCase().includes(needle))
}

function findAgent(name: string): Agent | null {
  return agents.value.find(a => a.name === name) ?? null
}

function assignedTasks(name: string): Task[] {
  return tasks.value.filter(t => t.assignee === name)
}

export function keeperChatTargetName(
  fallbackName: string,
  keeper: Pick<Keeper, 'name'> | null,
): string {
  return keeper?.name ?? fallbackName
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

function loadProfile(name: string): Promise<void> {
  if (profileLoadedName !== name) {
    profileResource.reset()
    profileLoadedName = name
  }
  return profileResource.load(async () => {
    const [lines, timeline, relations] = await Promise.all([
      fetchRoomMessages(80),
      fetchAgentTimeline(name, 4, 20).catch(() => null),
      fetchAgentRelations(name).catch(() => null),
    ])

    const activity = lines
      .filter(line => line.includes(name))
      .slice(0, 20)

    const owned = assignedTasks(name).slice(0, 6)
    let histories: TaskHistoryRow[] = []
    if (owned.length > 0) {
      histories = await Promise.all(
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
    }

    return {
      roomActivity: activity,
      taskHistories: histories,
      agentTimeline: timeline,
      agentRelations: relations,
    }
  })
}

async function submitMention(target: string): Promise<void> {
  const text = mentionText.value.trim()
  if (!target || !text) return
  sendingMention.value = true
  try {
    await sendBroadcast(currentDashboardActor(), `@${target} ${text}`)
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
    case 'broadcast': return '공지'
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
  const model = agent?.model ?? keeper?.model ?? null
  const keeperIdent = keeperIdentityHint(keeper?.name, keeper?.agent_name)
  const signalTruth = brief?.signal_truth
  const continuitySummary =
    trimText(contBrief?.continuity_summary, 160)
    ?? trimText(contBrief?.skill_route_summary, 160)
    ?? null
  const isKeeper = keeper != null
  const workerState = worker?.state
  const workerFocus = worker?.focus

  const cps = profileResource.state.value
  const timeline = cps.status === 'loaded' ? cps.data.agentTimeline : null
  const summary = timeline?.summary

  return html`
    <div class="ff-plate">
      <div class="flex flex-col items-center gap-1.5">
        <${AgentAvatar}
          name=${name}
          status=${headerStatus}
          traits=${agent?.traits}
          size="xl"
          currentWork=${currentWork}
          activityAge=${lastActivity}
          signalTruth=${signalTruth}
        />
        ${isKeeper ? html`<div class="text-3xs font-bold tracking-[1.5px] text-[var(--ff-gold)] uppercase text-center">KEEPER</div>` : null}
      </div>

      <div class="flex flex-col gap-1.5 min-w-0">
        <div class="flex items-baseline gap-2 flex-wrap">
          <h2 class="m-0 text-2xl text-[var(--ff-gold)] flex items-center gap-1.5">
            ${agentEmoji ? html`<span class="text-[1.4em]">${agentEmoji}</span>` : ''}
            ${displayName}
          </h2>
          ${koreanName ? html`<span class="text-base text-[var(--text-muted)]">(${koreanName})</span>` : ''}
          ${generation != null ? html`<span class="text-sm font-bold text-[var(--accent)] bg-[var(--accent-10)] border border-[var(--accent-30)] px-1.5 py-px tabular-nums rounded" title="세대 번호 — 핸드오프마다 증가 (레벨/등급 아님)">Gen.${generation}</span>` : null}
        </div>

        <div class="flex items-center gap-1.5 flex-wrap">
          <${StatusBadge} status=${headerStatus} />
          ${model ? html`<span class="font-[family-name:'IBM_Plex_Mono',monospace] text-2xs text-[var(--text-muted)] bg-[var(--accent-8)] border border-[var(--accent-10)] px-[5px] py-px rounded">${model}</span>` : null}
        </div>

        ${ctxPct != null ? html`
          <div class="flex items-center gap-2 mt-0.5">
            <span class="text-2xs font-bold text-[var(--ff-gold)] tracking-[1px] w-7">CTX</span>
            <div class="h-1.5 mt-1.5 rounded-sm overflow-hidden bg-[var(--white-10)]" style="flex:1">
              <div class="h-full rounded-sm transition-[width] duration-[250ms] ease-[ease] motion-reduce:transition-none ${ctxBarClass(ctxRatio) === 'warn' ? 'bg-linear-to-r from-[var(--warn)] to-[var(--warn-bright)]' : ctxBarClass(ctxRatio) === 'bad' ? 'bg-linear-to-r from-[var(--bad)] to-[var(--warn-bright)]' : 'bg-linear-to-r from-[var(--accent)] to-[var(--ok)]'}" style=${{ width: `${ctxPct}%` }}></div>
            </div>
            <span class="text-sm tabular-nums text-[var(--text-strong)] min-w-9 text-right">${ctxPct}%</span>
            ${keeper?.context_tokens != null && keeper?.context_max != null
              ? html`<span class="text-2xs tabular-nums text-[var(--text-muted)] font-mono ml-1">${formatTokens(keeper.context_tokens)} / ${formatTokens(keeper.context_max)}</span>`
              : null}
          </div>
        ` : null}

        <div class="flex gap-2 items-center flex-wrap">
          ${currentWork
            ? html`<span class="text-base text-[var(--text-body)]">${currentWork}</span>`
            : html`<span class="text-base text-[var(--text-dim)] italic">대기 중</span>`
          }
          ${workerState ? html`<span class="text-2xs text-[var(--accent)] bg-[var(--accent-8)] px-[5px] py-px rounded-xs">${workerState}</span>` : null}
          ${workerFocus ? html`<span class="text-2xs text-[var(--text-muted)]">${workerFocus}</span>` : null}
        </div>

        ${lastSeenAt || lastActivity != null ? html`
          <div class="flex gap-3 flex-wrap text-sm text-[var(--text-muted)]">
            ${lastSeenAt ? html`<span>마지막 확인: <${TimeAgo} timestamp=${lastSeenAt} /></span>` : null}
            ${lastActivity != null ? html`<span>${formatDuration(lastActivity)} 전 활동</span>` : null}
          </div>
        ` : null}

        ${keeperIdent || continuitySummary || brief?.related_session_id ? html`
          <div class="flex gap-3 flex-wrap text-sm text-[var(--text-muted)]">
            ${keeperIdent ? html`<span>${keeperIdent}</span>` : null}
            ${brief?.related_session_id ? html`<span>세션 ${brief.related_session_id}</span>` : null}
            ${continuitySummary ? html`<span>${continuitySummary}</span>` : null}
          </div>
        ` : null}
      </div>

      <div class="w-full mt-2">
        ${isKeeper ? html`
          <${StatGrid} cols=${4} items=${[
            { label: 'CTX', value: ctxPct != null ? `${ctxPct}%` : 'N/A', hint: keeper.context_tokens != null && keeper.context_max != null ? `${formatTokens(keeper.context_tokens)} / ${formatTokens(keeper.context_max)}` : undefined, variant: 'gold' },
            { label: '세대', value: generation ?? 0, variant: 'gold' },
            { label: '턴', value: keeper.turn_count ?? 0, variant: 'gold' },
            { label: '자율 턴', value: keeper.autonomous_turn_count ?? 0, hint: autonomyHint(keeper.autonomous_turn_count, keeper.proactive_enabled), variant: 'gold' },
          ]} />
        ` : html`
          <${StatGrid} cols=${4} items=${[
            { label: '완료', value: summary ? summary.tasks_completed : 'N/A', variant: 'gold' },
            { label: '수임', value: summary ? summary.tasks_claimed : 'N/A', variant: 'gold' },
            { label: '메시지', value: summary ? summary.messages_sent : 'N/A', variant: 'gold' },
            { label: '활동', value: summary && summary.active_duration_minutes > 0 ? `${Math.round(summary.active_duration_minutes)}m` : summary ? '0m' : 'N/A', variant: 'gold' },
          ]} />
        `}
      </div>
    </div>
  `
}

// --- Main Profile ---

export function AgentProfile({ name }: { name: string }) {
  useEffect(() => {
    void loadProfile(name)
    // Reset the activity filter when switching agents so a stale query
    // from the previous profile does not leak into the new one.
    activityQuery.value = ''
  }, [name])

  const ps = profileResource.state.value
  const profileData = ps.status === 'loaded' ? ps.data : undefined
  const profileLoading = ps.status === 'loading'

  const owned = assignedTasks(name)
  const lines = profileData?.roomActivity ?? []
  const timeline = profileData?.agentTimeline ?? null
  const keeper = findKeeper(name)
  const keeperChatName = keeperChatTargetName(name, keeper)
  const isKeeper = keeper != null

  return html`
    <div class="px-1 ${isKeeper ? 'ff-profile--keeper' : ''}">
      <div class="flex gap-2 mb-3">
        <${ActionButton} variant="ghost" onClick=${() => navigate('monitoring', { section: 'agents' })}>← 목록<//>
        <${ActionButton} variant="ghost" onClick=${() => { void loadProfile(name) }} disabled=${profileLoading}>
          ${profileLoading ? '...' : '새로고침'}
        <//>
      </div>

      ${ps.status === 'error'
        ? html`<div class="rounded border border-[var(--bad-30)] bg-[var(--bad-10)] px-3 py-2">${ps.message}</div>`
        : null}

      <${CharacterPlate} name=${name} />

      <${AgentRuntimeStrip} name=${name} />

      <div class="grid grid-cols-2 gap-4 mb-4">
        ${!isKeeper ? html`
        <${Card} title="태스크 (${owned.length})" class="ff-card rounded">
          ${owned.length === 0
            ? html`<${EmptyState} message="할당된 태스크 없음" compact />`
            : html`<div class="flex flex-col gap-2">${owned.map(t => html`
                <div class="flex items-center gap-2 border border-[var(--card-border)] bg-[var(--white-3)] px-2.5 py-2 rounded" key=${t.id}>
                  <span class="text-3xs py-0.5 px-2 border border-solid border-[var(--accent-36)] bg-[var(--accent-12)] text-[var(--accent)] whitespace-nowrap rounded-sm">${t.id}</span>
                  <span class="flex-1 text-[var(--text-strong)]">${t.title}</span>
                  <${StatusBadge} status=${t.status} />
                </div>
              `)}</div>`}
        <//>
        ` : null}

        ${(() => {
          const rel = profileData?.agentRelations ?? null
          if (!rel) return null
          const collabs = rel.collaborators ?? []
          const interests = rel.interests ?? []
          const hasData = collabs.length > 0 || interests.length > 0
          if (!hasData) return null
          return html`
            <${Card} title="관계 (${collabs.length})" class="ff-card rounded">
              ${collabs.length > 0 ? html`
                <div class="flex flex-col gap-1">
                  ${collabs.map(c => html`
                    <button type="button" class="w-full flex items-center gap-2 px-2 py-1.5 transition-colors duration-150 hover:bg-[var(--gold-8)] rounded text-left cursor-pointer focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-accent" key=${c.name}
                      onClick=${() => navigate('monitoring', { section: 'agents', agent: c.name })}
                    >
                      <span class="text-[var(--ff-gold)] font-semibold text-base flex-1">${c.name}</span>
                      <span class="text-[var(--white-50)] text-sm tabular-nums">${c.collaborations}회</span>
                      ${c.last_collab ? html`<span class="ff-relation-time"><${TimeAgo} timestamp=${c.last_collab} /></span>` : null}
                    </button>
                  `)}
                </div>
              ` : null}
              ${interests.length > 0 ? html`
                <div class="border-t border-[var(--white-6)] pt-2 mt-2">
                  <span class="ff-interests-label">관심사</span>
                  <div class="flex flex-wrap gap-1 mt-1.5">
                    ${interests.slice(0, 12).map(t => html`<span class="bg-[var(--gold-10)] text-[var(--white-70)] px-2 py-0.5 rounded-xs text-2xs border border-[var(--gold-15)]" key=${t}>${t}</span>`)}
                    ${interests.length > 12 ? html`<span class="bg-[var(--gold-10)] text-[var(--white-70)] px-2 py-0.5 rounded-xs text-2xs border border-[var(--gold-15)]">+${interests.length - 12}</span>` : null}
                  </div>
                </div>
              ` : null}
            <//>
          `
        })()}

        <${Card} title="타임라인" class="ff-card rounded">
          ${!timeline || (timeline.events ?? []).length === 0
            ? html`<${EmptyState} message="이벤트 없음" compact />`
            : html`<div class="flex flex-col gap-0.5 max-h-[300px] overflow-y-auto">${(timeline.events ?? []).map((evt: AgentTimelineEvent, idx: number) => {
                const detail = evt.detail as Record<string, string | undefined>
                const title = detail.title ?? detail.content ?? ''
                return html`
                  <div class="agent-timeline-event flex items-baseline gap-1.5 py-1 px-2 text-sm transition-[background] duration-100 rounded hover:bg-[var(--white-4)]" key=${idx}>
                    <span class="text-2xs font-semibold text-[var(--ff-gold)] min-w-8">${timelineEventLabel(evt.type)}</span>
                    ${title ? html`<span class="flex-1 text-sm text-[var(--text-body)]">${trimText(title, 80)}</span>` : null}
                    ${evt.ts ? html`<${TimeAgo} timestamp=${evt.ts} />` : null}
                  </div>
                `
              })}</div>`}
        <//>

        <${Card} title="실시간" class="ff-card rounded">
          <${AgentLiveTimeline} name=${name} />
        <//>

        <${Card} title="프로젝트 활동" class="ff-card rounded">
          ${lines.length === 0
            ? html`<${EmptyState} message="관련 활동 없음" compact />`
            : (() => {
                const visible = filterRoomActivity(lines, activityQuery.value)
                const isFiltering = activityQuery.value.trim() !== ''
                return html`
                  <div class="flex flex-col gap-1.5">
                    <input
                      type="search"
                      value=${activityQuery.value}
                      placeholder="활동 필터 (메시지 본문)"
                      aria-label="프로젝트 활동 필터"
                      onInput=${(e: Event) => { activityQuery.value = (e.target as HTMLInputElement).value }}
                      class="w-full rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-2xs text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)]"
                    />
                    ${isFiltering && visible.length === 0
                      ? html`<div class="py-4 text-center text-2xs text-[var(--text-dim)]">필터 결과 없음 (${lines.length} items)</div>`
                      : html`<div class="max-h-[210px] overflow-y-auto flex flex-col gap-1.5">${visible.map((line: string, idx: number) =>
                          html`<div key=${idx} class="border border-[var(--card-border)] bg-[var(--white-3)] px-2.5 py-2 font-[family-name:'IBM_Plex_Mono','Fira_Code',monospace] text-sm text-[var(--text-body)] leading-[1.4] rounded">${line}</div>`)}</div>`}
                  </div>
                `
              })()}
        <//>

        ${(profileData?.taskHistories ?? []).length > 0 ? html`
          <${Card} title="태스크 이력" class="ff-card rounded col-span-full">
            <div class="agent-history-list">${(profileData?.taskHistories ?? []).map((row: TaskHistoryRow) => html`
              <div class="border border-[var(--card-border)] rounded-[10px] bg-[var(--white-2)] p-2.5" key=${row.taskId}>
                <div class="mb-2"><span class="text-3xs py-0.5 px-2 border border-solid border-[var(--accent-36)] bg-[var(--accent-12)] text-[var(--accent)] whitespace-nowrap rounded-sm">${row.taskId}</span></div>
                <pre class="m-0 whitespace-pre-wrap text-sm leading-[1.5] text-[var(--text-strong)] font-[family-name:'IBM_Plex_Mono','Fira_Code',monospace]">${row.text || '이력 없음'}</pre>
              </div>
            `)}</div>
          <//>
        ` : null}
      </div>

      ${isKeeper ? html`
        <${KeeperChatPanel} name=${keeperChatName} />
      ` : html`
        <div class="flex gap-2 items-center px-3.5 py-2.5 bg-[rgba(10,22,40,0.8)] border border-[var(--ff-gold-15)] rounded">
          <span class="text-sm font-semibold text-[var(--ff-gold)] whitespace-nowrap">@${name}</span>
          <${TextInput}
            placeholder="메시지 입력..."
            value=${mentionText.value}
            onInput=${(e: Event) => { mentionText.value = (e.target as HTMLInputElement).value }}
            onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') void submitMention(name) }}
            disabled=${sendingMention.value}
          />
          <${ActionButton}
            onClick=${() => { void submitMention(name) }}
            disabled=${sendingMention.value || mentionText.value.trim() === ''}
          >
            ${sendingMention.value ? '...' : '전송'}
          <//>
        </div>
      `}
    </div>
  `
}
