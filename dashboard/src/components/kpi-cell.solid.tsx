/** @jsxImportSource solid-js */
//
// Solid mirror of `kpi-cell.ts` (Preact). Identical prop surface and
// aria-label assembly; uses Solid's prop-proxy reactivity instead of
// Preact re-renders. The `bare` default flips when the cell is rendered
// inside a `KpiStrip` (read via context — see kpi-strip.solid.tsx note).
//
// Surface parity: role=listitem, computed aria-label via `kpiCellAriaLabel`,
// optional Bar progress row, caption + delta in standard/stacked variants.

import { Show, type JSX } from 'solid-js'
import { Bar, type BarKind } from './bar.solid'
import { useKpiStripContext } from './kpi-strip.solid'
import {
  kpiCellAriaLabel,
  VALUE_COLOR_BY_KIND,
  DELTA_COLOR_BY_DIRECTION,
  MONO_STACK,
  type KpiCellProps,
  type KpiCellVariant,
} from './kpi-shared'

export {
  kpiCellAriaLabel,
  type KpiCellProps,
  type KpiCellKind,
  type KpiCellVariant,
  type KpiCellDelta,
} from './kpi-shared'

const surfaceStyle: JSX.CSSProperties = {
  background: 'var(--bg-panel)',
  border: '1px solid var(--border-base)',
  'border-radius': '3px',
}

const liveOverrideStyle: JSX.CSSProperties = {
  'border-color': 'var(--color-accent-brass)',
  'box-shadow':
    '0 0 0 1px var(--color-accent-brass), 0 0 12px rgb(var(--color-keeper-3-glow, 195 146 89) / 0.18)',
}

export function KpiCell(props: KpiCellProps): JSX.Element {
  const stripCtx = useKpiStripContext()

  const variant = (): KpiCellVariant => props.variant ?? 'standard'
  const bare = (): boolean => props.bare ?? (stripCtx ? true : false)
  const valueColor = (): string =>
    props.kind ? VALUE_COLOR_BY_KIND[props.kind] : 'var(--color-fg-primary)'

  const containerStyle = (): JSX.CSSProperties => {
    const v = variant()
    const isBare = bare()
    return {
      ...(isBare ? {} : surfaceStyle),
      ...(!isBare && props.live ? liveOverrideStyle : {}),
      display: 'flex',
      'flex-direction': v === 'compact' ? 'row' : 'column',
      'align-items': v === 'compact' ? 'baseline' : 'flex-start',
      gap:
        v === 'compact'
          ? 'var(--spacing-element)'
          : v === 'stacked'
            ? '4px'
            : '6px',
      padding: isBare
        ? '0'
        : v === 'stacked'
          ? '14px var(--spacing-card)'
          : '10px var(--spacing-group)',
      'font-family': MONO_STACK,
      'min-width': '0',
    }
  }

  const labelStyle: JSX.CSSProperties = {
    'font-size': 'var(--font-size-3xs)',
    color: 'var(--color-fg-disabled)',
    'letter-spacing': '0.08em',
    'text-transform': 'uppercase',
    'font-weight': 600,
  }

  const valueStyle = (): JSX.CSSProperties => {
    const v = variant()
    return {
      'font-size':
        v === 'stacked' ? '24px' : v === 'compact' ? 'var(--font-size-sm)' : '17px',
      color: valueColor(),
      'font-variant-numeric': 'tabular-nums',
      'font-weight': v === 'stacked' ? 700 : 600,
      'line-height': 1.1,
    }
  }

  const captionShown = (): boolean => {
    const v = variant()
    return (v === 'standard' || v === 'stacked') && Boolean(props.caption || props.delta)
  }

  const barKind = (): BarKind => props.kind ?? 'default'

  return (
    <div
      role="listitem"
      id={props.id}
      data-testid={props.testId}
      aria-label={kpiCellAriaLabel(props)}
      style={containerStyle()}
    >
      <span aria-hidden="true" style={labelStyle}>
        {props.label}
      </span>
      <span aria-hidden="true" style={valueStyle()}>
        {props.value}
      </span>
      <Show when={captionShown()}>
        <span
          aria-hidden="true"
          style={{
            display: 'inline-flex',
            'align-items': 'center',
            gap: '6px',
            'font-size': 'var(--font-size-3xs)',
            color: 'var(--color-fg-muted)',
            'letter-spacing': '0.06em',
            'text-transform': 'uppercase',
            'font-weight': 500,
          }}
        >
          {props.caption ?? ''}
          <Show when={props.delta}>
            {(d) => (
              <span
                style={{
                  color: DELTA_COLOR_BY_DIRECTION[d().direction],
                  'font-weight': 600,
                }}
              >
                · {d().value}
              </span>
            )}
          </Show>
        </span>
      </Show>
      <Show when={props.progress != null}>
        <div style={{ 'margin-top': '2px' }}>
          <Bar value={props.progress as number} kind={barKind()} />
        </div>
      </Show>
    </div>
  )
}
