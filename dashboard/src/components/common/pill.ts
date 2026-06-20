// Pill — the converged tone-pill primitive (keeper-v2 design system).
//
// The keeper-v2 design collapses a family of forked `*Pill/*Badge/*Chip`
// spans into ONE `<Pill>` with a tone + a few shape variants. This file is
// the canonical class engine + component for the bordered tone-pill shape
// (the StatusChip lineage, generalised): semantic tones, a `volt` accent,
// and `uppercase` / `mono` / `soft` / `dot` modifiers.
//
// Convergence path (see docs/design/dashboard-pill-convergence.md):
//   - `status-chip.ts` delegates its class assembly here (no fork; 33 callers
//     keep their API + `data-*` contract; output is byte-identical).
//   - Forked tone-pills across feature components migrate to `<Pill>` in
//     follow-up PRs (one family per PR).
//   - `badge.ts` (CountBadge, count shape) and `status-badge.ts` (`.status-badge`
//     CSS-utility shape) are a DIFFERENT styling lineage and are reconciled
//     separately — they are intentionally NOT routed through this engine yet.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

/** Semantic tones, plus the design's `volt` accent. A raw Tailwind class
 *  string (e.g. the output of a `verdictTone()` helper) is also accepted by
 *  {@link pillClasses} and passes through verbatim — exactly as the previous
 *  `statusChipClasses` did. */
export type PillTone =
  | 'neutral'
  | 'ok'
  | 'warn'
  | 'bad'
  | 'info'
  | 'volt'
  | 'paused'
  | 'select'

/** Bordered-chip tone palette. `''` aliases `neutral` so an unset tone renders
 *  the muted pill (the StatusChip default). `volt` mirrors the `--volt-*`
 *  triple used by settings-surface/StatCell (`--volt-strong` === `--brand`). */
const CHIP_TONE: Record<string, string> = {
  neutral: 'border-border bg-surface-subtle text-text-tertiary',
  '': 'border-border bg-surface-subtle text-text-tertiary',
  ok: 'border-success/20 bg-success/10 text-success',
  warn: 'border-warning/20 bg-warning/10 text-warning',
  bad: 'border-destructive/20 bg-destructive/10 text-destructive',
  info: 'border-brand/20 bg-brand/10 text-brand',
  volt: 'border-[var(--volt-dim)] bg-[var(--volt-wash)] text-[var(--volt-strong)]',
  paused: 'border-[var(--paused-20)] bg-[var(--paused-10)] text-[var(--paused)]',
  select: 'border-[var(--select-20)] bg-[var(--select-10)] text-[var(--select)]',
}

const CHIP_SHAPE =
  'inline-flex items-center rounded-[var(--r-0)] border px-2 py-0.5 text-[11px]'
const UPPERCASE_CLASS = 'uppercase tracking-[0.05em]'
const MONO_CLASS = 'font-mono'

/** True when `tone` is a known semantic tone (incl. `''` and `volt`). Raw
 *  Tailwind strings fall through as `false` so they compose verbatim. Exposed
 *  so `status-chip.ts` and higher-level helpers branch on one source. */
export function isPillTone(tone: string): boolean {
  return tone in CHIP_TONE
}

export interface PillClassOptions {
  /** Render `uppercase tracking-[0.05em]` (default true). Set false for plain
   *  tag pills (file paths, enum values) where all-caps changes the grammar. */
  uppercase?: boolean
  /** Monospace face (former FsmChip). */
  mono?: boolean
  /** Transparent ground (former TraitPill): keep border + text, drop the bg. */
  soft?: boolean
  /** Extra caller classes (margin, shrink-0, …) appended last. */
  extra?: string
}

