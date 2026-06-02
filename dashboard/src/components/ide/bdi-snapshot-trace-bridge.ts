import { pushTrace } from './keeper-trace-store'
import {
  normalizeTraceProducerContext,
  type KeeperTraceProducerContextInput,
} from './keeper-trace-context'

/**
 * RFC-0028 PR-δ producer: bdi-snapshot → keeper-trace bridge.
 *
 * Pure mapper — given a snapshot of KeeperBdiSnapshot values
 * (from `/api/v1/keepers/${keeper}/bdi-snapshot`, polled by
 * `InspectorKeeperBDI`) and a set of dedup keys that have already been
 * emitted, push trace events for the new ones and return the updated
 * set.
 *
 * Dedup-key shape: `bdi:${keeper}:${generated_at}`.
 *
 *   - The polling endpoint replays the same `generated_at` until the
 *     server publishes a fresh BDI tick. The dedup key naturally
 *     collapses these duplicates and only emits a trace event when
 *     `generated_at` advances.
 *   - The key never appears outside this module. The only consumer is
 *     `alreadyEmitted: ReadonlySet<string>` owned by the calling
 *     component — same lifecycle pattern as PR-δ-1 / PR-δ-2 / PR-δ-3.
 *
 * Mapping (KeeperBdiSnapshot → KeeperTraceEvent[bdi-snapshot]):
 *   id         ← `bdi:${keeper}:${generated_at}`
 *   tsMs       ← Date.parse(generated_at)  (NaN-guarded)
 *   keeperName ← snapshot.keeper
 *   source     ← 'bdi-snapshot'
 *   intention  ← snapshot.intention  (string | null; the BDI inspector
 *                renders "—" for null today, and consumers of the trace
 *                store can do the same.)
 *
 * Why a pure function (not a stateful subscription):
 *   - The owning component (`InspectorKeeperBDI`) already holds
 *     `snapshot` as a useState value. A pure mapper called from a
 *     `useEffect([snapshot])` is sufficient and trivially testable.
 *   - Avoids storing per-component state inside the trace store, which
 *     would couple the store to producer lifecycle.
 *   - Module-level mutable state would leak across components and break
 *     the deduplication guarantee on remount.
 *
 * Skip rules for missing fields:
 *   - generated_at === null OR malformed ISO → skip (no usable tsMs).
 *   - keeper === '' → skip (the trace store's keeperName field is used
 *     as a routing bucket; an empty string would coalesce unrelated
 *     rows).
 *
 * The bridge accepts an array even though `InspectorKeeperBDI` only
 * holds a single snapshot at a time — this keeps the call shape
 * consistent with the other PR-δ producers and makes it trivial to
 * batch from a multi-keeper polling source later.
 */

export interface BdiSnapshotProducerInput {
  readonly keeper: string
  readonly generated_at: string | null
  readonly intention: string | null
  readonly context?: KeeperTraceProducerContextInput | null
}

function dedupKey(snapshot: BdiSnapshotProducerInput): string {
  return `bdi:${snapshot.keeper}:${snapshot.generated_at ?? ''}`
}

/**
 * Push trace events for every snapshot not already in `alreadyEmitted`
 * and return the updated set. The caller (typically a component effect)
 * owns the set and re-passes it on each call.
 */
export function bridgeBdiSnapshotsToTrace(
  snapshots: ReadonlyArray<BdiSnapshotProducerInput>,
  alreadyEmitted: ReadonlySet<string>,
): ReadonlySet<string> {
  if (snapshots.length === 0) return alreadyEmitted
  const next = new Set(alreadyEmitted)
  for (const snapshot of snapshots) {
    if (snapshot.keeper === '') continue
    if (snapshot.generated_at === null) continue
    const key = dedupKey(snapshot)
    if (next.has(key)) continue
    const tsMs = Date.parse(snapshot.generated_at)
    if (!Number.isFinite(tsMs)) continue
    pushTrace({
      id: key,
      tsMs,
      keeperName: snapshot.keeper,
      source: 'bdi-snapshot',
      intention: snapshot.intention,
      ...normalizeTraceProducerContext(snapshot.context),
    })
    next.add(key)
  }
  return next
}
