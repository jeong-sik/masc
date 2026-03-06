// Activity tab — unified live feed and system journal

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { buildAgentMotion } from './common/agent-motion'
import { agents, tasks, messages, boardPosts, keepers } from '../store'
import { connected, eventCount, journal } from '../sse'
import type { Message, JournalEntry, Task, BoardPost, Keeper } from '../types'

type ActivityFilter = 'all' | 'messages' | 'board' | 'tasks' | 'keepers' | 'system'
const MAX_VISIBLE_ROWS = 120
const MAX_TASK_SNAPSHOT_ROWS = 12
const MAX_BOARD_SNAPSHOT_ROWS = 16
const MAX_KEEPER_SNAPSHOT_ROWS = 12

type ActivityRowModel = {
  id: string
  source: 'message' | 'event' | 'snapshot'
  kind: Exclude<ActivityFilter, 'all'>
  actor: string
  content: string
  timestamp: string
}

const activityFilter = signal<ActivityFilter>('all')

const FILTER_LABELS: Record<ActivityFilter, string> = {
  all: 'All',
  messages: 'Messages',
  board: 'Board',
  tasks: 'Tasks',
  keepers: 'Keepers',
  system: 'System',
}

const KIND_BADGE_LABELS: Record<Exclude<ActivityFilter, 'all'>, string> = {
  messages: 'MSG',
  board: 'BOARD',
  tasks: 'TASK',
  keepers: 'KEEPER',
  system: 'SYS',
}

function classifyJournalKind(entry: JournalEntry): Exclude<ActivityFilter, 'all'> {
  if (entry.kind) return entry.kind
  const text = entry.text
  if (text === 'New post' || text === 'New comment') return 'board'
  if (text.startsWith('Task:')) return 'tasks'
  if (
    text.startsWith('Heartbeat')
    || text.startsWith('Handoff')
    || text.startsWith('Compaction')
    || text.startsWith('Guardrail')
  ) return 'keepers'
  return 'system'
}

function fromMessage(msg: Message, idx: number): ActivityRowModel {
  return {
    id: msg.id ?? `msg-${msg.seq ?? idx}`,
    source: 'message',
    kind: 'messages',
    actor: msg.from ?? 'system',
    content: msg.content,
    timestamp: msg.timestamp,
  }
}

function fromJournal(entry: JournalEntry, idx: number): ActivityRowModel {
  return {
    id: `evt-${entry.timestamp}-${idx}`,
    source: 'event',
    kind: classifyJournalKind(entry),
    actor: entry.agent || 'system',
    content: entry.text,
    timestamp: new Date(entry.timestamp).toISOString(),
  }
}

function fromTaskSnapshot(task: Task, idx: number): ActivityRowModel | null {
  const actor = task.assignee?.trim()
  const timestamp = task.updated_at ?? task.created_at
  if (!actor || !timestamp) return null
  return {
    id: `task-${task.id}-${idx}`,
    source: 'snapshot',
    kind: 'tasks',
    actor,
    content: `Task: ${task.title} (${task.status})`,
    timestamp,
  }
}

function fromBoardSnapshot(post: BoardPost, idx: number): ActivityRowModel {
  return {
    id: `board-${post.id}-${idx}`,
    source: 'snapshot',
    kind: 'board',
    actor: post.author,
    content: `Post: ${post.title || post.content}`,
    timestamp: post.updated_at || post.created_at,
  }
}

function timestampFromAgeSeconds(ageSeconds: number | null | undefined): string | null {
  if (typeof ageSeconds !== 'number' || !Number.isFinite(ageSeconds) || ageSeconds < 0) return null
  return new Date(Date.now() - ageSeconds * 1000).toISOString()
}

function keeperSnapshotTimestamp(keeper: Keeper): string | null {
  return keeper.last_heartbeat
    ?? timestampFromAgeSeconds(keeper.last_turn_ago_s)
    ?? timestampFromAgeSeconds(keeper.last_proactive_ago_s)
    ?? timestampFromAgeSeconds(keeper.last_handoff_ago_s)
    ?? timestampFromAgeSeconds(keeper.last_compaction_ago_s)
}

function fromKeeperSnapshot(keeper: Keeper, idx: number): ActivityRowModel | null {
  const timestamp = keeperSnapshotTimestamp(keeper)
  if (!timestamp) return null
  const ratio = typeof keeper.context_ratio === 'number' && Number.isFinite(keeper.context_ratio)
    ? `${Math.round(keeper.context_ratio * 100)}%`
    : '?'
  return {
    id: `keeper-${keeper.name}-${idx}`,
    source: 'snapshot',
    kind: 'keepers',
    actor: keeper.name,
    content: keeper.last_heartbeat
      ? `Heartbeat gen=${keeper.generation ?? '?'} ctx=${ratio}`
      : `Keeper snapshot gen=${keeper.generation ?? '?'} ctx=${ratio}`,
    timestamp,
  }
}

function toEpoch(ts: string | number): number {
  const parsed = typeof ts === 'number' ? ts : Date.parse(ts)
  return Number.isNaN(parsed) ? 0 : parsed
}

