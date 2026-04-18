// StatusChip — rounded-full status/tag pill.
//
// Reference UIs (GitHub label, Linear state badge, Stripe API key
// badge, Vercel deployment state): a 10px uppercase pill with a
// semantic tone background is the universal "this is a tag, not
// prose" visual. The reader's eye picks them out of a row before
// reading content.
//
// Rewrite note: the previous version composed a `cmd-chip` class
// that has no CSS definition anywhere in the repo (audit verified
// with `rg cmd-chip`: zero hits outside this file). The tone param
// was a bare string passed straight into `class=`, which meant
// calls like `<StatusChip tone="warn">` rendered with no styling
// at all, while calls like `<StatusChip tone="bg-[var(--ok)]">`
// (verdictTone helper) rendered correctly. This rewrite closes the
// gap without breaking either caller shape:
//   - Semantic tones ('ok'|'warn'|'bad'|'info'|'neutral'|'') map
//     to Tailwind classes inside the primitive.
//   - Raw Tailwind class strings (e.g. "bg-[var(--ok)]") pass
//     through unchanged as extra classes.
// Caller helpers continue to work without audit.
//
// Also adds `children` support. The prior API was label-only but
// ~12 caller sites already pass children (cascade-config-panel,
// verification-requests-panel.test mocks). Accepting both keeps
// every existing usage compiling while the caller mix converges.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

type StatusChipTone =
  | 'ok'
  | 'warn'
  | 'bad'
  | 'info'
  | 'neutral'
  | 'paused'
  | 'select'
  | ''

const BASE =
  'inline-flex items-center rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-wider'

const SEMANTIC_TONE: Record<StatusChipTone, string> = {
  ok: 'border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--ok)]',
  warn: 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--warn)]',
  bad: 'border-[var(--bad-20)] bg-[var(--bad-10)] text-[var(--bad-light)]',
  info: 'border-[var(--accent-20)] bg-[var(--accent-10)] text-[var(--accent)]',
  neutral: 'border-[var(--white-10)] bg-[var(--white-5)] text-[var(--text-muted)]',
  paused: 'border-[var(--paused-20)] bg-[var(--paused-10)] text-[var(--paused)]',
  select: 'border-[var(--select-20)] bg-[var(--select-10)] text-[var(--select)]',
  '': 'border-[var(--white-10)] bg-[var(--white-5)] text-[var(--text-muted)]',
}

/** 12 keeper lifecycle states → StatusChip tone.
 *
 * Mapping follows the Anyang Sleepers design system: twelve runtime
 * states collapse into five visual groups because an operator
 * reading a row doesn't need crashed vs. dead separated in color —
 * both read as "error". Compaction / handing_off / draining all
 * read as "working", which is the slate/info tone.
 *
 * Exported so every surface that renders keeper status uses the
 * same palette. Takes an unknown string and returns 'neutral' for
 * unrecognised input rather than throwing — a new state added to
 * the backend FSM will render as neutral until this map is updated,
 * which beats a runtime error in a row of 40 keepers.
 */
export function keeperStateTone(state: string): StatusChipTone {
  switch (state) {
    case 'running':
      return 'ok'
    case 'compacting':
    case 'handing_off':
    case 'draining':
      return 'info'
    case 'failing':
    case 'overflowed':
    case 'restarting':
      return 'warn'
    case 'paused':
      return 'paused'
    case 'crashed':
    case 'dead':
      return 'bad'
    case 'stopped':
    case 'offline':
      return 'neutral'
    default:
      return 'neutral'
  }
}

/** Pure: true when `tone` is one of the semantic enum members. Raw
    Tailwind class strings (`bg-[var(--ok)]`) fall through and are
    composed as-is. Exposed so higher-level helpers can branch. */
export function isSemanticTone(tone: string): tone is StatusChipTone {
  return tone in SEMANTIC_TONE
}

/** Pure: class string for given tone + optional extra. Handles the
    semantic/raw dichotomy so callers never have to. Base Tailwind
    tokens (rounded-full + border + px-2 py-0.5 + uppercase +
    tracking-wider) are always present — they are what makes the
    chip visually consistent across the dashboard regardless of
    which tone helper the caller chose. */
export function statusChipClasses(
  tone: string = '',
  extra?: string,
): string {
  const toneClass = isSemanticTone(tone) ? SEMANTIC_TONE[tone] : tone
  const parts = [BASE]
  if (toneClass !== '') parts.push(toneClass)
  if (extra !== undefined && extra !== '') parts.push(extra)
  return parts.join(' ')
}

interface StatusChipProps {
  /** Legacy API — plain text label. Prefer `children` for new
      call sites. When both are set, `children` wins. */
  label?: string
  /** One of the semantic enum members, OR a raw Tailwind class
      string (e.g. the output of `verdictTone()`). Both are valid. */
  tone?: string
  /** Extra Tailwind classes for caller layout (margin, shrink-0). */
  class?: string
  children?: ComponentChildren
  testId?: string
}

export function StatusChip({
  label,
  tone = '',
  class: cx,
  children,
  testId,
}: StatusChipProps) {
  const cls = statusChipClasses(tone, cx)
  const content = children ?? label ?? ''
  return html`<span
    class=${cls}
    data-status-chip
    data-status-chip-tone=${tone}
    data-testid=${testId}
  >${content}</span>`
}
