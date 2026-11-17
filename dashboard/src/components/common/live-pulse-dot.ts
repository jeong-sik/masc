// LivePulseDot — tiny pulsing dot that answers "is the live stream connected?".
//
// The dashboard learns about changes over one SSE observer stream
// (dashboard-observer.ts). While that stream is admitted the data under the
// header follows the server; otherwise the view stays on its last read. A
// silent stream is closed by its idle deadline, so the observer's phase alone
// says whether the page is following, and whether it is trying to again.

import { html } from 'htm/preact'
import { dashboardObserverPhase, type DashboardObserverPhase } from '../../dashboard-observer-state'

type LivePulseTone = 'live' | 'waiting' | 'down'

interface LivePulseView {
  tone: LivePulseTone
  /** Human-readable status tucked into title/aria so hover + AT both
      explain what the dot means without a separate tooltip chip. */
  label: string
}

/** Pure: the dot for each observer phase. */
export function classifyLivePulse(phase: DashboardObserverPhase): LivePulseView {
  switch (phase) {
    case 'live':
      return { tone: 'live', label: '실시간 연결 · 서버 변경을 받는 중' }
    case 'connecting':
      return { tone: 'waiting', label: '실시간 연결 · 연결하는 중' }
    case 'retrying':
      return { tone: 'down', label: '실시간 연결 끊김 · 다시 연결하는 중' }
    case 'refused':
      return { tone: 'down', label: '실시간 연결 거부됨 · 인증을 확인해야 다시 연결해요' }
    case 'stopped':
      return { tone: 'waiting', label: '실시간 연결 안 함' }
  }
}

const DOT_BASE = 'inline-block h-2 w-2 rounded-full'

const DOT_TONE: Record<LivePulseTone, string> = {
  live: 'bg-[var(--ok-10)] animate-pulse shadow-[0_0_6px_rgb(var(--ok-glow)/0.6)]',
  waiting: 'bg-[var(--color-bg-hover)]',
  down: 'bg-[var(--warn-10)]',
}

interface LivePulseDotProps {
  class?: string
  testId?: string
}

export function LivePulseDot({ class: cx, testId }: LivePulseDotProps) {
  const phase = dashboardObserverPhase.value
  const view = classifyLivePulse(phase)
  return html`<span
    class=${`${DOT_BASE} ${DOT_TONE[view.tone]} ${cx ?? ''}`}
    role="img"
    aria-label=${view.label}
    title=${view.label}
    data-live-pulse-dot
    data-live-pulse-state=${phase}
    data-testid=${testId}
  ></span>`
}
