// Unified string formatting utilities.

/**
 * User-visible sentinel string for missing scalar data in panel rows.
 *
 * `'--'` is the dashboard's convention for "value not present" in metadata
 * tables (RuntimeMetaRow, ConfigRow, supervisor cohort summary, fleet
 * counts, etc.). Captured here so that a future glyph change — e.g.
 * an em-dash `'—'` for typography polish or a longer label for
 * accessibility — propagates without sweeping every `?? '--'` callsite
 * again. Keep this in sync with any user-visible documentation that
 * shows the literal.
 */
export const MISSING_DATA_DASH = '--'

/** Capitalize first character. Returns empty string unchanged. */
export function capitalize(text: string): string {
  if (!text) return text
  return text.charAt(0).toUpperCase() + text.slice(1)
}

/**
 * String presence check without trimming. Treats `''` as absent but keeps
 * whitespace-only strings (`'   '`) as present.
 *
 * Use for attribute presence gates (id/aria-label/title/testId) where raw
 * empty-string is the only absent state and whitespace is technically valid.
 */
export function isNonEmptyString(value: string | undefined): boolean {
  return value !== undefined && value !== ''
}

/**
 * String content check with trimming. Treats `''` and whitespace-only
 * strings (`'   '`) both as absent.
 *
 * Use for content-presence gates (visible label/copy/text) where
 * whitespace-only is functionally equivalent to empty.
 */
export function isNonBlankString(value: string | undefined): boolean {
  return value !== undefined && value.trim() !== ''
}

/**
 * Return the first value that, after trimming, has non-whitespace content.
 *
 * Treats `null`, `undefined`, empty strings, and whitespace-only strings as
 * absent. Returns the trimmed form (not the original) so callers don't have
 * to re-trim. Returns `null` when every input is absent.
 */
export function firstNonEmptyString(
  ...values: ReadonlyArray<string | null | undefined>
): string | null {
  for (const value of values) {
    const trimmed = value?.trim()
    if (trimmed) return trimmed
  }
  return null
}

/**
 * Escape a string for safe interpolation into a `new RegExp(...)` source.
 *
 * Replaces the standard ECMAScript regex meta-characters with their
 * backslash-escaped form so the input is matched literally. Use whenever
 * a user-supplied or interpolated string ends up inside a `RegExp` —
 * e.g. building a needle pattern, asserting a CSS token literal in a
 * test, etc.
 *
 * Two file-internal copies (`components/ide/ide-editor.ts` needle
 * highlighting, `styles/cockpit-token-cascade.test.ts` CSS literal
 * assertions) shipped this exact body before centralising here.
 */
export function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/**
 * Coerce an `unknown` caught error (try/catch, Promise reject) to a
 * display-ready string. Returns `err.message` when `err` is an `Error`
 * instance, otherwise routes through `String(err)` — which preserves
 * `'null'` / `'undefined'` distinctions and stringifies primitives.
 *
 * Differs from `fleet-telemetry-utils.errorMessageOrUnknown`, which
 * collapses every non-Error to the literal `'unknown error'`. Keep
 * both — `errorToString` surfaces the raw form (right for toast
 * messages and console logs), while the other is appropriate when a
 * stable display label is needed.
 *
 * ~45 call sites currently inline this exact ternary across
 * `dashboard-ws`, `lib/async-state` (file-internal helper),
 * `api/mcp`, `components/cascade-config-panel`,
 * `components/cascade-inspector`, `components/cascade-waterfall`,
 * `components/excuse-patterns`, `components/git-graph-view`,
 * `components/goal-loop-panel`, `components/goals/goal-tree`,
 * `components/handoff-timeline`, `components/ide/execute-output-drawer`,
 * `components/ide/ide-branch-context-panel`,
 * `components/ide/interject-store`, `components/journey-panel`,
 * `components/keeper-chat-panel`, `components/keeper-reactivity-monitor`,
 * `components/keeper-spawn/keeper-spawn-state`,
 * `components/prometheus-metrics`, `components/task-manage/task-manage-state`,
 * `components/telemetry-unified`,
 * `components/tool-executor/tool-executor-state`,
 * `components/tool-executor/tool-result-display`,
 * `components/tools/config-resolution-panel`,
 * `components/tools/prompt-registry-panel`,
 * `components/verification-requests-panel`, etc. Callsite migration is
 * staged separately (see follow-up PR).
 */
export function errorToString(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}
