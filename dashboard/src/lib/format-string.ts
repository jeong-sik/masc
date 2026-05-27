// Unified string formatting utilities.

/** Capitalize first character. Returns empty string unchanged. */
export function capitalize(text: string): string {
  if (!text) return text
  return text.charAt(0).toUpperCase() + text.slice(1)
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
