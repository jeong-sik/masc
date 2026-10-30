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

/**
 * Narrow an `unknown` to `ReadonlyArray<string>` — an array whose every
 * element is a string. Used wherever a JSON-decoded field is expected to
 * be a string list but the wire format is `unknown`.
 *
 * `keeper-detail-history.ts` and `ide/run-activity-store.ts` shipped this
 * exact body file-internal (the first as `value is string[]`, the
 * second as `value is ReadonlyArray<string>`). The wider readonly form
 * accommodates both call sites — TypeScript's array variance treats
 * `string[]` as assignable to `ReadonlyArray<string>` in the asserted
 * branch.
 */
export function isStringArray(value: unknown): value is ReadonlyArray<string> {
  return Array.isArray(value) && value.every(item => typeof item === 'string')
}
