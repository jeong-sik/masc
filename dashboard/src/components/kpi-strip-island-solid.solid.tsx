/** @jsxImportSource solid-js */
//
// Solid renderer factory for the KpiStrip island. Pairs with
// `kpi-strip-island.ts` (Preact wrapper) — the Preact side mounts a
// host `<div>`, calls `createKpiStripIsland(initial)` to get a JSX
// closure + state setter, then hands the closure to `solid-js/web`
// `render` and feeds prop changes into the setter on every Preact
// re-render.
//
// Why split into two files: a single .tsx with both Preact hooks and
// Solid JSX would force one transformer (Preact or Solid) to claim
// the file and silently mis-compile the other side. Physical file
// boundary = transform boundary; the Solid plugin's include regex
// captures `*.solid.tsx`, the rest stays on Preact.

import { For, createSignal, type JSX, type Setter } from 'solid-js'
import { KpiStrip, type KpiStripVariant } from './kpi-strip.solid'
import { KpiCell, type KpiCellProps } from './kpi-cell.solid'

export interface KpiStripIslandData {
  ariaLabel: string
  variant?: KpiStripVariant
  cols?: number
  cells: ReadonlyArray<KpiCellProps>
}

export interface KpiStripIslandHandle {
  /** JSX closure to hand to `solid-js/web` `render`. */
  jsx: () => JSX.Element
  /** Replace the entire state object — Solid diffs internally and only
   *  re-renders the cells whose props changed. */
  setState: Setter<KpiStripIslandData>
}

export function createKpiStripIsland(initial: KpiStripIslandData): KpiStripIslandHandle {
  const [state, setState] = createSignal<KpiStripIslandData>(initial)
  const jsx = (): JSX.Element => (
    <KpiStrip
      ariaLabel={state().ariaLabel}
      variant={state().variant}
      cols={state().cols}
    >
      <For each={state().cells}>{(cell) => <KpiCell {...cell} />}</For>
    </KpiStrip>
  )
  return { jsx, setState }
}
