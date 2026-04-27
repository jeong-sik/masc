// KPI strip — composite container for a row of KpiCell tiles.
//
// Ports the design-system v0.4 cb-group-a `.cb-kpi` strip pattern
// (preview/components.css lines 91-112). The strip owns the surface,
// the cells are flat columns inside it:
//
//   .cb-kpi {
//     display:grid; grid-template-columns: repeat(6, 1fr);
//     gap:1px;                                  /* hairline divider */
//     background: var(--color-border-default);  /* gap shows as 1px line */
//     border-bottom:1px solid var(--color-border-strong);
//   }
//   .cb-kpi.stacked { grid-template-columns: 1fr 1fr 1fr; }
//   .cb-kpi.compact .cell { min-height:36px; padding: 5px 8px; }
//
// SPEC variant cardinality:
//   standard  — 6 cols, default density
//   compact   — 6 cols, denser cells (callers tighten spacing themselves)
//   stacked   — 3 cols, larger cells
//
// The variant decides the grid layout. KpiCell's own variant decides
// the cell typography / spacing — they're independent axes named the
// same. KpiStrip default-applies `bare` to its KpiCell children
// because the strip itself draws the surface (background / hairline /
// border-bottom); cells must not paint a second border.
//
// Callers can override the column count with `cols` when the data
// length doesn't fit the SPEC default (e.g. 5-cell funnel, 4-cell
// infra grid). Doing so is a deliberate dashboard-side variation,
// not a SPEC variant.

import { html } from 'htm/preact'
import { cloneElement, toChildArray, type VNode, type ComponentChildren } from 'preact'

export type KpiStripVariant = 'standard' | 'compact' | 'stacked'

export interface KpiStripProps {
  /** Strip layout variant. Drives the column count + density. */
  variant?: KpiStripVariant
  /** Override the column count when the data length doesn't match the
   *  SPEC default for this variant. Use sparingly — most callers
   *  should align their data to one of the SPEC cardinalities. */
  cols?: number
  /** Required for screen readers. The strip is `role="list"`, so the
   *  label must announce the contents (e.g. "Fleet KPI strip"). */
  ariaLabel: string
  /** KpiCell children. The strip injects `bare` so cells render flat
   *  inside the strip's grid; pre-existing `bare` on a child is
   *  preserved (no override). */
  children: ComponentChildren
  /** Optional id reference forwarded to the strip container. */
  id?: string
  /** Extra Tailwind utility classes appended to the container. Kept
   *  narrow so callers cannot reset the strip's surface tokens. */
  class?: string
}

const COLS_BY_VARIANT: Record<KpiStripVariant, number> = {
  standard: 6,
  compact: 6,
  stacked: 3,
}

/** Resolve the grid column count for a strip. Pure: exposed for tests
 *  + for callers that compose their own grid wrapper but want SPEC
 *  alignment with the strip cardinality table. */
export function resolveStripCols(
  variant: KpiStripVariant | undefined,
  override: number | undefined,
): number {
  if (typeof override === 'number' && override > 0) return override
  return COLS_BY_VARIANT[variant ?? 'standard']
}

/** Inject `bare` into a single KpiCell vnode. Preserves any prop the
 *  caller already supplied — including a deliberate `bare={false}`. */
function withBareDefault(child: VNode<Record<string, unknown>>): VNode {
  const props = (child.props ?? {}) as Record<string, unknown>
  if ('bare' in props) return child
  return cloneElement(child, { bare: true })
}

export function KpiStrip(props: KpiStripProps): VNode {
  const variant = props.variant ?? 'standard'
  const cols = resolveStripCols(variant, props.cols)
  const children = toChildArray(props.children)
    .map((child) =>
      child !== null && typeof child === 'object'
        ? withBareDefault(child as VNode<Record<string, unknown>>)
        : child,
    )

  const containerStyle = {
    display: 'grid',
    gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))`,
    gap: '1px',
    background: 'var(--color-border-default)',
    borderBottom: '1px solid var(--color-border-strong)',
  }

  return html`
    <div
      role="list"
      id=${props.id}
      aria-label=${props.ariaLabel}
      data-variant=${variant}
      data-cols=${cols}
      class=${props.class}
      style=${containerStyle}
    >
      ${children}
    </div>
  `
}
