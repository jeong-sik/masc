// Delay schedule for owed failed reads. Successful initializing projections
// await their producer; only actual read failures use these capped delays.
// There is no cumulative attempt limit that can silently discard recovery.

export const WARM_RETRY_DELAYS_MS = [3_000, 5_000, 10_000, 20_000, 30_000]
export const WARM_RETRY_CAP_MS = 30_000

export function warmRetryDelayFor(attempt: number): number {
  // attempt is 1-indexed by callers; clamp to the schedule, falling back
  // to the cap so a misuse never produces 0 / NaN / negative delay.
  if (!Number.isFinite(attempt) || attempt < 1) return WARM_RETRY_DELAYS_MS[0] ?? WARM_RETRY_CAP_MS
  const idx = Math.min(attempt - 1, WARM_RETRY_DELAYS_MS.length - 1)
  const delay = WARM_RETRY_DELAYS_MS[idx]
  return delay ?? WARM_RETRY_CAP_MS
}