const sortedRows = computed(() => {
  const msgRows = messages.value.map(fromMessage)
  const journalRows = journal.value.map(fromJournal)
  const taskRows = [...tasks.value]
    .sort((a, b) => toEpoch(b.updated_at ?? b.created_at ?? 0) - toEpoch(a.updated_at ?? a.created_at ?? 0))
    .slice(0, MAX_TASK_SNAPSHOT_ROWS)
    .map(fromTaskSnapshot)
    .filter((row): row is ActivityRowModel => row !== null)
  const boardRows = [...boardPosts.value]
    .sort((a, b) => toEpoch(b.updated_at || b.created_at) - toEpoch(a.updated_at || a.created_at))
    .slice(0, MAX_BOARD_SNAPSHOT_ROWS)
    .map(fromBoardSnapshot)
  const keeperRows = [...keepers.value]
    .sort((a, b) => toEpoch(keeperSnapshotTimestamp(b) ?? 0) - toEpoch(keeperSnapshotTimestamp(a) ?? 0))
    .slice(0, MAX_KEEPER_SNAPSHOT_ROWS)
    .map(fromKeeperSnapshot)
    .filter((row): row is ActivityRowModel => row !== null)

  return [...msgRows, ...journalRows, ...taskRows, ...boardRows, ...keeperRows]
    .sort((a, b) => toEpoch(b.timestamp) - toEpoch(a.timestamp))
})

const activityCounts = computed(() => {
  const rows = sortedRows.value
  return {
    total: rows.length,
    messages: rows.filter(row => row.kind === 'messages').length,
    board: rows.filter(row => row.kind === 'board').length,
    tasks: rows.filter(row => row.kind === 'tasks').length,
    keepers: rows.filter(row => row.kind === 'keepers').length,
    system: rows.filter(row => row.kind === 'system').length,
  }
})

const filteredRows = computed(() => {
  const filter = activityFilter.value
  const rows = filter === 'all'
    ? sortedRows.value
    : sortedRows.value.filter(row => row.kind === filter)
  return rows.slice(0, MAX_VISIBLE_ROWS)
})

const agentMotionRows = computed(() =>
  agents.value
    .map(agent => ({
      agent,
      motion: buildAgentMotion(agent.name, tasks.value, messages.value, journal.value, {
        boardPosts: boardPosts.value,
        keepers: keepers.value,
      }),
    }))
    .sort((a, b) => {
      const countDiff = b.motion.activeAssignedCount - a.motion.activeAssignedCount
      if (countDiff !== 0) return countDiff
      return toEpoch(b.motion.lastActivityAt ?? 0) - toEpoch(a.motion.lastActivityAt ?? 0)
    })
)

function formatClock(timestamp: string): string {
  const date = new Date(timestamp)
  return Number.isNaN(date.getTime())
    ? '00:00:00'
    : date.toLocaleTimeString('en-US', { hour12: false })
}

function ActivityStat({
  label,
  value,
  color,
}: {
  label: string
  value: string | number
  color?: string
}) {
  return html`
    <div class="stat-card">
      <div class="stat-label">${label}</div>
      <div class="stat-value" style=${color ? `color:${color}` : ''}>${value}</div>
    </div>
  `
}

function TerminalRow({ row }: { row: ActivityRowModel }) {
  return html`
    <div class="term-row activity-row ${row.kind}">
      <span class="term-time">${formatClock(row.timestamp)}</span>
      <span class="activity-kind-badge ${row.kind}">${KIND_BADGE_LABELS[row.kind]}</span>
      <span class="term-actor">${row.actor}</span>
      <span class="term-text">${row.content}</span>
    </div>
  `
}

export function Activity() {
  const counts = activityCounts.value
  const rows = filteredRows.value
  const latest = rows[0]
  const motionRows = agentMotionRows.value

  return html`
    <div class="stats-grid">
      <${ActivityStat} label="Visible rows" value=${rows.length} />
      <${ActivityStat} label="Tracked messages" value=${counts.messages} color="#47b8ff" />
      <${ActivityStat} label="Keeper signals" value=${counts.keepers} color="#4ade80" />
      <${ActivityStat} label="Board signals" value=${counts.board} color="#fbbf24" />
      <${ActivityStat} label="SSE events" value=${eventCount.value} color="#c084fc" />
    </div>

    <${Card} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${(['all', 'messages', 'board', 'tasks', 'keepers', 'system'] as ActivityFilter[]).map(filter => html`
            <button
              class="goal-filter-btn ${activityFilter.value === filter ? 'active' : ''}"
              onClick=${() => { activityFilter.value = filter }}
            >
              ${FILTER_LABELS[filter]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${connected.value ? '' : 'pill-stale'}">
            ${connected.value ? 'Live SSE' : 'Reconnecting'}
          </span>
          <span>${latest ? html`Latest: <${TimeAgo} timestamp=${latest.timestamp} />` : 'Latest: —'}</span>
          <span>Showing up to ${MAX_VISIBLE_ROWS} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${rows.length === 0
          ? html`<div class="empty-state">Waiting for live or snapshot signals...</div>`
          : rows.map(row => html`<${TerminalRow} key=${row.id} row=${row} />`)}
      </div>
    <//>

    <${Card} title="Agent Motion" class="section">
      <div class="activity-motion-list">
        ${motionRows.length === 0
          ? html`<div class="empty-state">No active agents</div>`
          : motionRows.map(({ agent, motion }) => html`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${agent.name}</div>
                  <div class="activity-motion-meta">
                    ${motion.activeAssignedCount > 0 ? `${motion.activeAssignedCount} claimed tasks` : 'No claimed tasks'}
                    ${motion.lastActivityAt ? html` · <${TimeAgo} timestamp=${motion.lastActivityAt} />` : null}
                  </div>
                </div>
                <div class="activity-motion-text">${motion.lastActivityText ?? 'No recent message/event signal'}</div>
              </div>
            `)}
      </div>
    <//>
  `
}
