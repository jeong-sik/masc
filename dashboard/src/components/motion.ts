// Motion — atomic primitive ported from design-system v0.4 primitives.html
// "Motion" section. The SPEC defines four named, general-purpose
// animations:
//
//   anim-heartbeat  — 1.4s scale+opacity pulse for live keeper signals
//   anim-pulse-glow — 2.4s opacity wave for completion / waiting surfaces
//   anim-shimmer    — 1.5s linear gradient sweep for skeleton placeholders
//   anim-blink      — 1s step caret blink
//
// All four ride a `prefers-reduced-motion: reduce` gate via the global
// rule in a11y.css line 77 (`* { animation-duration: 0s !important; }`)
// — atom-level reduced-motion handling is not needed because the gate
// already covers any animation by name pattern.
//
// SPEC fidelity: matches design-system/source_styles/primitives.css
// `.anim-{heartbeat,pulse-glow,shimmer,blink}` selectors (lines 341,
// 347, 348, 352-359). Same fidelity contract as focusable.ts: dashboard
// owns the keyframe declarations (styles/keyframes.css), atom owns the
// SPEC translation (this module + the helper SSOT pattern).
//
// Helper module shape rather than Preact wrapper because animations
// apply *to* an element via class composition — wrapping would
// introduce a parent that doesn't share the animation target. Same
// architectural argument as atom 13/14 (focusable).
//
// Usage:
//   <span class={motion('heartbeat')} />
//   <span class={motion('pulseGlow')} />
//   <div class={motion('shimmer')} style={{ width: 140, height: 14 }} />
//   <span class={motion('blink')}>|</span>
//
// Composes via template literals like focusable():
//   <button class={`btn ${motion('pulseGlow')}`}>...</button>

export const MOTION_HEARTBEAT_CLASS = 'anim-heartbeat'
export const MOTION_PULSE_GLOW_CLASS = 'anim-pulse-glow'
export const MOTION_SHIMMER_CLASS = 'anim-shimmer'
export const MOTION_BLINK_CLASS = 'anim-blink'

/** Discriminated union of the four SPEC motion tokens. The keys are
 *  camelCased TypeScript-friendly variants of the kebab-cased SPEC
 *  class suffixes (`pulse-glow` -> `pulseGlow`). */
export type MotionKind = 'heartbeat' | 'pulseGlow' | 'shimmer' | 'blink'

const MOTION_CLASS: Record<MotionKind, string> = {
  heartbeat: MOTION_HEARTBEAT_CLASS,
  pulseGlow: MOTION_PULSE_GLOW_CLASS,
  shimmer: MOTION_SHIMMER_CLASS,
  blink: MOTION_BLINK_CLASS,
}

/** Returns the SPEC class string for the named motion. The exhaustive
 *  `MotionKind` keeps callsites honest — adding a new SPEC motion
 *  later requires extending the union, the constant, and the keyframe
 *  CSS in lockstep. */
export function motion(kind: MotionKind): string {
  return MOTION_CLASS[kind]
}
