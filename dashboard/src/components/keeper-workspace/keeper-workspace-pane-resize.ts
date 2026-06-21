// Keeper workspace pane resize — drag-to-resize the roster and context-rail
// columns of the 3-pane chat view, with widths persisted to localStorage.
//
// Ported from the v2 design (keepers.jsx startResize + rails.jsx usePersistentW):
// the design lets the operator widen the roster or context rail and remembers it.
// The local 3-pane is a CSS grid whose roster/rail columns are driven by the
// `--kw-roster-w` / `--kw-rail-w` custom properties (keeper-workspace.css), so a
// resize is just a clamped write to those vars + persistence.
//
// Perf: during a drag we set the CSS var DIRECTLY on the grid element every
// pointermove (no signal write → no re-render of the heavy detail subtree, the
// same reason keeper-detail-page isolates the keepers-list subscription). The
// persistent signal is written once on pointerup.

import { persistentSignal } from '../../lib/persistent-signal'

export type PaneKind = 'roster' | 'rail'

// Clamp ranges mirror the v2 design (keepers.jsx startResize: roster 200..440,
// ctx 240..480). Named so a future column-width change has a single source.
const PANE_BOUNDS: Record<PaneKind, { min: number; max: number; cssVar: string }> = {
  roster: { min: 200, max: 440, cssVar: '--kw-roster-w' },
  rail: { min: 240, max: 480, cssVar: '--kw-rail-w' },
}

export const DEFAULT_ROSTER_WIDTH = 286
export const DEFAULT_RAIL_WIDTH = 312

/** Persisted column widths (px). Reads subscribe the component, but values only
 *  change on drag-end so re-renders stay rare. */
function persistedPaneWidth(kind: PaneKind, key: string, defaultValue: number) {
  return persistentSignal<number>({
    key,
    defaultValue,
    deserialize: raw => {
      const parsed: unknown = JSON.parse(raw)
      return typeof parsed === 'number' && Number.isFinite(parsed)
        ? clampPaneWidth(kind, parsed)
        : defaultValue
    },
  })
}

export const rosterWidth = persistedPaneWidth('roster', 'kw.rosterWidth', DEFAULT_ROSTER_WIDTH)
export const railWidth = persistedPaneWidth('rail', 'kw.railWidth', DEFAULT_RAIL_WIDTH)

/** Pure: clamp a candidate width to the pane's bounds (rounded to whole px). */
export function clampPaneWidth(kind: PaneKind, px: unknown): number {
  const { min, max } = PANE_BOUNDS[kind]
  if (typeof px !== 'number' || !Number.isFinite(px)) return min
  return Math.max(min, Math.min(max, Math.round(px)))
}

/** Start a pointer-drag resize of one pane. Sets the CSS var directly on the
 *  grid element during the drag (no re-render), persists on release. The rail
 *  grows when dragging left, so its delta is inverted. */
export function beginPaneResize(kind: PaneKind, event: PointerEvent, gridEl: HTMLElement): void {
  event.preventDefault()
  const { cssVar } = PANE_BOUNDS[kind]
  const sig = kind === 'roster' ? rosterWidth : railWidth
  const startX = event.clientX
  const startW = clampPaneWidth(kind, sig.value)
  const dir = kind === 'roster' ? 1 : -1
  let latest = startW
  document.body.classList.add('kw-resizing')

  const onMove = (ev: PointerEvent) => {
    latest = clampPaneWidth(kind, startW + dir * (ev.clientX - startX))
    gridEl.style.setProperty(cssVar, `${latest}px`)
  }
  const onUp = () => {
    document.body.classList.remove('kw-resizing')
    window.removeEventListener('pointermove', onMove)
    window.removeEventListener('pointerup', onUp)
    // pointercancel fires (instead of pointerup) when the browser steals the
    // gesture — touch interrupt, context menu, tab switch. Tearing down on both
    // paths keeps body.kw-resizing / the move listener from leaking and still
    // persists the last width.
    window.removeEventListener('pointercancel', onUp)
    sig.value = latest
  }
  window.addEventListener('pointermove', onMove)
  window.addEventListener('pointerup', onUp)
  window.addEventListener('pointercancel', onUp)
}
