// Keeper attribution primitive — color + sigil, two-channel rule.
//
// SPEC §3.6 v0.3 (design-system/SPEC.md): color alone never identifies
// a keeper. Always emit color + sigil. <KeeperBadge> is the canonical
// attribution unit anywhere in the dashboard.
//
// Slot resolution: kSlot(id) → optional runtime override, else 1..12
// deterministic FNV-1a hash.
// Sigil: kSigil(id) → optional runtime override, else 2-letter monogram.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { MONO_STACK } from './common/font-stacks'

export interface KeeperRegistryEntry {
  slot: number
  sigil: string
}

export const KEEPER_REGISTRY: Record<string, KeeperRegistryEntry> = {}

interface MascDataWindow extends Window {
  MASC_DATA?: {
    keeper_registry?: unknown
    keeperRegistry?: unknown
  }
}

function normalizeKeeperSigil(raw: unknown): string | null {
  if (typeof raw !== 'string') return null
  const sigil = raw.replace(/[^a-z0-9]/gi, '').slice(0, 2).toUpperCase()
  return sigil.length === 2 ? sigil : null
}

export function normalizeKeeperRegistry(
  raw: unknown,
): Record<string, KeeperRegistryEntry> {
  if (!raw || typeof raw !== 'object') return {}
  const resolved: Record<string, KeeperRegistryEntry> = {}
  for (const [id, value] of Object.entries(raw)) {
    if (!value || typeof value !== 'object') continue
    const entry = value as Record<string, unknown>
    const slot = Number(entry.slot)
    const sigil = normalizeKeeperSigil(entry.sigil)
    if (!Number.isInteger(slot) || slot < 1 || slot > 12 || !sigil) continue
    resolved[id] = { slot, sigil }
  }
  return resolved
}

function runtimeKeeperRegistry(): Record<string, KeeperRegistryEntry> {
  if (typeof window === 'undefined') return KEEPER_REGISTRY
  const data = (window as MascDataWindow).MASC_DATA
  return normalizeKeeperRegistry(
    data?.keeper_registry ?? data?.keeperRegistry ?? KEEPER_REGISTRY,
  )
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
  const reg = runtimeKeeperRegistry()[id]
  if (reg) return reg.slot
  return hash12(String(id))
}

export function kSigil(id: string): string {
  const reg = runtimeKeeperRegistry()[id]
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
    color: 'var(--color-bg-page)',
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
