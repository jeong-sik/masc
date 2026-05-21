// Pure helpers for keeper-supervisor-diagnostics.
// Kept separate so they are unit-testable without preact rendering.

import type { KeeperSupervisorCrashLogEntry } from '../types'

export type CrashCategory = 'heartbeat' | 'turn' | 'fiber' | 'exception' | 'other'

export const CRASH_CATEGORY_KEYS: readonly CrashCategory[] = [
  'heartbeat',
  'turn',
  'fiber',
  'exception',
  'other',
] as const

// Known crash-reason prefixes emitted by the supervisor.
// The backend constructs free-form strings like "heartbeat_timeout",
// "turn_execution_failed", "fiber_crash", "Exception: …" — the prefix
// determines the cohort. Kept as an explicit prefix→category map so new
// prefixes require an entry here rather than falling through silently.
const CRASH_PREFIX_MAP: ReadonlyArray<{ readonly prefix: string; readonly category: CrashCategory }> = [
  { prefix: 'heartbeat', category: 'heartbeat' },
  { prefix: 'turn', category: 'turn' },
  { prefix: 'fiber', category: 'fiber' },
  { prefix: 'exception', category: 'exception' },
]

export function categorizeCrashReason(reason: string | null | undefined): CrashCategory {
  if (!reason) return 'other'
  const lower = reason.toLowerCase()
  for (const { prefix, category } of CRASH_PREFIX_MAP) {
    if (lower.startsWith(prefix)) return category
  }
  return 'other'
}

/**
 * Tally crash entries by cohort. Categories with zero entries are omitted.
 */
export function groupCrashCohorts(
  crash_log: readonly KeeperSupervisorCrashLogEntry[],
): Partial<Record<CrashCategory, number>> {
  const cohorts: Partial<Record<CrashCategory, number>> = {}
  for (const e of crash_log) {
    const key = categorizeCrashReason(e.reason)
    cohorts[key] = (cohorts[key] ?? 0) + 1
  }
  return cohorts
}

/**
 * Filter crash entries by selected category. `'all'` returns the input unchanged.
 * Returns a new array (does not mutate input).
 */
export function filterCrashLog(
  crash_log: readonly KeeperSupervisorCrashLogEntry[],
  category: 'all' | CrashCategory,
): KeeperSupervisorCrashLogEntry[] {
  if (category === 'all') return crash_log.slice()
  return crash_log.filter((e) => categorizeCrashReason(e.reason) === category)
}
