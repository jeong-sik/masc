// SurfaceCard — reusable card container with Tailwind variants
// Replaces 40+ inline `p-4 rounded-[var(--r-1)] border border-[var(--color-border-default)]` patterns

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { SectionHead } from '../section-head'
import { statusBadgeTone, statusDotColor } from './status-badge'

// ── Class constants (CARD_STANDARD exported for inline section usage) ──
const CARD_BASE = 'card'
export const CARD_STANDARD = `${CARD_BASE}`
const CARD_LIGHT = `${CARD_BASE} !bg-transparent !backdrop-blur-none`
const CARD_COMPACT = `${CARD_BASE} !p-3.5 !shadow-[var(--shadow-1)]`

export type CardVariant = 'standard' | 'light' | 'compact'
export type CardToneSource = 'none' | 'tone-class'
export type CardContentState = 'empty' | 'text' | 'node'
export type SectionCardLabelSource = 'label' | 'title' | 'empty'
export type SectionCardTailSource = 'right' | 'status-eyebrow' | 'none'
export type CardStatusDotTone = 'ok' | 'warn' | 'bad' | 'info' | 'neutral'

export interface SurfaceCardSummary {
  readonly variant: CardVariant
  readonly tone: string
  readonly toneSource: CardToneSource
  readonly hasTone: boolean
  readonly toneLength: number
  readonly hasCustomClass: boolean
  readonly classNameLength: number
  readonly hasStyle: boolean
  readonly styleLength: number
  readonly hasTestId: boolean
  readonly testIdLength: number
  readonly contentState: CardContentState
}

export interface SectionCardSummary {
  readonly variant: CardVariant
  readonly bodyPadding: string
  readonly labelSource: SectionCardLabelSource
  readonly labelState: CardContentState
  readonly labelTextLength: number
  readonly tailSource: SectionCardTailSource
  readonly status: string
  readonly normalizedStatus: string
  readonly statusDotTone: CardStatusDotTone
  readonly hasStatus: boolean
  readonly statusLength: number
  readonly hasEyebrow: boolean
  readonly eyebrowState: CardContentState
  readonly eyebrowTextLength: number
  readonly hasRightSlot: boolean
  readonly hasTone: boolean
  readonly toneLength: number
  readonly hasCustomClass: boolean
  readonly classNameLength: number
  readonly hasTestId: boolean
  readonly testIdLength: number
  readonly contentState: CardContentState
}

const VARIANT_CLASSES: Record<CardVariant, string> = {
  standard: CARD_STANDARD,
  light: CARD_LIGHT,
  compact: CARD_COMPACT,
}

function hasNonEmptyString(value: string | undefined): boolean {
  return value !== undefined && value.trim() !== ''
}

function trimmedTextLength(value: string | undefined): number {
  return value?.trim().length ?? 0
}

function contentState(children: ComponentChildren | undefined): CardContentState {
  if (
    children === undefined ||
    children === null ||
    children === false ||
    children === ''
  ) return 'empty'
  if (typeof children === 'string' || typeof children === 'number') return 'text'
  return 'node'
}

function textLength(children: ComponentChildren | undefined): number {
  if (typeof children === 'string') return children.length
  if (typeof children === 'number') return String(children).length
  return 0
}

function normalizeStatus(status: string | undefined): string {
  return status?.trim().toLowerCase() ?? ''
}

export function surfaceCardClassName({
  variant,
  tone,
  className,
}: {
  variant: CardVariant
  tone?: string
  className?: string
}): string {
  return [VARIANT_CLASSES[variant], tone, className].filter(Boolean).join(' ')
}

export function sectionCardStatusDotTone(status?: string): CardStatusDotTone {
  const normalized = normalizeStatus(status)
  switch (normalized) {
    case 'healthy':
    case 'live':
      return 'ok'
    case 'watch':
      return 'warn'
    case 'danger':
      return 'bad'
    default:
      return statusBadgeTone(normalized) as CardStatusDotTone
  }
}

