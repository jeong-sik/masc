import { pushTrace } from './keeper-trace-store'

/**
 * RFC-0028 PR-δ producer: decision-log → keeper-trace bridge.
 *
 * Pure mapper — given a snapshot of KeeperDecision values
 * (from `/api/v1/keeper/decisions`) and a set of dedup keys that have
 * already been emitted, push trace events for the new ones and return
 * the updated set.
 *
 * Dedup-key shape: `decision:${keeper_name}:${ts_unix}:${event_type}`.
 *
 *   - KeeperDecision has no native id field; the (keeper_name, ts_unix,
 *     event_type) tuple is unique under the assumption that a single
 *     keeper does not emit two events of the same type at the same
 *     millisecond.
 *   - The key never appears outside this module. The only consumer is
 *     `alreadyEmitted: ReadonlySet<string>` owned by the calling
 *     component — same lifecycle pattern as PR-δ-1 (#13375 anchored-
 *     thread) and PR-δ-2 (cascade-hop).
 *
 * Mapping (KeeperDecision → KeeperTraceEvent[decision-log]):
 *   id              ← `decision:${keeper_name}:${ts_unix}:${event_type}`
 *   tsMs            ← unixishToMs(decision.ts_unix)  (NaN-guarded; null/
 *                     non-finite skip)
 *   keeperName      ← decision.keeper_name  (real keeper-level — unlike
 *                     cascade-hop which uses cascade_name as a logical
 *                     bucket)
 *   source          ← 'decision-log'
 *   decisionId      ← same as id (RFC-0026 KeeperDecision has no
 *                     separate decision uuid — the synth tuple key
 *                     suffices for chip identity)
 *   semanticOutcome ← decision.outcome  (string | null; consumers can
 *                     surface "ok"/"error_retryable"/"error_fatal"/etc.
 *                     verbatim, or null for in-flight)
 *
 * Why a pure function (not a stateful subscription):
 *   - The owning component (`IdeConversationRailMock`) already has the
 *     fetched `decisions` array as a useState value. A pure mapper
 *     called from a `useEffect([decisions])` is sufficient and trivially
 *     testable.
 *   - Avoids storing per-component state inside the trace store, which
 *     would couple the store to producer lifecycle.
 *   - Module-level mutable state would leak across components and break
 *     the deduplication guarantee on remount.
 *
 * Skip rule for missing fields:
 *   - ts_unix === null OR non-finite → skip (no usable tsMs, would
 *     break binary-search insertion).
 *   - keeper_name === '' → skip (the trace store's keeperName field is
 *     used as a routing bucket; an empty string would coalesce
 *     unrelated rows).
 */

export interface DecisionLogProducerInput {
  readonly ts_unix: number | null
  readonly keeper_name: string
  readonly event_type: string
  readonly outcome: string | null
}

function unixishToMs(ts: number | null): number {
  if (ts === null || !Number.isFinite(ts)) return Number.NaN
  return ts > 1_000_000_000_000 ? ts : ts * 1000
}

function dedupKey(decision: DecisionLogProducerInput): string {
  return `decision:${decision.keeper_name}:${decision.ts_unix}:${decision.event_type}`
}

/**
 * Push trace events for every decision not already in `alreadyEmitted`
 * and return the updated set. The caller (typically a component effect)
 * owns the set and re-passes it on each call.
 */
export function bridgeDecisionsToTrace(
  decisions: ReadonlyArray<DecisionLogProducerInput>,
  alreadyEmitted: ReadonlySet<string>,
): ReadonlySet<string> {
  if (decisions.length === 0) return alreadyEmitted
  const next = new Set(alreadyEmitted)
  for (const decision of decisions) {
    if (decision.keeper_name === '') continue
    const key = dedupKey(decision)
    if (next.has(key)) continue
    const tsMs = unixishToMs(decision.ts_unix)
    if (!Number.isFinite(tsMs)) continue
    pushTrace({
      id: key,
      tsMs,
      keeperName: decision.keeper_name,
      source: 'decision-log',
      decisionId: key,
      semanticOutcome: decision.outcome,
    })
    next.add(key)
  }
  return next
}
