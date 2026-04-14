// Observatory cursor state (RFC-MASC-006 Phase 2b)
// Shared hover cursor across all tracks. Tracks emit mousemove → updates
// cursorPosition. Tracks render vertical line + tooltip at cursor's time.

import { signal, type Signal } from '@preact/signals'

export interface CursorPosition {
  /** Cursor's time in ms since epoch. */
  ts: number
  /** Normalized x position within track (0.0 - 1.0). */
  pct: number
}

export const cursorPosition: Signal<CursorPosition | null> = signal(null)

export function setCursorFromEvent(
  event: MouseEvent,
  trackEl: HTMLElement,
  windowStart: number,
  windowEnd: number,
): void {
  const rect = trackEl.getBoundingClientRect()
  const x = event.clientX - rect.left
  const pct = Math.max(0, Math.min(1, x / rect.width))
  const ts = windowStart + (windowEnd - windowStart) * pct
  cursorPosition.value = { ts, pct }
}

export function clearCursor(): void {
  cursorPosition.value = null
}
