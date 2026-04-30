// Shared KPI primitives — pure types, constants, and helpers used by both
// the Preact (`kpi-strip.ts` / `kpi-cell.ts`) and Solid
// (`kpi-strip.solid.tsx` / `kpi-cell.solid.tsx`) implementations.
//
// Keeping these in one place removes the duplication that otherwise
// drifts when one side is updated and the other is forgotten.

// ── Strip ──

export type KpiStripVariant = 'standard' | 'compact' | 'stacked'

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

// ── Cell ──

export type KpiCellVariant = 'standard' | 'compact' | 'stacked'

/** Status tone — drives the value color. `undefined` = neutral primary. */
export type KpiCellKind = 'ok' | 'warn' | 'err'

export interface KpiCellDelta {
  /** Display string e.g. "+0.1" or "-2". */
  value: string
  /** Direction governs the delta color. */
  direction: 'pos' | 'neg'
}

export interface KpiCellProps {
  label: string
  /** Pre-formatted value string (e.g. "1.24", "87%", "12"). */
  value: string | number
  /** Optional secondary line (e.g. "47 / 54", "SEC/TOK", "IN FLIGHT"). */
  caption?: string
  /** Live tile draws a brass accent border + soft glow halo. */
  live?: boolean
  /** Status tone for the value. */
  kind?: KpiCellKind
  /** Density. `compact` = label + value only, `standard` adds caption,
   *  `stacked` enlarges the value and stacks caption below. */
  variant?: KpiCellVariant
  /** Delta chip rendered next to caption when present (standard only). */
  delta?: KpiCellDelta
  /** Optional id reference forwarded to the host listitem. */
  id?: string
  /** Drop the cell-level surface (background + border + radius). Use when
   *  an outer strip already owns the surface and the cells should look
   *  like flat columns inside it. `live` styling is also suppressed
   *  in bare mode because the live ring assumes a cell-level border. */
  bare?: boolean
  /** Optional `data-testid` forwarded to the host listitem. Lets call
   *  sites preserve existing test selectors when swapping in from
   *  hand-rolled cells. */
  testId?: string
  /** Optional 0-100 progress bar rendered below the value. The bar fill
   *  follows `kind` (or fg-secondary when neutral). Out-of-range values
   *  are clamped, not rejected — caller decides whether 113% is a bug
   *  or just "saturated". `kind` mapping is the caller's job: this
   *  component intentionally doesn't pick warn/err thresholds. */
  progress?: number
}

/** Assemble the screen-reader announcement for one KPI cell.
 *  Pure: no DOM access; exported for tests + for callers that want to
 *  wire their own aria-label outside this component. */
export function kpiCellAriaLabel(props: KpiCellProps): string {
  const live = props.live ? ' (live)' : ''
  const delta = props.delta
    ? `, ${props.delta.direction === 'pos' ? 'up' : 'down'} ${props.delta.value}`
    : ''
  const kind =
    props.kind === 'ok'
      ? ' (passing)'
      : props.kind === 'err'
        ? ' (failing)'
        : props.kind === 'warn'
          ? ' (warning)'
          : ''
  const cap = props.caption ? ` ${props.caption}` : ''
  const prog = props.progress != null
    ? `, progress ${Math.round(Math.min(Math.max(props.progress, 0), 100))}%`
    : ''
  return `${props.label}: ${props.value}${cap}${delta}${prog}${kind}${live}`
}

// ── Colors / Tokens ──

export const VALUE_COLOR_BY_KIND: Record<KpiCellKind, string> = {
  ok: 'var(--color-status-ok)',
  warn: 'var(--color-status-warn)',
  err: 'var(--color-status-err)',
}

export const DELTA_COLOR_BY_DIRECTION: Record<'pos' | 'neg', string> = {
  pos: 'var(--color-status-ok)',
  neg: 'var(--color-status-err)',
}

export { MONO_STACK } from './common/font-stacks'
