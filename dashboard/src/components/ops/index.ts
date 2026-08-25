import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { CARD_STANDARD } from '../common/card'
import { EmptyState } from '../common/feedback-state'
import { TimeAgo } from '../common/time-ago'
import { route } from '../../router'
import {
  operatorActionLog,
  operatorDigestError,
  operatorError,
  operatorSnapshot,
} from '../../operator-store'
import {
  workflowActionLabel,
  workflowContextForRoute,
  workflowTargetLabel,
} from '../../workflow-context'
import type {
  OperatorActionLogEntry,
  OperatorContextMetricsUnavailable,
  OperatorKeeperSnapshot,
  OperatorSnapshot,
} from '../../types'
import { ComposerV2 } from '../board/composer-v2'
import {
  actionTypeLabel,
  formatMessageContent,
  hydrateOpsWorkflow,
  hydratedWorkflowId,
  targetTypeLabel,
  workflowTargetReady,
} from './helpers'
import { FlowControlPanel } from '../flow-control/flow-control-panel'
import { CmdGateLinks, CmdInterveneForm } from './cmd-intervene-form'

// keeper-v2 command.jsx tones: confirmed/executed → ok, preview → warn,
// error → bad. The design's cmd-log badge only marks ok/bad (CMD_TONE warn
// renders with no tone class).
type ActivityTone = 'ok' | 'bad' | ''

export const ACTIVITY_MAX_AGE_MS = 3 * 24 * 60 * 60 * 1000

interface OpsActivityTimelineEntry {
  key: string
  kind: 'review' | 'intervention'
  at: string
  actor: string
  label: string
  target: string
  detail: string
  tone: ActivityTone
}

interface ContextMetricsDiagnostic {
  keeper: OperatorKeeperSnapshot
  source: 'keeper' | 'persistent_agent'
  error: OperatorContextMetricsUnavailable
}

export function contextMetricsDiagnostics(snapshot: OperatorSnapshot | null): ContextMetricsDiagnostic[] {
  if (!snapshot) return []
  const keepers = snapshot.keepers
    .filter((keeper): keeper is OperatorKeeperSnapshot & { context_metrics_unavailable: OperatorContextMetricsUnavailable } =>
      keeper.context_metrics_unavailable != null)
    .map(keeper => ({ keeper, source: 'keeper' as const, error: keeper.context_metrics_unavailable }))
  const persistentAgents = (snapshot.persistent_agents ?? [])
    .filter((keeper): keeper is OperatorKeeperSnapshot & { context_metrics_unavailable: OperatorContextMetricsUnavailable } =>
      keeper.context_metrics_unavailable != null)
    .map(keeper => ({ keeper, source: 'persistent_agent' as const, error: keeper.context_metrics_unavailable }))
  const byName = new Map<string, ContextMetricsDiagnostic>()
  for (const diagnostic of [...keepers, ...persistentAgents]) {
    // persistent_agents is a filtered projection of keepers (same rows), so an
    // autoboot keeper appears in both sections. Collapse to one diagnostic per
    // keeper identity, preferring the canonical 'keeper' source (inserted first).
    if (!byName.has(diagnostic.keeper.name)) byName.set(diagnostic.keeper.name, diagnostic)
  }
  return [...byName.values()]
}

function renderContextMetricsDiagnostic(diagnostic: ContextMetricsDiagnostic) {
  const { keeper, source, error } = diagnostic
  const sourceLabel = source === 'keeper' ? 'Keeper' : 'Persistent agent'
  if (error.kind === 'not_observed') {
    return html`
      <li
        data-testid="ops-context-metrics-diagnostic"
        data-error-kind=${error.kind}
      >
        <span class="mono">${sourceLabel} ${keeper.name}</span> — context measurement <span class="mono">not_observed</span>
      </li>
    `
  }
  return html`
    <li
      data-testid="ops-context-metrics-diagnostic"
      data-error-kind=${error.kind}
    >
      <span class="mono">${sourceLabel} ${keeper.name}</span> — invalid context metrics diagnostic
      ${error.reported_kind ? html`<span>kind: <span class="mono">${error.reported_kind}</span></span>` : null}
      ${error.reported_reason ? html`<span>reason: <span class="mono">${error.reported_reason}</span></span>` : null}
    </li>
  `
}

