// Keeper attribution primitive — two-channel identity (OKLCH slot + collision-free sigil)
// with soft-tinted chip surface (16% bg / 35% border) and optional 28–36px portrait.png thumbnail.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useState } from 'preact/hooks'
import { useAuthenticatedPortrait } from '../lib/portrait-cache'

// FNV-1a 32-bit hash mapped onto 1..12 (1-indexed OKLCH keeper slot).
function hash12(str: string): number {
  let h = 0x811c9dc5
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i)
    h = Math.imul(h, 0x01000193)
  }
  return ((h >>> 0) % 12) + 1
}

export function kSlot(id: string): number {
  return hash12(String(id))
}

/**
 * Collision-resistant 2-letter monogram for a keeper ID.
 * Multi-segment hyphenated names take the first and last segment initials
 * (`code-reviewer-sister` -> `CS`, `e-masc-the-leader` -> `EL`, `foo-bar` -> `FB`)
 * so sibling keepers in the same family never collapse onto the same monogram.
 * Single-segment IDs take the first 2 alphanumeric characters.
 */
export function kSigil(id: string): string {
  const cleaned = String(id).replace(/[^a-z0-9-]/gi, '')
  const parts = cleaned.split('-').filter(Boolean)
  if (parts.length >= 2) {
    const first = parts[0]!
    const last = parts[parts.length - 1]!
    if (first[0] && last[0]) {
      return (first[0] + last[0]).toUpperCase()
    }
  }
  return cleaned.replace(/-/g, '').slice(0, 2).toUpperCase()
}

export function keeperPortraitUrl(id: string, size = 64): string {
  return `/api/v1/keepers/${encodeURIComponent(id)}/portrait.png?size=${size}`
}

export type KeeperBadgeSize = 'sm' | 'md' | 'lg'
export type KeeperBadgeVariant = 'sigil' | 'full' | 'name'

export interface KeeperBadgeProps {
  id: string
  name?: string
  size?: KeeperBadgeSize
  variant?: KeeperBadgeVariant
  title?: string
  beat?: boolean
  /** Render a 28-36px portrait thumbnail with 1.5px slot ring (falls back to sigil on error). */
  portrait?: boolean | string
}

export function KeeperBadge({
  id,
  name,
  size = 'md',
  variant = 'full',
  title,
  beat = false,
  portrait = false,
}: KeeperBadgeProps): VNode {
  const slot = kSlot(id)
  const sigil = kSigil(id)
  const display = name ?? id
  const [failedSrc, setFailedSrc] = useState<string | null>(null)

  const portraitSrc = typeof portrait === 'string'
    ? portrait
    : portrait === true
      ? keeperPortraitUrl(id, 64)
      : null

  const authenticatedPortraitSrc = useAuthenticatedPortrait(portraitSrc)
  const showPortrait = authenticatedPortraitSrc !== null && failedSrc !== authenticatedPortraitSrc

  const avatarEl = showPortrait
    ? html`
        <img
          class=${`kb-portrait kb-portrait--${size}${beat ? ' kb-beat' : ''}`}
          src=${authenticatedPortraitSrc}
          data-portrait-url=${portraitSrc ?? undefined}
          alt=${variant === 'full' ? '' : display}
          aria-hidden=${variant === 'full' ? 'true' : undefined}
          loading="lazy"
          decoding="async"
          onError=${() => setFailedSrc(authenticatedPortraitSrc)}
        />
      `
    : html`
        <span
          class=${`kb-sigil kb-sigil--${size}${beat ? ' kb-beat' : ''}`}
          aria-hidden=${variant === 'full' ? 'true' : 'false'}
        >${sigil}</span>
      `

  if (variant === 'sigil') {
    return html`
      <span
        class=${`kb-root kb-slot-${slot}`}
        data-keeper-slot=${slot}
        title=${title || display}
        aria-label=${display}
      >${avatarEl}</span>
    `
  }

  if (variant === 'name') {
    return html`
      <span class=${`kb-name kb-slot-${slot}`} data-keeper-slot=${slot} title=${title}>
        ${display}
      </span>
    `
  }

  return html`
    <span
      class=${`kb-chip kb-chip--${size} kb-slot-${slot}`}
      data-keeper-slot=${slot}
      title=${title}
    >
      ${avatarEl}
      <span class="kb-label">${display}</span>
    </span>
  `
}
