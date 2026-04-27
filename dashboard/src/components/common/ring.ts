// Ring — focus / selection / inner-highlight ring atom (helper-only).
//
// Tailwind ring utilities are CSS, not a component — but the *combinations*
// drift wildly across dashboard. Audit (2026-04-27, 18 callsites with
// `ring-1|ring-2|ring-accent|ring-inset`):
//
//   13 sites — keyboard focus indicator
//              `focus-visible:outline-none focus-visible:ring-1 ring-accent`
//              with 5 distinct offset/color permutations
//                (`ring-offset-2 ring-offset-[var(--color-bg-page)]`,
//                 `ring-offset-1 ring-offset-bg-1`, `ring-offset-2 ring-offset-[var(--color-bg-surface)]`,
//                 no-offset, `ring-accent/40` color variant).
//    4 sites — persistent selection highlight on list items / event tracks
//              (`ring-2 ring-accent ring-offset-1 ring-offset-bg-1`).
//    1 site  — decorative inner ring on a modal panel
//              (`ring-1 ring-white/5`).
//
// Intent groups:
//
//   focus  — keyboard-only outline. Applied via the `focus-visible:`
//            prefix. Disappears on mouse interaction. Most-used.
//   select — persistent (non-focus) selection indicator. Applied
//            conditionally on isSelected / isActive state.
//   inner  — purely decorative interior outline (no state semantics).
//            Use sparingly — most cards prefer `border` over `ring`.
//
// SPEC mapping: Tailwind v4 ring-* utilities, with kind tones from the
// dashboard token system (`--color-status-ok|warn|err|info`,
// `--color-accent-fg`, `--color-border-strong`, `--white-N`).
//
// Why a helper rather than a VNode component: per
// `feedback_tailwind-only-dashboard`, Preact dashboard uses Tailwind
// utility classes only — no handwritten CSS, no wrapper components for
// pure styling. Ring stays in the same idiom as `kbdClasses()` /
// `statusChipClasses()` / `idPillClasses()`.

export type RingTone =
  | 'accent'
  | 'accent-soft'
  | 'border'
  | 'muted'
  | 'ok'
  | 'warn'
  | 'bad'
  | 'info'

export type RingWidth = 1 | 2

export type RingOffset = 0 | 1 | 2

/** Color token for the ring *offset gap*. The offset is a transparent
 *  band between the ring and the element bg, so its color must match
 *  the *parent surface*, not the element itself. Three values cover
 *  the 5 callsite permutations seen in the audit. */
export type RingOffsetSurface = 'page' | 'surface' | 'bg-1'

const TONE_CLASS: Record<RingTone, string> = {
  accent: 'ring-accent',
  // `accent-soft` = `ring-accent/40` — same hue, half-strength.
  // Used by agent-detail.ts:286 anchor underline focus, where a
  // full-strength accent ring would compete with the underline.
  'accent-soft': 'ring-accent/40',
  border: 'ring-[var(--color-border-strong)]',
  muted: 'ring-white/5',
  ok: 'ring-[var(--color-status-ok)]',
  warn: 'ring-[var(--color-status-warn)]',
  bad: 'ring-[var(--color-status-err)]',
  info: 'ring-[var(--color-status-info)]',
}

const WIDTH_CLASS: Record<RingWidth, string> = {
  1: 'ring-1',
  2: 'ring-2',
}

const OFFSET_SURFACE_CLASS: Record<RingOffsetSurface, string> = {
  page: 'ring-offset-[var(--color-bg-page)]',
  surface: 'ring-offset-[var(--color-bg-surface)]',
  'bg-1': 'ring-offset-bg-1',
}

export interface RingFocusOpts {
  /** Tone token. Default `accent` — matches the existing 13 callsites. */
  tone?: RingTone
  /** Ring stroke width in 1px units. Default `1`. Use `2` for primary
   *  controls / dialog buttons where the focus needs to be unambiguous. */
  width?: RingWidth
  /** Offset gap between the ring and the element. Default `0` (ring
   *  hugs the element). Use `1` or `2` when the element sits on a
   *  surface that would otherwise blend into the ring. */
  offset?: RingOffset
  /** Color of the offset gap (must match parent surface). Required
   *  whenever `offset > 0`, otherwise the offset would render as the
   *  wrong color. Default `page`. */
  offsetSurface?: RingOffsetSurface
  /** Focus ring uses the `focus-visible:` Tailwind variant by default
   *  (keyboard-only). Set `false` to use bare `focus:` (mouse + keyboard
   *  — rare, but matches a few legacy callsites). */
  visible?: boolean
}

/** Compose the canonical focus-ring class string.
 *
 *  Default produces:
 *    `focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-accent`
 *
 *  The `outline-none` reset is included because every callsite in the
 *  audit pairs the ring with `outline-none` to suppress the browser's
 *  native focus ring (which would otherwise stack with the Tailwind
 *  ring and produce a doubled outline). Forgetting it is a frequent
 *  drift bug — the helper bakes it in.
 */
export function ringFocusClasses(opts: RingFocusOpts = {}): string {
  const tone = opts.tone ?? 'accent'
  const width = opts.width ?? 1
  const offset = opts.offset ?? 0
  const visible = opts.visible !== false
  const prefix = visible ? 'focus-visible:' : 'focus:'

  const parts: string[] = [
    `${prefix}outline-none`,
    `${prefix}${WIDTH_CLASS[width]}`,
    `${prefix}${TONE_CLASS[tone]}`,
  ]

  if (offset > 0) {
    parts.push(`${prefix}ring-offset-${offset}`)
    const offsetSurface = opts.offsetSurface ?? 'page'
    parts.push(`${prefix}${OFFSET_SURFACE_CLASS[offsetSurface]}`)
  }

  return parts.join(' ')
}

export interface RingSelectOpts {
  tone?: RingTone
  width?: RingWidth
  offset?: RingOffset
  offsetSurface?: RingOffsetSurface
}

/** Compose a persistent (non-focus) selection ring. Apply
 *  conditionally based on `isSelected` / `isActive` state.
 *
 *  Default: `ring-2 ring-accent` — matches the dominant select pattern
 *  on event-track / tool-call-track (selection vs hover distinction
 *  needs higher visual weight than focus). */
export function ringSelectClasses(opts: RingSelectOpts = {}): string {
  const tone = opts.tone ?? 'accent'
  const width = opts.width ?? 2
  const offset = opts.offset ?? 0

  const parts: string[] = [WIDTH_CLASS[width], TONE_CLASS[tone]]

  if (offset > 0) {
    parts.push(`ring-offset-${offset}`)
    const offsetSurface = opts.offsetSurface ?? 'bg-1'
    parts.push(OFFSET_SURFACE_CLASS[offsetSurface])
  }

  return parts.join(' ')
}

/** Compose a decorative inner ring (no state semantics). Use sparingly
 *  — most cards prefer `border` over `ring`. The single audit callsite
 *  (agent-detail.ts:249 modal panel) uses `ring-1 ring-white/5`, mapped
 *  here to tone=`muted` width=1. */
export function ringInnerClasses(
  tone: RingTone = 'muted',
  width: RingWidth = 1,
): string {
  return `${WIDTH_CLASS[width]} ${TONE_CLASS[tone]}`
}
