// What keeps a runtime from answering, apart from a quota rest.
//
// GET /api/v1/runtime/resolved carries three facts next to quota_rest
// (lib/server/server_dashboard_runtime_resolved_json.ml): a refused credential,
// this process's own 429 observation, and the last attempt that failed without
// answering. The TUI reads them in this order
// (lib/masc_tui/screens_domain/screen_runtime.ml standing_override_for):
// refused credential, then quota rest, then a live rate limit, then the failed
// attempt. A refused credential or a live rate limit means the runtime does not
// answer now, so it is not counted as available. A failed attempt does not stop
// the lane walk (it tries the runtime after the ones that answered), so it is
// shown but still counted as available.

import type { RuntimeAttemptFailure, RuntimeFailedAttempt, RuntimeResolution } from './types'

export type RuntimeLivenessBlock =
  | { readonly kind: 'credential_refused'; readonly since: number }
  | { readonly kind: 'rate_limited'; readonly resetsAt: number | null }

export interface RuntimeLivenessRow {
  readonly runtime: RuntimeResolution
  readonly block: RuntimeLivenessBlock | null
  readonly failedAttempt: RuntimeFailedAttempt | null
}

/** The fact that stops this runtime answering now, or null when the payload
 *  states none. A rate limit whose stated reset has passed no longer blocks,
 *  as in the TUI; one without a stated reset holds until a call succeeds. */
export function runtimeLivenessBlock(rt: RuntimeResolution, nowUnix: number): RuntimeLivenessBlock | null {
  if (typeof rt.credential_refused_at === 'number') {
    return { kind: 'credential_refused', since: rt.credential_refused_at }
  }
  if (rt.rate_limited !== true) return null
  const resetsAt = rt.rate_limit_resets_at ?? null
  if (resetsAt !== null && resetsAt <= nowUnix) return null
  return { kind: 'rate_limited', resetsAt }
}

/** Runtimes with a liveness fact to show, quota-resting ones excluded: the
 *  quota panel already lists those, and the TUI shows quota rest over a rate
 *  limit or a failed attempt. A refused credential is listed even on a
 *  resting runtime because the TUI puts it first. */
export function collectRuntimeLiveness(
  runtimes: readonly RuntimeResolution[],
  nowUnix: number,
): readonly RuntimeLivenessRow[] {
  const rows: RuntimeLivenessRow[] = []
  for (const runtime of runtimes) {
    const block = runtimeLivenessBlock(runtime, nowUnix)
    if (runtime.quota_rest !== null && block?.kind !== 'credential_refused') continue
    const failedAttempt = runtime.failed_attempt ?? null
    if (block === null && failedAttempt === null) continue
    rows.push({ runtime, block, failedAttempt })
  }
  return rows
}

/** Whether the runtime answers calls now as far as the payload says. */
export function runtimeIsAvailable(rt: RuntimeResolution, nowUnix: number): boolean {
  return rt.quota_rest === null && runtimeLivenessBlock(rt, nowUnix) === null
}

export function attemptFailureLabel(failure: RuntimeAttemptFailure): string {
  switch (failure) {
    case 'server_error':
      return '서버 오류'
    case 'provider_capacity':
      return '제공자 용량 부족'
    case 'network_transient':
      return '네트워크 일시 오류'
    case 'provider_timeout':
      return '제공자 응답 시간 초과'
  }
}
