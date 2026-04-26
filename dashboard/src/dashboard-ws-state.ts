import { signal } from '@preact/signals'

export const dashboardWsConnected = signal(false)
export const dashboardWsReady = signal(false)
export const dashboardWsLastError = signal<string | null>(null)
export const dashboardWsLastSeq = signal(0)

// Cutover beacon signals.  The transport beacon (operator-facing UI)
// reads these to show whether events are actually flowing through the WS
// channel after a WS-only cutover.  [lastEventAt] is the wall-clock ms
// timestamp of the last applied delta; [eventCount60s] is a running
// counter of deltas applied in the last 60 seconds (decayed lazily by
// the beacon component on each render).
export const dashboardWsLastEventAt = signal(0)
export const dashboardWsEventCount60s = signal(0)

// Ring of (timestamp_ms) entries for events applied in the last 60s.
// Kept in module scope (not a signal) so we don't trigger a re-render on
// every push — the beacon's [eventCount60s] signal is updated only when
// the count actually changes.
const eventTimestamps: number[] = []
const WINDOW_MS = 60_000

export function noteDashboardWsEvent(now: number = Date.now()): void {
  eventTimestamps.push(now)
  // Trim entries older than the window.
  const cutoff = now - WINDOW_MS
  while (eventTimestamps.length > 0 && eventTimestamps[0]! < cutoff) {
    eventTimestamps.shift()
  }
  dashboardWsLastEventAt.value = now
  dashboardWsEventCount60s.value = eventTimestamps.length
}

export function _resetDashboardWsCounterForTests(): void {
  eventTimestamps.length = 0
  dashboardWsLastEventAt.value = 0
  dashboardWsEventCount60s.value = 0
}
