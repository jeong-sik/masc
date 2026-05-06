import { html } from 'htm/preact'
import { useCallback, useEffect, useState } from 'preact/hooks'
import { RefreshCw } from 'lucide-preact'
import { SectionCard } from './common/card'
import { LoadingState } from './common/feedback-state'
import { ActionButton } from './common/button'
import { fetchGoalLoopStatus } from '../api/goal-loop'
import {
  GOAL_LOOP_PHASES,
  auditCatalogSummary,
  deriveCorpusBlocker,
  goalLoopStatusTone,
  normalizeGoalLoopStatus,
  phaseLabel,
  phaseSummaryValue,
  verifyEvidenceLabel,
  verifyEvidenceState,
  type GoalLoopPhaseName,
  type GoalLoopStatusResponse,
} from '../goal-loop-status'

interface GoalLoopPanelProps {
  initialStatus?: GoalLoopStatusResponse
}

function displayValue(value: unknown): string {
  if (value === null || value === undefined || value === '') return 'n/a'
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  if (typeof value === 'number') return Number.isFinite(value) ? String(value) : 'n/a'
  if (typeof value === 'string') return value
  return JSON.stringify(value)
}

function statusChip(status: string) {
  return html`
    <span class=${`inline-flex items-center rounded-[var(--r-0)] border px-2 py-0.5 font-mono text-2xs font-semibold uppercase tracking-[var(--track-caps)] ${goalLoopStatusTone(normalizeGoalLoopStatus({ overall_status: status }).overallStatus)}`}>
      ${status}
    </span>
  `
}

function phaseMetricKeys(phase: GoalLoopPhaseName): string[] {
  switch (phase) {
    case 'observe':
      return ['critical_matches', 'warning_matches', 'matched_lines']
    case 'orient':
      return ['critical_present', 'evidence_present', 'findings_total']
    case 'decide':
      return ['decisions_total', 'p0_count', 'act_missing_count']
    case 'act':
      return ['act_linked_count', 'act_missing_count', 'decisions_total']
    case 'verify':
      return ['verify_status', 'violations', 'post_act_verify']
  }
}

function PhaseBlock({
  status,
  phase,
}: {
  status: GoalLoopStatusResponse
  phase: GoalLoopPhaseName
}) {
  const phaseStatus = status.phases[phase].status
  return html`
    <div
      class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2"
      data-testid=${`goal-loop-phase-${phase}`}
    >
      <div class="mb-2 flex items-center justify-between gap-2">
        <div class="font-mono text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
          ${phaseLabel(phase)}
        </div>
        ${statusChip(phaseStatus)}
      </div>
      <dl class="grid grid-cols-1 gap-1 text-xs">
        ${phaseMetricKeys(phase).map(key => html`
          <div class="flex min-w-0 justify-between gap-3">
            <dt class="truncate text-[var(--color-fg-muted)]">${key}</dt>
            <dd class="min-w-0 truncate font-mono text-[var(--color-fg-secondary)]">
              ${displayValue(phaseSummaryValue(status, phase, key))}
            </dd>
          </div>
        `)}
      </dl>
    </div>
  `
}

function AuditCatalogBlock({ status }: { status: GoalLoopStatusResponse }) {
  const audit = auditCatalogSummary(status)
  const blocker = deriveCorpusBlocker(status)
  if (!audit && !blocker) return null

  return html`
    <${SectionCard}
      title="Audit Catalog"
      right=${blocker ? statusChip(blocker.status) : null}
      data-testid="goal-loop-audit-catalog"
    >
      <dl class="grid grid-cols-2 gap-x-4 gap-y-2 text-xs max-[760px]:grid-cols-1">
        <div class="flex justify-between gap-3">
          <dt class="text-[var(--color-fg-muted)]">catalog status</dt>
          <dd class="font-mono text-[var(--color-fg-secondary)]">${displayValue(audit?.status)}</dd>
        </div>
        <div class="flex justify-between gap-3">
          <dt class="text-[var(--color-fg-muted)]">itemized findings</dt>
          <dd class="font-mono text-[var(--color-fg-secondary)]">
            ${displayValue(blocker?.itemizedFindingsTotal)}
            /
            ${displayValue(blocker?.expectedFindingsTotal)}
          </dd>
        </div>
        <div class="flex justify-between gap-3">
          <dt class="text-[var(--color-fg-muted)]">missing rows</dt>
          <dd class="font-mono text-[var(--color-status-err)]" data-testid="goal-loop-corpus-missing">
            ${displayValue(blocker?.missingItemizedFindings)}
          </dd>
        </div>
        <div class="flex justify-between gap-3">
          <dt class="text-[var(--color-fg-muted)]">strict row corpus</dt>
          <dd class="font-mono text-[var(--color-fg-secondary)]">
            ${displayValue(blocker?.strictRowCorpusValidated)}
          </dd>
        </div>
      </dl>
      ${blocker
        ? html`
          <div class="rounded-[var(--r-1)] border border-[var(--err-25)] bg-[var(--err-10)] px-3 py-2 text-xs text-[var(--color-status-err)]">
            <span class="font-mono">${blocker.id}</span>
            ${blocker.issue ? html`<span class="ml-2 font-mono">${blocker.issue}</span>` : null}
          </div>
        `
        : null}
    <//>
  `
}

