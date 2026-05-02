// StatusChip — rounded-[var(--r-0)] status/tag pill.
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
// at all, while calls like `<StatusChip tone="bg-[var(--color-status-ok)]">`
// (verdictTone helper) rendered correctly. This rewrite closes the
// gap without breaking either caller shape:
//   - Semantic tones ('ok'|'warn'|'bad'|'info'|'neutral'|'') map
//     to Tailwind classes inside the primitive.
//   - Raw Tailwind class strings (e.g. "bg-[var(--color-status-ok)]") pass
//     through unchanged as extra classes.
// Caller helpers continue to work without audit.
//
// Also adds `children` support. The prior API was label-only but
// ~12 caller sites already pass children (cascade-config-panel,
// verification-requests-panel.test mocks). Accepting both keeps
// every existing usage compiling while the caller mix converges.
//
// P3 update — `uppercase` prop (default true) splits the shape
// tokens (rounded-[var(--r-0)] + border + px-2 py-0.5 + text-3xs) from
// the uppercase/tracking-wider pair. `uppercase={false}` renders
// a plain (non-uppercase, non-tracked) neutral pill — the shape
// used by config-resolution-panel's 4 "inline tag" call sites
// (sourceLabel / pathInfo.kind / cache age / resolved config
// root). Those sites were inline Tailwind strings with the exact
// same shape minus the uppercase/tracking — folding them into
// StatusChip removes the last remaining chip-shape duplication
// from that file.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

export type StatusChipTone =
  | 'ok'
  | 'warn'
  | 'bad'
  | 'info'
  | 'neutral'
  | 'paused'
  | 'select'
  | ''

const BASE_SHAPE =
  'inline-flex items-center rounded-[var(--r-0)] border px-2 py-0.5 text-3xs'
const UPPERCASE_CLASS = 'uppercase tracking-wider'

const SEMANTIC_TONE: Record<StatusChipTone, string> = {
  ok: 'border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--color-status-ok)]',
  warn: 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--color-status-warn)]',
  bad: 'border-[var(--bad-20)] bg-[var(--bad-10)] text-[var(--bad-light)]',
  info: 'border-[var(--accent-20)] bg-[var(--accent-10)] text-[var(--color-accent-fg)]',
  neutral: 'border-[var(--white-10)] bg-[var(--white-5)] text-[var(--color-fg-muted)]',
  paused: 'border-[var(--paused-20)] bg-[var(--paused-10)] text-[var(--paused)]',
  select: 'border-[var(--select-20)] bg-[var(--select-10)] text-[var(--select)]',
  '': 'border-[var(--white-10)] bg-[var(--white-5)] text-[var(--color-fg-muted)]',
}

/** Keeper lifecycle state → StatusChip tone.
 *
 * Accepts both vocabularies in use across the codebase:
 *
 *   1. Design-system / backend FSM names from the Anyang Sleepers
 *      spec: running, compacting, handing_off, draining, failing,
 *      overflowed, restarting, paused, stopped, crashed, dead,
 *      offline.
 *
 *   2. Dashboard-layer names defined in `types/core.ts#KeeperLifecycleState`
 *      and the live agent `status` union: active, preparing,
 *      handoff-imminent, idle, unbooted, busy, listening, inactive.
 *
 * Both collapse into the same five visual groups the design system
 * prescribes (ok / working / warn / paused / error), with inactive
 * variants landing in neutral. Unknown strings return 'neutral'
 * rather than throwing so a backend-added state renders as muted
 * until this map is updated — a row of 40 keepers should not crash
 * on vocabulary drift.
 */
export function keeperStateTone(state: string): StatusChipTone {
  switch (state) {
    // ok — live and serving
    case 'running':
    case 'active':
      return 'ok'
    // working — in flight, not actionable
    case 'compacting':
    case 'handing_off':
    case 'handoff-imminent':
    case 'draining':
    case 'preparing':
    case 'listening':
      return 'info'
    // warn — degraded but not yet dead
    case 'failing':
    case 'overflowed':
    case 'restarting':
    case 'busy':
      return 'warn'
    // paused — human or governor paused
    case 'paused':
      return 'paused'
    // error — crash / lost
    case 'crashed':
    case 'dead':
      return 'bad'
    // inactive — offline / stopped / never started
    case 'stopped':
    case 'offline':
    case 'idle':
    case 'unbooted':
    case 'inactive':
      return 'neutral'
    default:
      return 'neutral'
  }
}

/** Pure: true when `tone` is one of the semantic enum members. Raw
    Tailwind class strings (`bg-[var(--color-status-ok)]`) fall through and are
    composed as-is. Exposed so higher-level helpers can branch. */
export function isSemanticTone(tone: string): tone is StatusChipTone {
  return tone in SEMANTIC_TONE
}

/** Pure: class string for given tone + optional extra + optional
    uppercase flag (default true). Handles the semantic/raw tone
    dichotomy so callers never have to.

    Shape tokens (rounded-[var(--r-0)] + border + px-2 py-0.5 + text-3xs)
    are always present. `uppercase + tracking-wider` is conditional
    on the `uppercase` flag — callers rendering plain tag pills
    (no all-caps) pass `uppercase={false}` to drop both together. */
export function statusChipClasses(
  tone: string = '',
  extra?: string,
  uppercase: boolean = true,
): string {
  const toneClass = isSemanticTone(tone) ? SEMANTIC_TONE[tone] : tone
  const parts = [BASE_SHAPE]
  if (uppercase) parts.push(UPPERCASE_CLASS)
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
  /** Render with `uppercase tracking-wider` (default true). Set
      false for plain tag pills (e.g. neutral "inline label" chips
      where uppercase would change the visual grammar — typically
      file paths, enum values, short textual tags). */
  uppercase?: boolean
  children?: ComponentChildren
  testId?: string
}

export function StatusChip({
  label,
  tone = '',
  class: cx,
  uppercase = true,
  children,
  testId,
}: StatusChipProps) {
  const cls = statusChipClasses(tone, cx, uppercase)
  const content = children ?? label ?? ''
  return html`<span
    class=${cls}
    data-status-chip
    data-status-chip-tone=${tone}
    data-status-chip-uppercase=${uppercase ? 'true' : 'false'}
    data-testid=${testId}
  >${content}</span>`
}
