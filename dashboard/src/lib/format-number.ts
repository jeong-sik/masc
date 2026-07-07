// Unified number formatting utilities.

/** Format a 0–1 ratio as percentage string. Returns fallback for null/NaN. */
export function formatPct(value: number | null | undefined, fallback = '-'): string {
  if (!isFiniteMetricValue(value)) return fallback
  return `${Math.round(value * 100)}%`
}

/** Format a 0–1 ratio as percentage with 1 decimal. Returns fallback for null/NaN. */
export function formatPct1(value: number | null | undefined, fallback = '-'): string {
  if (!isFiniteMetricValue(value)) return fallback
  return `${(value * 100).toFixed(1)}%`
}

/** Abbreviate large token counts: 1234567 → "1.2M", 4500 → "4.5K".
 *  Distinguishes 0 (valid data) from undefined (no data). */
export function formatTokens(n: number | null | undefined): string {
  if (!isFiniteMetricValue(n)) return '-'
  if (n === 0) return '0'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`
  return String(n)
}

/** Format a max-context window as a ctx label: 1_000_000 → "1M ctx",
 *  131072 → "131K ctx", 512 → "512 ctx". Returns null for missing or
 *  non-positive values so callers pick their own fallback ('—', omit, …).
 *  Single owner of the ctx label — the keeper rail and the runtime model
 *  editor previously shipped divergent copies ("1000k ctx" vs "1M ctx"). */
export function formatContextTokens(value: number | null | undefined): string | null {
  if (!isFiniteMetricValue(value) || value <= 0) return null
  if (value >= 1_000_000) return `${Number.parseFloat((value / 1_000_000).toFixed(1))}M ctx`
  if (value >= 1_000) return `${Math.round(value / 1_000)}K ctx`
  return `${value} ctx`
}

/** Format a number with locale-aware grouping and configurable decimals.
 *  Returns fallback for null/NaN/undefined. */
export function formatNumber(value: number | null | undefined, digits = 0, fallback = '--'): string {
  if (!isFiniteMetricValue(value)) return fallback
  return value.toLocaleString('ko-KR', {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  })
}

export function formatTokPerSec(value: number | null | undefined, digits = 1, fallback = '-'): string {
  if (!isFiniteMetricValue(value)) return fallback
  return `${formatNumber(value, digits, fallback)} tok/s`
}

export function deriveTokPerSec(
  tokens: number | null | undefined,
  durationMs: number | null | undefined,
): number | null {
  if (!isFiniteMetricValue(tokens) || !isFiniteMetricValue(durationMs) || durationMs <= 0) return null
  return tokens / (durationMs / 1000)
}

/** Format a USD cost value. Sub-cent values get 4 decimals; otherwise 2.
 *  Returns fallback for null/NaN/undefined. */
export function formatCost(value: number | null | undefined, fallback = '--'): string {
  if (!isFiniteMetricValue(value)) return fallback
  if (value === 0) return '$0'
  if (value < 0.01) return `$${value.toFixed(4)}`
  return `$${value.toFixed(2)}`
}

/** Format millisecond duration as compact string: "3ms", "1.5s", "2.3m".
 *  Returns fallback for null/NaN/undefined/negative. */
export function formatMsCompact(ms: number | null | undefined, fallback = ''): string {
  if (!isFiniteMetricValue(ms) || ms < 0) return fallback
  const rounded = Math.round(ms)
  if (rounded < 1000) return `${rounded}ms`
  if (rounded < 60_000) return `${(rounded / 1000).toFixed(1)}s`
  return `${(rounded / 60_000).toFixed(1)}m`
}

/**
 * Type predicate for "a finite numeric metric value". Narrows
 * `number | null | undefined` (the wire shape for nullable metrics)
 * down to `number` so callers can plot or compare directly.
 *
 * `keeper-detail-charts.ts` and `keeper-detail-telemetry.ts` shipped
 * this body file-internal with the same signature; the inline copies
 * are deleted in the same change that exports this helper.
 */
export function isFiniteMetricValue(value: number | null | undefined): value is number {
  return typeof value === 'number' && Number.isFinite(value)
}

/**
 * Clamp a percentage value into the `[0, 100]` range. Width-style
 * renderers, badge colour thresholds, and quality-score normalisers
 * all need this exact body — three callsites previously inlined
 * `Math.max(0, Math.min(100, ...))` (plus `progress-bar.ts` shipped
 * a file-internal `clampProgressPct` helper with this body).
 *
 * Does not handle `NaN`: a `NaN` input returns `NaN`. Pair with
 * `isFiniteMetricValue` if the input could be invalid.
 */
export function clampPct(value: number): number {
  return Math.max(0, Math.min(100, value))
}
