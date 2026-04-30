/** @jsxImportSource solid-js */
//
// Solid mirror of `bar.ts` (Preact). Same prop surface and DOM contract;
// reactivity comes from Solid's prop proxy + JSX expression tracking
// instead of Preact's re-render cycle. Lives under `*.solid.tsx` so
// vite-plugin-solid claims the file (vite.config.ts include regex).
//
// Surface parity with bar.ts:
//   - role="progressbar" + aria-value{now,min,max}
//   - data-kind, data-testid, title pass-through
//   - barPercent clamps NaN → 0 and rounds to int

import type { JSX } from 'solid-js'

export type BarKind = 'default' | 'ok' | 'warn' | 'err'

export interface BarProps {
  value: number
  kind?: BarKind
  ariaLabel?: string
  testId?: string
  title?: string
  noTransition?: boolean
}

const FILL_COLOR: Record<BarKind, string> = {
  default: 'var(--color-accent-fg)',
  ok: 'var(--color-status-ok)',
  warn: 'var(--color-status-warn)',
  err: 'var(--color-status-err)',
}

export function barPercent(value: number): number {
  if (Number.isNaN(value)) return 0
  return Math.round(Math.min(Math.max(value, 0), 100))
}

export function Bar(props: BarProps): JSX.Element {
  const kind = (): BarKind => props.kind ?? 'default'
  const pct = (): number => barPercent(props.value)
  const announce = (): string => props.ariaLabel ?? `${pct()}%`

  return (
    <div
      role="progressbar"
      aria-valuenow={pct()}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-label={announce()}
      data-testid={props.testId}
      data-kind={kind()}
      title={props.title}
      style={{
        display: 'block',
        width: '100%',
        height: '4px',
        background: 'var(--color-bg-elevated)',
        'border-radius': '2px',
        overflow: 'hidden',
      }}
    >
      <span
        aria-hidden="true"
        style={{
          display: 'block',
          height: '100%',
          width: `${pct()}%`,
          background: FILL_COLOR[kind()],
          transition: props.noTransition === true ? undefined : 'width 500ms',
        }}
      />
    </div>
  )
}
