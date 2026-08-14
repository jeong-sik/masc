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
/**
 * The closed set `overall_status` can carry, mirroring OCaml
 * `Health_status.to_string` (`lib/types/health_status.mli`). Kept as a parsed
 * view rather than the wire field's type: the field stays `string` because
 * that is what the transport delivers, and an unrecognized value is a fact the
 * dashboard must react to rather than a shape it can assume away.
 */
type FleetStatus =
  | 'ok'
  | 'warming'
  | 'snapshot_not_ready'
  | 'degraded'
  | 'stale'
  | 'warning'
  | 'unavailable'
  | 'unknown'
  | 'blocked'
  | 'error'
  | 'timeout'

/**
 * Mirrors `Health_status.rank status >= 3`. The switch is exhaustive on
 * purpose: a status added to the OCaml variant without a decision here becomes
 * a compile error instead of silently ranking as a warning.
 */
function rankThreeStatus(status: FleetStatus): boolean {
  switch (status) {
    case 'blocked':
    case 'error':
    case 'timeout':
      return true
    case 'ok':
    case 'warming':
    case 'snapshot_not_ready':
    case 'degraded':
    case 'stale':
    case 'warning':
    case 'unavailable':
    case 'unknown':
      return false
  }
}

const FLEET_STATUSES: readonly FleetStatus[] = [
  'ok',
  'warming',
  'snapshot_not_ready',
  'degraded',
  'stale',
  'warning',
  'unavailable',
  'unknown',
  'blocked',
  'error',
  'timeout',
]

/**
 * True when the backend's fleet status warrants the loud tone. An unrecognized
 * status also returns true: the dashboard and the backend disagree about the
 * vocabulary, and an operator should see that rather than have it rendered as
 * a warning indistinguishable from a healthy-but-busy fleet.
 */
function fleetStatusIsBad(status: string | null): boolean {
  if (status === null) return false
  const known = FLEET_STATUSES.find(candidate => candidate === status)
  return known === undefined ? true : rankThreeStatus(known)
}

export function projectDashboardCompositeHealth(
  health: DashboardCompositeHealthSource | null | undefined,
): DashboardCompositeHealthVerdict {
  const snapshot = health?.full_health_snapshot
  const snapshotStatus = snapshot?.status ?? null
  const status = health?.overall_status?.trim() || null
  const requiresAction = health?.operator_action_required
  const snapshotUnhealthy = snapshotStatus !== null
    && (snapshotStatus !== 'ready' || snapshot?.component_timed_out === true)
  if (requiresAction !== true && snapshotStatus === null && status === null) {
    return { state: 'unavailable', issueCount: 0, issues: [] }
  }

  const effectiveStatus = status ?? snapshotStatus ?? 'unavailable'
  // Two independent backend axes, judged separately. `overall_status` carries
  // `Health_status.rank`; `operator_action_required` is computed from component
  // flags and can be true while the rank sits below 3 (live 2026-08-14:
  // overall_status=degraded with operator_action_required=true). Folding them
  // into one string comparison dropped the second axis.
  const severity: 'warn' | 'bad' =
    requiresAction === true
    || fleetStatusIsBad(status)
    || snapshotStatus === 'error'
    || snapshotStatus === 'timeout'
    || snapshot?.component_timed_out === true
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
