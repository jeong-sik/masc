import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'

import { missionSnapshot } from '../mission-store'
import { journal } from '../sse'
import {
  executionContinuityBriefs,
  executionSessionBriefs,
  executionWorkerSupportBriefs,
  keepers,
  tasks,
} from '../store'
import type {
  DashboardExecutionContinuityBrief,
  DashboardExecutionSessionBrief,
  DashboardExecutionWorkerSupportBrief,
  JournalEntry,
  Keeper,
  Task,
} from '../types'
import { formatPct, formatTokens } from '../lib/format-number'
import { trimText, truncate } from '../lib/truncate'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { TextInput } from './common/input'
import { RouteLink } from './common/route-link'
import { StatusBadge } from './common/status-badge'
import { StatusChip, keeperStateTone } from './common/status-chip'
import { TimeAgo } from './common/time-ago'

type JourneyMissionSession = {
  session_id: string
  goal: string
  member_names: string[]
  communication_summary?: string | null
  last_event_at?: string | null
  last_event_summary?: string | null
  operation_badges?: Array<{ operation_id: string }>
  keeper_refs?: Array<{ name: string; agent_name?: string | null }>
}

type JourneyLifeEntry = {
  id: string
  source: 'journal' | 'session' | 'handoff'
  text: string
  timestamp: string | number | null
}

export interface JourneyRecord {
  key: string
  kind: 'task' | 'keeper'
  title: string
  subtitle: string | null
  task: Task | null
  keeper: Keeper | null
  continuity: DashboardExecutionContinuityBrief | null
  worker: DashboardExecutionWorkerSupportBrief | null
  executionSession: DashboardExecutionSessionBrief | null
  missionSession: JourneyMissionSession | null
  sessionId: string | null
  operationId: string | null
  workerRunId: string | null
  life: JourneyLifeEntry[]
}

interface JourneyBuildInput {
  tasks: Task[]
  keepers: Keeper[]
  executionSessions: DashboardExecutionSessionBrief[]
  continuityBriefs: DashboardExecutionContinuityBrief[]
  workerBriefs: DashboardExecutionWorkerSupportBrief[]
  missionSessions: JourneyMissionSession[]
  journalEntries: JournalEntry[]
}

const ACTIVE_TASK_STATUSES = new Set(['todo', 'claimed', 'in_progress', 'awaiting_verification'])

function taskStatusRank(status?: string | null): number {
  switch (status) {
    case 'in_progress': return 0
    case 'claimed': return 1
    case 'awaiting_verification': return 2
    case 'todo': return 3
    case 'done': return 4
    case 'cancelled': return 5
    default: return 6
  }
}

function parseTimestamp(value?: string | number | null): number {
  if (typeof value === 'number') {
    return value < 1_000_000_000_000 ? value * 1000 : value
  }
  if (!value) return 0
  const parsed = Date.parse(value)
  return Number.isNaN(parsed) ? 0 : parsed
}

function priorityRank(priority?: number): number {
  if (typeof priority !== 'number' || !Number.isFinite(priority)) return 999
  return priority
}

function normalizeText(value?: string | null): string | null {
  const normalized = (value ?? '').trim()
  return normalized === '' ? null : normalized
}

function formatAgeSeconds(seconds?: number | null): string {
  if (seconds == null || !Number.isFinite(seconds)) return '기록 없음'
  if (seconds < 60) return `${Math.round(seconds)}s 전`
  if (seconds < 3600) return `${Math.round(seconds / 60)}분 전`
  if (seconds < 86_400) return `${Math.round(seconds / 3600)}시간 전`
  return `${Math.round(seconds / 86_400)}일 전`
}

function pipelineTone(stage?: string | null): string {
  switch (stage) {
    case 'thinking':
    case 'tool_use':
    case 'scheduled_autonomous':
      return 'info'
    case 'compacting':
    case 'handoff':
    case 'draining':
      return 'warn'
    case 'failing':
    case 'crashed':
      return 'bad'
    case 'paused':
      return 'paused'
    case 'offline':
    case 'restarting':
      return 'neutral'
    default:
      return 'neutral'
  }
}

