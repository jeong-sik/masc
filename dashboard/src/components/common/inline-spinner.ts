// InlineSpinner — tiny border-based spinner that sits inline with text.
//
// Reference UIs (GitHub PR checks \"pending\" spinner, Vercel deployment
// log row inline spinner, Linear sync dot, Stripe in-flight inline):
// a small border-circle-with-transparent-top-border is the canonical
// \"something is happening right here\" indicator. Distinct from
// LoadingState (a large centered Loader2 with breathing room) and
// LivePulseDot (an animate-pulse state marker). This primitive is the
// spin-in-the-middle-of-a-sentence variant.
//
// Pre-change the dashboard had 5+ call sites with near-identical
// Tailwind strings:
//   inline-block h-3 w-3 rounded-full border-2
//     border-[var(--color-accent-fg)] border-t-transparent animate-spin
// This primitive pins the canonical 3 sizes + 2 tones.

import { html } from 'htm/preact'

export type InlineSpinnerSize = 'xs' | 'sm' | 'md'
export type InlineSpinnerTone = 'accent' | 'muted'

export interface InlineSpinnerSummary {
  readonly size: InlineSpinnerSize
  readonly tone: InlineSpinnerTone
  readonly hasSemanticLabel: boolean
  readonly hasCustomClass: boolean
  readonly hasTestId: boolean
  readonly ariaLabelLength: number
  readonly classNameLength: number
  readonly testIdLength: number
}

/** Pure: Tailwind size tokens for each variant. Exposed so a hot-path
    render (timeline rows, log tail, iterating progress lists) can
    compose the class once without mounting N components. */
export function inlineSpinnerSizeClass(size: InlineSpinnerSize = 'sm'): string {
  switch (size) {
    case 'xs': return 'h-2.5 w-2.5 border-2'
    case 'sm': return 'h-3 w-3 border-2'
    case 'md': return 'h-4 w-4 border-2'
  }
}

/** Pure: Tailwind tone classes. Accent is the default (\"I'm working
    on it\" confirmation); muted is the subtle \"background sync\"
    variant for when the spinner is secondary to the row it lives in. */
export function inlineSpinnerToneClass(tone: InlineSpinnerTone = 'accent'): string {
  return tone === 'accent'
    ? 'border-[var(--color-accent-fg)] border-t-transparent'
    : 'border-[var(--color-fg-disabled)] border-t-transparent'
}

const BASE = 'inline-block rounded-full animate-spin shrink-0'

/** Pure: full class string. Exposed so callers that wrap their own
    span (e.g. conditionally-rendered inside a denser flex row) stay
    pixel-identical to the primitive. */
export function inlineSpinnerClasses(
  size: InlineSpinnerSize = 'sm',
  tone: InlineSpinnerTone = 'accent',
  extra?: string,
): string {
  const parts = [BASE, inlineSpinnerSizeClass(size), inlineSpinnerToneClass(tone)]
  if (extra !== undefined && extra !== '') parts.push(extra)
  return parts.join(' ')
}

export function normalizeInlineSpinnerAriaLabel(ariaLabel?: string): string | undefined {
  const normalized = ariaLabel?.trim()
  return normalized === undefined || normalized === '' ? undefined : normalized
}

export function summarizeInlineSpinner({
  size = 'sm',
  tone = 'accent',
  className,
  ariaLabel,
  testId,
}: {
  size?: InlineSpinnerSize
  tone?: InlineSpinnerTone
  className?: string
  ariaLabel?: string
  testId?: string
}): InlineSpinnerSummary {
  const normalizedAriaLabel = normalizeInlineSpinnerAriaLabel(ariaLabel)
  return {
    size,
    tone,
    hasSemanticLabel: normalizedAriaLabel !== undefined,
    hasCustomClass: className !== undefined && className !== '',
    hasTestId: testId !== undefined && testId !== '',
    ariaLabelLength: normalizedAriaLabel?.length ?? 0,
    classNameLength: className?.length ?? 0,
    testIdLength: testId?.length ?? 0,
  }
}

export interface InlineSpinnerProps {
  size?: InlineSpinnerSize
  tone?: InlineSpinnerTone
  class?: string
  /** Override the decorative default. Setting a non-empty label flips to role=\"status\"
      (screen-reader announces the loading state) instead of
      aria-hidden. Use when the spinner is the ONLY indication of
      progress — otherwise a nearby text label already carries it. */
  ariaLabel?: string
  testId?: string
}

export function InlineSpinner({
  size = 'sm',
  tone = 'accent',
  class: cx,
  ariaLabel,
  testId,
}: InlineSpinnerProps) {
  const summary = summarizeInlineSpinner({
    size,
    tone,
    className: cx,
    ariaLabel,
    testId,
  })
  const normalizedAriaLabel = normalizeInlineSpinnerAriaLabel(ariaLabel)
  const cls = inlineSpinnerClasses(size, tone, cx)
  return html`<span
    class=${cls}
    role=${summary.hasSemanticLabel ? 'status' : undefined}
    aria-label=${normalizedAriaLabel}
    aria-hidden=${summary.hasSemanticLabel ? undefined : 'true'}
    data-inline-spinner
    data-inline-spinner-size=${summary.size}
    data-inline-spinner-tone=${summary.tone}
    data-inline-spinner-has-semantic-label=${summary.hasSemanticLabel}
    data-inline-spinner-has-custom-class=${summary.hasCustomClass}
    data-inline-spinner-has-test-id=${summary.hasTestId}
    data-inline-spinner-aria-label-length=${summary.ariaLabelLength}
    data-inline-spinner-class-length=${summary.classNameLength}
    data-inline-spinner-test-id-length=${summary.testIdLength}
    data-testid=${testId}
  ></span>`
}
