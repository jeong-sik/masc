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

/**
 * Classify a crash reason string into a coarse cohort.
 * `null`/`undefined`/empty → 'other'.
 * Matches existing prefix-based cohort assignment in CrashCohortBar.
 */
export function categorizeCrashReason(reason: string | null | undefined): CrashCategory {
  if (!reason) return 'other'
  if (reason.startsWith('heartbeat')) return 'heartbeat'
  if (reason.startsWith('turn')) return 'turn'
  if (reason.startsWith('fiber')) return 'fiber'
  if (reason.startsWith('exception')) return 'exception'
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
