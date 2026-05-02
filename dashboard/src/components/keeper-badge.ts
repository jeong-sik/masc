// Keeper attribution primitive — color + sigil, two-channel rule.
//
// SPEC §3.6 v0.3 (design-system/SPEC.md): color alone never identifies
// a keeper. Always emit color + sigil. <KeeperBadge> is the canonical
// attribution unit anywhere in the dashboard.
//
// Slot resolution: kSlot(id) → 1..12 deterministic FNV-1a hash, with
// 5 anchor ids in KEEPER_REGISTRY pinned for brand recall.
// Sigil: kSigil(id) → 2-letter monogram (registry override or
// auto-derived from id).

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { MONO_STACK } from './common/font-stacks'

export interface KeeperRegistryEntry {
  slot: number
  sigil: string
}

export const KEEPER_REGISTRY: Record<string, KeeperRegistryEntry> = {
  // Canonical 5 — pinned slots for brand recall.
  // These match the v0.2 alias targets in design-system tokens
  // so visual identity is preserved across the v0.2→v0.3 migration.
  'nick0cave':     { slot: 3,  sigil: 'NK' },  /* amber  */
  'masc-improver': { slot: 6,  sigil: 'MS' },  /* jade   */
  'sangsu':        { slot: 9,  sigil: 'SS' },  /* sky    */
  'qa-king':       { slot: 2,  sigil: 'QA' },  /* clay   */
  'rama':          { slot: 11, sigil: 'RM' },  /* violet */
}

// FNV-1a 32-bit hash mapped onto 1..12 (avoids 0 so slot is 1-indexed).
function hash12(str: string): number {
  let h = 0x811c9dc5
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i)
    h = Math.imul(h, 0x01000193)
  }
  return ((h >>> 0) % 12) + 1
}

export function kSlot(id: string): number {
  const reg = KEEPER_REGISTRY[id]
  if (reg) return reg.slot
  return hash12(String(id))
}

export function kSigil(id: string): string {
  const reg = KEEPER_REGISTRY[id]
  if (reg) return reg.sigil
  // Auto-derive: first letter + first letter after hyphen, else first 2.
  const s = String(id).replace(/[^a-z0-9-]/gi, '')
  const parts = s.split('-').filter(Boolean)
  const first = parts[0]
  const second = parts[1]
  if (first && second && first[0] && second[0]) {
    return (first[0] + second[0]).toUpperCase()
  }
  return s.slice(0, 2).toUpperCase()
}

const SANS_STACK = '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif'
const HEARTBEAT_EASING = 'var(--ease-inout)'

export type KeeperBadgeSize = 'sm' | 'md' | 'lg'
export type KeeperBadgeVariant = 'sigil' | 'full' | 'name'

export interface KeeperBadgeProps {
  id: string
  name?: string
  size?: KeeperBadgeSize
  variant?: KeeperBadgeVariant
  title?: string
  beat?: boolean
}

export function KeeperBadge({
  id,
  name,
  size = 'md',
  variant = 'full',
  title,
  beat = false,
}: KeeperBadgeProps): VNode {
  const slot = kSlot(id)
  const sigil = kSigil(id)
  const display = name ?? id
  const sizePx = size === 'sm' ? 14 : size === 'lg' ? 24 : 18
  const fontPx = size === 'sm' ? 8 : size === 'lg' ? 11 : 9
  const radius = size === 'lg' ? 3 : 2

  const sigilStyle = {
    display: 'inline-flex',
    alignItems: 'center',
    justifyContent: 'center',
    width: `${sizePx}px`,
    height: `${sizePx}px`,
    fontSize: `${fontPx}px`,
    borderRadius: `${radius}px`,
    background: `var(--color-keeper-${slot})`,
    color: 'var(--color-bg-0)',
    fontFamily: MONO_STACK,
    fontWeight: 700,
    letterSpacing: 0,
    flex: 'none',
    boxShadow: beat
      ? `0 0 6px rgb(var(--color-keeper-${slot}-glow) / 0.7)`
      : undefined,
    animation: beat
      ? `keeper-heartbeat 1.4s ${HEARTBEAT_EASING} infinite`
      : undefined,
  }

  const sigilEl = html`
    <span
      style=${sigilStyle}
      aria-hidden=${variant === 'full' ? 'true' : 'false'}
    >${sigil}</span>
  `

  if (variant === 'sigil') {
    return html`
      <span title=${title || display} aria-label=${display}>${sigilEl}</span>
    `
  }
  if (variant === 'name') {
    return html`
      <span style=${{ color: `var(--color-keeper-${slot})`, fontWeight: 500 }}>
        ${display}
      </span>
    `
  }
  return html`
    <span
      style=${{
        display: 'inline-flex',
        alignItems: 'center',
        gap: '6px',
        verticalAlign: 'middle',
      }}
      title=${title}
    >
      ${sigilEl}
      <span
        style=${{
          color: `var(--color-keeper-${slot})`,
          fontFamily: SANS_STACK,
          fontSize: '11px',
          fontWeight: 500,
        }}
      >${display}</span>
    </span>
  `
}

export interface KeeperStackProps {
  ids: string[]
  cap?: number
  size?: KeeperBadgeSize
}

export function KeeperStack({
  ids,
  cap = 4,
  size = 'md',
}: KeeperStackProps): VNode {
  const visible = ids.slice(0, cap)
  const overflow = ids.length - visible.length
  const sizePx = size === 'sm' ? 14 : size === 'lg' ? 24 : 18
  const surface = 'var(--color-bg-1)'

  const overflowChip = overflow > 0
    ? html`
        <span
          aria-label=${`${overflow} more`}
          style=${{
            marginLeft: '-4px',
            width: `${sizePx}px`,
            height: `${sizePx}px`,
            display: 'inline-flex',
            alignItems: 'center',
            justifyContent: 'center',
            background: 'var(--color-bg-2)',
            color: 'var(--color-text-body)',
            border: `2px solid ${surface}`,
            borderRadius: '3px',
            fontFamily: MONO_STACK,
            fontSize: '10px',
            fontWeight: 600,
          }}
        >+${overflow}</span>
      `
    : null

  return html`
    <span style=${{ display: 'inline-flex', alignItems: 'center' }}>
      ${visible.map((id, i) => html`
        <span
          key=${id}
          style=${{
            marginLeft: i === 0 ? '0' : '-4px',
            border: `2px solid ${surface}`,
            borderRadius: '3px',
            display: 'inline-flex',
          }}
        ><${KeeperBadge} id=${id} variant="sigil" size=${size} /></span>
      `)}
      ${overflowChip}
    </span>
  `
}
