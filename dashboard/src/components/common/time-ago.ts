// Relative time display — "2분 전", "3시간 전" 등.

import { html } from 'htm/preact'

interface TimeAgoProps {
  timestamp: string | number
}

function formatTimeAgo(ts: string | number): string {
  const now = Date.now()
  const then =
    typeof ts === 'number'
      ? (ts < 1_000_000_000_000 ? ts * 1000 : ts)
      : new Date(ts).getTime()
  const diffSec = Math.floor((now - then) / 1000)

  if (diffSec < 60) return `${diffSec}초 전`
  const diffMin = Math.floor(diffSec / 60)
  if (diffMin < 60) return `${diffMin}분 전`
  const diffHr = Math.floor(diffMin / 60)
  if (diffHr < 24) return `${diffHr}시간 전`
  const diffDay = Math.floor(diffHr / 24)
  return `${diffDay}일 전`
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
