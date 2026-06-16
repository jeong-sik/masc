import { html } from 'htm/preact'
import { useCallback, useEffect, useState } from 'preact/hooks'
import { ArrowRight, Plus, RefreshCw } from 'lucide-preact'
import { SectionCard } from './common/card'
import { LoadingState } from './common/feedback-state'
import { ActionButton } from './common/button'
import { Table, type TableColumn } from './common/table'
import { Drawer } from './common/drawer'
import { CollapsibleSection } from './common/collapsible'
import { TextInput } from './common/input'
import { Select } from './common/select'
import { fetchGoalLoopStatus } from '../api/goal-loop'
import { fetchDashboardGoalsTree } from '../api/dashboard'
import { callMcpTool } from '../api/mcp'
import { asString, isRecord } from './common/normalize'
import { formatMsCompact } from '../lib/format-number'
import { errorToString } from '../lib/format-string'
import { hydrateGoalTreeSnapshot } from '../goal-tree-state'
import { navigate } from '../router'
import {
  GOAL_LOOP_PHASES,
  auditCatalogSummary,
  goalLoopStatusTone,
  normalizeGoalLoopStatusLevel,
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

type GoalHorizon = 'short' | 'mid' | 'long'

interface CreatedGoal {
  title: string
  goalId: string | null
  taskLinkField: string | null
}

const GOAL_HORIZON_OPTIONS = [
  { value: 'short', label: 'Short' },
  { value: 'mid', label: 'Mid' },
  { value: 'long', label: 'Long' },
]

const GOAL_PRIORITY_OPTIONS = [
  { value: '1', label: 'P1' },
  { value: '2', label: 'P2' },
  { value: '3', label: 'P3' },
  { value: '4', label: 'P4' },
]

function displayValue(value: unknown): string {
  if (value === null || value === undefined || value === '') return 'n/a'
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  if (typeof value === 'number') return Number.isFinite(value) ? String(value) : 'n/a'
  if (typeof value === 'string') return value
  return JSON.stringify(value)
}

type MetricFormat = 'raw' | 'number' | 'percent' | 'duration_ms' | 'boolean' | 'count'

interface PhaseMetricSchema {
  key: string
  label: string
  format: MetricFormat
}

function formatValue(value: unknown, format: MetricFormat): string {
  if (value === null || value === undefined || value === '') return 'n/a'
  switch (format) {
    case 'raw':
      return displayValue(value)
    case 'number':
    case 'count':
      if (typeof value === 'number') return Number.isFinite(value) ? String(value) : 'n/a'
      return displayValue(value)
    case 'percent':
      if (typeof value === 'number' && Number.isFinite(value))
        return `${(value * 100).toFixed(1)}%`
      return displayValue(value)
    case 'duration_ms':
      if (typeof value === 'number' && Number.isFinite(value))
        return formatMsCompact(value)
      return displayValue(value)
    case 'boolean':
      if (typeof value === 'boolean') return value ? 'yes' : 'no'
      return displayValue(value)
  }
}

const PHASE_SCHEMA: Record<GoalLoopPhaseName, PhaseMetricSchema[]> = {
  observe: [
    { key: 'critical_matches', label: 'Critical', format: 'count' },
    { key: 'warning_matches', label: 'Warnings', format: 'count' },
    { key: 'matched_lines', label: 'Matched', format: 'count' },
  ],
  orient: [
    { key: 'critical_present', label: 'Critical', format: 'boolean' },
    { key: 'evidence_present', label: 'Evidence', format: 'boolean' },
    { key: 'findings_total', label: 'Findings', format: 'count' },
  ],
  decide: [
    { key: 'decisions_total', label: 'Decisions', format: 'count' },
    { key: 'p0_count', label: 'P0', format: 'count' },
    { key: 'act_missing_count', label: 'Unlinked', format: 'count' },
  ],
  act: [
    { key: 'act_linked_count', label: 'Linked', format: 'count' },
    { key: 'act_missing_count', label: 'Unlinked', format: 'count' },
    { key: 'decisions_total', label: 'Decisions', format: 'count' },
  ],
  verify: [
    { key: 'verify_status', label: 'Status', format: 'raw' },
    { key: 'violations', label: 'Violations', format: 'count' },
    { key: 'post_act_verify', label: 'Post-Act', format: 'raw' },
  ],
}

function statusChip(status: string) {
  const level = normalizeGoalLoopStatusLevel(status)
  return html`
    <span class=${`inline-flex items-center rounded-[var(--r-0)] border px-2 py-0.5 font-mono text-2xs font-semibold uppercase tracking-[var(--track-caps)] ${goalLoopStatusTone(level)}`}>
      ${status}
    </span>
  `
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
      class="v2-workspace-panel min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2"
      data-testid=${`goal-loop-phase-${phase}`}
    >
      <div class="mb-2 flex items-center justify-between gap-2">
        <div class="font-mono text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
          ${phaseLabel(phase)}
        </div>
        ${statusChip(phaseStatus)}
      </div>
      <dl class="grid grid-cols-1 gap-1 text-xs">
        ${PHASE_SCHEMA[phase].map(({ key, label, format }) => html`
          <div class="flex min-w-0 justify-between gap-3">
            <dt class="truncate text-[var(--color-fg-muted)]">${label}</dt>
            <dd class="min-w-0 truncate font-mono text-[var(--color-fg-secondary)]">
              ${formatValue(phaseSummaryValue(status, phase, key), format)}
            </dd>
          </div>
        `)}
      </dl>
    </div>
  `
}

function AuditCatalogBlock({ status }: { status: GoalLoopStatusResponse }) {
  const audit = auditCatalogSummary(status)
  const catalogStatus = audit?.status ?? 'missing'
  const expectedFindingsTotal = audit?.expected_findings_total
  const itemizedFindingsTotal = audit?.itemized_findings_total
  const missingItemizedFindings = audit?.missing_itemized_findings

  return html`
    <${SectionCard}
      title="Audit Catalog"
      right=${statusChip(displayValue(catalogStatus))}
      data-testid="goal-loop-audit-catalog"
    >
      <dl class="grid grid-cols-2 gap-x-4 gap-y-2 text-xs max-[760px]:grid-cols-1">
        <div class="flex justify-between gap-3">
          <dt class="text-[var(--color-fg-muted)]">catalog status</dt>
          <dd class="font-mono text-[var(--color-fg-secondary)]">${displayValue(catalogStatus)}</dd>
        </div>
        <div class="flex justify-between gap-3">
          <dt class="text-[var(--color-fg-muted)]">itemized findings</dt>
          <dd class="font-mono text-[var(--color-fg-secondary)]">
            ${displayValue(itemizedFindingsTotal)}
            /
            ${displayValue(expectedFindingsTotal)}
          </dd>
        </div>
        <div class="flex justify-between gap-3">
          <dt class="text-[var(--color-fg-muted)]">missing rows</dt>
          <dd class="font-mono text-[var(--color-status-err)]" data-testid="goal-loop-corpus-missing">
            ${displayValue(missingItemizedFindings)}
          </dd>
        </div>
      </dl>
    <//>
  `
}

function NextActionBlock({ status }: { status: GoalLoopStatusResponse }) {
  const action = status.nextAction
  if (!action) {
    return html`
      <${SectionCard} label="Next Action" data-testid="goal-loop-next-action">
        <div class="text-xs text-[var(--color-fg-muted)]">n/a</div>
      <//>
    `
  }
  return html`
    <${SectionCard} label="Next Action" data-testid="goal-loop-next-action">
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

function parseGoalUpsertResult(text: string): Omit<CreatedGoal, 'title'> {
  try {
    const raw = JSON.parse(text) as unknown
    if (!isRecord(raw)) return { goalId: null, taskLinkField: null }
    return {
      goalId: asString(raw.goal_id) ?? null,
      taskLinkField: asString(raw.task_link_field) ?? null,
    }
  } catch {
    return { goalId: null, taskLinkField: null }
  }
}

function GoalCreateBlock({ onCreated }: { onCreated: () => void }) {
  const [title, setTitle] = useState('')
  const [horizon, setHorizon] = useState<GoalHorizon>('short')
  const [priority, setPriority] = useState('3')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [created, setCreated] = useState<CreatedGoal | null>(null)

  const submit = useCallback((event?: Event) => {
    event?.preventDefault()
    const trimmedTitle = title.trim()
    if (!trimmedTitle) {
      setError('title required')
      return
    }
    setSubmitting(true)
    setError(null)
    setCreated(null)
    void callMcpTool('masc_goal_upsert', {
      title: trimmedTitle,
      horizon,
      priority: Number(priority),
    })
      .then((resultText) => {
        const upsertResult = parseGoalUpsertResult(resultText)
        setTitle('')
        setHorizon('short')
        setPriority('3')
        setCreated({
          title: trimmedTitle,
          goalId: upsertResult.goalId,
          taskLinkField: upsertResult.taskLinkField,
        })
        onCreated()
        void fetchDashboardGoalsTree()
          .then(hydrateGoalTreeSnapshot)
          .catch(() => undefined)
      })
      .catch((err) => {
        setError(errorToString(err))
      })
      .finally(() => setSubmitting(false))
  }, [horizon, onCreated, priority, title])

  return html`
    <${SectionCard} label="Create Goal" data-testid="goal-loop-create-goal">
      <form class="grid gap-3 md:grid-cols-[minmax(0,1fr)_8rem_6rem_auto]" onSubmit=${submit}>
        <label class="flex min-w-0 flex-col gap-1 text-2xs font-medium text-[var(--color-fg-muted)]">
          Title
          <${TextInput}
            value=${title}
            placeholder="Goal title"
            ariaLabel="Goal title"
            disabled=${submitting}
            onInput=${(e: Event) => setTitle((e.target as HTMLInputElement).value)}
          />
        </label>
        <label class="flex min-w-0 flex-col gap-1 text-2xs font-medium text-[var(--color-fg-muted)]">
          Horizon
          <${Select}
            value=${horizon}
            options=${GOAL_HORIZON_OPTIONS}
            disabled=${submitting}
            onInput=${(next: string) => setHorizon(next as GoalHorizon)}
          />
        </label>
        <label class="flex min-w-0 flex-col gap-1 text-2xs font-medium text-[var(--color-fg-muted)]">
          Priority
          <${Select}
            value=${priority}
            options=${GOAL_PRIORITY_OPTIONS}
            disabled=${submitting}
            onInput=${setPriority}
          />
        </label>
        <div class="flex items-end">
          <${ActionButton}
            type="submit"
            variant="primary"
            size="md"
            disabled=${submitting || title.trim() === ''}
            ariaBusy=${submitting}
            ariaLabel="Create goal"
            title="Create goal"
          >
            <span class="inline-flex items-center gap-1">
              <${Plus} size=${14} />
              ${submitting ? 'Creating' : 'Create'}
            </span>
          <//>
        </div>
      </form>
      ${error
        ? html`
          <div class="rounded-[var(--r-1)] border border-[var(--err-25)] bg-[var(--err-10)] px-3 py-2 text-xs text-[var(--color-status-err)]">
            ${error}
          </div>
        `
        : null}
      ${created
        ? html`
          <div
            class="rounded-[var(--r-1)] border border-[var(--ok-25)] bg-[var(--ok-10)] px-3 py-2 text-xs text-[var(--color-status-ok)]"
            data-testid="goal-loop-created-goal"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div class="min-w-0">
                <div class="min-w-0 truncate">created ${created.title}</div>
                ${created.goalId
                  ? html`
                    <div class="mt-1 font-mono text-3xs text-[var(--color-fg-muted)]" data-testid="goal-loop-created-goal-id">
                      goal ${created.goalId}
                      ${created.taskLinkField ? html` · task link ${created.taskLinkField}` : null}
                    </div>
                  `
                  : null}
              </div>
              ${created.goalId
                ? html`
                  <${ActionButton}
                    type="button"
                    variant="ghost"
                    size="sm"
                    ariaLabel=${`Open ${created.title} in Goal Manager`}
                    title=${`Open ${created.title} in Goal Manager`}
                    onClick=${() => navigate('workspace', { section: 'planning', goal: created.goalId! })}
                  >
                    <span class="inline-flex items-center gap-1">
                      Open
                      <${ArrowRight} size=${14} />
                    </span>
                  <//>
                `
                : null}
            </div>
          </div>
        `
        : null}
    <//>
  `
}

interface GoalLoopTableRow {
  phase: GoalLoopPhaseName
  status: string
  metrics: PhaseMetricSchema[]
}

function GoalLoopTable({
  status,
  selectedPhase,
  onSelectPhase,
}: {
  status: GoalLoopStatusResponse
  selectedPhase: GoalLoopPhaseName | null
  onSelectPhase: (phase: GoalLoopPhaseName | null) => void
}) {
  const rows: GoalLoopTableRow[] = GOAL_LOOP_PHASES.map((phase) => ({
    phase,
    status: status.phases[phase].status,
    metrics: PHASE_SCHEMA[phase],
  }))

  const columns: TableColumn<GoalLoopTableRow>[] = [
    {
      key: 'phase',
      header: 'Phase',
      render: (row) => html`
        <span class="font-mono text-xs font-semibold uppercase tracking-[var(--track-caps)]">
          ${phaseLabel(row.phase)}
        </span>
      `,
    },
    {
      key: 'status',
      header: 'Status',
      render: (row) => statusChip(row.status),
    },
    {
      key: 'summary',
      header: 'Key metrics',
      render: (row) => {
        const m0 = row.metrics[0]
        const m1 = row.metrics[1]
        return html`
          <div class="flex flex-col gap-0.5 text-xs">
            ${m0
              ? html`
                  <span class="text-[var(--color-fg-muted)]">
                    ${m0.label}:
                    <span class="font-mono text-[var(--color-fg-secondary)]">
                      ${formatValue(phaseSummaryValue(status, row.phase, m0.key), m0.format)}
                    </span>
                  </span>
                `
              : null}
            ${m1
              ? html`
                  <span class="text-[var(--color-fg-muted)]">
                    ${m1.label}:
                    <span class="font-mono text-[var(--color-fg-secondary)]">
                      ${formatValue(phaseSummaryValue(status, row.phase, m1.key), m1.format)}
                    </span>
                  </span>
                `
              : null}
          </div>
        `
      },
    },
  ]

  return html`
    <div class="overflow-x-auto rounded-[var(--r-1)] border border-[var(--color-border-default)]">
      <${Table}
        columns=${columns}
        rows=${rows}
        getRowId=${(row: GoalLoopTableRow) => row.phase}
        selectedIds=${selectedPhase ? [selectedPhase] : []}
        onSelect=${(ids: string[]) => {
          const next = ids.length > 0 ? (ids[ids.length - 1] as GoalLoopPhaseName) : null
          onSelectPhase(next)
        }}
        aria-label="Goal loop phases"
      />
    </div>
  `
}

function GoalLoopDetailDrawer({
  phase,
  status,
  onClose,
}: {
  phase: GoalLoopPhaseName | null
  status: GoalLoopStatusResponse
  onClose: () => void
}) {
  if (!phase) return null
  return html`
    <${Drawer}
      open=${true}
      onClose=${onClose}
      title=${`${phaseLabel(phase)} Detail`}
    >
      <${PhaseBlock} status=${status} phase=${phase} />
      ${phase === 'verify'
        ? html`<div class="mt-4"><${VerifyEvidenceBlock} status=${status} /></div>`
        : null}
    <//>
  `
}

export function GoalLoopPanel({ initialStatus }: GoalLoopPanelProps) {
  const [status, setStatus] = useState<GoalLoopStatusResponse | null>(initialStatus ?? null)
  const [loading, setLoading] = useState(initialStatus === undefined)
  const [error, setError] = useState<string | null>(null)
  const [selectedPhase, setSelectedPhase] = useState<GoalLoopPhaseName | null>(null)

  const refresh = useCallback(() => {
    setLoading(true)
    setError(null)
    void fetchGoalLoopStatus()
      .then(setStatus)
      .catch((err) => {
        setError(errorToString(err))
      })
      .finally(() => setLoading(false))
  }, [])

  useEffect(() => {
    if (initialStatus !== undefined) return
    refresh()
  }, [initialStatus, refresh])

  if (loading && status === null) {
    return html`<div class="v2-workspace-surface"><${LoadingState}>Loading GOAL LOOP...<//></div>`
  }

  if (status === null) {
    return html`
      <div class="v2-workspace-surface">
        <${SectionCard} label="GOAL LOOP" data-testid="goal-loop-panel">
          <div class="text-xs text-[var(--color-status-err)]">${error ?? 'status unavailable'}</div>
        <//>
      </div>
    `
  }

  return html`
    <div class="v2-workspace-surface flex flex-col gap-4" data-testid="goal-loop-panel">
      <div class="v2-workspace-panel flex flex-wrap items-center justify-between gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
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
          class="v2-workspace-action"
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

      <${GoalLoopTable}
        status=${status}
        selectedPhase=${selectedPhase}
        onSelectPhase=${setSelectedPhase}
      />

      <${CollapsibleSection} title="Audit & Verify" open=${false}>
        <div class="flex flex-col gap-4">
          <${AuditCatalogBlock} status=${status} />
          <${VerifyEvidenceBlock} status=${status} />
        </div>
      <//>

      <${NextActionBlock} status=${status} />

      <${GoalCreateBlock} onCreated=${refresh} />

      <${GoalLoopDetailDrawer}
        phase=${selectedPhase}
        status=${status}
        onClose=${() => setSelectedPhase(null)}
      />
    </div>
  `
}
