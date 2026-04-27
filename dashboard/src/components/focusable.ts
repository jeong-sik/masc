// Focusable — atomic primitive ported from design-system v0.4
// primitives.html "Focus ring" section (`<input class="focusable">`,
// `<button class="focusable">`). The SPEC defines an opt-in brass
// double-ring keyboard focus treatment that supersedes the dashboard's
// default global single-ring. SPEC primitives.css line 279-280:
//
//   .focusable:focus-visible       { box-shadow: var(--focus-ring); }
//   .focusable.is-err:focus-visible { box-shadow: var(--focus-ring-err); }
//
// Where `--focus-ring` is the brass double-ring (1px solid brass + 3px
// translucent brass glow) and `--focus-ring-err` swaps brass for err
// status. The CSS side lives in dashboard/src/styles/a11y.css next to
// the global `:focus-visible` rule so the layering relationship is
// explicit: global single-ring is the default; `.focusable` upgrades.
//
// This module is the *helper SSOT* — callers use the `focusable()`
// function rather than reaching for raw `class="focusable"` strings,
// so an eslint rule (future) can flag bare-string usage and force
// authors through this module. Same fidelity contract as chip.ts /
// pill.ts / btn.ts / elev.ts: dashboard owns runtime tokens, atom owns
// SPEC translation.
//
// Usage:
//   <input class=${focusable()} />
//   <input class=${focusable({ err: true })} />
//   <button class=${`btn ${focusable()}`}>...</button>
//
// The class string composes with arbitrary user classes via template-
// literal concatenation; the helper does not own combinator logic
// because callers already pass user classes through atom `class` props
// (see Btn / Elev) and adding another collapse path here would
// duplicate that responsibility.

export const FOCUSABLE_CLASS = 'focusable'
export const FOCUSABLE_ERR_CLASS = 'focusable is-err'

export interface FocusableOptions {
  /** When true, the focus ring uses err-status tokens instead of
   *  brass. Pair with form input invalid states or destructive
   *  controls that have an error condition. */
  err?: boolean
}

/** Returns the SPEC-canonical class string for the brass double-ring
 *  focus treatment. Pass `{ err: true }` to swap brass for err status.
 *
 *  The result is a literal class fragment — caller composes with
 *  layout / atom classes via template literals or join helpers. */
export function focusable(opts?: FocusableOptions): string {
  return opts?.err === true ? FOCUSABLE_ERR_CLASS : FOCUSABLE_CLASS
}
