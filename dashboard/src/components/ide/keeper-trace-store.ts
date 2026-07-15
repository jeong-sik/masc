import { signal } from '@preact/signals'

/**
 * RFC-0028 PR-α: keeper-trace store.
 *
 * Stitched read-side projection over existing IDE/runtime surfaces:
 *  - anchored-thread (RFC-0021)
 *  - runtime-hop     (RFC-0023)
 *  - decision-log    (RFC-0026)
 *  - activity-event  (/api/v1/activity/events normalized context)
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
  | 'runtime-hop'
  | 'decision-log'
  | 'activity-event'

interface KeeperTraceBase {
  readonly id: string
  readonly tsMs: number
  readonly keeperName: string
  readonly count: number
  readonly source: KeeperTraceSource
}

export interface KeeperTraceContextFields {
  readonly filePath?: string
  readonly line?: number
  readonly taskId?: string
  readonly boardPostId?: string
  readonly commentId?: string
  readonly prId?: string
  readonly gitRef?: string
  readonly logId?: string
  readonly sessionId?: string
  readonly operationId?: string
  readonly workerRunId?: string
}

export type KeeperTraceEvent =
  | (KeeperTraceBase & {
      readonly source: 'anchored-thread'
      readonly threadId: string
      readonly filePath?: string | null
      readonly line: number | null
    })
  | (KeeperTraceBase & KeeperTraceContextFields & {
      readonly source: 'runtime-hop'
      readonly hopId: string
      readonly provider: string
    })
  | (KeeperTraceBase & KeeperTraceContextFields & {
      readonly source: 'decision-log'
      readonly decisionId: string
      readonly semanticOutcome: string | null
      readonly decisionChoice?: string | null
      readonly decisionReason?: string | null
    })
  | (KeeperTraceBase & {
      readonly source: 'activity-event'
      readonly eventId: string
      readonly filePath: string
      readonly line: number
      readonly surface: string
      readonly taskId?: string
      readonly boardPostId?: string
      readonly commentId?: string
      readonly prId?: string
      readonly gitRef?: string
      readonly logId?: string
      readonly sessionId?: string
      readonly operationId?: string
      readonly workerRunId?: string
    })

export type KeeperTraceEventInput =
  | Omit<Extract<KeeperTraceEvent, { source: 'anchored-thread' }>, 'count'>
  | Omit<Extract<KeeperTraceEvent, { source: 'runtime-hop' }>, 'count'>
  | Omit<Extract<KeeperTraceEvent, { source: 'decision-log' }>, 'count'>
  | Omit<Extract<KeeperTraceEvent, { source: 'activity-event' }>, 'count'>

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
 *   if the existing entry with the largest tsMs has the same trace bucket
 *   (source + keeperName, and for line-anchored sources also filePath + line)
 *   AND `(input.tsMs - existing.tsMs) <= COALESCE_WINDOW_MS`,
 *   then replace it in-array with `{ ...existing, count: existing.count + 1, tsMs: input.tsMs }`.
 *   Otherwise insert at the binary-search position and prune retention.
 *
 * Out-of-order tsMs (a producer with stale clock) is supported — the entry
 * is inserted at the correct ascending position. Coalescing only matches the
 * latest entry by tsMs of the same trace bucket.
 */
export function pushTrace(input: KeeperTraceEventInput): void {
  const prev = keeperTraceState.value.events
  const incoming: KeeperTraceEvent = { ...input, count: 1 } as KeeperTraceEvent

  // Find latest entry of the same trace bucket — needed for coalescing.
  // Walk backwards because retention prune keeps the array bounded.
  let coalesceIdx = -1
  for (let i = prev.length - 1; i >= 0; i -= 1) {
    const candidate = prev[i]!
    if (sameTraceBucket(candidate, incoming)) {
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

export function filterTraceEventsByReplay<T extends { readonly tsMs: number }>(
  events: ReadonlyArray<T>,
  untilMs: number | null,
): ReadonlyArray<T> {
  if (untilMs === null || !Number.isFinite(untilMs)) return events
  return events.filter(event => Number.isFinite(event.tsMs) && event.tsMs <= untilMs)
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

function sameTraceBucket(left: KeeperTraceEvent, right: KeeperTraceEvent): boolean {
  if (left.source !== right.source || left.keeperName !== right.keeperName) return false
  if (left.source === 'anchored-thread' && right.source === 'anchored-thread') {
    return (left.filePath ?? null) === (right.filePath ?? null)
      && left.line === right.line
  }
  if (left.source === 'activity-event' && right.source === 'activity-event') {
    return left.filePath === right.filePath && left.line === right.line
  }
  if (hasTraceContext(left) || hasTraceContext(right)) {
    return traceContextKey(left) === traceContextKey(right)
  }
  return true
}

function hasTraceContext(event: KeeperTraceEvent): boolean {
  return event.source === 'runtime-hop'
    || event.source === 'decision-log'
    ? traceContextKey(event) !== ''
    : false
}

function traceContextKey(event: KeeperTraceEvent): string {
  if (
    event.source !== 'runtime-hop'
    && event.source !== 'decision-log'
  ) return ''

  return [
    event.filePath ?? '',
    event.line ?? '',
    event.taskId ?? '',
    event.boardPostId ?? '',
    event.commentId ?? '',
    event.prId ?? '',
    event.gitRef ?? '',
    event.logId ?? '',
    event.sessionId ?? '',
    event.operationId ?? '',
    event.workerRunId ?? '',
  ].join('\u001f')
}
