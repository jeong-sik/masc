export interface DashboardCompositeHealthSource {
  overall_status?: string | null
  operator_action_required?: boolean | null
  operator_action_reasons?: readonly string[]
  full_health_snapshot?: {
    status?: 'ready' | 'warming' | 'stale' | 'timeout' | 'error' | null
    stale_reason?: string | null
    last_good_available?: boolean | null
    component_timed_out?: boolean | null
  } | null
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
    state: 'status'
    severity: 'warn' | 'bad'
    issueCount: 0
    issues: readonly [DashboardCompositeHealthIssue]
  }
  | {
    state: 'attention'
    severity: 'warn' | 'bad'
    issueCount: 1
    issues: readonly [DashboardCompositeHealthIssue]
  }

/**
 * Projects the backend-owned /health composite verdict without reimplementing
 * its subsystem policy. A composite verdict contributes one operator-attention
 * item only when the backend explicitly requests action; non-ok or non-fresh
 * status remains visible without being recounted as operator work.
 */
export function projectDashboardCompositeHealth(
  health: DashboardCompositeHealthSource | null | undefined,
): DashboardCompositeHealthVerdict {
  const snapshot = health?.full_health_snapshot
  const snapshotStatus = snapshot?.status ?? null
  const status = health?.overall_status?.trim() || null
  const requiresAction = health?.operator_action_required
  const snapshotUnhealthy = snapshotStatus !== null
    && (snapshotStatus !== 'ready' || snapshot?.component_timed_out === true)
  if (requiresAction !== true && snapshotStatus === null) {
    return { state: 'unavailable', issueCount: 0, issues: [] }
  }

  const effectiveStatus = status ?? snapshotStatus ?? 'unavailable'
  const severity = effectiveStatus === 'blocked' || effectiveStatus === 'error'
    || effectiveStatus === 'timeout' || snapshotStatus === 'error'
    || snapshotStatus === 'timeout' || snapshot?.component_timed_out === true
    ? 'bad'
    : 'warn'
  const reasons = health?.operator_action_reasons?.filter(reason => reason.trim() !== '') ?? []
  const snapshotDetails = snapshotUnhealthy
    ? [
        `snapshot=${snapshotStatus}`,
        snapshot?.component_timed_out === true ? 'component_timed_out=true' : null,
        snapshot?.stale_reason ? `reason=${snapshot.stale_reason}` : null,
        snapshot?.last_good_available === true ? 'last_good_available=true' : null,
      ].filter((detail): detail is string => detail !== null)
    : []
  const issue: DashboardCompositeHealthIssue = {
    kind: 'runtime-health',
    severity,
    label: `Runtime health ${effectiveStatus}`,
    detail: [
      status ? `status=${status}` : null,
      typeof requiresAction === 'boolean'
        ? `operator_action_required=${requiresAction}`
        : null,
      ...reasons,
      ...snapshotDetails,
    ].filter((detail): detail is string => detail !== null).join(' · '),
  }

  if (requiresAction !== true) {
    if (
      status === 'ok'
      && requiresAction === false
      && snapshotStatus === 'ready'
      && snapshot?.component_timed_out === false
    ) {
      return { state: 'healthy', issueCount: 0, issues: [] }
    }
    return {
      state: 'status',
      severity,
      issueCount: 0,
      issues: [issue],
    }
  }

  return {
    state: 'attention',
    severity,
    issueCount: 1,
    issues: [issue],
  }
}
