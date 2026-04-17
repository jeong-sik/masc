/**
 * Best-effort dashboard error reporter.
 *
 * - Always calls console.error with a clear tag.
 * - Never throws; all failures are swallowed.
 * - No-op in SSR contexts (no window / no fetch).
 *
 * NOTE: POST is reserved for a future backend endpoint
 * (e.g. `/api/v1/dashboard/errors`). That endpoint does not exist
 * yet, so this reporter is currently console-only. The payload shape
 * the reporter would send is exposed via `buildErrorPayload` so that
 * wiring it in later is a single-site change.
 */
export interface ReporterInfo {
  componentStack?: string
}

const TAG = '[dashboard-error]'

export function reportDashboardError(
  error: Error,
  info: ReporterInfo = {},
): void {
  try {
    console.error(TAG, error, info)
  } catch {
    // console.error itself threw (extremely unusual). Swallow.
  }

  // SSR / non-browser guard. If the caller ever enables a POST branch,
  // it must bail early when fetch or window is unavailable.
  if (typeof window === 'undefined' || typeof fetch === 'undefined') {
    return
  }
}

/**
 * Payload shape the reporter will POST once the backend endpoint ships.
 * Exported for testability and so the contract is visible at import sites.
 *
 * - `stack` is only included when `error.stack` exists.
 * - `url` / `user_agent` are only set in browser contexts.
 */
export function buildErrorPayload(
  error: Error,
  info: ReporterInfo = {},
): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    message: error.message,
    component_stack: info.componentStack,
    url:
      typeof window !== 'undefined' && window.location
        ? window.location.href
        : undefined,
    user_agent:
      typeof navigator !== 'undefined' ? navigator.userAgent : undefined,
    ts: new Date().toISOString(),
  }
  if (error.stack) {
    payload.stack = error.stack
  }
  return payload
}
