// Counter display helper for a pair whose numerator never exceeds its
// denominator, rendered as "N/M" (e.g. manifest_returned_rows /
// manifest_total_rows). Two counters without that ordering must not use it:
// "909/722" reads as a 126% ratio.

export type RatioPair = {
  readonly numerator: number
  readonly denominator: number
}

/**
 * Render a ratio pair as "N/M". Caller asserts numerator ≤ denominator
 * as a domain invariant; this helper does not enforce it at runtime
 * because the values originate from backend cumulative counters where a
 * transient over-count is itself a signal worth seeing.
 */
export function formatRatioPair(pair: RatioPair): string {
  return `${pair.numerator}/${pair.denominator}`
}
