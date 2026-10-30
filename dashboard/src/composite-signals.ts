// Composite lifecycle SSE envelope signal (RFC-0003 §6 / PR#7060).
//
// The SSE stream emits [keeper_composite_changed] with a name + wall-clock
// envelope whenever a registry mutation may have changed the composite
// snapshot. This event is *signal-only freshness transport*; the payload is
// intentionally not the authoritative read model. Subscribers observe
// [compositeTick] and re-fetch the full payload from
// [/api/v1/keepers/:name/composite] — keeping the registry as the single
// writer. See docs/SYSTEM-EVENT-AND-SNAPSHOT-INVENTORY.md §Read Model Rules.

import { signal } from '@preact/signals'

import type { FleetCompositeSnapshot, KeeperCompositeSnapshot } from './api/schemas/keeper-composite'

interface CompositeTickEnvelope {
  name: string
  ts_unix: number
}

export const compositeTick = signal<CompositeTickEnvelope>({
  name: '',
  ts_unix: 0,
})

export const fleetCompositeSnapshot = signal<FleetCompositeSnapshot | null>(null)

export function buildCompositeByKeeperKey(
  snapshot: FleetCompositeSnapshot | null,
): ReadonlyMap<string, KeeperCompositeSnapshot> {
  const map = new Map<string, KeeperCompositeSnapshot>()
  if (!snapshot) return map
  for (const snap of snapshot.snapshots) {
    const identityKeys = [snap.keeper, snap.correlation_id]
    for (const candidate of identityKeys) {
      if (typeof candidate === 'string' && candidate !== '' && !map.has(candidate)) {
        map.set(candidate, snap)
      }
    }
  }
  return map
}

export function hydrateFleetCompositeSnapshot(payload: unknown): void {
  void import('./api/schemas/keeper-composite')
    .then(({ parseFleetCompositeSnapshot }) => {
      fleetCompositeSnapshot.value = parseFleetCompositeSnapshot(payload)
    })
    .catch(err => {
      // Mirrors sse-store.ts §256 rationale: hydration failures leave the UI
      // showing stale composite data — operator-actionable, so warn (visible
      // in default DevTools level) rather than debug (hidden).
      console.warn('[Composite] fleet snapshot hydration failed', err instanceof Error ? err.message : '')
    })
}