export interface SurfaceCardProps {
  variant?: CardVariant
  class?: string
  /** Tone class: 'ok' | 'warn' | 'bad' */
  tone?: string
  style?: string
  testId?: string
  children: ComponentChildren
  [key: string]: unknown
}

export function summarizeSurfaceCard({
  variant = 'standard',
  class: cx,
  tone,
  style,
  testId,
  children,
}: SurfaceCardProps): SurfaceCardSummary {
  return {
    variant,
    tone: tone ?? '',
    toneSource: hasNonEmptyString(tone) ? 'tone-class' : 'none',
    hasTone: hasNonEmptyString(tone),
    toneLength: trimmedTextLength(tone),
    hasCustomClass: hasNonEmptyString(cx),
    classNameLength: trimmedTextLength(cx),
    hasStyle: hasNonEmptyString(style),
    styleLength: trimmedTextLength(style),
    hasTestId: hasNonEmptyString(testId),
    testIdLength: trimmedTextLength(testId),
    contentState: contentState(children),
  }
}

export function SurfaceCard({
  variant = 'standard',
  class: cx,
  tone,
  style,
  testId,
  children,
  ...rest
}: SurfaceCardProps) {
  const summary = summarizeSurfaceCard({
    variant,
    class: cx,
    tone,
    style,
    testId,
    children,
  })
  const cls = surfaceCardClassName({ variant, tone, className: cx })
  return html`<div
    class=${cls}
    style=${style}
    data-surface-card
    data-surface-card-variant=${summary.variant}
    data-surface-card-tone=${summary.tone}
    data-surface-card-tone-source=${summary.toneSource}
    data-surface-card-has-tone=${summary.hasTone}
    data-surface-card-tone-length=${summary.toneLength}
    data-surface-card-has-custom-class=${summary.hasCustomClass}
    data-surface-card-class-length=${summary.classNameLength}
    data-surface-card-has-style=${summary.hasStyle}
    data-surface-card-style-length=${summary.styleLength}
    data-surface-card-has-test-id=${summary.hasTestId}
    data-surface-card-test-id-length=${summary.testIdLength}
    data-surface-card-content-state=${summary.contentState}
    data-testid=${testId}
    ...${rest}
  >${children}</div>`
}

// ── Section card with label header ──
export interface SectionCardProps {
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
  [key: string]: unknown
}

function statusDotClass(status?: string): string {
  return statusDotColor(sectionCardStatusDotTone(status))
}

