/** Read metadata shared by the awaiting queue and task-specific verification history. */
export interface VerificationCoverage {
  readonly backlogError: string | null
  readonly backlogRecovery: string | null
  readonly unreadableTotal: number | null
  readonly unresolvedTotal: number | null
  readonly total: number | null
  readonly truncated: boolean
}

export function decodeVerificationCoverage(raw: Record<string, unknown>): VerificationCoverage {
  const reason = (value: unknown): string | null =>
    typeof value === 'string' && value.trim().length > 0 ? value.trim() : null
  const count = (value: unknown): number | null =>
    typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : null
  return {
    backlogError: reason(raw.backlog_error),
    backlogRecovery: reason(raw.backlog_recovery),
    unreadableTotal: count(raw.unreadable_total),
    unresolvedTotal: count(raw.awaiting_unresolved_total),
    total: count(raw.total),
    truncated: raw.truncated === true,
  }
}