/** Pure class engine for the bordered tone-pill. Shape tokens are always
 *  present; `uppercase`/`mono` are conditional; a semantic `tone` maps to the
 *  palette while a raw Tailwind string passes through. `soft` strips the bg
 *  token from the resolved tone class.
 *
 *  Invariant: `pillClasses(tone, { uppercase, extra })` reproduces the previous
 *  `statusChipClasses(tone, extra, uppercase)` byte-for-byte (mono/soft default
 *  off contribute nothing and do not reorder the existing tokens). */
export function pillClasses(tone: string = '', opts: PillClassOptions = {}): string {
  const { uppercase = true, mono = false, soft = false, extra } = opts
  // isPillTone guarantees the key exists; `?? ''` only satisfies
  // noUncheckedIndexedAccess (never taken for a real tone).
  let toneClass = isPillTone(tone) ? (CHIP_TONE[tone] ?? '') : tone
  if (soft && toneClass !== '') {
    toneClass = toneClass.replace(/\s*\bbg-\S+/g, '').trim()
  }
  const parts = [CHIP_SHAPE]
  if (uppercase) parts.push(UPPERCASE_CLASS)
  if (mono) parts.push(MONO_CLASS)
  if (toneClass !== '') parts.push(toneClass)
  if (extra !== undefined && extra !== '') parts.push(extra)
  return parts.join(' ')
}

export interface PillSummary {
  readonly tone: string
  readonly isSemanticTone: boolean
  readonly uppercase: boolean
  readonly hasDot: boolean
  readonly contentSource: 'children' | 'empty'
  readonly hasCustomClass: boolean
  readonly hasTestId: boolean
}

export interface PillProps {
  /** A {@link PillTone} member, or a raw Tailwind class string (passthrough). */
  tone?: PillTone | string
  /** Leading status pip, coloured by the tone (currentColor). */
  dot?: boolean
  dotPulse?: boolean
  uppercase?: boolean
  mono?: boolean
  soft?: boolean
  class?: string
  title?: string
  testId?: string
  children?: ComponentChildren
}

/** Pure: the Pill's render-independent metadata (mirrors the `summarize*`
 *  pattern used by the other common primitives so behaviour is unit-testable
 *  without a DOM). */
export function summarizePill({
  tone = 'neutral',
  uppercase = true,
  dot = false,
  class: cx,
  testId,
  children,
}: Pick<PillProps, 'tone' | 'uppercase' | 'dot' | 'class' | 'testId' | 'children'>): PillSummary {
  return {
    tone,
    isSemanticTone: isPillTone(tone),
    uppercase,
    hasDot: dot,
    contentSource: children !== undefined && children !== null ? 'children' : 'empty',
    hasCustomClass: cx !== undefined && cx !== '',
    hasTestId: testId !== undefined && testId !== '',
  }
}

/** The converged tone-pill. New code and migrated forks render `<Pill>`;
 *  `status-chip.ts` shares this engine. */
export function Pill({
  tone = 'neutral',
  dot = false,
  dotPulse = false,
  uppercase = true,
  mono = false,
  soft = false,
  class: cx,
  title,
  testId,
  children,
}: PillProps) {
  const summary = summarizePill({ tone, uppercase, dot, class: cx, testId, children })
  const cls = pillClasses(tone, { uppercase, mono, soft, extra: cx })
  const dotCls = `size-1.5 rounded-full bg-current${dotPulse ? ' animate-pulse' : ''}${dot ? ' mr-1.5' : ''}`
  return html`<span
    class=${cls}
    data-pill
    data-pill-tone=${tone}
    data-pill-semantic-tone=${summary.isSemanticTone}
    data-pill-uppercase=${summary.uppercase ? 'true' : 'false'}
    data-pill-has-dot=${summary.hasDot}
    data-pill-content-source=${summary.contentSource}
    data-pill-has-custom-class=${summary.hasCustomClass}
    data-pill-has-test-id=${summary.hasTestId}
    title=${title}
    data-testid=${testId}
  >${dot ? html`<span class=${dotCls}></span>` : null}${children}</span>`
}