export function summarizeSectionCard({
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
}: SectionCardProps): SectionCardSummary {
  const sectionLabel = label ?? title
  const normalizedStatus = normalizeStatus(status)
  const hasStatus = normalizedStatus !== ''
  const labelSource =
    label != null ? 'label' :
      title != null ? 'title' :
        'empty'
  const tailSource =
    right != null ? 'right' :
      eyebrow != null || hasStatus ? 'status-eyebrow' :
        'none'
  const effectiveTestId = testId ?? dataTestId

  return {
    variant,
    bodyPadding: variant === 'compact' ? 'p-3.5' : 'p-4',
    labelSource,
    labelState: contentState(sectionLabel),
    labelTextLength: textLength(sectionLabel),
    tailSource,
    status: status ?? '',
    normalizedStatus,
    statusDotTone: sectionCardStatusDotTone(status),
    hasStatus,
    statusLength: normalizedStatus.length,
    hasEyebrow: eyebrow != null,
    eyebrowState: contentState(eyebrow),
    eyebrowTextLength: textLength(eyebrow),
    hasRightSlot: right != null,
    hasTone: hasNonEmptyString(tone),
    toneLength: trimmedTextLength(tone),
    hasCustomClass: hasNonEmptyString(cx),
    classNameLength: trimmedTextLength(cx),
    hasTestId: hasNonEmptyString(effectiveTestId),
    testIdLength: trimmedTextLength(effectiveTestId),
    contentState: contentState(children),
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
  ...rest
}: SectionCardProps) {
  // SPEC `.section-head` upgrade — SectionHead atom replaces the
  // legacy SectionHeader. The strip wants to sit flush against the
  // card's top edge, so the outer SurfaceCard padding is forced to 0
  // (overflow-hidden lets the strip clip into the rounded-[var(--r-1)] corner) and
  // the body padding moves into a dedicated wrapper. The `light`
  // variant deliberately keeps the bg-transparent override — the
  // SectionHead's bg-surface still reads as a strip because it sits
  // above transparent body. Variant `compact` had p-3.5 in the legacy
  // path; the new wrapper uses p-3.5 to preserve that visual.
  const summary = summarizeSectionCard({
    label,
    title,
    right,
    eyebrow,
    status,
    tone,
    class: cx,
    variant,
    testId,
    'data-testid': dataTestId,
    children,
  })
  const bodyPadding = summary.bodyPadding
  const sectionLabel = label ?? title ?? ''
  const tail = right ?? (
    eyebrow != null || summary.hasStatus
      ? html`
          <span class="inline-flex items-center gap-1.5 text-2xs text-[var(--color-fg-muted)]">
            ${summary.hasStatus ? html`<span class="h-1.5 w-1.5 rounded-full ${statusDotClass(status)}" />` : null}
            ${eyebrow != null ? html`<span>${eyebrow}</span>` : null}
          </span>
        `
      : null
  )
  const effectiveTestId = testId ?? dataTestId
  const rootClass = surfaceCardClassName({
    variant,
    tone,
    className: ['flex flex-col !p-0 overflow-hidden', cx].filter(Boolean).join(' '),
  })
  return html`
    <div
      class=${rootClass}
      data-surface-card
      data-surface-card-variant=${summary.variant}
      data-surface-card-tone=${tone ?? ''}
      data-surface-card-tone-source=${summary.hasTone ? 'tone-class' : 'none'}
      data-surface-card-has-tone=${summary.hasTone}
      data-surface-card-tone-length=${summary.toneLength}
      data-surface-card-has-custom-class=${summary.hasCustomClass}
      data-surface-card-class-length=${summary.classNameLength}
      data-surface-card-has-test-id=${summary.hasTestId}
      data-surface-card-test-id-length=${summary.testIdLength}
      data-surface-card-content-state=${summary.contentState}
      data-section-card
      data-section-card-variant=${summary.variant}
      data-section-card-body-padding=${summary.bodyPadding}
      data-section-card-label-source=${summary.labelSource}
      data-section-card-label-state=${summary.labelState}
      data-section-card-label-text-length=${summary.labelTextLength}
      data-section-card-tail-source=${summary.tailSource}
      data-section-card-status=${summary.normalizedStatus}
      data-section-card-status-dot-tone=${summary.statusDotTone}
      data-section-card-has-status=${summary.hasStatus}
      data-section-card-status-length=${summary.statusLength}
      data-section-card-has-eyebrow=${summary.hasEyebrow}
      data-section-card-eyebrow-state=${summary.eyebrowState}
      data-section-card-eyebrow-text-length=${summary.eyebrowTextLength}
      data-section-card-has-right-slot=${summary.hasRightSlot}
      data-section-card-has-tone=${summary.hasTone}
      data-section-card-tone-length=${summary.toneLength}
      data-section-card-has-custom-class=${summary.hasCustomClass}
      data-section-card-class-length=${summary.classNameLength}
      data-section-card-has-test-id=${summary.hasTestId}
      data-section-card-test-id-length=${summary.testIdLength}
      data-section-card-content-state=${summary.contentState}
      data-testid=${effectiveTestId}
      ...${rest}
    >
      <${SectionHead} tail=${tail}>${sectionLabel}<//>
      <div class="${bodyPadding} flex flex-col gap-4">${children}</div>
    </div>
  `
}


// ── Legacy Card (backward compat — accepts title prop) ──
export interface CardProps {
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
