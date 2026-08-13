export interface DashboardCompositeHealthSource {
  overall_status?: string | null
  operator_action_required?: boolean | null
  operator_action_reasons?: readonly string[]
}

export interface DashboardCompositeHealthIssue {
  kind: 'runtime-health'
  severity: 'warn' | 'bad'
  label: string
  detail: string
}

export type DashboardCompositeHealthVerdict =
  | { state: 'unavailable'; issueCount: 0; issues: readonly [] }
  | { state: 'healthy'; issueCount: 0; issues: readonly [] }
  | {
    state: 'attention'
    severity: 'warn' | 'bad'
    issueCount: 1
    issues: readonly [DashboardCompositeHealthIssue]
  }

/**
 * Projects the backend-owned /health composite verdict without reimplementing
 * its subsystem policy. One composite verdict is one operator-attention item;
 * operator_action_reasons remain evidence rather than a client-side recount.
 */
export function projectDashboardCompositeHealth(
  health: DashboardCompositeHealthSource | null | undefined,
): DashboardCompositeHealthVerdict {
  const status = health?.overall_status?.trim() || null
  const requiresAction = health?.operator_action_required
  if (!status || typeof requiresAction !== 'boolean') {
    return { state: 'unavailable', issueCount: 0, issues: [] }
  }
  if (status === 'ok' && !requiresAction) {
    return { state: 'healthy', issueCount: 0, issues: [] }
  }

  const severity = status === 'blocked' || status === 'error' ? 'bad' : 'warn'
  const reasons = health?.operator_action_reasons?.filter(reason => reason.trim() !== '') ?? []
  return {
    state: 'attention',
    severity,
    issueCount: 1,
    issues: [{
      kind: 'runtime-health',
      severity,
      label: `Runtime health ${status}`,
      detail: reasons.length > 0
        ? `status=${status} · ${reasons.join(' · ')}`
        : `status=${status} · operator_action_required=${requiresAction}`,
    }],
  }
}
