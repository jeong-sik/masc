// Counter display helpers that separate two semantically distinct shapes:
//
//   1. RatioPair  — invariant: numerator ≤ denominator. Safe to render as
//                   "N/M" because that visually implies a "of-quota" ratio.
//                   Examples: manifest_returned_rows / manifest_total_rows,
//                   provider_attempt_finished_count / provider_attempt_started_count.
//
//   2. IndependentCounters — two monotonic lifetime counters with NO ordering
//                   invariant between them. Rendering as "N/M" implicates a
//                   ratio (e.g. "909/722" reads as 126% used-of-quota) which
//                   is wrong. We render these with explicit labels and a
//                   non-slash separator to remove the ratio implication.
//                   Examples: memory_injected_count vs memory_flushed_count
//                   (injected events and flushed events are independent
//                   lifetime tallies), memory_flush_success_count vs
//                   memory_flush_error_count.
//
// The split exists because we observed live keepers showing "mem 909/722"
// (126%) — telemetry-as-fix anti-pattern where two independent counters were
// jammed into a ratio-shaped UI without typed disambiguation.

export type RatioPair = {
  readonly numerator: number
  readonly denominator: number
}

export type IndependentCounters = {
  readonly leftLabel: string
  readonly leftValue: number
  readonly rightLabel: string
  readonly rightValue: number
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

/**
 * Render two independent counters with labels and a non-slash separator
 * (mid dot). Use this whenever the two counts do NOT have a numerator ≤
 * denominator relationship.
 */
export function formatIndependentCounters(counters: IndependentCounters): string {
  return `${counters.leftLabel} ${counters.leftValue} · ${counters.rightLabel} ${counters.rightValue}`
}
