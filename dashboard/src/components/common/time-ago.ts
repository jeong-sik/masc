// Relative time display — "2분 전", "3시간 전" 등.

import { signal } from '@preact/signals'
import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { formatTimeAgo } from '../../lib/format-time'

interface TimeAgoProps {
  timestamp: string | number
}

const CLOCK_TICK_MS = 30_000
const relativeClock = signal(Date.now())
let relativeClockTimer: number | null = null
let relativeClockSubscribers = 0

function startRelativeClock(): void {
  if (relativeClockTimer != null || typeof window === 'undefined') return
  relativeClockTimer = window.setInterval(() => {
    relativeClock.value = Date.now()
  }, CLOCK_TICK_MS)
}

function stopRelativeClock(): void {
  if (relativeClockTimer == null || typeof window === 'undefined') return
  window.clearInterval(relativeClockTimer)
  relativeClockTimer = null
}

export function TimeAgo({ timestamp }: TimeAgoProps) {
  useEffect(() => {
    relativeClockSubscribers += 1
    startRelativeClock()
    return () => {
      relativeClockSubscribers = Math.max(0, relativeClockSubscribers - 1)
      if (relativeClockSubscribers === 0) stopRelativeClock()
    }
  }, [])

  void relativeClock.value
  const text = formatTimeAgo(timestamp)
  const title =
    typeof timestamp === 'string'
      ? timestamp
      : new Date(timestamp < 1_000_000_000_000 ? timestamp * 1000 : timestamp).toISOString()
  return html`<span class="time-ago" title=${title}>${text}</span>`
}

export { formatTimeAgo }
