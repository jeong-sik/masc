import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { CARD_STANDARD } from '../common/card'
import { EmptyState } from '../common/feedback-state'
import { CountBadge } from '../common/badge'
import { TimeAgo } from '../common/time-ago'
import { route } from '../../router'
import {
  operatorActionLog,
  operatorDigestError,
  operatorError,
  operatorRoomDigest,
  operatorSnapshot,
} from '../../operator-store'
import {
  workflowActionLabel,
  workflowContextForRoute,
  workflowTargetLabel,
} from '../../workflow-context'
import type { OperatorActionLogEntry, OperatorReviewDecision } from '../../types'
import { QuickIntervene } from './quick-intervene'
import { KeeperUtilitiesPanel } from './keeper-utilities'
import {
  actionTypeLabel,
  formatMessageContent,
  hydrateOpsWorkflow,
  hydratedWorkflowId,
  targetTypeLabel,
  workflowTargetReady,
} from './helpers'
import { FlowControlPanel } from '../flow-control/flow-control-panel'

type ActivityTone = 'default' | 'warn' | 'ok' | 'bad' | 'accent'

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

function parseTimestamp(value?: string | null): number {
  if (!value) return 0
  const parsed = Date.parse(value)
  return Number.isNaN(parsed) ? 0 : parsed
}

function reviewDecisionLabel(value?: string | null): string {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'resolved':
      return 'Review Resolved'
    case 'deferred':
      return 'Review Deferred'
    default:
      return value?.trim() || 'Review Action'
  }
}

function reviewDecisionTone(value?: string | null): ActivityTone {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'resolved':
      return 'ok'
    case 'deferred':
      return 'warn'
    default:
      return 'accent'
  }
}

function actionLogTone(entry: OperatorActionLogEntry): ActivityTone {
  switch (entry.outcome) {
    case 'error':
      return 'bad'
    case 'preview':
      return 'warn'
    case 'confirmed':
      return 'accent'
    default:
      return 'default'
  }
}

function targetSummary(targetType?: string | null, targetId?: string | null): string {
  return `${targetTypeLabel(targetType)}${targetId ? ` · ${targetId}` : ''}`
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
  const reviews = (operatorRoomDigest.value?.recent_reviews ?? []).map((item: OperatorReviewDecision) => ({
    key: `review:${item.item_id}:${item.at}`,
    kind: 'review' as const,
    at: item.at,
    actor: item.actor || 'unknown',
    label: reviewDecisionLabel(item.decision),
    target: targetSummary(item.target_type, item.target_id),
    detail: item.reason || 'No reason recorded',
    tone: reviewDecisionTone(item.decision),
  }))

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
  return [...reviews, ...interventions]
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
      <div data-testid="ops-activity-timeline-empty">
        <${EmptyState} message=${message} compact />
        ${hint ? html`<div class="mt-0.5 text-center text-2xs text-text-dim">${hint}</div>` : null}
      </div>
    `
  }

  return html`
    <div class="grid gap-2" data-testid="ops-activity-timeline">
      ${entries.map(entry => html`
        <article
          key=${entry.key}
          data-testid="ops-activity-item"
          data-activity-kind=${entry.kind}
          class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--white-3)] p-3"
        >
          <div class="flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]">
            <${CountBadge} tone=${entry.tone}>${entry.label}<//>
            <span>${entry.target}</span>
            <span>${entry.actor}</span>
            <span><${TimeAgo} timestamp=${entry.at} /></span>
          </div>
          <div class="mt-2 text-sm leading-paragraph text-[var(--color-fg-primary)]">${entry.detail}</div>
        </article>
      `)}
    </div>
  `
}

export function Ops() {
  const snapshot = operatorSnapshot.value
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
    <section class="flex flex-col gap-4" aria-label="Operations panel">
      ${operatorError.value ? html`<section class="ops-banner rounded-[var(--r-1)] py-3 px-3.5 border border-[var(--color-border-default)] error" role="alert">${operatorError.value}</section>` : null}
      ${operatorDigestError.value ? html`<section class="ops-banner rounded-[var(--r-1)] py-3 px-3.5 border border-[var(--color-border-default)] error" role="alert">${operatorDigestError.value}</section>` : null}

      ${workflowContext ? html`
        <section class="ops-banner rounded-[var(--r-1)] py-3 px-3.5 border border-[var(--color-border-default)] ${workflowReady ? 'info' : 'warn'} grid gap-2" aria-label="Workflow context">
          <div class="flex gap-2 flex-wrap items-center text-[var(--color-fg-primary)]">
            <strong class="font-semibold">${workflowContext.source_label}</strong>
            <span>${workflowActionLabel(workflowContext.action_type)}</span>
            <span>${workflowTargetLabel(workflowContext)}</span>
          </div>
          <div class="text-[var(--color-fg-secondary)] leading-relaxed">${workflowContext.summary}</div>
          ${workflowContext.payload_preview ? html`<div class="mt-1 p-2 rounded-[var(--r-1)] bg-[var(--white-3)] text-xs font-mono">${workflowContext.payload_preview}</div>` : null}
          <div class="text-[var(--color-fg-muted)] text-xs">
            ${workflowReady
              ? 'Target and inputs were prefilled from the recommended action.'
              : 'Target is not present in the current snapshot. Choose the concrete target manually.'}
          </div>
        </section>
      ` : null}

      <${FlowControlPanel} />
      <section class="grid grid-cols-2 gap-4 max-[1200px]:grid-cols-1" aria-label="Operations controls">
        <div class="grid gap-4 order-1 max-[1200px]:order-2">
          <${QuickIntervene} />
          <${KeeperUtilitiesPanel} />
        </div>

        <section class="${CARD_STANDARD} grid gap-3 order-2 max-[1200px]:order-1" aria-label="Recent operator activity">
          <div>
            <h2 class="text-sm font-semibold text-[var(--color-fg-secondary)]">Recent Activity</h2>
            <p class="mt-1 text-xs text-[var(--color-fg-muted)]">Interventions and review outcomes, newest first. Governance queues stay in the governance view.</p>
          </div>
          <${renderActivityTimeline} />
        </section>
      </section>
    </section>
  `
}
