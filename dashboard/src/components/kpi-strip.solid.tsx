/** @jsxImportSource solid-js */
//
// Solid mirror of `kpi-strip.ts` (Preact). Same DOM contract: a
// `role="list"` grid container with hairline gap and bottom border.
//
// Difference from Preact: Preact uses `cloneElement` + `toChildArray`
// to inject `bare={true}` into KpiCell children. Solid has no
// cloneElement equivalent — children are JSX expressions, not VNode
// trees we can map. We replace that pattern with **context**:
// KpiStrip provides KpiStripContext; KpiCell.solid reads it and
// defaults `bare` to true when the cell is inside a strip. Caller
// can still set `bare={false}` to opt out (test parity below).
//
// `resolveStripCols` is exported for direct testing (pure helper).

import { createContext, useContext, type JSX } from 'solid-js'

export type KpiStripVariant = 'standard' | 'compact' | 'stacked'

export interface KpiStripProps {
  variant?: KpiStripVariant
  cols?: number
  ariaLabel: string
  children: JSX.Element
  id?: string
  class?: string
}

const COLS_BY_VARIANT: Record<KpiStripVariant, number> = {
  standard: 6,
  compact: 6,
  stacked: 3,
}

export function resolveStripCols(
  variant: KpiStripVariant | undefined,
  override: number | undefined,
): number {
  if (typeof override === 'number' && override > 0) return override
  return COLS_BY_VARIANT[variant ?? 'standard']
}

interface KpiStripContextValue {
  readonly inStrip: true
}

const KpiStripContext = createContext<KpiStripContextValue>()

export function useKpiStripContext(): KpiStripContextValue | undefined {
  return useContext(KpiStripContext)
}

export function KpiStrip(props: KpiStripProps): JSX.Element {
  const variant = (): KpiStripVariant => props.variant ?? 'standard'
  const cols = (): number => resolveStripCols(variant(), props.cols)

  return (
    <KpiStripContext.Provider value={{ inStrip: true }}>
      <div
        role="list"
        id={props.id}
        aria-label={props.ariaLabel}
        data-variant={variant()}
        data-cols={cols()}
        class={props.class}
        style={{
          display: 'grid',
          'grid-template-columns': `repeat(${cols()}, minmax(0, 1fr))`,
          gap: '1px',
          background: 'var(--color-border-default)',
          'border-bottom': '1px solid var(--color-border-strong)',
        }}
      >
        {props.children}
      </div>
    </KpiStripContext.Provider>
  )
}
