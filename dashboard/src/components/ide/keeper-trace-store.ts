import { signal } from '@preact/signals'

/**
 * RFC-0028 PR-α: keeper-trace store.
 *
 * Stitched read-side projection over 4 existing layer surfaces:
 *  - anchored-thread (RFC-0021)
 *  - cascade-hop     (RFC-0023)
 *  - bdi-snapshot    (RFC-0024)
 *  - decision-log    (RFC-0026)
 *
 * The store is *append-only* from the producer's perspective. It enforces
 * three invariants on every `pushTrace` call:
 *
 *   (1) tsMs ascending order (binary insertion).
 *   (2) Coalescing of bursts within `COALESCE_WINDOW_MS` for the same
 *       (source, keeperName) tuple — increments `count` instead of adding a
 *       second entry.
 *   (3) Retention pruning of entries older than `RETENTION_MS` relative to
 *       the most recent event.
 *
 * Cap-on-render (RFC-0028 §5: "stacked gutter chip cap 3 + `+N`") is the
 * concern of `overlay-keeper-trace.tsx` (PR-β); the store is unbounded but
 * pruned by retention so memory stays O(events-in-last-10min).
 *
 * No new server endpoint: PR-β will wire the 4 producers (each existing
 * endpoint's polling client) into `pushTrace` so the store joins them
 * client-side.
 */

export const COALESCE_WINDOW_MS = 50
export const RETENTION_MS = 10 * 60 * 1000 // 10 minutes

export type KeeperTraceSource =
  | 'anchored-thread'
  | 'cascade-hop'
  | 'bdi-snapshot'
  | 'decision-log'

interface KeeperTraceBase {
  readonly id: string
  readonly tsMs: number
  readonly keeperName: string
  readonly count: number
  readonly source: KeeperTraceSource
}

export type KeeperTraceEvent =
  | (KeeperTraceBase & {
      readonly source: 'anchored-thread'
      readonly threadId: string
      readonly line: number | null
    })
  | (KeeperTraceBase & {
      readonly source: 'cascade-hop'
      readonly hopId: string
      readonly provider: string
    })
  | (KeeperTraceBase & {
      readonly source: 'bdi-snapshot'
      readonly intention: string | null
    })
  | (KeeperTraceBase & {
      readonly source: 'decision-log'
      readonly decisionId: string
      readonly semanticOutcome: string | null
    })

export type KeeperTraceEventInput =
  | Omit<Extract<KeeperTraceEvent, { source: 'anchored-thread' }>, 'count'>
  | Omit<Extract<KeeperTraceEvent, { source: 'cascade-hop' }>, 'count'>
  | Omit<Extract<KeeperTraceEvent, { source: 'bdi-snapshot' }>, 'count'>
  | Omit<Extract<KeeperTraceEvent, { source: 'decision-log' }>, 'count'>

export interface KeeperTraceState {
  readonly events: ReadonlyArray<KeeperTraceEvent>
}

const INITIAL_STATE: KeeperTraceState = { events: [] }

export const keeperTraceState = signal<KeeperTraceState>(INITIAL_STATE)

/**
 * Ingest a new trace event. The input omits `count` because the store either
 * coalesces with the latest matching entry (incrementing its count) or starts
 * a fresh entry with `count: 1`.
 *
 * Coalescing rule (RFC-0028 §4):
 *   if the existing entry with the largest tsMs has the same `source` AND the
 *   same `keeperName` AND `(input.tsMs - existing.tsMs) <= COALESCE_WINDOW_MS`,
 *   then replace it in-array with `{ ...existing, count: existing.count + 1, tsMs: input.tsMs }`.
 *   Otherwise insert at the binary-search position and prune retention.
 *
 * Out-of-order tsMs (a producer with stale clock) is supported — the entry
 * is inserted at the correct ascending position. Coalescing only matches the
 * latest entry by tsMs of the same (source, keeperName) tuple.
 */
export function pushTrace(input: KeeperTraceEventInput): void {
  const prev = keeperTraceState.value.events
  const incoming: KeeperTraceEvent = { ...input, count: 1 } as KeeperTraceEvent

  // Find latest entry of same (source, keeperName) — needed for coalescing.
  // Walk backwards because retention prune keeps the array bounded.
  let coalesceIdx = -1
  for (let i = prev.length - 1; i >= 0; i -= 1) {
    const candidate = prev[i]!
    if (candidate.source === incoming.source && candidate.keeperName === incoming.keeperName) {
      coalesceIdx = i
      break
    }
  }

  let nextEvents: ReadonlyArray<KeeperTraceEvent>
  if (coalesceIdx >= 0) {
    const existing = prev[coalesceIdx]!
    const dt = incoming.tsMs - existing.tsMs
    if (dt >= 0 && dt <= COALESCE_WINDOW_MS) {
      // Coalesce: bump count and refresh tsMs to the more recent timestamp.
      const merged = { ...existing, count: existing.count + 1, tsMs: incoming.tsMs }
      nextEvents = replaceAt(prev, coalesceIdx, merged)
    } else {
      nextEvents = insertSorted(prev, incoming)
    }
  } else {
    nextEvents = insertSorted(prev, incoming)
  }

  // Retention prune relative to the latest event's tsMs (NOT Date.now() —
  // tests need deterministic eviction independent of wall clock).
  const latestTs = nextEvents[nextEvents.length - 1]?.tsMs ?? incoming.tsMs
  const cutoff = latestTs - RETENTION_MS
  const pruned = nextEvents.filter(e => e.tsMs >= cutoff)

  keeperTraceState.value = { events: pruned }
}

export function clearTraces(): void {
  if (keeperTraceState.value.events.length === 0) return
  keeperTraceState.value = INITIAL_STATE
}

export function tracesByKeeper(keeperName: string): ReadonlyArray<KeeperTraceEvent> {
  const trimmed = keeperName.trim()
  if (!trimmed) return []
  return keeperTraceState.value.events.filter(e => e.keeperName === trimmed)
}

export function tracesBySource(source: KeeperTraceSource): ReadonlyArray<KeeperTraceEvent> {
  return keeperTraceState.value.events.filter(e => e.source === source)
}

function replaceAt(
  arr: ReadonlyArray<KeeperTraceEvent>,
  idx: number,
  value: KeeperTraceEvent,
): ReadonlyArray<KeeperTraceEvent> {
  const next = arr.slice()
  next[idx] = value
  // Coalesce may have shifted tsMs forward; ensure the array stays sorted by
  // walking the entry to its correct position (only forward, since tsMs only
  // increases on coalesce).
  let i = idx
  while (i + 1 < next.length && next[i + 1]!.tsMs < next[i]!.tsMs) {
    const tmp = next[i]!
    next[i] = next[i + 1]!
    next[i + 1] = tmp
    i += 1
  }
  return next
}

function insertSorted(
  arr: ReadonlyArray<KeeperTraceEvent>,
  incoming: KeeperTraceEvent,
): ReadonlyArray<KeeperTraceEvent> {
  if (arr.length === 0) return [incoming]
  // Binary search for insertion position (first index where arr[i].tsMs > incoming.tsMs).
  let lo = 0
  let hi = arr.length
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (arr[mid]!.tsMs <= incoming.tsMs) {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  const next = arr.slice()
  next.splice(lo, 0, incoming)
  return next
}
