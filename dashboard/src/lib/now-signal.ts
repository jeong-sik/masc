// Shared 5 s wall-clock signal.
//
// Components that display elapsed durations (`fmtDuration(now - x)`)
// previously each held a useState `now` and a setInterval, which means
// every consumer paid for its own per-5-second re-render scope.
// Hoisting to a shared signal lets multiple consumers subscribe to the
// same tick — and, more importantly, isolates the re-render scope to
// the leaf component that actually reads the signal value (Preact's
// signal model rerenders only the component that performed the `.value`
// read at render time).
//
// The interval is module-level and refcounted via `createSharedTicker`:
// it starts on the first `useNowSecondsTicker()` mount and stops when
// the last consumer unmounts.  No background work runs when no component
// on the page needs the tick.

import { createSharedTicker } from './shared-ticker'

const TICK_MS = 5_000
const ticker = createSharedTicker(TICK_MS, () => Date.now() / 1000)

export const nowSecondsSignal = ticker.signal

/**
 * Reference-counted hook: while at least one component using this hook
 * is mounted, a single shared interval updates `nowSecondsSignal` every
 * 5 s.  When the last consumer unmounts the interval stops.
 *
 * Pause-aware callers should still gate via their own visibility logic
 * (the ticker keeps running regardless of `document.visibilityState`).
 */
export const useNowSecondsTicker = ticker.use
