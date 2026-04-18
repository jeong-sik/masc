// SectionCap — uppercase tracking-wider tiny heading primitive.
//
// Reference UIs (Linear right-panel section caps, Vercel project
// sidebar headers, Stripe dashboard overview labels): the 10px
// all-caps 0.05em-tracked label is the universal "here starts a
// small section" marker. Recognizing it instantly gives the reader
// a grid: subhead above, content below, more whitespace before the
// next one. Inline Tailwind strings scattered across ~20 files
// always drift within weeks (tracking-1 vs tracking-4
// vs tracking-[0.18em] — pixel-noise differences that break the
// grid silently).
//
// Two axes because the existing usage already uses them:
//  - `tone`   — muted (default, section heads next to body text)
//             / dim (stronger hush, dense telemetry panels)
//  - `weight` — normal (read-only narrative labels, feature-health)
//             / semibold (pressable subhead, keeper-tool-telemetry
//                         column headers, tool-allowlist sections)
//
// Tone tokens resolve through the Tailwind v4 `@theme` (tokens.css):
//   text-text-muted → var(--color-text-muted)
//   text-text-dim   → var(--color-text-dim)
// Using the generated utility instead of `text-[var(--text-muted)]`
// keeps purge predictable, autocomplete honest, and fixes the
// `text-text-muted` / `text-[var(--text-muted)]` / `text-[var(--text-muted)]`
// trident drift the audit surfaced.
//
// NOT a replacement for:
//  - `Kbd` (keyboard shortcut pill — has <kbd> semantics)
//  - `CountBadge` (numeric pill — tabular-nums + tone background)
//  - `StatusChip` (status pill — rounded-sm + border + tone)
// SectionCap is a *label*, not a *chip*. It has no border/background
// by default and renders as <div> so flexbox stacking works without
// the caller reaching for inline-block overrides.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

type SectionCapTone = 'muted' | 'dim'
type SectionCapWeight = 'normal' | 'semibold'

const BASE = 'text-3xs uppercase tracking-wider'

const TONE: Record<SectionCapTone, string> = {
  muted: 'text-text-muted',
  dim: 'text-text-dim',
}

const WEIGHT: Record<SectionCapWeight, string> = {
  normal: '',
  semibold: 'font-semibold',
}

/** Pure: class string for a given tone/weight + optional extra
    (caller margin, inline-flex composition, border-b, bg). Exposed
    so callers that wrap their own element (e.g. a <summary> that
    needs ::marker overrides) stay pixel-identical. */
export function sectionCapClasses(
  tone: SectionCapTone = 'muted',
  weight: SectionCapWeight = 'normal',
  extra?: string,
): string {
  const parts = [BASE, TONE[tone]]
  const w = WEIGHT[weight]
  if (w !== '') parts.push(w)
  if (extra !== undefined && extra !== '') parts.push(extra)
  return parts.join(' ')
}

interface SectionCapProps {
  tone?: SectionCapTone
  weight?: SectionCapWeight
  /** Additional Tailwind classes for margin, inline-flex composition,
      border-b, bg, etc. Caller-owned because layout concerns
      (mb-1, flex items-center, border-b) belong to the caller row,
      not the heading primitive. */
  class?: string
  children?: ComponentChildren
  testId?: string
}

export function SectionCap({
  tone = 'muted',
  weight = 'normal',
  class: cx,
  children,
  testId,
}: SectionCapProps) {
  const cls = sectionCapClasses(tone, weight, cx)
  return html`<div
    class=${cls}
    data-section-cap
    data-section-cap-tone=${tone}
    data-section-cap-weight=${weight}
    data-testid=${testId}
  >${children}</div>`
}
