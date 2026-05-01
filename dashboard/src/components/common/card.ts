// SurfaceCard — reusable card container with Tailwind variants
// Replaces 40+ inline `p-4 rounded border border-[var(--color-border-default)]` patterns

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { SectionHead } from '../section-head'
import { statusDotColor } from './status-badge'

// ── Class constants (CARD_STANDARD exported for inline section usage) ──
const CARD_BASE = 'card'
export const CARD_STANDARD = `${CARD_BASE}`
const CARD_LIGHT = `${CARD_BASE} !bg-transparent !backdrop-blur-none`
const CARD_COMPACT = `${CARD_BASE} !p-3.5 !shadow-[0_1px_2px_rgba(0,0,0,0.14)]`

type CardVariant = 'standard' | 'light' | 'compact'

const VARIANT_CLASSES: Record<CardVariant, string> = {
  standard: CARD_STANDARD,
  light: CARD_LIGHT,
  compact: CARD_COMPACT,
}

interface SurfaceCardProps {
  variant?: CardVariant
  class?: string
  /** Tone class: 'ok' | 'warn' | 'bad' */
  tone?: string
  testId?: string
  children: ComponentChildren
}

export function SurfaceCard({
  variant = 'standard',
  class: cx,
  tone,
  testId,
  children,
}: SurfaceCardProps) {
  const cls = [VARIANT_CLASSES[variant], tone, cx].filter(Boolean).join(' ')
  return html`<div class=${cls} data-testid=${testId}>${children}</div>`
}

// ── Section card with label header ──
interface SectionCardProps {
  label?: ComponentChildren
  title?: ComponentChildren
  right?: ComponentChildren
  eyebrow?: ComponentChildren
  status?: string
  tone?: string
  class?: string
  variant?: CardVariant
  testId?: string
  'data-testid'?: string
  children: ComponentChildren
}

function statusDotClass(status?: string): string {
  const normalized = (status ?? '').toLowerCase()
  switch (normalized) {
    case 'healthy':
    case 'live':
      return statusDotColor('active')
    case 'watch':
    case 'danger':
      return statusDotColor(status === 'watch' ? 'warn' : 'bad')
    case 'offline':
      return statusDotColor('bad')
    default:
      return statusDotColor(normalized)
  }
}

export function SectionCard({
  label,
  title,
  right,
  eyebrow,
  status,
  tone,
  class: cx,
  variant = 'light',
  testId,
  'data-testid': dataTestId,
  children,
}: SectionCardProps) {
  // SPEC `.section-head` upgrade — SectionHead atom replaces the
  // legacy SectionHeader. The strip wants to sit flush against the
  // card's top edge, so the outer SurfaceCard padding is forced to 0
  // (overflow-hidden lets the strip clip into the rounded corner) and
  // the body padding moves into a dedicated wrapper. The `light`
  // variant deliberately keeps the bg-transparent override — the
  // SectionHead's bg-surface still reads as a strip because it sits
  // above transparent body. Variant `compact` had p-3.5 in the legacy
  // path; the new wrapper uses p-3.5 to preserve that visual.
  const bodyPadding = variant === 'compact' ? 'p-3.5' : 'p-4'
  const sectionLabel = label ?? title ?? ''
  const tail = right ?? (
    eyebrow != null || status != null
      ? html`
          <span class="inline-flex items-center gap-1.5 text-2xs text-[var(--color-fg-muted)]">
            ${status != null ? html`<span class="h-1.5 w-1.5 rounded-full ${statusDotClass(status)}" />` : null}
            ${eyebrow != null ? html`<span>${eyebrow}</span>` : null}
          </span>
        `
      : null
  )
  return html`
    <${SurfaceCard}
      variant=${variant}
      tone=${tone}
      testId=${testId ?? dataTestId}
      class="flex flex-col !p-0 overflow-hidden ${cx ?? ''}"
    >
      <${SectionHead} tail=${tail}>${sectionLabel}<//>
      <div class="${bodyPadding} flex flex-col gap-4">${children}</div>
    <//>
  `
}


// ── Legacy Card (backward compat — accepts title prop) ──
interface CardProps {
  title?: ComponentChildren
  class?: string
  variant?: CardVariant
  testId?: string
  children: ComponentChildren
}

export function Card({ title, class: cx, variant = 'standard', testId, children }: CardProps) {
  if (title) {
    return html`
      <${SectionCard} label=${title} class=${cx ?? ''} variant=${variant}>
        ${children}
      <//>
    `
  }
  return html`<${SurfaceCard} variant=${variant} class=${cx} testId=${testId}>${children}<//>`
}