function parseTimestamp(value?: string | null): number {
  if (!value) return 0
  const parsed = Date.parse(value)
  return Number.isNaN(parsed) ? 0 : parsed
}

function actionLogTone(entry: OperatorActionLogEntry): ActivityTone {
  switch (entry.outcome) {
    case 'error':
      return 'bad'
    case 'executed':
    case 'confirmed':
      return 'ok'
    default:
      return ''
  }
}

function prettyTargetLabel(label?: string | null): string {
  const value = label?.trim()
  if (!value) return 'No target'
  const separator = value.indexOf(':')
  if (separator < 0) return targetTypeLabel(value)
  const type = value.slice(0, separator)
  const rest = value.slice(separator + 1)
  return `${targetTypeLabel(type)} · ${rest}`
}

function timelineEntries(limit = 10): OpsActivityTimelineEntry[] {
  const interventions = operatorActionLog.value.map((entry: OperatorActionLogEntry) => ({
    key: `intervention:${entry.id}`,
    kind: 'intervention' as const,
    at: entry.at,
    actor: entry.actor || 'unknown',
    label: actionTypeLabel(entry.action_type),
    target: prettyTargetLabel(entry.target_label),
    detail: formatMessageContent(entry.message) || 'No detail',
    tone: actionLogTone(entry),
  }))

  const cutoff = Date.now() - ACTIVITY_MAX_AGE_MS
  return interventions
    .filter(entry => parseTimestamp(entry.at) >= cutoff)
    .sort((left, right) => parseTimestamp(right.at) - parseTimestamp(left.at))
    .slice(0, limit)
}

export function activityTimelineEmptyState(): { message: string; hint: string | null } {
  const root = operatorSnapshot.value?.root
  if (root?.paused) {
    const reason = root.pause_reason?.trim()
    const by = root.paused_by?.trim()
    const parts = [reason, by ? `by ${by}` : null].filter(Boolean).join(' · ')
    return {
      message: 'Namespace is paused. New operator activity will not be recorded until resume.',
      hint: parts || null,
    }
  }
  return {
    message: 'No operator activity in the last 3 days. Interventions and reviews appear here automatically.',
    hint: null,
  }
}

function renderActivityTimeline() {
  const entries = timelineEntries()
  if (entries.length === 0) {
    const { message, hint } = activityTimelineEmptyState()
    return html`
      <div class="v2-command-panel" data-testid="ops-activity-timeline-empty">
        <${EmptyState} message=${message} compact />
        ${hint ? html`<div class="mt-0.5 text-center text-2xs text-text-dim">${hint}</div>` : null}
      </div>
    `
  }

  return html`
    <div class="v2-command-panel cmd-log" data-testid="ops-activity-timeline">
      ${entries.map(entry => html`
        <article
          key=${entry.key}
          data-testid="ops-activity-item"
          data-activity-kind=${entry.kind}
          class="v2-command-row cmd-log-row"
        >
          <div class="cmd-log-h">
            <span class="ai-b ${entry.tone}">${entry.label}</span>
            <span class="mono dim">${entry.target}</span>
            <span class="mono dim">${entry.actor}</span>
            <span class="mono dim"><${TimeAgo} timestamp=${entry.at} /></span>
          </div>
          <div class="cmd-log-b">${entry.detail}</div>
        </article>
      `)}
    </div>
  `
}

