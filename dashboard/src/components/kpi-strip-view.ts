// Data-driven Preact renderer for a KpiStrip of KpiCell tiles.

import { h } from 'preact'
import { KpiStrip } from './kpi-strip'
import { KpiCell } from './kpi-cell'
import type { KpiCellProps, KpiStripVariant } from './kpi-shared'

export interface KpiStripViewData {
  ariaLabel: string
  variant?: KpiStripVariant
  cols?: number
  cells: ReadonlyArray<KpiCellProps>
}

export function KpiStripView(props: KpiStripViewData) {
  return h(KpiStrip, {
    ariaLabel: props.ariaLabel,
    variant: props.variant,
    cols: props.cols,
    children: props.cells.map(cell => h(KpiCell, cell)),
  })
}
