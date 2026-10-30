// LogFilter — flat label-only filter toggle.
//
// Distinct from FilterChip (.rfilter, pill + count): this is the flatter,
// label-only filter used in log/level strips (.log-f). It delegates layout
// and state to the parent.

import { html } from 'htm/preact'
import type { JSX, ComponentChildren, VNode } from 'preact'

export interface LogFilterProps extends JSX.HTMLAttributes<HTMLButtonElement> {
  active?: boolean
  children?: ComponentChildren
}

export function LogFilter({
  active = false,
  children,
  class: cx,
  ...rest
}: LogFilterProps): VNode {
  const cls = `log-f${active ? ' on' : ''}${cx ? ` ${cx}` : ''}`
  return html`
    <button
      type="button"
      class=${cls}
      aria-pressed=${active}
      ...${rest}
    >${children}</button>
  `
}
