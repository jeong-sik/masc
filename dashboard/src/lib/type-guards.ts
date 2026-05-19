// Low-level type guards shared across all layers (api/, lib/, schemas/, components/).

/** Check if a value is a plain object (not null, not array). */
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
