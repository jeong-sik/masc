// Low-level type guards shared across all layers (api/, lib/, schemas/, components/).

/** Check if a value is a plain object (not null, not array). */
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Check that a record field exists, is a string, and contains non-whitespace content.
 *
 * Distinguished from `common/*` value-based `hasNonEmptyString(value)` by signature
 * (record + key vs value-only) — keep names different so callers can't mix them up.
 */
export function hasNonEmptyStringField(
  record: Record<string, unknown>,
  key: string,
): boolean {
  const value = record[key]
  return typeof value === 'string' && value.trim() !== ''
}
