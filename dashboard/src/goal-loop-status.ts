import { asBoolean, asInt, asString, isRecord } from './components/common/normalize'

export const GOAL_LOOP_PHASES = ['observe', 'orient', 'decide', 'act', 'verify'] as const

export type GoalLoopPhaseName = typeof GOAL_LOOP_PHASES[number]
export type GoalLoopStatusLevel = 'ok' | 'unknown' | 'warning' | 'critical'

export interface GoalLoopPhase {
  status: GoalLoopStatusLevel
  summary: Record<string, unknown>
}

export interface GoalLoopDashboardSource {
  kind: string
  path: string | null
  error: string | null
  statusPathCandidates: string[]
}

export interface GoalLoopKnownBlocker {
  id: string
  status: string
  issue: string | null
  description: string | null
}

export interface GoalLoopStatusResponse {
  schemaVersion: number
  generatedAt: string | null
  loopIteration: string
  overallStatus: GoalLoopStatusLevel
  phases: Record<GoalLoopPhaseName, GoalLoopPhase>
  nextAction: Record<string, unknown> | null
  systemHealthSignals: Record<string, unknown>
  dashboardSource: GoalLoopDashboardSource
  knownBlockers: GoalLoopKnownBlocker[]
}

export interface GoalLoopCorpusBlocker {
  id: string
  status: string
  issue: string | null
  expectedFindingsTotal: number | null
  itemizedFindingsTotal: number | null
  missingItemizedFindings: number | null
  strictRowCorpusValidated: boolean | null
}

export type VerifyEvidenceState =
  | 'post-act-live'
  | 'startup-fixture-failure'
  | 'missing'
  | 'unknown'

function normalizeStatus(value: unknown): GoalLoopStatusLevel {
  const text = asString(value, 'unknown').toLowerCase()
  if (text === 'ok' || text === 'warning' || text === 'critical') return text
  return 'unknown'
}

function normalizePhase(value: unknown): GoalLoopPhase {
  if (!isRecord(value)) {
    return { status: 'unknown', summary: { reason: 'phase_missing' } }
  }
  const summary = value.summary
  return {
    status: normalizeStatus(value.status),
    summary: isRecord(summary) ? summary : {},
  }
}

function normalizeDashboardSource(value: unknown): GoalLoopDashboardSource {
  if (!isRecord(value)) {
    return {
      kind: 'unknown',
      path: null,
      error: null,
      statusPathCandidates: [],
    }
  }
  const rawCandidates = value.status_path_candidates
  const statusPathCandidates = Array.isArray(rawCandidates)
    ? rawCandidates.filter((item): item is string => typeof item === 'string')
    : []
  return {
    kind: asString(value.kind, 'unknown'),
    path: asString(value.path) ?? null,
    error: asString(value.error) ?? null,
    statusPathCandidates,
  }
}

function normalizeKnownBlockers(value: unknown): GoalLoopKnownBlocker[] {
  if (!Array.isArray(value)) return []
  return value.filter(isRecord).map(item => ({
    id: asString(item.id, 'unknown'),
    status: asString(item.status, 'UNKNOWN'),
    issue: asString(item.issue) ?? null,
    description: asString(item.description) ?? null,
  }))
}

export function normalizeGoalLoopStatus(raw: unknown): GoalLoopStatusResponse {
  const root = isRecord(raw) ? raw : {}
  const rawPhases = isRecord(root.phases) ? root.phases : {}
  const phases = Object.fromEntries(
    GOAL_LOOP_PHASES.map(phase => [phase, normalizePhase(rawPhases[phase])]),
  ) as Record<GoalLoopPhaseName, GoalLoopPhase>

  return {
    schemaVersion: asInt(root.schema_version) ?? 1,
    generatedAt: asString(root.generated_at) ?? null,
    loopIteration: asString(root.loop_iteration, 'unknown'),
    overallStatus: normalizeStatus(root.overall_status),
    phases,
    nextAction: isRecord(root.next_action) ? root.next_action : null,
    systemHealthSignals: isRecord(root.system_health_signals) ? root.system_health_signals : {},
    dashboardSource: normalizeDashboardSource(root.dashboard_source),
    knownBlockers: normalizeKnownBlockers(root.known_blockers),
  }
}

