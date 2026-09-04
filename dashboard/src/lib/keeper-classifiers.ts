/**
 * RFC-0174: Centralized typed classifiers for keeper status/phase/verdict strings.
 *
 * Every function takes `string` input from backend wire-format and returns a
 * typed result. Unknown inputs map to explicit fallbacks (null, false, or
 * 'unknown') — never silently accepted as a valid variant.
 *
 * Pattern follows `keeper-store-normalize.ts` (`BACKEND_PHASE_LOWERCASE_MAP`
 * + compile-time coverage checks).
 */

// ── Keeper priority (journey-waterfall sorting) ──────────

export type KeeperPriority = 1 | 2 | 3

// Agent/keeper status SSOT: values from `types/core.ts#AgentStatus` plus
// backend-emitted defaults (`'offline'`, `'unknown'`). Trajectory content
// types (`'thinking'`, `'tool_use'`) are NOT keeper statuses — they live
// in a different axis (trajectory event kind).
const ACTIVE_STATUSES: ReadonlySet<string> = new Set([
  'active', 'running', 'busy', 'listening', 'claimed', 'in_progress',
])

/** Terminal statuses for waterfall priority — does NOT include 'crashed'
 *  (a crashed keeper was recently active, so it gets priority 2, not 3). */
const PRIORITY_TERMINAL_STATUSES: ReadonlySet<string> = new Set([
  'offline', 'inactive', 'stopped',
])

/** Offline display statuses — includes 'crashed' (keeper is not running
 *  but was recently active) and 'unbooted'/'stopped' (lifecycle terminal).
 *  Used for UI contextual messages, not sorting. */
const OFFLINE_DISPLAY_STATUSES: ReadonlySet<string> = new Set([
  'offline', 'inactive', 'crashed', 'unbooted', 'stopped',
])

/** Classify keeper status into a priority tier for waterfall display ordering.
 *  1 = active, 2 = intermediate (includes crashed), 3 = terminal. */
export function keeperPriority(status: string): KeeperPriority {
  if (ACTIVE_STATUSES.has(status)) return 1
  if (PRIORITY_TERMINAL_STATUSES.has(status)) return 3
  return 2
}

/** True if the status string represents an offline keeper for display purposes.
 *  Includes 'crashed' — the keeper is not currently running. */
export function isOfflineStatus(status: string): boolean {
  return OFFLINE_DISPLAY_STATUSES.has(status)
}

// ── Harness verdict ──────────────────────────────────────
//
// The producer is a closed variant. `lib/eval_calibration.ml:42` serialises
// `Task.Anti_rationalization.Approve | Reject of string` as four
// shapes -- `approve`, `approve:<reason>`, `reject`, and `reject:<reason>` --
// and is the only place the `verdict` field is written.
//
// Reading it back with `startsWith` accepted strings the producer cannot make
// (`approvex` read as approve) and misread one it does make: `reject` with no
// colon is a rejection whose reason is empty, but `startsWith('reject:')` is
// false for it, so the summary printed the word "reject" where the reason
// goes. Parsing the way the producer's own inverse does -- OCaml splits on
// ':' at line 47, it does not prefix-match -- answers both.

export type HarnessVerdict =
  | { readonly kind: 'approve'; readonly reason: string | null }
  | { readonly kind: 'reject'; readonly reason: string | null }
  | { readonly kind: 'unknown'; readonly raw: string }

export function parseHarnessVerdict(raw: string): HarnessVerdict {
  if (!raw) return { kind: 'unknown', raw: '' }
  const [head, ...rest] = raw.split(':')
  if (head === 'approve') {
    const reason = rest.join(':').trim()
    return { kind: 'approve', reason: reason === '' ? null : reason }
  }
  if (head === 'reject') {
    const reason = rest.join(':').trim()
    return { kind: 'reject', reason: reason === '' ? null : reason }
  }
  return { kind: 'unknown', raw }
}

/** What the verdict cell shows: the rejection's reason, or the verdict itself. */
export function verdictSummaryText(raw: string): string {
  const verdict = parseHarnessVerdict(raw)
  switch (verdict.kind) {
    case 'approve':
      return verdict.reason ?? 'approve'
    case 'reject':
      return verdict.reason ?? '(no reject reason)'
    case 'unknown':
      return verdict.raw
  }
}

/** CSS tone class for verdict display. An unparsable verdict is not an
 *  approval, so it keeps the error tone rather than reading as one. */
export function verdictToneClass(raw: string): string {
  return parseHarnessVerdict(raw).kind === 'approve'
    ? 'bg-[var(--color-status-ok)]'
    : 'bg-[var(--color-status-err)]'
}

// ── Rail status message ──────────────────────────────────

/** Derive a Korean status message from rail status strings.
 *  Returns null when no actionable message is warranted. */
export function railStatusMessage(statuses: string[]): string | null {
  if (statuses.includes('warning')) return '감시 채널에 주의가 필요합니다.'
  if (statuses.includes('stale')) return '신호는 있지만 최신성이 떨어집니다.'
  return null
}
