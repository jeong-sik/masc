// Journal tab — SSE event log

import { html } from 'htm/preact'
import { journal } from '../sse'
import { journalActor, journalDisplayText, journalEventLabel } from '../journal-entry'
import type { JournalEntry, JournalEventType } from '../types'

type EntryVisual = {
  label: string
  color: string
}

function classifyEntry(entry: JournalEntry): EntryVisual {
  const label = journalEventLabel(entry)
  const colors: Partial<Record<JournalEventType | 'event', string>> = {
    agent_joined: '#4ade80',
    agent_left: '#ef4444',
    broadcast: '#94a3b8',
    task_update: '#fbbf24',
    board_post: '#fbbf24',
    board_comment: '#f59e0b',
    keeper_heartbeat: '#22d3ee',
    keeper_handoff: '#a78bfa',
    keeper_compaction: '#a78bfa',
    keeper_guardrail: '#fb7185',
    event: '#94a3b8',
  }
  return { label, color: colors[label] ?? colors.event ?? '#94a3b8' }
}

function EventRow({ entry }: { entry: JournalEntry }) {
  const visual = classifyEntry(entry)

  const detail = journalDisplayText(entry)
  const ts = new Date(entry.timestamp)
  const timeLabel = Number.isNaN(ts.getTime())
    ? '00:00:00'
    : ts.toLocaleTimeString('en-US', { hour12: false })

  return html`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${visual.color}" title=${timeLabel}>${visual.label}</span>
      <span class="journal-agent">${journalActor(entry)}</span>
      <span class="journal-data">${detail}</span>
    </div>
  `
}

export function Journal() {
  const events = journal.value

  return html`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${events.length === 0
          ? html`<div class="empty-state">No events recorded yet</div>`
          : events.map((entry, i) => html`<${EventRow} key=${i} entry=${entry} />`)}
      </div>
    </div>
  `
}
