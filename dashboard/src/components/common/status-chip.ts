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
// ~12 caller sites already pass children (runtime-config-panel,
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
import { pillClasses } from './pill'

export type StatusChipTone =
  | 'ok'
  | 'warn'
  | 'bad'
  | 'info'
  | 'neutral'
  | 'paused'
  | 'select'
  | ''

export type StatusChipContentSource = 'children' | 'empty'

export interface StatusChipSummary {
  readonly tone: string
  readonly isSemanticTone: boolean
  readonly contentSource: StatusChipContentSource
  readonly uppercase: boolean
  readonly hasCustomClass: boolean
  readonly hasTestId: boolean
  readonly classNameLength: number
  readonly testIdLength: number
}

// Tone class strings + base shape now live in `pill.ts` (single source — the
// convergence). StatusChip keeps only its own public tone-enum membership so
// its type guard stays honest: the `volt` accent is Pill-only, not a
// StatusChip tone.
const STATUS_CHIP_TONES: ReadonlySet<string> = new Set([
  'ok', 'warn', 'bad', 'info', 'neutral', 'paused', 'select', '',
])

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
  return STATUS_CHIP_TONES.has(tone)
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
  // Delegates to the converged engine; output is byte-identical to the prior
  // inline implementation (pill.ts CHIP_TONE === the old SEMANTIC_TONE).
  return pillClasses(tone, { uppercase, extra })
}

function hasChildrenContent(children: ComponentChildren | undefined): boolean {
  return children !== undefined && children !== null
}

export function summarizeStatusChip({
  tone = '',
  className,
  uppercase = true,
  children,
  testId,
}: {
  tone?: string
  className?: string
  uppercase?: boolean
  children?: ComponentChildren
  testId?: string
}): StatusChipSummary {
  const contentSource = hasChildrenContent(children) ? 'children' : 'empty'

  return {
    tone,
    isSemanticTone: isSemanticTone(tone),
    contentSource,
    uppercase,
    hasCustomClass: className !== undefined && className !== '',
    hasTestId: testId !== undefined && testId !== '',
    classNameLength: className?.length ?? 0,
    testIdLength: testId?.length ?? 0,
  }
}

export interface StatusChipProps {
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
  title?: string
  children?: ComponentChildren
  testId?: string
}

export function StatusChip({
  tone = '',
  class: cx,
  uppercase = true,
  title,
  children,
  testId,
}: StatusChipProps) {
  const summary = summarizeStatusChip({
    tone,
    className: cx,
    uppercase,
    children,
    testId,
  })
  const cls = statusChipClasses(tone, cx, uppercase)
  const content = summary.contentSource === 'children' ? children : ''
  return html`<span
    class=${cls}
    data-status-chip
    data-status-chip-tone=${summary.tone}
    data-status-chip-is-semantic-tone=${summary.isSemanticTone}
    data-status-chip-content-source=${summary.contentSource}
    data-status-chip-uppercase=${summary.uppercase ? 'true' : 'false'}
    data-status-chip-has-custom-class=${summary.hasCustomClass}
    data-status-chip-has-test-id=${summary.hasTestId}
    data-status-chip-class-length=${summary.classNameLength}
    data-status-chip-test-id-length=${summary.testIdLength}
    title=${title}
    data-testid=${testId}
  >${content}</span>`
}
