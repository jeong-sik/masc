// LivePulseDot — tiny pulsing dot that answers "is polling still live?".
//
// Reference UIs (Datadog host-list "live" column, Grafana dashboard
// refresh indicator, GitHub Status page): a pulsing green dot beside
// the section header says "data under this header is being refreshed
// right now". When the dot stops pulsing (stale) or goes idle (never
// sampled), the operator immediately sees that the view is frozen —
// a frozen heartbeat strip looks identical to a legitimately stable
// one, so this indicator is the only surface that tells them apart.
//
// Pure classifier — a test pins the threshold math so a future change
// to HEARTBEAT_SAMPLE_MS doesn't silently break the stale banding.

import { html } from 'htm/preact'

type LivePulseState = 'live' | 'stale' | 'idle'

interface LivePulseView {
  state: LivePulseState
  /** Human-readable status tucked into title/aria so hover + AT both
      explain what the dot means without a separate tooltip chip. */
  label: string
}

/** Pure: classify the pulse state from the last-tick timestamp.
    - `idle`: sampler has never fired (null). Grey dot, no pulse.
    - `live`: last tick within 2× the sample interval — the operator's
      view is fresh. Green dot, breathing pulse.
    - `stale`: last tick older than 2× interval — sampler is frozen or
      tab was backgrounded. Amber dot, no pulse.
    2× threshold mirrors Datadog's "missed one expected heartbeat →
    still healthy; missed two → something's wrong" convention, robust
    to one-off scheduling jitter. */
export function classifyLivePulse(
  lastTickMs: number | null,
  nowMs: number,
  sampleIntervalMs: number,
): LivePulseView {
  if (lastTickMs === null) {
    return { state: 'idle', label: '실시간 폴링 · 샘플 대기 중' }
  }
  const ageMs = nowMs - lastTickMs
  if (ageMs > sampleIntervalMs * 2) {
    const ageSec = Math.max(1, Math.floor(ageMs / 1000))
    return { state: 'stale', label: `Live polling · 샘플 멈춤 (${ageSec}s ago)` }
  }
  return { state: 'live', label: '실시간 폴링 · 샘플링 정상' }
}

const DOT_BASE = 'inline-block h-2 w-2 rounded-full'

const DOT_TONE: Record<LivePulseState, string> = {
  live: 'bg-[var(--ok-10)] animate-pulse shadow-[0_0_6px_rgba(52,211,153,0.6)]',
  stale: 'bg-[var(--warn-10)]',
  idle: 'bg-[var(--white-10)]',
}

interface LivePulseDotProps {
  lastTickMs: number | null
  nowMs: number
  sampleIntervalMs: number
  class?: string
  testId?: string
}

export function LivePulseDot({
  lastTickMs,
  nowMs,
  sampleIntervalMs,
  class: cx,
  testId,
}: LivePulseDotProps) {
  const view = classifyLivePulse(lastTickMs, nowMs, sampleIntervalMs)
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