export function Ops() {
  const snapshot = operatorSnapshot.value
  const metricsDiagnostics = contextMetricsDiagnostics(snapshot)
  const workflowContext = route.value.tab === 'command' ? workflowContextForRoute(route.value) : null
  const workflowReady = workflowTargetReady(workflowContext, snapshot?.keepers ?? [])

  useEffect(() => {
    if (route.value.tab !== 'command' || route.value.params.section !== 'operations') {
      hydratedWorkflowId.value = null
      return
    }
    if (!workflowContext) {
      hydratedWorkflowId.value = null
      return
    }
    if (hydratedWorkflowId.value === workflowContext.id) return
    hydratedWorkflowId.value = workflowContext.id
    hydrateOpsWorkflow(workflowContext)
  }, [
    route.value.tab,
    route.value.params.source,
    route.value.params.action_type,
    route.value.params.target_type,
    route.value.params.target_id,
    route.value.params.focus_kind,
    workflowContext?.id,
  ])

  return html`
    <section class="v2-command-surface flex flex-col gap-4" aria-label="Operations panel">
      ${operatorError.value ? html`<section class="ops-banner v2-command-panel rounded-[var(--r-1)] py-3 px-3.5 border border-[var(--color-border-default)] error" role="alert">${operatorError.value}</section>` : null}
      ${operatorDigestError.value ? html`<section class="ops-banner v2-command-panel rounded-[var(--r-1)] py-3 px-3.5 border border-[var(--color-border-default)] error" role="alert">${operatorDigestError.value}</section>` : null}
      ${metricsDiagnostics.length > 0 ? html`
        <section
          class="ops-banner v2-command-panel cmd-banner"
          role="alert"
          data-testid="ops-context-metrics-unavailable"
        >
          <b>Context metrics unavailable</b>
          <ul>${metricsDiagnostics.map(renderContextMetricsDiagnostic)}</ul>
          <span class="mono dim">스냅샷은 occupancy 를 관측하지 않습니다 — 잘못된 kind/reason 은 별도 진단으로 표시됩니다.</span>
        </section>
      ` : null}

      ${workflowContext ? html`
        <section class="ops-banner v2-command-panel rounded-[var(--r-1)] py-3 px-3.5 border border-[var(--color-border-default)] ${workflowReady ? 'info' : 'warn'} grid gap-2" aria-label="Workflow context">
          <div class="flex gap-2 flex-wrap items-center text-[var(--color-fg-primary)]">
            <strong class="font-semibold">${workflowContext.source_label}</strong>
            <span>${workflowActionLabel(workflowContext.action_type)}</span>
            <span>${workflowTargetLabel(workflowContext)}</span>
          </div>
          <div class="text-[var(--color-fg-secondary)] leading-relaxed">${workflowContext.summary}</div>
          ${workflowContext.payload_preview ? html`<div class="v2-command-detail mt-1 p-2 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] text-xs font-mono">${workflowContext.payload_preview}</div>` : null}
          <div class="text-[var(--color-fg-muted)] text-xs">
            ${workflowReady
              ? 'Target and inputs were prefilled from the recommended action.'
              : 'Target is not present in the current snapshot. Choose the concrete target manually.'}
          </div>
        </section>
      ` : null}

      <${FlowControlPanel} />
      <section class="v2-command-panel cmd-cols" aria-label="Operations controls">
        <div class="grid gap-4 order-1 max-[1200px]:order-2">
          <${CmdInterveneForm} />
          <${ComposerV2} workspaceId="ops" />
        </div>

        <section class="${CARD_STANDARD} v2-command-panel grid gap-3 order-2 max-[1200px]:order-1" aria-label="Recent operator activity">
          <div>
            <h2 class="text-sm font-semibold text-[var(--color-fg-secondary)]">Recent Activity</h2>
            <p class="mt-1 text-xs text-[var(--color-fg-muted)]">Interventions and review outcomes, newest first. Gate/HITL requests stay in the Gate view.</p>
          </div>
          <${renderActivityTimeline} />
        </section>
      </section>
      ${route.value.params.view === 'ops' ? html`<${CmdGateLinks} />` : null}
    </section>
  `
}
