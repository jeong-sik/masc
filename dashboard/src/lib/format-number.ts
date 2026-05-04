// Unified number formatting utilities.

/** Format a 0–1 ratio as percentage string. Returns fallback for null/NaN. */
export function formatPct(value: number | null | undefined, fallback = '-'): string {
  if (value == null || !Number.isFinite(value)) return fallback
  return `${Math.round(value * 100)}%`
}

/** Format a 0–1 ratio as percentage with 1 decimal. Returns fallback for null/NaN. */
export function formatPct1(value: number | null | undefined, fallback = '--'): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback
  return `${(value * 100).toFixed(1)}%`
}

/** Abbreviate large token counts: 1234567 → "1.2M", 4500 → "4.5K".
 *  Distinguishes 0 (valid data) from undefined (no data). */
export function formatTokens(n: number | null | undefined): string {
  if (n == null || !Number.isFinite(n)) return '-'
  if (n === 0) return '0'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`
  return String(n)
}

/** Format a number with locale-aware grouping and configurable decimals.
 *  Returns fallback for null/NaN/undefined. */
export function formatNumber(value: number | null | undefined, digits = 0, fallback = '--'): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback
  return value.toLocaleString('ko-KR', {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  })
}

/** Format a USD cost value. Sub-cent values get 4 decimals; otherwise 2.
 *  Returns fallback for null/NaN/undefined. */
export function formatCost(value: number | null | undefined, fallback = '--'): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback
  if (value === 0) return '$0'
  if (value < 0.01) return `$${value.toFixed(4)}`
  return `$${value.toFixed(2)}`
}
