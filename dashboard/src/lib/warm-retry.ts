// Warm-up retry schedule shared by the bootstrap reads (namespace truth,
// execution). Exponential backoff replaces a fixed 3 000 ms cadence, which
// kept beating the server at 3 s intervals during cold starts and raced
// Dashboard_cache stampede protection. The schedule (3 s / 5 s / 10 s / 20 s /
// cap 30 s) keeps the worst-case warm-up budget (WARM_MAX_RETRIES retries)
// while smoothing client load.

export const WARM_RETRY_DELAYS_MS = [3_000, 5_000, 10_000, 20_000, 30_000]
export const WARM_RETRY_CAP_MS = 30_000
export const WARM_MAX_RETRIES = 10

export function warmRetryDelayFor(attempt: number): number {
  // attempt is 1-indexed by callers; clamp to the schedule, falling back
  // to the cap so a misuse never produces 0 / NaN / negative delay.
  if (!Number.isFinite(attempt) || attempt < 1) return WARM_RETRY_DELAYS_MS[0] ?? WARM_RETRY_CAP_MS
  const idx = Math.min(attempt - 1, WARM_RETRY_DELAYS_MS.length - 1)
  const delay = WARM_RETRY_DELAYS_MS[idx]
  return delay ?? WARM_RETRY_CAP_MS
}