function NextActionBlock({ status }: { status: GoalLoopStatusResponse }) {
  const action = status.nextAction
  if (!action) {
    return html`
      <${SectionCard} title="Next Action" data-testid="goal-loop-next-action">
        <div class="text-xs text-[var(--color-fg-muted)]">n/a</div>
      <//>
    `
  }
  return html`
    <${SectionCard} title="Next Action" data-testid="goal-loop-next-action">
      <div class="grid grid-cols-[minmax(0,8rem)_minmax(0,1fr)] gap-x-4 gap-y-2 text-xs max-[760px]:grid-cols-1">
        <div class="font-mono text-[var(--color-fg-muted)]">decision</div>
        <div class="min-w-0 truncate font-mono text-[var(--color-fg-secondary)]">${displayValue(action.decision_id)}</div>
        <div class="font-mono text-[var(--color-fg-muted)]">priority</div>
        <div class="font-mono text-[var(--color-fg-secondary)]">${displayValue(action.priority)}</div>
        <div class="font-mono text-[var(--color-fg-muted)]">owner</div>
        <div class="font-mono text-[var(--color-fg-secondary)]">${displayValue(action.owner)}</div>
        <div class="font-mono text-[var(--color-fg-muted)]">action</div>
        <div class="min-w-0 text-[var(--color-fg-secondary)]">${displayValue(action.action)}</div>
      </div>
    <//>
  `
}

function VerifyEvidenceBlock({ status }: { status: GoalLoopStatusResponse }) {
  const summary = status.phases.verify.summary
  const state = verifyEvidenceState(status)
  return html`
    <${SectionCard}
      title="Verify Evidence"
      right=${statusChip(state)}
      data-testid="goal-loop-verify-evidence"
    >
      <div class="text-sm font-semibold text-[var(--color-fg-secondary)]">
        ${verifyEvidenceLabel(state)}
      </div>
      <dl class="grid grid-cols-2 gap-x-4 gap-y-2 text-xs max-[760px]:grid-cols-1">
        <div class="flex justify-between gap-3">
          <dt class="text-[var(--color-fg-muted)]">verify status</dt>
          <dd class="font-mono">${displayValue(summary.verify_status)}</dd>
        </div>
        <div class="flex justify-between gap-3">
          <dt class="text-[var(--color-fg-muted)]">evidence kind</dt>
          <dd class="font-mono">${displayValue(summary.evidence_kind)}</dd>
        </div>
        <div class="col-span-2 flex justify-between gap-3 max-[760px]:col-span-1">
          <dt class="text-[var(--color-fg-muted)]">evidence source</dt>
          <dd class="min-w-0 truncate font-mono">${displayValue(summary.evidence_source)}</dd>
        </div>
      </dl>
    <//>
  `
}

export function GoalLoopPanel({ initialStatus }: GoalLoopPanelProps) {
  const [status, setStatus] = useState<GoalLoopStatusResponse | null>(initialStatus ?? null)
  const [loading, setLoading] = useState(initialStatus === undefined)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(() => {
    setLoading(true)
    setError(null)
    void fetchGoalLoopStatus()
      .then(setStatus)
      .catch(err => {
        setError(err instanceof Error ? err.message : String(err))
      })
      .finally(() => setLoading(false))
  }, [])

  useEffect(() => {
    if (initialStatus !== undefined) return
    refresh()
  }, [initialStatus, refresh])

  if (loading && status === null) {
    return html`<${LoadingState}>Loading GOAL LOOP...<//>`
  }

  if (status === null) {
    return html`
      <${SectionCard} title="GOAL LOOP" data-testid="goal-loop-panel">
        <div class="text-xs text-[var(--color-status-err)]">${error ?? 'status unavailable'}</div>
      <//>
    `
  }

  return html`
    <div class="flex flex-col gap-4" data-testid="goal-loop-panel">
      <div class="flex flex-wrap items-center justify-between gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-mono text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
              iteration ${status.loopIteration}
            </span>
            ${statusChip(status.overallStatus)}
          </div>
          <div class="mt-1 min-w-0 truncate text-xs text-[var(--color-fg-muted)]" data-testid="goal-loop-source">
            ${status.dashboardSource.kind}
            ${status.dashboardSource.path ? html` · ${status.dashboardSource.path}` : null}
          </div>
        </div>
        <${ActionButton}
          variant="ghost"
          size="sm"
          ariaLabel="Refresh GOAL LOOP status"
          title="Refresh GOAL LOOP status"
          onClick=${refresh}
          disabled=${loading}
        >
          <${RefreshCw} size=${14} />
        <//>
      </div>

      ${error
        ? html`
          <div class="rounded-[var(--r-1)] border border-[var(--err-25)] bg-[var(--err-10)] px-3 py-2 text-xs text-[var(--color-status-err)]">
            ${error}
          </div>
        `
        : null}

      <div class="grid grid-cols-5 gap-3 max-[1180px]:grid-cols-3 max-[760px]:grid-cols-1">
        ${GOAL_LOOP_PHASES.map(phase => html`<${PhaseBlock} status=${status} phase=${phase} />`)}
      </div>

      <div class="grid grid-cols-2 gap-4 max-[980px]:grid-cols-1">
        <${AuditCatalogBlock} status=${status} />
        <${VerifyEvidenceBlock} status=${status} />
      </div>

      <${NextActionBlock} status=${status} />
    </div>
  `
}