export function goalLoopStatusTone(status: GoalLoopStatusLevel): string {
  switch (status) {
    case 'ok':
      return 'text-[var(--color-status-ok)] border-[var(--ok-25)] bg-[var(--ok-10)]'
    case 'warning':
      return 'text-[var(--color-status-warn)] border-[var(--warn-25)] bg-[var(--warn-10)]'
    case 'critical':
      return 'text-[var(--color-status-err)] border-[var(--err-25)] bg-[var(--err-10)]'
    case 'unknown':
      return 'text-[var(--color-fg-muted)] border-[var(--color-border-default)] bg-[var(--color-bg-surface)]'
  }
}

export function phaseLabel(phase: GoalLoopPhaseName): string {
  switch (phase) {
    case 'observe':
      return 'Observe'
    case 'orient':
      return 'Orient'
    case 'decide':
      return 'Decide'
    case 'act':
      return 'Act'
    case 'verify':
      return 'Verify'
  }
}

export function phaseSummaryValue(
  status: GoalLoopStatusResponse,
  phase: GoalLoopPhaseName,
  key: string,
): unknown {
  return status.phases[phase].summary[key]
}

export function auditCatalogSummary(status: GoalLoopStatusResponse): Record<string, unknown> | null {
  const catalog = status.phases.orient.summary.audit_catalog
  return isRecord(catalog) ? catalog : null
}

export function deriveCorpusBlocker(status: GoalLoopStatusResponse): GoalLoopCorpusBlocker | null {
  const catalog = auditCatalogSummary(status)
  if (catalog) {
    const catalogStatus = asString(catalog.status, 'unknown')
    const missing = asInt(catalog.missing_itemized_findings) ?? null
    const strictValidated = asBoolean(catalog.strict_row_corpus_validated) ?? null
    const blocked =
      catalogStatus !== 'COMPLETE'
      || (missing !== null && missing > 0)
      || strictValidated === false
    if (blocked) {
      return {
        id: 'strict_row_level_catalog_complete',
        status: 'BLOCKED',
        issue: '#13265',
        expectedFindingsTotal: asInt(catalog.expected_findings_total) ?? null,
        itemizedFindingsTotal: asInt(catalog.itemized_findings_total) ?? null,
        missingItemizedFindings: missing,
        strictRowCorpusValidated: strictValidated,
      }
    }
  }

  const blocker = status.knownBlockers.find(item => item.id === 'strict_row_level_catalog_complete')
  if (!blocker) return null
  return {
    id: blocker.id,
    status: blocker.status,
    issue: blocker.issue,
    expectedFindingsTotal: null,
    itemizedFindingsTotal: null,
    missingItemizedFindings: null,
    strictRowCorpusValidated: null,
  }
}

export function verifyEvidenceState(status: GoalLoopStatusResponse): VerifyEvidenceState {
  const summary = status.phases.verify.summary
  const verifyStatus = asString(summary.verify_status)
  if (!verifyStatus) return 'missing'
  const postAct = asBoolean(summary.post_act_verify) ?? false
  const evidenceKind = asString(summary.evidence_kind)
  if (postAct && evidenceKind === 'live_runtime_logs') return 'post-act-live'
  if (!postAct && verifyStatus === 'FAIL') return 'startup-fixture-failure'
  return 'unknown'
}

export function verifyEvidenceLabel(state: VerifyEvidenceState): string {
  switch (state) {
    case 'post-act-live':
      return 'Post-ACT live Verify evidence'
    case 'startup-fixture-failure':
      return 'Startup fixture failure'
    case 'missing':
      return 'Verify evidence missing'
    case 'unknown':
      return 'Verify evidence unknown'
  }
}
