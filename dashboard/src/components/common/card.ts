// SurfaceCard — reusable card container with Tailwind variants
// Replaces 40+ inline `p-4 rounded-xl border border-[var(--card-border)]` patterns

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { SectionHeader } from './section-header'

// ── Exported class constants for non-component usage ──
export const CARD_BASE = 'rounded-xl border border-card-border shadow-sm'
export const CARD_STANDARD = `${CARD_BASE} p-6 bg-card/90 backdrop-blur-sm`
export const CARD_LIGHT = `${CARD_BASE} p-6 bg-card/90 backdrop-blur-none`
export const CARD_COMPACT = `${CARD_BASE} p-5 bg-card/90 backdrop-blur-sm`

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

// ── Clickable card (adds hover + cursor) ──
interface ClickableCardProps {
  variant?: CardVariant
  class?: string
  onClick?: () => void
  children: ComponentChildren
}

// ── Legacy Card (backward compat — accepts title prop) ──
interface CardProps {
  title?: ComponentChildren
  class?: string
  testId?: string
  children: ComponentChildren
}

export function Card({ title, class: cx, testId, children }: CardProps) {
  if (title) {
    return html`
      <${SectionCard} label=${title} class=${cx ?? ''} variant="standard">
        ${children}
      <//>
    `
  }
  return html`<${SurfaceCard} class=${cx} testId=${testId}>${children}<//>`
}

export function ClickableCard({
  variant = 'standard',
  class: cx,
  onClick,
  children,
}: ClickableCardProps) {
  const cls = [
    VARIANT_CLASSES[variant],
    'cursor-pointer transition-all duration-200 hover:border-accent/40 hover:-translate-y-0.5 hover:shadow-md group',
    cx,
  ].filter(Boolean).join(' ')
  return html`<div class=${cls} onClick=${onClick}>${children}</div>`
}
