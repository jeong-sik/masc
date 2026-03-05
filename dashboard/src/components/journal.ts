// Journal tab — SSE event log

import { html } from 'htm/preact'
import { journal } from '../sse'
import type { JournalEntry } from '../types'

type EntryVisual = {
  label: string
  color: string
}

function classifyEntry(entry: JournalEntry): EntryVisual {
  const text = entry.text
  if (text === 'Joined') return { label: 'agent_joined', color: '#4ade80' }
  if (text === 'Left') return { label: 'agent_left', color: '#ef4444' }
  if (text.startsWith('Task:')) return { label: 'task_update', color: '#fbbf24' }
  if (text.startsWith('Heartbeat')) return { label: 'keeper_heartbeat', color: '#22d3ee' }
  if (text.startsWith('Handoff')) return { label: 'keeper_handoff', color: '#a78bfa' }
  if (text.startsWith('Compaction')) return { label: 'keeper_compaction', color: '#a78bfa' }
  if (text.startsWith('Guardrail')) return { label: 'keeper_guardrail', color: '#fb7185' }
  return { label: 'event', color: '#94a3b8' }
}

function EventRow({ entry }: { entry: JournalEntry }) {
  const typeColors: Record<string, string> = {
    event: '#94a3b8',
  }
  const visual = classifyEntry(entry)
  const color = typeColors[visual.label] ?? visual.color

  const detail = entry.text
  const ts = new Date(entry.timestamp)
  const timeLabel = Number.isNaN(ts.getTime())
    ? '00:00:00'
    : ts.toLocaleTimeString('en-US', { hour12: false })

  return html`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${color}" title=${timeLabel}>${visual.label}</span>
      <span class="journal-agent">${entry.agent || 'system'}</span>
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
