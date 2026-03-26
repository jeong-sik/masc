// Unified number formatting utilities.

/** Format a 0–1 ratio as percentage string. Returns fallback for null/NaN. */
export function formatPct(value: number | null | undefined, fallback = '-'): string {
  if (value == null || !Number.isFinite(value)) return fallback
  return `${Math.round(value * 100)}%`
}
