// CountBadge / StatusBadge — small pill indicators
// Replaces 20+ inline badge patterns (text-[10px] px-1.5 py-px rounded)

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

type BadgeTone = 'default' | 'warn' | 'ok' | 'bad' | 'accent'

const TONE_CLASSES: Record<BadgeTone, string> = {
  default: 'bg-[var(--white-8)] text-[var(--text-muted)]',
  warn: 'bg-[var(--warn-12)] text-[var(--warn)]',
  ok: 'bg-[rgba(74,222,128,0.12)] text-[#86efac]',
  bad: 'bg-[rgba(251,113,133,0.12)] text-[#fda4af]',
  accent: 'bg-[var(--accent-12)] text-[var(--accent)]',
}

const BASE = 'inline-flex items-center text-[10px] px-1.5 py-px rounded tabular-nums font-medium'

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

// ── Status dot + label ──
type StatusKind = 'online' | 'offline' | 'warning' | 'busy'

const STATUS_DOT: Record<StatusKind, string> = {
  online: 'bg-[var(--ok)] shadow-[0_0_6px_rgba(74,222,128,0.6)]',
  offline: 'bg-[var(--text-dim)]',
  warning: 'bg-[var(--warn)]',
  busy: 'bg-[var(--accent)]',
}

const STATUS_TEXT: Record<StatusKind, string> = {
  online: 'text-[#86efac]',
  offline: 'text-[var(--text-dim)]',
  warning: 'text-[var(--warn)]',
  busy: 'text-[var(--accent)]',
}

interface StatusDotProps {
  status: StatusKind
  label?: string
}

/** Colored dot with optional label — connection status, agent status */
export function StatusDot({ status, label }: StatusDotProps) {
  return html`
    <span class="inline-flex items-center gap-1.5">
      <span class="size-[7px] rounded-full ${STATUS_DOT[status]}"></span>
      ${label ? html`<span class="text-[10px] ${STATUS_TEXT[status]}">${label}</span>` : null}
    </span>
  `
}
