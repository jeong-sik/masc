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

type CountBadgeSummaryInput = Pick<CountBadgeProps, 'tone' | 'class'> & {
  /** Back-compat alias for older pure callers. `class` wins when both exist. */
  className?: string
}

const TONE_CLASSES: Record<BadgeTone, string> = {
  default: 'bg-[var(--color-bg-hover)] text-[var(--color-fg-muted)]',
  warn: 'bg-[var(--warn-12)] text-[var(--color-status-warn)]',
  ok: 'bg-[var(--ok-10)] text-[var(--ok-20)]',
  bad: 'bg-[var(--bad-10)] text-[var(--bad-light)]',
  accent: 'bg-[var(--accent-12)] text-[var(--color-accent-fg)]',
}

const BASE = 'inline-flex items-center text-3xs px-1.5 py-px rounded-[var(--r-1)] tabular-nums font-medium'

export function countBadgeClasses(tone: BadgeTone = 'default', extra?: string): string {
  return [BASE, TONE_CLASSES[tone], extra].filter(Boolean).join(' ')
}

export function summarizeCountBadge({
  tone = 'default',
  class: classProp,
  className,
}: CountBadgeSummaryInput): CountBadgeSummary {
  const customClass = classProp ?? className
  return {
    tone,
    hasCustomClass: customClass !== undefined && customClass !== '',
    customClassLength: customClass?.length ?? 0,
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
