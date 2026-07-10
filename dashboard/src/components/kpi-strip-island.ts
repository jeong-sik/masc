// KpiStrip renderer — a data-driven Preact strip of KpiCell tiles.
//
// Previously this mounted a Solid subtree as an island for fine-grained KPI
// reactivity. As of #66 the dashboard is unified on Preact: the Solid island
// and its mirror components (kpi-strip.solid, kpi-cell.solid, bar.solid, and
// createKpiStripIsland) were removed along with the solid-js toolchain. This
// now renders the Preact KpiStrip / KpiCell directly — the same output the
// island's test-environment fallback already used, so the five call sites
// (governance, harness-health, feature-health, surface-readiness, connector-
// status) need no change.
//
// Trade-off recorded at removal: Solid diffed only the cells whose props
// changed; Preact re-renders the whole strip on each parent render. A KPI
// strip is a handful of cells, so the full re-render cost is negligible, and
// dropping the second framework removes the dual-transform build complexity.

import type { VNode } from 'preact'
import { KpiStrip } from './kpi-strip'
import { KpiCell } from './kpi-cell'
import type { KpiCellProps, KpiStripVariant } from './kpi-shared'

export interface KpiStripIslandData {
  ariaLabel: string
  variant?: KpiStripVariant
  cols?: number
  cells: ReadonlyArray<KpiCellProps>
}

export function KpiStripIsland(props: KpiStripIslandData): VNode {
  return KpiStrip({
    ariaLabel: props.ariaLabel,
    variant: props.variant,
    cols: props.cols,
    children: props.cells.map(cell => KpiCell(cell)),
  })
}
