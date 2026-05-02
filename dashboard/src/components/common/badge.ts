// CountBadge / StatusBadge — small pill indicators
// Replaces 20+ inline badge patterns (text-3xs px-1.5 py-px rounded)

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

type BadgeTone = 'default' | 'warn' | 'ok' | 'bad' | 'accent'

const TONE_CLASSES: Record<BadgeTone, string> = {
  default: 'bg-[var(--white-8)] text-[var(--color-fg-muted)]',
  warn: 'bg-[var(--warn-12)] text-[var(--color-status-warn)]',
  ok: 'bg-[var(--ok-10)] text-[var(--ok-20)]',
  bad: 'bg-[var(--bad-10)] text-[var(--bad-light)]',
  accent: 'bg-[var(--accent-12)] text-[var(--color-accent-fg)]',
}

const BASE = 'inline-flex items-center text-3xs px-1.5 py-px rounded-[var(--r-1)] tabular-nums font-medium'

interface CountBadgeProps {
  tone?: BadgeTone
  class?: string
  children: ComponentChildren
}

/** Compact count pill — e.g. task counts, filter chips */
export function CountBadge({ tone = 'default', class: cx, children }: CountBadgeProps) {
  const cls = [BASE, TONE_CLASSES[tone], cx].filter(Boolean).join(' ')
  return html`<span class=${cls}>${children}</span>`
}