function shouldShowStandaloneKeeper(keeper: Keeper): boolean {
  const status = (keeper.status ?? '').trim().toLowerCase()
  if (keeper.keepalive_running === true) return true
  if (keeper.last_turn_ago_s != null) return true
  if (keeper.pipeline_stage && keeper.pipeline_stage !== 'offline') return true
  return !['offline', 'inactive', 'stopped', 'dead'].includes(status)
}

function findKeeperForTask(task: Task, keeperList: Keeper[]): Keeper | null {
  const assignee = normalizeText(task.assignee)
  if (!assignee) return null
  return keeperList.find((keeper) =>
    keeper.name === assignee || keeper.agent_name === assignee,
  ) ?? null
}

function findContinuityForActor(
  actorName: string | null,
  keeper: Keeper | null,
  briefs: DashboardExecutionContinuityBrief[],
): DashboardExecutionContinuityBrief | null {
  if (!actorName && !keeper) return null
  return briefs.find((brief) => {
    if (keeper && (brief.name === keeper.name || brief.agent_name === keeper.agent_name)) return true
    return actorName != null && (brief.name === actorName || brief.agent_name === actorName)
  }) ?? null
}

function findWorkerForActor(
  actorName: string | null,
  keeper: Keeper | null,
  briefs: DashboardExecutionWorkerSupportBrief[],
): DashboardExecutionWorkerSupportBrief | null {
  if (!actorName && !keeper) return null
  return briefs.find((brief) => {
    if (keeper && brief.name === keeper.name) return true
    return actorName != null && (brief.name === actorName || brief.agent_name === actorName)
  }) ?? null
}

function findMissionSessionForContext(
  task: Task | null,
  actorName: string | null,
  keeper: Keeper | null,
  missionSessions: JourneyMissionSession[],
): JourneyMissionSession | null {
  const taskSessionId = normalizeText(task?.execution_links?.session_id)
  if (taskSessionId) {
    return missionSessions.find((session) => session.session_id === taskSessionId) ?? null
  }
  return missionSessions.find((session) => {
    if (actorName && session.member_names.includes(actorName)) return true
    return session.keeper_refs?.some((ref) => {
      if (keeper && ref.name === keeper.name) return true
      return actorName != null && ref.agent_name === actorName
    }) ?? false
  }) ?? null
}

function collectLifeEntries(
  task: Task | null,
  actorName: string | null,
  keeper: Keeper | null,
  sessionId: string | null,
  operationId: string | null,
  missionSession: JourneyMissionSession | null,
  journalEntries: JournalEntry[],
): JourneyLifeEntry[] {
  const related = journalEntries
    .filter((entry) => {
      if (sessionId && entry.sessionId === sessionId) return true
      if (operationId && entry.operationId === operationId) return true
      if (actorName && entry.agent === actorName) return true
      if (keeper && entry.agent === keeper.name) return true
      if (task && entry.text.includes(task.id)) return true
      return false
    })
    .map((entry) => ({
      id: `journal:${entry.timestamp}:${entry.agent}:${entry.text}`,
      source: 'journal' as const,
      text: trimText(entry.narrativeText ?? entry.text, 120) ?? entry.text,
      timestamp: entry.timestamp,
    }))

  const derived: JourneyLifeEntry[] = []
  const handoffText = trimText(task?.handoff_context?.summary, 120)
  if (handoffText) {
    derived.push({
      id: `handoff:${task?.id ?? 'keeper'}`,
      source: 'handoff',
      text: handoffText,
      timestamp: task?.handoff_context?.updated_at ?? task?.updated_at ?? null,
    })
  }
  const sessionSummary = trimText(
    missionSession?.last_event_summary ?? missionSession?.communication_summary,
    120,
  )
  if (sessionSummary) {
    derived.push({
      id: `session:${missionSession?.session_id ?? 'unknown'}`,
      source: 'session',
      text: sessionSummary,
      timestamp: missionSession?.last_event_at ?? null,
    })
  }

  const merged = [...related, ...derived]
    .filter((entry, index, all) =>
      all.findIndex((candidate) => candidate.source === entry.source && candidate.text === entry.text) === index,
    )
    .sort((left, right) => parseTimestamp(right.timestamp) - parseTimestamp(left.timestamp))

  return merged.slice(0, 3)
}

