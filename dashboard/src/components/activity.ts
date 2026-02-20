// Activity tab — Recent messages and events

import { html } from 'htm/preact'
import { TimeAgo } from './common/time-ago'
import { messages } from '../store'
import { journal } from '../sse'
import type { Message, JournalEntry } from '../types'

type ActivityRowModel = {
  id: string
  source: 'message' | 'event'
  actor: string
  content: string
  timestamp: string
}

function fromMessage(msg: Message, idx: number): ActivityRowModel {
  return {
    id: msg.id ?? `msg-${msg.seq ?? idx}`,
    source: 'message',
    actor: msg.from ?? 'system',
    content: msg.content,
    timestamp: msg.timestamp,
  }
}

function fromJournal(entry: JournalEntry, idx: number): ActivityRowModel {
  return {
    id: `evt-${entry.timestamp}-${idx}`,
    source: 'event',
    actor: entry.agent || 'system',
    content: entry.text,
    timestamp: new Date(entry.timestamp).toISOString(),
  }
}

function toEpoch(ts: string): number {
  const parsed = Date.parse(ts)
  return Number.isNaN(parsed) ? 0 : parsed
}

function MessageRow({ row }: { row: ActivityRowModel }) {
  return html`
    <div class="message-row">
      <span class="message-agent">${row.actor}</span>
      <span class="message-source ${row.source}">${row.source}</span>
      <span class="message-text">${row.content}</span>
      <span class="message-time"><${TimeAgo} timestamp=${row.timestamp} /></span>
    </div>
  `
}

export function Activity() {
  const msgRows = messages.value.map(fromMessage)
  const journalRows = journal.value.map(fromJournal)
  const rows = [...msgRows, ...journalRows]
    .sort((a, b) => toEpoch(b.timestamp) - toEpoch(a.timestamp))
    .slice(0, 80)

  return html`
    <div class="section">
      <h2>Recent Activity</h2>
      <div class="message-list">
        ${rows.length === 0
          ? html`<div class="empty-state">No recent activity</div>`
          : rows.map(row =>
              html`<${MessageRow} key=${row.id} row=${row} />`
            )}
      </div>
    </div>
  `
}
