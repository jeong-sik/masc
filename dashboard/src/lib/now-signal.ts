// Shared 5 s wall-clock signal.
//
// Components that display elapsed durations (`fmtDuration(now - x)`)
// previously each held a useState `now` and a setInterval, which means
// every consumer paid for its own per-second/per-5-second re-render
// scope.  Hoisting to a shared signal lets multiple consumers subscribe
// to the same tick — and, more importantly, isolates the re-render
// scope to the leaf component that actually reads the signal value
// (Preact's signal model rerenders only the component that performed
// the `.value` read at render time).
//
// The interval is module-level and refcounted: it starts on the first
// `useNowSecondsTicker()` mount and stops when the last consumer
// unmounts.  No background work runs when no component on the page
// needs the tick.

import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'

const TICK_MS = 5_000

export const nowSecondsSignal = signal(Date.now() / 1000)

let intervalId: number | null = null
let consumerCount = 0

function startTicker(): void {
  if (intervalId != null) return
  if (typeof window === 'undefined') return
  intervalId = window.setInterval(() => {
    nowSecondsSignal.value = Date.now() / 1000
  }, TICK_MS)
}

function stopTicker(): void {
  if (intervalId == null) return
  if (typeof window === 'undefined') return
  window.clearInterval(intervalId)
  intervalId = null
}

/**
 * Reference-counted hook: while at least one component using this hook
 * is mounted, a single shared interval updates `nowSecondsSignal` every
 * 5 s.  When the last consumer unmounts the interval stops.
 *
 * Pause-aware callers should still gate via their own visibility logic
 * (the ticker keeps running regardless of `document.visibilityState`).
 */
export function useNowSecondsTicker(): void {
  useEffect(() => {
    consumerCount += 1
    startTicker()
    return () => {
      consumerCount = Math.max(0, consumerCount - 1)
      if (consumerCount === 0) stopTicker()
    }
  }, [])
}
