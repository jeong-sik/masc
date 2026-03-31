// Unified number formatting utilities.

/** Format a 0–1 ratio as percentage string. Returns fallback for null/NaN. */
export function formatPct(value: number | null | undefined, fallback = '-'): string {
  if (value == null || !Number.isFinite(value)) return fallback
  return `${Math.round(value * 100)}%`
}

/** Abbreviate large token counts: 1234567 → "1.2M", 4500 → "4.5K". */
export function formatTokens(n: number | undefined): string {
  if (!n) return '-'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`
  return String(n)
}
