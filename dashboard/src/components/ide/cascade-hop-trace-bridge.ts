import { pushTrace } from './keeper-trace-store'

/**
 * RFC-0028 PR-δ producer: cascade-hop → keeper-trace bridge.
 *
 * Pure mapper — given a snapshot of CascadeStrategyTraceEvent values
 * (from `/api/v1/cascade/strategy_trace`) and a set of dedup keys that
 * have already been emitted, push trace events for the new ones and
 * return the updated set.
 *
 * Dedup-key shape: `cascade:${cascade_name}:${cycle}:${ts}`.
 *
 *   - `cascade_name + cycle` would be sufficient under monotonic cycle
 *     assumption, but `ts` is included to survive a server-side cycle
 *     reset (e.g., process restart) without false-coalesce.
 *   - The key never appears outside this module. The only consumer is
 *     `alreadyEmitted: ReadonlySet<string>` owned by the calling
 *     component — same lifecycle pattern as the anchored-thread bridge
 *     (PR-δ-1, #13375).
 *
 * Mapping (CascadeStrategyTraceEvent → KeeperTraceEvent[cascade-hop]):
 *   id         ← `cascade:${cascade_name}:${cycle}:${ts}` (synthesized)
 *   tsMs       ← unixishToMs(event.ts)  (NaN-guarded; second or ms input)
 *   keeperName ← event.cascade_name  (cascade is cascade-level, not
 *                keeper-level — the trace store's `keeperName` field is
 *                used as a logical bucket and consumers route cascade
 *                rows to RFC §5 cascade-name lane.)
 *   source     ← 'cascade-hop'
 *   hopId      ← `${cascade_name}-${cycle}` (single strategy decision
 *                identity for replay grouping)
 *   provider   ← event.strategy  (the cascade strategy that produced
 *                the hop; RFC-0023 uses "strategy" as the routing
 *                discriminator and this surfaces it on the chip.)
 *
 * Why a pure function (not a stateful subscription):
 *   - The owning component (`IdeConversationRailMock`) already has the
 *     fetched `cascadeEvents` array as a useState value. A pure mapper
 *     called from a `useEffect([cascadeEvents])` is sufficient and
 *     trivially testable.
 *   - Avoids storing per-component state inside the trace store, which
 *     would couple the store to producer lifecycle.
 *   - Module-level mutable state would leak across components and break
 *     the deduplication guarantee on remount.
 *
 * NaN-guard rationale: a malformed `ts` (or a null) would propagate
 * `NaN` into the store and break binary-search insertion. We silently
 * skip such events — they cannot participate in replay either.
 */

export interface CascadeHopProducerInput {
  readonly ts: number
  readonly cascade_name: string
  readonly strategy: string
  readonly cycle: number
}

function unixishToMs(ts: number): number {
  if (!Number.isFinite(ts)) return Number.NaN
  return ts > 1_000_000_000_000 ? ts : ts * 1000
}

function dedupKey(event: CascadeHopProducerInput): string {
  return `cascade:${event.cascade_name}:${event.cycle}:${event.ts}`
}

/**
 * Push trace events for every cascade event not already in
 * `alreadyEmitted` and return the updated set. The caller (typically a
 * component effect) owns the set and re-passes it on each call.
 */
export function bridgeCascadeEventsToTrace(
  events: ReadonlyArray<CascadeHopProducerInput>,
  alreadyEmitted: ReadonlySet<string>,
): ReadonlySet<string> {
  if (events.length === 0) return alreadyEmitted
  const next = new Set(alreadyEmitted)
  for (const event of events) {
    const key = dedupKey(event)
    if (next.has(key)) continue
    const tsMs = unixishToMs(event.ts)
    if (!Number.isFinite(tsMs)) continue
    pushTrace({
      id: key,
      tsMs,
      keeperName: event.cascade_name,
      source: 'cascade-hop',
      hopId: `${event.cascade_name}-${event.cycle}`,
      provider: event.strategy,
    })
    next.add(key)
  }
  return next
}