export function buildJourneyRecords(input: JourneyBuildInput): JourneyRecord[] {
  const activeTasks = input.tasks
    .filter((task) => ACTIVE_TASK_STATUSES.has(task.status ?? 'todo'))
    .slice()
    .sort((left, right) => {
      const statusDelta = taskStatusRank(left.status) - taskStatusRank(right.status)
      if (statusDelta !== 0) return statusDelta
      const priorityDelta = priorityRank(left.priority) - priorityRank(right.priority)
      if (priorityDelta !== 0) return priorityDelta
      return parseTimestamp(right.updated_at ?? right.created_at ?? null)
        - parseTimestamp(left.updated_at ?? left.created_at ?? null)
    })

  const taskRecords = activeTasks.map((task): JourneyRecord => {
    const keeper = findKeeperForTask(task, input.keepers)
    const actorName = normalizeText(task.assignee)
    const continuity = findContinuityForActor(actorName, keeper, input.continuityBriefs)
    const worker = findWorkerForActor(actorName, keeper, input.workerBriefs)
    const missionSession = findMissionSessionForContext(task, actorName, keeper, input.missionSessions)
    const sessionId =
      normalizeText(task.execution_links?.session_id)
      ?? normalizeText(task.contract?.links?.session_id)
      ?? normalizeText(worker?.related_session_id)
      ?? normalizeText(continuity?.related_session_id)
      ?? normalizeText(missionSession?.session_id)
      ?? null
    const executionSession = sessionId
      ? input.executionSessions.find((session) => session.session_id === sessionId) ?? null
      : null
    const life = collectLifeEntries(
      task,
      actorName,
      keeper,
      sessionId,
      normalizeText(task.execution_links?.operation_id)
        ?? normalizeText(task.contract?.links?.operation_id)
        ?? normalizeText(worker?.related_operation_id)
        ?? normalizeText(executionSession?.linked_operation_id)
        ?? normalizeText(missionSession?.operation_badges?.[0]?.operation_id)
        ?? null,
      missionSession,
      input.journalEntries,
    )
    const workerRunId = life.find((entry) => entry.source === 'journal')
      ? input.journalEntries.find((entry) => {
          if (sessionId && entry.sessionId === sessionId && entry.workerRunId) return true
          if (actorName && entry.agent === actorName && entry.workerRunId) return true
          return false
        })?.workerRunId ?? null
      : null

    return {
      key: `task:${task.id}`,
      kind: 'task',
      title: task.title,
      subtitle:
        trimText(task.description, 120)
        ?? trimText(missionSession?.goal, 120)
        ?? trimText(task.handoff_context?.summary, 120)
        ?? null,
      task,
      keeper,
      continuity,
      worker,
      executionSession,
      missionSession,
      sessionId,
      operationId:
        normalizeText(task.execution_links?.operation_id)
        ?? normalizeText(task.contract?.links?.operation_id)
        ?? normalizeText(worker?.related_operation_id)
        ?? normalizeText(executionSession?.linked_operation_id)
        ?? normalizeText(missionSession?.operation_badges?.[0]?.operation_id)
        ?? null,
      workerRunId: normalizeText(workerRunId),
      life,
    }
  })

  const usedKeeperNames = new Set(
    taskRecords.flatMap((record) => {
      if (!record.keeper) return []
      return [record.keeper.name, record.keeper.agent_name].filter((value): value is string => Boolean(value))
    }),
  )

  const standaloneKeepers = input.keepers
    .filter((keeper) => !usedKeeperNames.has(keeper.name) && !usedKeeperNames.has(keeper.agent_name ?? ''))
    .filter(shouldShowStandaloneKeeper)
    .slice()
    .sort((left, right) => {
      const leftAge = left.last_activity_ago_s ?? left.last_turn_ago_s ?? Number.POSITIVE_INFINITY
      const rightAge = right.last_activity_ago_s ?? right.last_turn_ago_s ?? Number.POSITIVE_INFINITY
      return leftAge - rightAge
    })

  const keeperRecords = standaloneKeepers.map((keeper): JourneyRecord => {
    const actorName = normalizeText(keeper.agent_name) ?? keeper.name
    const continuity = findContinuityForActor(actorName, keeper, input.continuityBriefs)
    const worker = findWorkerForActor(actorName, keeper, input.workerBriefs)
    const missionSession = findMissionSessionForContext(null, actorName, keeper, input.missionSessions)
    const sessionId =
      normalizeText(worker?.related_session_id)
      ?? normalizeText(continuity?.related_session_id)
      ?? normalizeText(missionSession?.session_id)
      ?? null
    const executionSession = sessionId
      ? input.executionSessions.find((session) => session.session_id === sessionId) ?? null
      : null
    const operationId =
      normalizeText(worker?.related_operation_id)
      ?? normalizeText(executionSession?.linked_operation_id)
      ?? normalizeText(missionSession?.operation_badges?.[0]?.operation_id)
      ?? null
    const life = collectLifeEntries(
      null,
      actorName,
      keeper,
      sessionId,
      operationId,
      missionSession,
      input.journalEntries,
    )

    return {
      key: `keeper:${keeper.name}`,
      kind: 'keeper',
      title: keeper.name,
      subtitle:
        trimText(continuity?.continuity_summary, 120)
        ?? trimText(continuity?.skill_route_summary, 120)
        ?? trimText(worker?.note, 120)
        ?? null,
      task: null,
      keeper,
      continuity,
      worker,
      executionSession,
      missionSession,
      sessionId,
      operationId,
      workerRunId:
        input.journalEntries.find((entry) =>
          ((sessionId && entry.sessionId === sessionId) || entry.agent === keeper.name) && entry.workerRunId,
        )?.workerRunId ?? null,
      life,
    }
  })

  return [...taskRecords, ...keeperRecords]
}

