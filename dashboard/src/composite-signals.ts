// Composite lifecycle SSE envelope signal (RFC-0003 §6 / PR#7060).
//
// The SSE stream emits [keeper_composite_changed] with a name + wall-clock
// envelope whenever a registry mutation may have changed the composite
// snapshot. Subscribers observe [compositeTick] and re-fetch the full
// payload from [/api/v1/keepers/:name/composite] — keeping the registry
// as the single writer.

import { signal } from '@preact/signals'

interface CompositeTickEnvelope {
  name: string
  ts_unix: number
}

export const compositeTick = signal<CompositeTickEnvelope>({
  name: '',
  ts_unix: 0,
})
