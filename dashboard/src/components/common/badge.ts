// CountBadge / StatusBadge — small pill indicators
// Replaces 20+ inline badge patterns (text-3xs px-1.5 py-px rounded-[var(--r-1)])

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

export type BadgeTone = 'default' | 'warn' | 'ok' | 'bad' | 'accent'

export interface CountBadgeSummary {
  readonly tone: BadgeTone
  readonly hasCustomClass: boolean
  readonly customClassLength: number
}

export interface CountBadgeProps {
  tone?: BadgeTone
  class?: string
  children?: ComponentChildren
}

const TONE_CLASSES: Record<BadgeTone, string> = {
  default: 'bg-surface-muted text-text-secondary',
  warn: 'bg-warning/10 text-warning',
  ok: 'bg-success/10 text-success',
  bad: 'bg-destructive/10 text-destructive',
  accent: 'bg-brand/10 text-brand',
}

const BASE = 'inline-flex items-center text-[12px] px-1.5 py-px rounded-md tabular-nums font-medium uppercase tracking-[0.05em]'

export function countBadgeClasses(tone: BadgeTone = 'default', extra?: string): string {
  return [BASE, TONE_CLASSES[tone], extra].filter(Boolean).join(' ')
}

export function summarizeCountBadge({
  tone = 'default',
  class: classProp,
}: Pick<CountBadgeProps, 'tone' | 'class'>): CountBadgeSummary {
  return {
    tone,
    hasCustomClass: classProp !== undefined && classProp !== '',
    customClassLength: classProp?.length ?? 0,
  }
}

/** Compact count pill — e.g. task counts, filter chips */
export function CountBadge({ tone = 'default', class: cx, children }: CountBadgeProps) {
  const summary = summarizeCountBadge({ tone, class: cx })
  const cls = countBadgeClasses(tone, cx)
  return html`<span
    class=${cls}
    data-count-badge
    data-count-badge-tone=${summary.tone}
    data-count-badge-has-custom-class=${summary.hasCustomClass}
    data-count-badge-custom-class-length=${summary.customClassLength}
  >${children}</span>`
}
