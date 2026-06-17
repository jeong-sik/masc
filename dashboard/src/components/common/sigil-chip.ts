// Sigil / SigilChip — keeper identity monogram primitive.
//
// Ported from keeper-v2 primitives.jsx. Slot colors are resolved through
// the --kp1..--kp12 bridge aliases defined in variables.css, so the
// component stays visually compatible with the source while using the
// dashboard's generated keeper palette.

import { html } from 'htm/preact'
import type { ComponentChildren, JSX, VNode } from 'preact'

export interface SigilProps {
  /** Keeper slot 1–12 or a raw CSS color value. */
  slot?: number | string
  /** Render size in pixels. */
  size?: number
  /** Pulse glow animation. */
  heartbeat?: boolean
  /** Tooltip / accessible name override. */
  title?: string
  /** Scale factor applied to the size to compute font-size. */
  fontScale?: number
  /** Additional inline styles merged after the base sigil styles. */
  style?: JSX.CSSProperties
  children?: ComponentChildren
}

export interface SigilChipProps {
  slot?: number | string
  /** Two-letter monogram rendered inside the sigil. */
  mono?: string
  children?: ComponentChildren
}

function slotVar(slot: number | string): string {
  return typeof slot === 'number' ? `var(--kp${slot})` : slot
}

function slotGlowVar(slot: number | string): string {
  return typeof slot === 'number' ? `var(--kp${slot}-glow)` : slot
}

export function Sigil({
  slot = 1,
  size = 32,
  heartbeat = false,
  title,
  fontScale = 0.4,
  style,
  children,
}: SigilProps): VNode {
  const kc = slotVar(slot)
  const kcGlow = slotGlowVar(slot)
  const label = title ?? (typeof children === 'string' ? children : undefined)
  return html`
    <span
      class=${`sigil${heartbeat ? ' heartbeat' : ''}`}
      style=${{
        '--kc': kc,
        '--kc-glow': kcGlow,
        width: size,
        height: size,
        fontSize: Math.round(size * fontScale),
        ...style,
      }}
      title=${title}
      aria-label=${label}
      aria-hidden=${label ? undefined : 'true'}
    >${children}</span>
  `
}

export function SigilChip({ slot = 1, mono, children }: SigilChipProps): VNode {
  const kc = slotVar(slot)
  return html`
    <span class="sigil-chip" style=${{ '--kc': kc }}>
      <${Sigil} slot=${slot} size=${17}>${mono}<//>
      ${children}
    </span>
  `
}
