// Sigil / SigilChip — keeper identity monogram primitive.
//
// Ported from keeper-v2 primitives.jsx. Slot colors are resolved through
// the --kp1..--kp12 bridge aliases defined in variables.css, so the
// component stays visually compatible with the source while using the
// dashboard's generated keeper palette.

import { html } from 'htm/preact'
import type { ComponentChildren, VNode } from 'preact'

export interface SigilProps {
  /** Keeper slot 1–12 or a raw CSS color value. */
  slot?: number | string
  /** Render size in pixels. */
  size?: number
  /** Pulse glow animation. */
  heartbeat?: boolean
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

export function Sigil({ slot = 1, size = 32, heartbeat = false, children }: SigilProps): VNode {
  const kc = slotVar(slot)
  const kcGlow = slotGlowVar(slot)
  return html`
    <span
      class=${`sigil${heartbeat ? ' heartbeat' : ''}`}
      style=${{
        '--kc': kc,
        '--kc-glow': kcGlow,
        width: size,
        height: size,
        fontSize: Math.round(size * 0.4),
      }}
      aria-label=${typeof children === 'string' ? children : undefined}
      aria-hidden=${typeof children === 'string' ? undefined : 'true'}
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
