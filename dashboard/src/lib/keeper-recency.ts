// Single source of truth for "how recently was this keeper active".
//
// Both the keepers-page default selection (keeper-detail-page.ts) and the
// roster's '최근순' sort (keeper-workspace-roster.ts) resolve recency through
// these helpers, so the visible top-of-list and the auto-selected keeper can
// never diverge again. Prior behavior selected `keepers.value[0]` — the raw,
// unsorted store order — which made an alphabetically-first keeper (e.g.
// "albini") stick as the default regardless of activity.
//
// Pure by design: `nowMs` is injected rather than read from `Date.now()` so
// unit tests are deterministic. The low-level `keeperRecencyMs` /
// `compareByRecency` / `sortByRecency` take an explicit `nowMs` (callers read
// the clock once per comparison pass); only the top-level
// `mostRecentlyActiveKeeper` convenience defaults `nowMs` to `Date.now()`.

import type { Keeper } from '../types'

/** Sentinel for "no usable recency signal on this keeper" — sorts last. */
const NO_RECENCY = Number.NEGATIVE_INFINITY

/**
 * Best-available activity timestamp as epoch milliseconds; larger = more recent.
 *
 * Resolution order (first usable wins):
 *  1. absolute ISO timestamps — comparable across keepers directly:
 *     `last_activity_at` → `updated_at` → `last_heartbeat` → `created_at`
 *  2. relative "seconds ago" fields converted against `nowMs`:
 *     `last_activity_ago_s` → `last_turn_ago_s`
 *
 * Absolute wins over relative because a snapshot's relative fields are only
 * self-consistent within that snapshot; anchoring them to `nowMs` keeps them on
 * the same epoch-ms scale as the ISO fields for a single comparison pass.
 */
export function keeperRecencyMs(keeper: Keeper, nowMs: number): number {
  // Try each absolute field in priority order, using the first that PARSES —
  // a malformed value (e.g. a non-ISO string) falls through to the next field
  // rather than poisoning recency to "unknown".
  const isoCandidates = [
    keeper.last_activity_at,
    keeper.updated_at,
    keeper.last_heartbeat,
    keeper.created_at,
  ]
  for (const iso of isoCandidates) {
    if (!iso) continue
    const parsed = Date.parse(iso)
    if (Number.isFinite(parsed)) return parsed
  }
  const agoS = keeper.last_activity_ago_s ?? keeper.last_turn_ago_s
  if (typeof agoS === 'number' && Number.isFinite(agoS)) {
    return nowMs - agoS * 1000
  }
  return NO_RECENCY
}

/**
 * Comparator for most-recent-first ordering. Ties (including two keepers with
 * no recency signal) break by name so the order is stable across renders.
 */
export function compareByRecency(a: Keeper, b: Keeper, nowMs: number): number {
  return keeperRecencyMs(b, nowMs) - keeperRecencyMs(a, nowMs) || a.name.localeCompare(b.name)
}

/**
 * Most-recent-first sorted copy. Decorate-sort-undecorate: each keeper's
 * recency is computed ONCE (not on every comparator call), so a large roster
 * costs O(n) timestamp parses instead of O(n log n). Ties break by name.
 */
export function sortByRecency(keepers: readonly Keeper[], nowMs: number): Keeper[] {
  return keepers
    .map(keeper => ({ keeper, recency: keeperRecencyMs(keeper, nowMs) }))
    .sort((a, b) => b.recency - a.recency || a.keeper.name.localeCompare(b.keeper.name))
    .map(entry => entry.keeper)
}

/**
 * The most recently active keeper, or `null` for an empty list. Used as the
 * keepers-page default selection when there is no URL target and no
 * previously-pinned keeper. Deterministic: with `nowMs` fixed, the same input
 * always yields the same pick (name-tiebreak via `compareByRecency`).
 */
export function mostRecentlyActiveKeeper(
  keepers: readonly Keeper[],
  nowMs: number = Date.now(),
): Keeper | null {
  let best: Keeper | null = null
  for (const keeper of keepers) {
    if (best === null || compareByRecency(keeper, best, nowMs) < 0) best = keeper
  }
  return best
}
