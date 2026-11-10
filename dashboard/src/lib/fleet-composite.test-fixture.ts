import { signal } from '@preact/signals'
import type { FleetCompositeSnapshot } from '../api/keeper'

/** Controlled query data for existing presentation-only component tests. */
export const fleetCompositeFixture = signal<FleetCompositeSnapshot | null>(null)
