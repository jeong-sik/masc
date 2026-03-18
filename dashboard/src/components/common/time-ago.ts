// Relative time display — "2분 전", "3시간 전" 등.

import { html } from 'htm/preact'
import { formatTimeAgo } from '../../lib/format-time'

interface TimeAgoProps {
  timestamp: string | number
}

export function TimeAgo({ timestamp }: TimeAgoProps) {
  const text = formatTimeAgo(timestamp)
  const title =
    typeof timestamp === 'string'
      ? timestamp
      : new Date(timestamp < 1_000_000_000_000 ? timestamp * 1000 : timestamp).toISOString()
  return html`<span class="time-ago" title=${title}>${text}</span>`
}

export { formatTimeAgo }