export function filterJourneyRecords(
  records: readonly JourneyRecord[],
  query: string,
): readonly JourneyRecord[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return records
  return records.filter((record) => {
    const haystack = [
      record.title,
      record.subtitle,
      record.task?.id,
      record.task?.assignee,
      record.task?.status,
      record.keeper?.name,
      record.keeper?.agent_name,
      record.keeper?.cascade_name,
      record.keeper?.active_model,
      record.keeper?.model,
      record.continuity?.model,
      record.continuity?.skill_reason,
      record.worker?.focus,
      record.sessionId,
      record.operationId,
      record.workerRunId,
      ...record.life.map((entry) => entry.text),
    ]
      .filter((value): value is string => typeof value === 'string' && value.trim() !== '')
      .map((value) => value.toLowerCase())

    return haystack.some((value) => value.includes(needle))
  })
}

function MetricChip({
  label,
  value,
  tone = 'neutral',
}: {
  label: string
  value: string | number
  tone?: string
}) {
  return html`
    <div class="rounded border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2">
      <div class="text-3xs uppercase tracking-3 text-[var(--text-dim)]">${label}</div>
      <div class="mt-1 flex items-center gap-2 text-sm font-semibold text-[var(--text-strong)]">
        <${StatusChip} tone=${tone} uppercase=${false}>${value}<//>
      </div>
    </div>
  `
}

function JourneyTile({
  label,
  children,
}: {
  label: string
  children: preact.ComponentChildren
}) {
  return html`
    <section class="rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] p-4 flex flex-col gap-3 min-h-[150px]">
      <div class="text-3xs font-semibold uppercase tracking-4 text-[var(--text-dim)]">${label}</div>
      <div class="flex flex-col gap-2 text-sm text-[var(--text-body)]">
        ${children}
      </div>
    </section>
  `
}

function TileHint({ text }: { text: string }) {
  return html`<div class="text-xs leading-relaxed text-[var(--text-muted)]">${text}</div>`
}

