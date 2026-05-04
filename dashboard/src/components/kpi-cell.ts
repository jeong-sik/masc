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
import { Bar } from './bar'
import { type BarKind } from './bar-shared'
import {
  kpiCellAriaLabel,
  VALUE_COLOR_BY_KIND,
  DELTA_COLOR_BY_DIRECTION,
  MONO_STACK,
  type KpiCellProps,
} from './kpi-shared'

export {
  kpiCellAriaLabel,
  type KpiCellProps,
  type KpiCellKind,
  type KpiCellVariant,
  type KpiCellDelta,
} from './kpi-shared'

const surfaceStyle = {
  background: 'var(--bg-panel)',
  border: '1px solid var(--border-base)',
  borderRadius: 'var(--r-1)',
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
    fontSize: 'var(--fs-11)',
    fontFamily: 'var(--font-sans)',
    lineHeight: 'var(--lh-tight)',
    color: labelColor,
    letterSpacing: '0.08em',
    textTransform: 'uppercase' as const,
    fontWeight: 600,
  }

  const valueStyle = {
    fontSize: variant === 'stacked' ? 'var(--fs-20)' : variant === 'compact' ? 'var(--fs-13)' : 'var(--fs-16)',
    fontFamily: 'var(--font-mono)',
    lineHeight: 'var(--lh-tight)',
    color: valueColor,
    fontVariantNumeric: 'tabular-nums' as const,
    fontWeight: variant === 'stacked' ? 700 : 600,
  }

  // Progress bar swapped to atomic <Bar> primitive (#bar atom). Kind
  // mapping: KpiCellKind ('ok' | 'warn' | 'err') is a strict subset of
  // BarKind so it forwards directly; absent kind → 'default' (brass-2
  // accent fill, matches SPEC `.bar > .fill` default rule).
  const barKind: BarKind = props.kind ?? 'default'
  const progressRow = props.progress != null
    ? html`
        <div style=${{ marginTop: '2px' }}>
          <${Bar} value=${props.progress} kind=${barKind} />
        </div>
      `
    : null

  const captionRow = (variant === 'standard' || variant === 'stacked') && (props.caption || props.delta)
    ? html`
        <span
          aria-hidden="true"
          style=${{
            display: 'inline-flex',
            alignItems: 'center',
            gap: '6px',
            fontSize: 'var(--fs-9)',
            fontFamily: 'var(--font-mono)',
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
      ${progressRow}
    </div>
  `
}
