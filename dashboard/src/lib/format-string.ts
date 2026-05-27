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
