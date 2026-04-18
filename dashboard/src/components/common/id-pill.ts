// IdPill — rounded-md accent pill for identifier-style tokens
// (task ids, agent run tokens, object handles). Distinct from
// StatusChip (rounded-sm semantic status badge) and Kbd (keyboard
// shortcut pill): IdPill is *flat value surface* — the reader sees
// it and knows "this is the ID of the thing", not its status.
//
// Reference UIs (Linear issue id badge, GitHub commit SHA pill,
// Vercel deployment hash, Stripe object id chip): small accent-
// tinted rounded-md badges with monospace option for hashes/SHAs.
//
// Before this primitive, agent-detail.ts had three sites re-
// implementing the same accent-tinted identifier pill shape
// (TaskSummary task.id, TaskHistoryPanel row.taskId, archived-
// participant label). Subtle drift across them: lines 117/128
// used `py-1 px-2.5 shadow-sm`, line 229 had drifted to `py-1
// px-2` (tighter). Primitive normalises to px-2.5 + shadow-sm —
// 229 widens ~4px which the flex-wrap parent absorbs without
// overflow. P4 of the 9-PR dashboard hygiene sweep.
//
// Scope note — what IdPill is NOT absorbing in this PR:
// • agent-detail:224 (secondaryLabel) — `px-2 py-0.5` no border,
//   different pill shape (name tag, not id badge). P7 rounded
//   sweep.
// • agent-detail:228 (unified.description) — neutral tone with
//   drifted opacities (bg-white/5 border-white/10). Needs a
//   neutral tone variant which itself has drift vs line 230
//   (mono version: reversed bg-white/10 border-white/5). Both
//   belong in P6 color normalisation.
// • agent-detail:230 (agent.model) — mono neutral pill with
//   reversed opacities to 228. P6.
// • agent-detail-worker:45 (signal_truth) — `rounded-sm` with
//   raw `rgba(71,184,255,0.36)` border. That is StatusChip
//   shape with an untypeable border, not IdPill shape. P6 when
//   raw rgba colors resolve to CSS vars.
//
// Keeping the primitive single-axis (mono flag only) avoids
// variant sprawl; neutral-tone expansion lands in P6 where the
// opacity drift itself gets audited.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

const BASE =
  'inline-flex items-center text-[10px] font-medium py-1 px-2.5 rounded-md whitespace-nowrap shadow-sm border'
const TONE_ACCENT =
  'border-accent/20 bg-[var(--accent-10)] text-accent'
const MONO_CLASS = 'font-mono'

/** Pure: class string for an IdPill, with optional monospace and
    extra class composition. Exposed so callers that wrap the pill
    in a non-span element (e.g. a `<button>` with IdPill shape)
    stay visually consistent without mounting the component. */
export function idPillClasses(
  mono: boolean = false,
  extra?: string,
): string {
  const parts = [BASE, TONE_ACCENT]
  if (mono) parts.push(MONO_CLASS)
  if (extra !== undefined && extra !== '') parts.push(extra)
  return parts.join(' ')
}

interface IdPillProps {
  /** The identifier text (task id, hash, token). Children win
      over implicit whitespace — callers typically pass a string. */
  children?: ComponentChildren
  /** Render with `font-mono` (for hashes, SHAs, tokens, paths).
      Default false (proportional font matches ID convention for
      task slugs and agent runtime names). */
  mono?: boolean
  /** Extra Tailwind classes for caller composition — parent group-
      hover states (`group-hover:bg-accent/20 transition-colors`),
      margin/width, custom title attribute. The primitive
      deliberately does not know about parent `group` context. */
  class?: string
  /** HTML title attribute — tooltip on hover. Matches the existing
      `title={unified.description}` usage in agent-detail.ts:228. */
  title?: string
  testId?: string
}

export function IdPill({
  children,
  mono = false,
  class: cx,
  title,
  testId,
}: IdPillProps) {
  const cls = idPillClasses(mono, cx)
  return html`<span
    class=${cls}
    data-id-pill
    data-id-pill-mono=${mono ? 'true' : 'false'}
    title=${title}
    data-testid=${testId}
  >${children}</span>`
}
