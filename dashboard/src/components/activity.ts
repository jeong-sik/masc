// Activity tab — Hacker Terminal Style Live Feed

import { html } from 'htm/preact'
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

function TerminalRow({ row }: { row: ActivityRowModel }) {
  // Simple time formatter HH:MM:SS
  const d = new Date(row.timestamp)
  const timeStr = isNaN(d.getTime()) ? '00:00:00' : d.toLocaleTimeString('en-US', { hour12: false })

  return html`
    <div class="term-row">
      <span class="term-time">${timeStr}</span>
      <span class="term-actor">${row.actor}</span>
      <span class="term-source ${row.source}">${row.source === 'message' ? 'msg' : 'evt'}</span>
      <span class="term-text">${row.content}</span>
    </div>
  `
}

export function Activity() {
  const msgRows = messages.value.map(fromMessage)
  const journalRows = journal.value.map(fromJournal)
  const rows = [...msgRows, ...journalRows]
    .sort((a, b) => toEpoch(b.timestamp) - toEpoch(a.timestamp))
    .slice(0, 100)

  return html`
    <div class="section">
      <h2 style="color: var(--accent); text-shadow: 0 0 10px rgba(0,240,255,0.5); margin-bottom: 16px; font-family: monospace;">> LIVE_ACTIVITY_STREAM</h2>
      <div class="terminal-feed">
        ${rows.length === 0
          ? html`<div class="empty-state" style="font-family: monospace; color: var(--ok);">> Waiting for signal...</div>`
          : rows.map(row => html`<${TerminalRow} key=${row.id} row=${row} />`)}
      </div>
    </div>
  `
}
