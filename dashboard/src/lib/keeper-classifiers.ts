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
  'offline', 'inactive', 'stopped', 'dead',
])

/** Offline display statuses — includes 'crashed' (keeper is not running
 *  but was recently active) and 'unbooted'/'stopped' (lifecycle terminal).
 *  Used for UI contextual messages, not sorting. */
const OFFLINE_DISPLAY_STATUSES: ReadonlySet<string> = new Set([
  'offline', 'inactive', 'dead', 'crashed', 'unbooted', 'stopped',
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

// ── Execution attention code ─────────────────────────────

/** True if an attention code value starts with "satisfied" (no attention needed). */
export function isAttentionCodeSatisfied(code: string): boolean {
  return code.startsWith('satisfied')
}

// ── Crash reason classification (RFC-0174 SSOT source) ───
//
// `LibCrashCategory` and `classifyCrashReasonLib` are the RFC-0174
// source for crash-reason classification. A separate production-side
// variant lives at `components/keeper-supervisor-helpers.ts`
// (`SupervisorCrashCategory` / `categorizeCrashReason`) and diverges on
// the unmatched fallback — this file returns `'unknown'`, the
// supervisor variant returns `'other'`. The two are intentional
// homonyms today (no production callsite of `classifyCrashReasonLib`
// exists, so the supervisor variant is the de-facto production SSOT),
// not a missed unification.
//
// Migrating the supervisor variant onto this RFC-0174 source — which
// would consolidate the diverging fallback literal and the
// `COHORT_COLORS` Record key — is a design call (`'unknown'` is more
// semantically truthful for *classification failure*, `'other'` is more
// UI-friendly as a *displayed bucket label*) and is tracked separately.

export type LibCrashCategory = 'heartbeat' | 'turn' | 'fiber' | 'exception' | 'unknown'

const CRASH_EXACT: ReadonlySet<LibCrashCategory> = new Set<LibCrashCategory>([
  'heartbeat', 'turn', 'fiber', 'exception',
])

const CRASH_PREFIX_MAP: readonly { prefix: string; category: LibCrashCategory }[] = [
  { prefix: 'heartbeat', category: 'heartbeat' },
  { prefix: 'turn', category: 'turn' },
  { prefix: 'fiber', category: 'fiber' },
  { prefix: 'exception', category: 'exception' },
]

/** Classify a raw crash reason string into a typed category.
 *  Exact match preferred over prefix matching to avoid ambiguity.
 *  RFC-0174 SSOT source — see file-level note for divergence from the
 *  production `categorizeCrashReason` UI helper. */
export function classifyCrashReasonLib(raw: string): LibCrashCategory {
  const lower = raw.toLowerCase()
  if (CRASH_EXACT.has(lower as LibCrashCategory)) return lower as LibCrashCategory
  for (const { prefix, category } of CRASH_PREFIX_MAP) {
    if (lower.startsWith(prefix)) return category
  }
  return 'unknown'
}

// ── Harness verdict ──────────────────────────────────────

/** True if a harness verdict string starts with "approve". */
export function isApproveVerdict(verdict: string): boolean {
  return verdict.startsWith('approve')
}

/** Strip "reject:" prefix from verdict, returning the reason or the raw value. */
export function verdictWithoutRejectPrefix(verdict: string): string {
  if (!verdict.startsWith('reject:')) return verdict
  return verdict.slice('reject:'.length).trim() || '(no reject reason)'
}

/** CSS tone class for verdict display. */
export function verdictToneClass(verdict: string): string {
  return isApproveVerdict(verdict)
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
