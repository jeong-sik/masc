// Composite lifecycle SSE envelope signal (RFC-0003 §6 / PR#7060).
//
// The SSE stream emits [keeper_composite_changed] with a name + wall-clock
// envelope whenever a registry mutation may have changed the composite
// snapshot. Subscribers observe [compositeTick] and re-fetch the full
// payload from [/api/v1/keepers/:name/composite] — keeping the registry
// as the single writer.

import { signal } from '@preact/signals'

import type { FleetCompositeSnapshot } from './api/schemas/keeper-composite'

interface CompositeTickEnvelope {
  name: string
  ts_unix: number
}

export const compositeTick = signal<CompositeTickEnvelope>({
  name: '',
  ts_unix: 0,
})

export const fleetCompositeSnapshot = signal<FleetCompositeSnapshot | null>(null)

export function hydrateFleetCompositeSnapshot(payload: unknown): void {
  void import('./api/schemas/keeper-composite')
    .then(({ parseFleetCompositeSnapshot }) => {
      fleetCompositeSnapshot.value = parseFleetCompositeSnapshot(payload)
    })
    .catch(err => {
      console.debug('[Composite] fleet snapshot hydration failed', err instanceof Error ? err.message : '')
    })
}
