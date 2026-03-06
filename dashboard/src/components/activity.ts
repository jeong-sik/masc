// Activity tab — unified live feed and system journal

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { buildAgentMotion } from './common/agent-motion'
import { agents, tasks, messages } from '../store'
import { connected, eventCount, journal } from '../sse'
import type { Message, JournalEntry } from '../types'

type ActivityFilter = 'all' | 'messages' | 'board' | 'tasks' | 'keepers' | 'system'
const MAX_VISIBLE_ROWS = 120

type ActivityRowModel = {
  id: string
  source: 'message' | 'event'
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

function toEpoch(ts: string | number): number {
  const parsed = typeof ts === 'number' ? ts : Date.parse(ts)
  return Number.isNaN(parsed) ? 0 : parsed
}

const sortedRows = computed(() => {
  const msgRows = messages.value.map(fromMessage)
  const journalRows = journal.value.map(fromJournal)
  return [...msgRows, ...journalRows]
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
      motion: buildAgentMotion(agent.name, tasks.value, messages.value, journal.value),
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
      <${ActivityStat} label="Tracked keeper events" value=${counts.keepers} color="#4ade80" />
      <${ActivityStat} label="Tracked board events" value=${counts.board} color="#fbbf24" />
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
          <span>Journal merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${rows.length === 0
          ? html`<div class="empty-state">Waiting for events...</div>`
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
