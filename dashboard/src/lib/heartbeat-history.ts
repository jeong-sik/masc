// Heartbeat history — per-connector ring buffer of up/down/unknown samples.
//
// Reference pattern (Uptime Kuma status page): each monitor gets a row of
// ~45 colored bars representing the last N heartbeats. We don't have a
// backend time-series endpoint yet, so we sample the current connector
// signals in-memory at a fixed cadence. Samples are reset when the page
// reloads — honest about "since page opened". A future backend history
// API can swap the read side of this store without touching the strip.

import { signal } from '@preact/signals'

export type HeartbeatState = 'up' | 'down' | 'unknown'

/** How many samples we retain per connector. Matches Uptime Kuma's
    default bar count so the visual rhythm is familiar. */
export const HEARTBEAT_MAX_SAMPLES = 45

const history = signal<Record<string, HeartbeatState[]>>({})

/** Record one sample for a connector. Ring-buffers at HEARTBEAT_MAX_SAMPLES. */
export function recordHeartbeat(connectorId: string, state: HeartbeatState): void {
  const current = history.value[connectorId] ?? []
  const next = current.length >= HEARTBEAT_MAX_SAMPLES
    ? [...current.slice(current.length - HEARTBEAT_MAX_SAMPLES + 1), state]
    : [...current, state]
  history.value = { ...history.value, [connectorId]: next }
}

/** Read the current history for a connector. Returns [] for unknown ids. */
export function getHeartbeatHistory(connectorId: string): HeartbeatState[] {
  return history.value[connectorId] ?? []
}

/** Subscribe-friendly signal read — call inside a component render to
    re-render when any connector's history changes. */
export function useHeartbeatHistory(connectorId: string): HeartbeatState[] {
  // Touching .value registers a subscription when called inside a
  // component render (preact/signals semantics).
  return history.value[connectorId] ?? []
}

/** Clear all recorded history. For tests + "reset fleet view" flows. */
export function resetHeartbeatHistory(): void {
  history.value = {}
}

/** Current state + how many contiguous trailing samples share it.
    Uptime Kuma / Statuspage convention — "Operational for 22 checks"
    or "Down for 3 checks" answers the operator question "how long
    has it been like this?" directly. */
export interface HeartbeatStreak {
  state: HeartbeatState
  samples: number
}

/** Pure: scan the tail of the history for the current contiguous
    same-state run. Returns null for an empty history so callers can
    render "no data yet" instead of a fake zero streak. */
export function currentHeartbeatStreak(history: HeartbeatState[]): HeartbeatStreak | null {
  if (history.length === 0) return null
  const last = history[history.length - 1]!
  let samples = 1
  for (let i = history.length - 2; i >= 0; i--) {
    if (history[i] === last) samples++
    else break
  }
  return { state: last, samples }
}
