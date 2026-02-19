// Relative time display — "2m ago", "3h ago", etc.

import { html } from 'htm/preact'

interface TimeAgoProps {
  timestamp: string | number
}

function formatTimeAgo(ts: string | number): string {
  const now = Date.now()
  const then = typeof ts === 'number' ? ts : new Date(ts).getTime()
  const diffSec = Math.floor((now - then) / 1000)

  if (diffSec < 60) return `${diffSec}s ago`
  const diffMin = Math.floor(diffSec / 60)
  if (diffMin < 60) return `${diffMin}m ago`
  const diffHr = Math.floor(diffMin / 60)
  if (diffHr < 24) return `${diffHr}h ago`
  const diffDay = Math.floor(diffHr / 24)
  return `${diffDay}d ago`
}

export function TimeAgo({ timestamp }: TimeAgoProps) {
  const text = formatTimeAgo(timestamp)
  return html`<span class="time-ago" title=${typeof timestamp === 'string' ? timestamp : new Date(timestamp).toISOString()}>${text}</span>`
}

export { formatTimeAgo }
