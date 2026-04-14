// Observatory drill-down selection store (RFC-MASC-006 Phase 2d)
//
// Separate from cursor-store on purpose:
//   - cursor = ephemeral (hover, clears on mouseleave) → "overview"
//   - selection = persistent (click, clears on explicit close/next click) → "deep dive"
//
// Tracks dispatch entity selections here; DetailPane reads this signal and
// renders raw entry plus metadata for the selected point.

import { signal, type Signal } from '@preact/signals'
import type { TelemetryEntry } from '../../api/dashboard'

export type DetailSelection =
  | { kind: 'event'; entry: TelemetryEntry; ts: number }
  | { kind: 'tool_call'; entry: TelemetryEntry; ts: number }

export const detailSelection: Signal<DetailSelection | null> = signal(null)

export function selectEntity(selection: DetailSelection): void {
  detailSelection.value = selection
}

export function clearSelection(): void {
  detailSelection.value = null
}