function JourneyCard({ record }: { record: JourneyRecord }) {
  const task = record.task
  const keeper = record.keeper
  const completionItems = task?.contract?.completion_contract ?? task?.gate?.completion_contract ?? []
  const requiredEvidence = task?.contract?.required_evidence ?? []
  const unmetItems = task?.gate?.unmet_completion_contract ?? []
  const lifeEntries = record.life.slice(0, 2)
  const searchKeeperName = keeper?.name ?? task?.assignee ?? null
  const contextSummary = keeper?.context_tokens != null && keeper?.context_max != null
    ? `${formatTokens(keeper.context_tokens)} / ${formatTokens(keeper.context_max)}`
    : null
  const showExtended = useSignal(false)

  return html`
    <${Card} class="flex flex-col gap-5 bg-gradient-to-br from-[rgba(var(--white-rgb,255),0.08)] via-[rgba(var(--white-rgb,255),0.04)] to-[rgba(var(--white-rgb,255),0.06)] border border-[var(--white-10)] backdrop-blur-md">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            <h3 class="m-0 text-xl font-semibold text-[var(--text-strong)]">${record.title}</h3>
            ${task?.status
              ? html`<${StatusBadge} status=${task.status} />`
              : keeper?.status
                ? html`<${StatusChip} tone=${keeperStateTone(keeper.status)}>${keeper.status}<//>`
                : null}
            <${StatusChip} tone=${record.kind === 'task' ? 'info' : 'neutral'}>
              ${record.kind === 'task' ? 'task journey' : 'keeper journey'}
            <//>
          </div>
          ${record.subtitle
            ? html`<div class="mt-1 text-sm leading-relaxed text-[var(--text-muted)]">${record.subtitle}</div>`
            : null}
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <${RouteLink}
            tab="workspace"
            params=${{ section: 'planning' }}
            class="inline-flex items-center rounded-full border border-[var(--white-10)] bg-[var(--white-5)] px-3 py-1.5 text-xs text-[var(--text-body)] hover:bg-[var(--white-8)]"
          >
            작업 보기
          <//>
          ${record.sessionId || record.operationId
            ? html`
                <${RouteLink}
                  tab="monitoring"
                  params=${{
                    section: 'fleet-health',
                    view: 'event-log',
                    ...(record.sessionId ? { session_id: record.sessionId } : {}),
                    ...(record.operationId ? { operation_id: record.operationId } : {}),
                  }}
                  class="inline-flex items-center rounded-full border border-[var(--accent-20)] bg-[var(--accent-10)] px-3 py-1.5 text-xs text-[var(--accent)] hover:bg-[var(--accent-20)]"
                >
                  실행 로그
                <//>
              `
            : null}
          ${searchKeeperName
            ? html`
                <${RouteLink}
                  tab="monitoring"
                  params=${{ section: 'agents', agent: searchKeeperName }}
                  class="inline-flex items-center rounded-full border border-[var(--ok-20)] bg-[var(--ok-10)] px-3 py-1.5 text-xs text-[var(--ok)] hover:bg-[var(--ok-20)]"
                >
                  키퍼 보기
                <//>
              `
            : null}
        </div>
      </div>

      <div class="flex flex-col gap-4">
        <div class="grid gap-3 md:grid-cols-2">
          <${JourneyTile} label="Task">
            ${task
              ? html`
                  <div class="font-mono text-xs text-[var(--text-strong)]">${task.id}</div>
                  ${task.assignee
                    ? html`<div>담당: <strong class="text-[var(--text-strong)]">${task.assignee}</strong></div>`
                    : html`<${TileHint} text="아직 assignee가 없습니다." />`}
                  ${task.updated_at
                    ? html`<div class="text-xs text-[var(--text-muted)]">최근 갱신 <${TimeAgo} timestamp=${task.updated_at} /></div>`
                    : null}
                `
              : html`<${TileHint} text="현재 연결된 task 없이 keeper 연속성만 추적 중입니다." />`}
          <//>

          <${JourneyTile} label="Run">
            ${record.sessionId
              ? html`<div><span class="text-[var(--text-dim)]">session</span><div class="mt-1 font-mono text-xs text-[var(--text-strong)]">${truncate(record.sessionId, 24)}</div></div>`
              : html`<${TileHint} text="아직 session_id가 연결되지 않았습니다." />`}
            ${record.operationId
              ? html`<div><span class="text-[var(--text-dim)]">operation</span><div class="mt-1 font-mono text-xs text-[var(--text-strong)]">${truncate(record.operationId, 24)}</div></div>`
              : null}
            ${record.workerRunId
              ? html`<div><span class="text-[var(--text-dim)]">worker run</span><div class="mt-1 font-mono text-xs text-[var(--text-strong)]">${truncate(record.workerRunId, 24)}</div></div>`
              : null}
            ${trimText(record.executionSession?.goal ?? record.missionSession?.goal, 90)
              ? html`<div class="text-xs leading-relaxed text-[var(--text-muted)]">${trimText(record.executionSession?.goal ?? record.missionSession?.goal, 90)}</div>`
              : null}
          <//>

          <${JourneyTile} label="Contract" class="md:col-span-2">
            ${task
              ? html`
                  <div class="flex flex-wrap items-center gap-2">
                    <${StatusChip} tone=${task.contract?.strict ? 'info' : 'neutral'}>
                      ${task.contract?.strict ? 'strict' : 'advisory'}
                    <//>
                    ${task.status === 'awaiting_verification'
                      ? html`<${StatusChip} tone="select">verification pending<//>`
                      : null}
                  </div>
                  <div class="grid grid-cols-3 gap-2">
                    <${MetricChip} label="completion" value=${completionItems.length} />
                    <${MetricChip} label="unmet" value=${unmetItems.length} tone=${unmetItems.length > 0 ? 'bad' : 'ok'} />
                    <${MetricChip} label="evidence" value=${requiredEvidence.length} />
                  </div>
                  ${unmetItems.length > 0
                    ? html`<div class="text-xs leading-relaxed text-[var(--warn)]">${unmetItems.slice(0, 2).join(' · ')}</div>`
                    : null}
                `
              : keeper?.runtime_blocker_class === 'completion_contract_violation'
                ? html`<div class="text-xs leading-relaxed text-[var(--bad-light)]">최근 runtime blocker가 completion contract violation으로 관측됐습니다.</div>`
                : html`<${TileHint} text="현재 contract gate가 연결된 task가 없습니다." />`}
          <//>

          <${JourneyTile} label="Keeper" class="md:col-span-2">
            ${keeper
              ? html`
                  <div class="flex flex-wrap items-center gap-2">
                    <div class="font-semibold text-[var(--text-strong)]">${keeper.name}</div>
                    ${keeper.phase ? html`<${StatusChip} tone=${keeperStateTone(keeper.phase)}>${keeper.phase}<//>` : null}
                    <${StatusChip} tone=${keeperStateTone(keeper.status)}>${keeper.status}<//>
                  </div>
                  <div class="flex flex-wrap gap-3 text-xs text-[var(--text-muted)]">
                    <span>ctx ${formatPct(keeper.context_ratio)}</span>
                    ${contextSummary ? html`<span>${contextSummary}</span>` : null}
                    ${keeper.last_activity_ago_s != null ? html`<span>활동 ${formatAgeSeconds(keeper.last_activity_ago_s)}</span>` : null}
                  </div>
                  ${trimText(record.continuity?.continuity_summary ?? record.continuity?.note, 100)
                    ? html`<div class="text-xs leading-relaxed text-[var(--text-muted)]">${trimText(record.continuity?.continuity_summary ?? record.continuity?.note, 100)}</div>`
                    : null}
                `
              : html`<${TileHint} text="현재 task에 연결된 keeper가 없습니다." />`}
          <//>
        </div>

        <div class="flex items-center gap-3 border-t border-[var(--white-8)] pt-3">
          <button
            class="inline-flex items-center rounded px-3 py-1.5 text-xs font-medium text-[var(--text-muted)] transition hover:text-[var(--text-body)] hover:bg-[var(--white-5)]"
            onClick=${() => { showExtended.value = !showExtended.value }}
          >
            ${showExtended.value ? '▼' : '▶'} 추가 정보
          </button>
          <div class="text-2xs text-[var(--text-dim)]">
            thinking, memory, turn, lifecycle, cascade
          </div>
        </div>

        ${showExtended.value
          ? html`
              <div class="grid gap-3 md:grid-cols-2 lg:grid-cols-3">
                <${JourneyTile} label="Thinking">
                  ${keeper?.pipeline_stage
                    ? html`<${StatusChip} tone=${pipelineTone(keeper.pipeline_stage)}>${keeper.pipeline_stage}<//>`
                    : html`<${TileHint} text="thinking stage가 아직 보고되지 않았습니다." />`}
                  ${keeper?.skill_primary
                    ? html`<div><span class="text-[var(--text-dim)]">skill</span><div class="mt-1 font-semibold text-[var(--text-strong)]">${keeper.skill_primary}</div></div>`
                    : null}
                  ${trimText(keeper?.skill_reason ?? keeper?.recent_input_preview ?? record.worker?.focus, 100)
                    ? html`<div class="text-xs leading-relaxed text-[var(--text-muted)]">${trimText(keeper?.skill_reason ?? keeper?.recent_input_preview ?? record.worker?.focus, 100)}</div>`
                    : null}
                <//>

                <${JourneyTile} label="Memory">
                  ${trimText(keeper?.memory_recent_note, 100)
                    ? html`<div class="text-xs leading-relaxed text-[var(--text-body)]">${trimText(keeper?.memory_recent_note, 100)}</div>`
                    : html`<${TileHint} text="최근 memory note가 아직 없습니다." />`}
                  ${keeper?.metrics_window
                    ? html`
                        <div class="grid grid-cols-3 gap-2">
                          <${MetricChip} label="pass" value=${formatPct(keeper.metrics_window.memory_pass_rate)} tone="ok" />
                          <${MetricChip} label="checks" value=${keeper.metrics_window.memory_checks ?? 0} />
                          <${MetricChip} label="compact" value=${keeper.compaction_count ?? keeper.metrics_window.memory_compaction_events ?? 0} tone="warn" />
                        </div>
                      `
                    : null}
                <//>

                <${JourneyTile} label="Turn">
                  ${keeper
                    ? html`
                        <div class="grid grid-cols-3 gap-2">
                          <${MetricChip} label="turns" value=${keeper.turn_count ?? keeper.total_turns ?? 0} />
                          <${MetricChip} label="last" value=${formatAgeSeconds(keeper.last_turn_ago_s)} tone="info" />
                          <${MetricChip} label="auto" value=${keeper.autonomous_turn_count ?? 0} />
                        </div>
                        ${keeper.runtime_blocker_summary
                          ? html`<div class="text-xs leading-relaxed text-[var(--warn)]">${trimText(keeper.runtime_blocker_summary, 100)}</div>`
                          : null}
                      `
                    : html`<${TileHint} text="연결된 keeper turn 정보가 없습니다." />`}
                <//>

                <${JourneyTile} label="Life" class="lg:col-span-2">
                  ${lifeEntries.length > 0
                    ? html`
                        ${lifeEntries.map((entry) => html`
                          <div key=${entry.id} class="rounded border border-[var(--white-8)] bg-[var(--white-4)] px-3 py-2">
                            <div class="flex items-center justify-between gap-2">
                              <${StatusChip} tone=${entry.source === 'journal' ? 'info' : entry.source === 'handoff' ? 'warn' : 'neutral'} uppercase=${false}>
                                ${entry.source}
                              <//>
                              ${entry.timestamp ? html`<${TimeAgo} timestamp=${entry.timestamp} class="text-2xs text-[var(--text-dim)]" />` : null}
                            </div>
                            <div class="mt-2 text-xs leading-relaxed text-[var(--text-body)]">${entry.text}</div>
                          </div>
                        `)}
                      `
                    : html`<${TileHint} text="현재 컨텍스트에 엮인 recent life signal이 없습니다." />`}
                <//>

                <${JourneyTile} label="Cascade">
                  ${keeper
                    ? html`
                        <div class="flex flex-wrap items-center gap-2">
                          ${keeper.cascade_name ? html`<${StatusChip} tone="info">${keeper.cascade_name}<//>` : null}
                          ${keeper.active_model ? html`<${StatusChip} tone="neutral" uppercase=${false}>${keeper.active_model}<//>` : null}
                        </div>
                        <div class="text-xs text-[var(--text-muted)]">
                          ${keeper.last_model_used || keeper.model ? html`last ${keeper.last_model_used ?? keeper.model}` : 'model 기록 없음'}
                        </div>
                        ${keeper.next_model_hint
                          ? html`<div class="text-xs text-[var(--text-muted)]">next ${keeper.next_model_hint}</div>`
                          : null}
                        ${keeper.metrics_window?.fallback_rate != null
                          ? html`<div class="text-xs text-[var(--text-muted)]">fallback ${formatPct(keeper.metrics_window.fallback_rate)}</div>`
                          : null}
                      `
                    : html`<${TileHint} text="cascade 선택 정보는 keeper runtime에서만 노출됩니다." />`}
                <//>
              </div>
            `
          : null}
      </div>
    <//>
  `
}

export function JourneyPanel() {
  const query = useSignal('')
  const missionSessions = Array.isArray(missionSnapshot.value?.sessions)
    ? missionSnapshot.value.sessions as JourneyMissionSession[]
    : []
  const records = buildJourneyRecords({
    tasks: tasks.value,
    keepers: keepers.value,
    executionSessions: executionSessionBriefs.value,
    continuityBriefs: executionContinuityBriefs.value,
    workerBriefs: executionWorkerSupportBriefs.value,
    missionSessions,
    journalEntries: journal.value,
  })
  const visible = filterJourneyRecords(records, query.value)
  const taskCount = records.filter((record) => record.kind === 'task').length
  const keeperCount = records.filter((record) => record.kind === 'keeper').length
  const blockedCount = records.filter((record) =>
    record.keeper?.runtime_blocker_class != null || (record.task?.gate?.done?.status === 'blocked'),
  ).length
  const thinkingCount = records.filter((record) => record.keeper?.pipeline_stage === 'thinking').length
  const memoryHotCount = records.filter((record) =>
    Boolean(record.keeper?.memory_recent_note) || (record.keeper?.compaction_count ?? 0) > 0,
  ).length
  const taskRecords = visible.filter((record) => record.kind === 'task')
  const keeperRecords = visible.filter((record) => record.kind === 'keeper')

  return html`
    <div class="flex flex-col gap-4">
      <${Card} class="flex flex-col gap-4">
        <div class="flex flex-col gap-2">
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="m-0 text-2xl font-semibold text-[var(--text-strong)]">Task → Run → Contract → Keeper → Thinking → Memory → Turn → Life → Cascade</h2>
            <${StatusChip} tone="info">journey beta<//>
          </div>
          <div class="text-sm leading-relaxed text-[var(--text-muted)]">
            task 중심 흐름과 task에 안 묶인 keeper 연속성을 같은 카드 문법으로 읽습니다. 실행 링크, contract gate, keeper stage, memory note, recent life signal, cascade 선택을 한 번에 붙여 봅니다.
          </div>
        </div>

        <div class="grid gap-3 md:grid-cols-5">
          <${MetricChip} label="journeys" value=${records.length} tone="info" />
          <${MetricChip} label="tasks" value=${taskCount} />
          <${MetricChip} label="keepers" value=${keeperCount} />
          <${MetricChip} label="blocked" value=${blockedCount} tone=${blockedCount > 0 ? 'bad' : 'ok'} />
          <${MetricChip} label="thinking/memory" value=${`${thinkingCount} / ${memoryHotCount}`} tone="warn" />
        </div>

        <div class="flex flex-wrap items-center gap-3">
          <${TextInput}
            type="search"
            value=${query.value}
            placeholder="task / keeper / session / operation / model / life 검색"
            ariaLabel="journey 검색"
            class="max-w-[460px]"
            onInput=${(event: Event) => {
              query.value = (event.target as HTMLInputElement).value
            }}
          />
          <div class="text-xs text-[var(--text-muted)]">
            ${query.value.trim() !== '' ? `${visible.length} / ${records.length}개 표시` : `${records.length}개 흐름`}
          </div>
        </div>
      <//>

      ${visible.length === 0
        ? html`<${EmptyState} message="현재 조건에 맞는 journey가 없습니다." compact />`
        : html`
            ${taskRecords.length > 0
              ? html`
                  <div class="flex flex-col gap-3">
                    <div class="text-2xs font-semibold uppercase tracking-3 text-[var(--text-muted)]">Task Journeys</div>
                    ${taskRecords.map((record) => html`<${JourneyCard} key=${record.key} record=${record} />`)}
                  </div>
                `
              : null}

            ${keeperRecords.length > 0
              ? html`
                  <div class="flex flex-col gap-3">
                    <div class="text-2xs font-semibold uppercase tracking-3 text-[var(--text-muted)]">Standalone Keeper Journeys</div>
                    ${keeperRecords.map((record) => html`<${JourneyCard} key=${record.key} record=${record} />`)}
                  </div>
                `
              : null}
          `}
    </div>
  `
}
