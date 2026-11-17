// LivePulseDot — tiny pulsing dot that answers "is the live stream connected?".
//
// The dashboard learns about changes over one SSE observer stream
// (dashboard-observer.ts). While that stream is admitted the data under the
// header follows the server; when it drops, the view stays on its last read
// until the stream is admitted again. A silent stream is closed by its idle
// deadline, so "admitted" alone says whether the view is following.

import { html } from 'htm/preact'
import { dashboardObserverReady } from '../../dashboard-observer-state'

type LivePulseState = 'live' | 'idle'

interface LivePulseView {
  state: LivePulseState
  /** Human-readable status tucked into title/aria so hover + AT both
      explain what the dot means without a separate tooltip chip. */
  label: string
}

/** Pure: `live` while the observer stream is admitted, `idle` otherwise. */
export function classifyLivePulse(ready: boolean): LivePulseView {
  return ready
    ? { state: 'live', label: '실시간 연결 · 서버 변경을 받는 중' }
    : { state: 'idle', label: '실시간 연결 끊김 · 다시 연결하는 중' }
}

const DOT_BASE = 'inline-block h-2 w-2 rounded-full'

const DOT_TONE: Record<LivePulseState, string> = {
  live: 'bg-[var(--ok-10)] animate-pulse shadow-[0_0_6px_rgb(var(--ok-glow)/0.6)]',
  idle: 'bg-[var(--warn-10)]',
}

interface LivePulseDotProps {
  class?: string
  testId?: string
}

export function LivePulseDot({ class: cx, testId }: LivePulseDotProps) {
  const view = classifyLivePulse(dashboardObserverReady.value)
  const tone = DOT_TONE[view.state]
  return html`<span
    class=${`${DOT_BASE} ${tone} ${cx ?? ''}`}
    role="img"
    aria-label=${view.label}
    title=${view.label}
    data-live-pulse-dot
    data-live-pulse-state=${view.state}
    data-testid=${testId}
  ></span>`
}
