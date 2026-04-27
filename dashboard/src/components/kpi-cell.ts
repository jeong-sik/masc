// KPI cell — single tile in a fleet/health KPI strip.
//
// Ported from design-system v0.4 cb-group-a (preview/cb-group-a.jsx,
// see KpiStandard / KpiCompact / KpiStacked + KPI_CELLS data shape).
// The original css selectors `.cb-kpi .cell.live.is-{kind}` live in
// design-system/source_styles/, which the dashboard does NOT import
// (CSS-ARCHITECTURE keeps preview styles isolated). This module is a
// re-implementation against the dashboard token set + Tailwind v4 utility
// + htm/preact convention, so the layout/spacing intent translates while
// the surface fits the dashboard shell.
//
// Usage: parent renders `<KpiCell ... />` inside a `role="list"` strip
// container. Each cell self-emits `role="listitem"` + an aria-label
// composed via `kpiCellAriaLabel`.

import { html } from 'htm/preact'
import type { VNode } from 'preact'

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
  return `${props.label}: ${props.value}${cap}${delta}${kind}${live}`
}

const VALUE_COLOR_BY_KIND: Record<KpiCellKind, string> = {
  ok: 'var(--color-status-ok)',
  warn: 'var(--color-status-warn)',
  err: 'var(--color-status-err)',
}

const DELTA_COLOR_BY_DIRECTION: Record<'pos' | 'neg', string> = {
  pos: 'var(--color-status-ok)',
  neg: 'var(--color-status-err)',
}

const MONO_STACK = 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace'

const surfaceStyle = {
  background: 'var(--bg-panel)',
  border: '1px solid var(--border-base)',
  borderRadius: '3px',
}

const liveOverrideStyle = {
  borderColor: 'var(--color-accent-brass)',
  boxShadow: '0 0 0 1px var(--color-accent-brass), 0 0 12px rgb(var(--color-keeper-3-glow, 195 146 89) / 0.18)',
}

export function KpiCell(props: KpiCellProps): VNode {
  const variant = props.variant ?? 'standard'
  const valueColor = props.kind ? VALUE_COLOR_BY_KIND[props.kind] : 'var(--color-fg-primary)'
  const labelColor = 'var(--color-fg-disabled)'
  const captionColor = 'var(--color-fg-muted)'

  const bare = props.bare === true
  const containerStyle = {
    ...(bare ? {} : surfaceStyle),
    ...(!bare && props.live ? liveOverrideStyle : {}),
    display: 'flex',
    flexDirection: variant === 'compact' ? ('row' as const) : ('column' as const),
    alignItems: variant === 'compact' ? ('baseline' as const) : ('flex-start' as const),
    gap: variant === 'compact' ? 'var(--spacing-element)' : variant === 'stacked' ? '4px' : '6px',
    padding: bare
      ? '0'
      : variant === 'stacked'
        ? `14px var(--spacing-card)`
        : `10px var(--spacing-group)`,
    fontFamily: MONO_STACK,
    minWidth: '0',
  }

  const labelStyle = {
    fontSize: 'var(--font-size-3xs)',
    color: labelColor,
    letterSpacing: '0.08em',
    textTransform: 'uppercase' as const,
    fontWeight: 600,
  }

  const valueStyle = {
    fontSize: variant === 'stacked' ? '24px' : variant === 'compact' ? 'var(--font-size-sm)' : '17px',
    color: valueColor,
    fontVariantNumeric: 'tabular-nums' as const,
    fontWeight: variant === 'stacked' ? 700 : 600,
    lineHeight: 1.1,
  }

  const captionRow = (variant === 'standard' || variant === 'stacked') && (props.caption || props.delta)
    ? html`
        <span
          aria-hidden="true"
          style=${{
            display: 'inline-flex',
            alignItems: 'center',
            gap: '6px',
            fontSize: 'var(--font-size-3xs)',
            color: captionColor,
            letterSpacing: '0.06em',
            textTransform: 'uppercase',
            fontWeight: 500,
          }}
        >
          ${props.caption ?? ''}
          ${props.delta
            ? html`
                <span style=${{
                  color: DELTA_COLOR_BY_DIRECTION[props.delta.direction],
                  fontWeight: 600,
                }}>· ${props.delta.value}</span>
              `
            : null}
        </span>
      `
    : null

  return html`
    <div
      role="listitem"
      id=${props.id}
      data-testid=${props.testId}
      aria-label=${kpiCellAriaLabel(props)}
      style=${containerStyle}
    >
      <span aria-hidden="true" style=${labelStyle}>${props.label}</span>
      <span aria-hidden="true" style=${valueStyle}>${props.value}</span>
      ${captionRow}
    </div>
  `
}
