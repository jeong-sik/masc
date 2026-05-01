// bar-shared.ts — SSOT for Bar types, constants, and pure helpers.
// Imported by both Preact (`bar.ts`) and Solid (`bar.solid.tsx`) builds.

export type BarKind = 'default' | 'ok' | 'warn' | 'err'

export interface BarProps {
  /** Progress value 0–100. Out-of-range values clamp on render. */
  value: number
  /** Fill tone. `undefined` ≡ `default` (brass / accent). */
  kind?: BarKind
  /** Override the auto aria-label. Default is `"<roundedPct>%"`. */
  ariaLabel?: string
  /** Forwarded to data-testid. */
  testId?: string
  /** Optional native `title` attribute for hover tooltips. */
  title?: string
  /** Disable the SPEC width-transition. Default false (transition on). */
  noTransition?: boolean
}

export const FILL_COLOR: Record<BarKind, string> = {
  default: 'var(--color-accent-fg)',
  ok: 'var(--color-status-ok)',
  warn: 'var(--color-status-warn)',
  err: 'var(--color-status-err)',
}

/** Pure: clamp to [0, 100] and round to integer percent. Exported so
 *  callers that label a Bar inside a parent label can reuse the same
 *  rounding without mounting the component. */
export function barPercent(value: number): number {
  if (Number.isNaN(value)) return 0
  return Math.round(Math.min(Math.max(value, 0), 100))
}
