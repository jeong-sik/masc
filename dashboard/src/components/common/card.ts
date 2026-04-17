// SurfaceCard — reusable card container with Tailwind variants
// Replaces 40+ inline `p-4 rounded-xl border border-[var(--card-border)]` patterns

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { SectionHeader } from './section-header'

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
  label: string
  class?: string
  variant?: CardVariant
  children: ComponentChildren
}

export function SectionCard({
  label,
  class: cx,
  variant = 'light',
  children,
}: SectionCardProps) {
  return html`
    <${SurfaceCard} variant=${variant} class="flex flex-col gap-4 ${cx ?? ''}">
      <${SectionHeader}>${label}<//>
      ${children}
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
