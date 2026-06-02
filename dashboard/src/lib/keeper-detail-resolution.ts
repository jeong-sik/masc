// Pure resolution helper for the keeper-detail page. Extracted so unit
// tests can exercise the logic without pulling in the React component
// import graph (which transitively reaches lucide-preact mocks).
//
// Issue #12283 background: see [resolveKeeperForDetail].

import type { Keeper } from '../types'

/**
 * Resolve which Keeper object to render in the detail panel.
 *
 * Pre-fix behavior trusted [selectedKeeper.value] (the cached pin)
 * whenever the live registry lookup returned null. That worked across
 * registry refresh transitions, but it also kept the panel rendering
 * a *dead* keeper after the live registry had already dropped it (e.g.
 * stale-watchdog kill — KeeperHeartbeat.tla idle_turn class, fixed
 * runtime-side by #12271). Downstream panels then ran field accesses
 * against a stale shape, eventually producing
 * "Failed to execute 'insertBefore' on 'Node': parameter 1 is not of
 * type 'Node'".
 *
 * Resolution rule:
 * - Live registry hit wins.
 * - The cached fallback is only honored when the live registry is empty
 *   (likely a refresh transition); when the registry has keepers but
 *   our target is absent, the absence is treated as real and the caller
 *   should render the missing-state.
 *
 * Pure for testability — takes the live count rather than reading
 * [keepers.value] internally so unit tests don't need a signal harness.
 */
export function resolveKeeperForDetail(
  keeperName: string,
  liveMatch: Keeper | null,
  fallback: Keeper | null,
  liveRegistryCount: number,
): Keeper | null {
  if (liveMatch) return liveMatch
  if (fallback == null) return null
  const fallbackMatchesName =
    fallback.name === keeperName || fallback.agent_name === keeperName
  if (!fallbackMatchesName) return null
  // Trust the cached fallback only during registry-empty transitions.
  return liveRegistryCount === 0 ? fallback : null
}
