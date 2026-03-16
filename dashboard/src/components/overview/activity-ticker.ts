// MASC Dashboard — Activity Ticker (recent events scrolling display)
// Consumes JournalEntry signal from the SSE store.

import { html } from 'htm/preact'
import type { ReadonlySignal } from '@preact/signals'
import type { JournalEntry } from '../../types'

interface ActivityTickerProps {
  entries: ReadonlySignal<JournalEntry[]>
  maxItems?: number
}

function formatTime(tsMs: number): string {
  try {
    const date = new Date(tsMs)
    return date.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', second: '2-digit' })
  } catch {
    return ''
  }
}

function kindIcon(kind?: string): string {
  switch (kind) {
    case 'board': return '\uD83D\uDCDD'
    case 'tasks': return '\u2705'
    case 'keepers': return '\uD83D\uDC51'
    case 'system': return '\u2699\uFE0F'
    default: return '\u25CF'
  }
}

export function ActivityTicker({ entries, maxItems }: ActivityTickerProps) {
  const limit = maxItems ?? 5
  const items = entries.value.slice(-limit).reverse()

  if (items.length === 0) {
    return html`
      <div class="activity-ticker">
        <div class="activity-ticker__item" style="color: var(--text-muted); justify-content: center;">
          이벤트 대기 중...
        </div>
      </div>
    `
  }

  return html`
    <div class="activity-ticker">
      ${items.map((entry, i) => html`
        <div class="activity-ticker__item" key=${i}>
          <span class="activity-ticker__time">${formatTime(entry.timestamp)}</span>
          <span style="flex-shrink: 0">${kindIcon(entry.kind)}</span>
          ${entry.agent ? html`<span class="activity-ticker__actor">${entry.agent}</span>` : null}
          <span>${entry.preview ?? entry.text}</span>
        </div>
      `)}
    </div>
  `
}
