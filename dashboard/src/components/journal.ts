// Journal tab — SSE event log

import { html } from 'htm/preact'
import { journal } from '../sse'
import type { SSEEvent } from '../types'

function EventRow({ event }: { event: SSEEvent }) {
  const typeColors: Record<string, string> = {
    agent_joined: '#4ade80',
    agent_left: '#ef4444',
    broadcast: '#22d3ee',
    task_update: '#fbbf24',
    board_post: '#a78bfa',
    board_comment: '#a78bfa',
    heartbeat: '#666',
  }
  const color = typeColors[event.type] ?? '#888'

  // Extract displayable text from event fields
  const detail = event.message ?? event.content ?? event.status ?? ''

  return html`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${color}">${event.type}</span>
      <span class="journal-agent">${event.agent ?? event.from ?? event.from_agent ?? ''}</span>
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
          : events.map((e, i) => html`<${EventRow} key=${i} event=${e} />`)}
      </div>
    </div>
  `
}
