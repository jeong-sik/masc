// Goal Manager — goal-first planning surface with explicit phase, detail, and evidence.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useCallback, useEffect, useMemo, useState } from 'preact/hooks'
import { SECONDS_PER_HOUR } from '../../lib/format-time'
import { fetchDashboardGoalDetail, fetchDashboardGoalsTree } from '../../api/dashboard'
import { currentDashboardActor } from '../../api/core'
import { callMcpTool } from '../../api/mcp'
import { route } from '../../router'
import {
  goalTreeData as treeData,
  goalTreeError as treeError,
  goalTreeLoading as treeLoading,
  hydrateGoalTreeSnapshot,
} from '../../goal-tree-state'
import { workspaceFsmSnapshot } from '../../store'
import { EmptyState, ErrorState, LoadingState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import { FilterChips } from '../common/filter-chips'
import { StatusBadge } from '../common/status-badge'
import { executionOutcomeLabel } from '../fsm-hub-types'
import { operatorDispositionReasonLabel } from '../fsm-hub-types'
import { runtimeOutcomeLabel } from '../fsm-hub-types'
import { ringFocusClasses } from '../common/ring'
import { trustDispositionLabel } from '../fsm-hub-types'
import { TimeAgo } from '../common/time-ago'
import { TaskCreateForm } from '../task-manage/task-create-form'
import type {
  DashboardGoalDetailResponse,
  DashboardWorkspaceFsmViolation,
  GoalCompletionSummary,
  GoalDetailKeeper,
  GoalDetailTimelineEvent,
  GoalFsmProjection,
  GoalTreeNode,
  GoalTreeTask,
  GoalTreeSummary,
} from '../../types'
import {
  priorityStars,
  countAwaitingVerificationTasks,
  countAwaitingVerificationInTree,
  type GoalPhaseFilter,
  goalPhaseLabel,
  goalPhaseStatus,
  matchesGoalPhaseFilter,
  phaseFilterLabel,
  TaskProgressBar,
} from './goal-helpers'
import { trustHasPendingFirstEvidence } from './trust-summary-evidence'
import {
  goalTaskCompletionLabel,
  goalTaskLinkageLabel,
  goalTaskSummaryForNode,
} from './goal-task-summary'
import {
  goalCompletionLabel,
  goalCompletionSummaryForNode,
  goalCompletionTone,
} from './goal-completion-summary'
import { DECK_CHIP, DECK_LABEL } from './deck-classes'
import { errorToString } from '../../lib/format-string'

type GoalDetailTab = 'summary' | 'tasks' | 'evidence'
type GoalTransitionAction = 'request_complete'

const CARD_BOX = 'rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3'
const GOAL_PANEL = 'rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] p-5'
const TREE_NODE_CARD_BASE = 'group flex items-start gap-3 rounded-[var(--r-1)] border p-3 transition-colors w-full text-left'
const TREE_NODE_CARD_ACTIVE = `${TREE_NODE_CARD_BASE} border-[var(--color-state-active-border)] bg-[var(--color-state-active-bg)] shadow-[0_0_0_1px_var(--color-brass-border)]`

/**
 * Pure hierarchy filter for goal tree nodes.
 *
 * Case-insensitive substring match on `node.title` and on `task.title` for
 * any task attached to the node. Ancestors of matching nodes are preserved
 * so the operator retains context (parent goal, horizon) — the tree shape
 * is never broken by the filter.
 */
function filterGoalTree(
  nodes: readonly GoalTreeNode[],
  query: string,
): readonly GoalTreeNode[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return nodes

  const result: GoalTreeNode[] = []
  for (const node of nodes) {
    const pruned = pruneNode(node, needle)
    if (pruned !== null) result.push(pruned)
  }
  return result
}

function pruneNode(node: GoalTreeNode, needle: string): GoalTreeNode | null {
  const title = node.title ?? ''
  const nodeMatches = title.toLowerCase().includes(needle)
  if (nodeMatches) return node

  const matchingTasks = node.tasks.filter(t =>
    (t.title ?? '').toLowerCase().includes(needle),
  )
  const prunedChildren: GoalTreeNode[] = []
  for (const child of node.children) {
    const prunedChild = pruneNode(child, needle)
    if (prunedChild !== null) prunedChildren.push(prunedChild)
  }

  if (matchingTasks.length === 0 && prunedChildren.length === 0) return null

  return {
    ...node,
    tasks: matchingTasks,
    children: prunedChildren,
  }
}

function filterGoalTreeByPhase(
  nodes: readonly GoalTreeNode[],
  filter: GoalPhaseFilter,
): readonly GoalTreeNode[] {
  if (filter === 'all') return nodes

  const result: GoalTreeNode[] = []
  for (const node of nodes) {
    const pruned = pruneNodeByPhase(node, filter)
    if (pruned !== null) result.push(pruned)
  }
  return result
}

function pruneNodeByPhase(
  node: GoalTreeNode,
  filter: GoalPhaseFilter,
): GoalTreeNode | null {
  const nodeMatches = matchesGoalPhaseFilter(node.phase, filter)
  const prunedChildren: GoalTreeNode[] = []
  for (const child of node.children) {
    const prunedChild = pruneNodeByPhase(child, filter)
    if (prunedChild !== null) prunedChildren.push(prunedChild)
  }

  if (!nodeMatches && prunedChildren.length === 0) return null
  if (nodeMatches && prunedChildren.length === node.children.length) return node

  return {
    ...node,
    tasks: nodeMatches ? node.tasks : [],
    children: prunedChildren,
  }
}

function flattenGoalTree(nodes: readonly GoalTreeNode[]): GoalTreeNode[] {
  const acc: GoalTreeNode[] = []
  const walk = (items: readonly GoalTreeNode[]) => {
    for (const item of items) {
      acc.push(item)
      if (item.children.length > 0) walk(item.children)
    }
  }
  walk(nodes)
  return acc
}

// `trustDispositionLabel` moved to `../fsm-hub-types` to deduplicate the
// 4-entry inline label literal that also lived in
// `keeper-detail-alert-strip.ts:201-205`. Same map, single SSOT.

function goalFsmStateLabel(state: GoalFsmProjection['state']): string {
  switch (state) {
    case 'executing': return '실행'
    case 'blocked': return '차단'
    case 'paused': return '일시정지'
    case 'completed': return '완료'
    case 'dropped': return '중단'
    default: return state
  }
}

function goalFsmObservationLabel(
  observation: GoalFsmProjection['activity_observation'],
): string {
  switch (observation) {
    case 'runtime': return 'runtime evidence'
    case 'approval': return 'approval event'
    case 'task': return 'task update'
    case 'goal_metadata': return 'goal metadata only'
    default: return observation
  }
}

function GoalFsmBadge({ fsm }: { fsm: GoalFsmProjection }) {
  const toneClass =
    fsm.state === 'blocked'
      ? 'border-bad/35 bg-bad/10 text-bad'
      : 'border-card-border/60 bg-[var(--color-bg-elevated)] text-text-body'
  return html`
    <span
      class="inline-flex items-center rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-semibold uppercase ${toneClass}"
      title=${`source=${fsm.source}; activity=${goalFsmObservationLabel(fsm.activity_observation)}`}
    >
      Goal FSM · ${goalFsmStateLabel(fsm.state)}
    </span>
  `
}

function keeperTrustDispositionClass(
  trust: GoalDetailKeeper['runtime_trust'],
): string {
  const disposition = trust?.disposition
  if (disposition === 'Alert') return 'border-bad/25 bg-bad/10 text-bad'
  if (disposition === 'Blocked' || disposition === 'Pause' || trust?.needs_attention) {
    return 'border-warn/25 bg-warn/10 text-warn'
  }
  if (disposition === 'Pass') return 'border-ok/25 bg-ok/10 text-ok'
  return 'border-card-border/60 bg-[var(--color-bg-elevated)] text-text-body'
}

function timelineSeverityClass(severity: GoalDetailTimelineEvent['severity']): string {
  switch (severity) {
    case 'bad': return 'border-bad/25 bg-bad/10 text-bad'
    case 'warn': return 'border-warn/25 bg-warn/10 text-warn'
    default: return 'border-card-border/50 bg-[var(--color-bg-surface)] text-text-body'
  }
}

const expandedNodes = signal<Set<string>>(new Set())
const filterQuery = signal('')
const treePhaseFilter = signal<GoalPhaseFilter>('all')
const selectedGoalId = signal<string | null>(null)
const detailData = signal<DashboardGoalDetailResponse | null>(null)
const detailLoading = signal(false)
const detailError = signal<string | null>(null)
const detailTab = signal<GoalDetailTab>('summary')
let detailRequestSeq = 0

function toggleNode(id: string) {
  const next = new Set(expandedNodes.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedNodes.value = next
}

function selectGoal(id: string) {
  selectedGoalId.value = id
}

function cleanRouteGoalId(value: string | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed && trimmed.length > 0 ? trimmed : null
}

function goalExpansionPath(nodes: readonly GoalTreeNode[], goalId: string): string[] | null {
  for (const node of nodes) {
    if (node.id === goalId) return [node.id]
    const childPath = goalExpansionPath(node.children, goalId)
    if (childPath) return [node.id, ...childPath]
  }
  return null
}

function expandAll(nodes: GoalTreeNode[]) {
  const ids = new Set(expandedNodes.value)
  function walk(items: GoalTreeNode[]) {
    for (const item of items) {
      ids.add(item.id)
      walk(item.children)
    }
  }
  walk(nodes)
  expandedNodes.value = ids
}

function collapseAll() {
  expandedNodes.value = new Set()
}

async function refreshTree() {
  treeLoading.value = true
  treeError.value = null
  try {
    hydrateGoalTreeSnapshot(await fetchDashboardGoalsTree())
  } catch (err) {
    treeError.value = errorToString(err)
  } finally {
    treeLoading.value = false
  }
}

async function refreshGoalDetail(goalId: string) {
  const reqId = ++detailRequestSeq
  detailLoading.value = true
  detailError.value = null
  try {
    const next = await fetchDashboardGoalDetail(goalId)
    if (!next || typeof next !== 'object' || !('goal' in next)) {
      throw new Error('invalid goal detail payload')
    }
    if (detailRequestSeq !== reqId) return
    detailData.value = next
  } catch (err) {
    if (detailRequestSeq !== reqId) return
    detailError.value = errorToString(err)
  } finally {
    if (detailRequestSeq === reqId) detailLoading.value = false
  }
}

// Task-derived attainment_pct must not read as a metric result when the goal
// declares a metric that no evaluator measures (task-1743): show "미평가"
// rather than a percentage. Distinct from "미측정" (no task data at all).
export function attainmentValueLabel(attainment: GoalTreeNode['attainment']): string {
  if (attainment.metric_evaluation === 'unevaluated') return '미평가'
  if (attainment.attainment_pct == null) return '미측정'
  return `${attainment.attainment_pct}%`
}

function attainmentTone(attainment: GoalTreeNode['attainment']): 'default' | 'ok' | 'warn' | 'bad' {
  // A declared-but-unevaluated metric is never "attained": the pct is
  // task-derived, so surface it as attention (warn), not success (ok).
  if (attainment.metric_evaluation === 'unevaluated') return 'warn'
  if (attainment.state === 'attained') return 'ok'
  if (attainment.state === 'unmeasured') return 'warn'
  if (attainment.state === 'not_started') return 'bad'
  return 'default'
}

function attainmentClass(attainment: GoalTreeNode['attainment']): string {
  switch (attainmentTone(attainment)) {
    case 'ok': return 'border-ok/30 bg-ok/10 text-ok'
    case 'warn': return 'border-warn/30 bg-warn/10 text-warn'
    case 'bad': return 'border-bad/30 bg-bad/10 text-bad'
    default: return 'border-card-border/60 bg-[var(--color-bg-elevated)] text-text-body'
  }
}

function attainmentLabel(attainment: GoalTreeNode['attainment']): string {
  return `달성 ${attainmentValueLabel(attainment)}`
}

function GoalAttainmentChip({ attainment }: { attainment: GoalTreeNode['attainment'] }) {
  return html`
    <span
      class="rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-semibold ${attainmentClass(attainment)}"
      title=${`${attainment.basis}; target=${attainment.target_value ?? '-'}; observed=${attainment.observed_value ?? '-'}; ${attainment.note}`}
    >
      ${attainmentLabel(attainment)}
    </span>
  `
}

function completionToneClass(tone: 'default' | 'ok' | 'warn' | 'bad'): string {
  switch (tone) {
    case 'ok': return 'border-ok/30 bg-ok/10 text-ok'
    case 'warn': return 'border-warn/30 bg-warn/10 text-warn'
    case 'bad': return 'border-bad/30 bg-bad/10 text-bad'
    default: return 'border-card-border/60 bg-[var(--color-bg-elevated)] text-text-body'
  }
}

function TreeSummary({
  summary,
  awaitingVerificationCount,
}: {
  summary: GoalTreeSummary
  awaitingVerificationCount: number
}) {
  return html`
    <div class="grid grid-cols-[repeat(auto-fit,minmax(112px,1fr))] gap-2">
      <div class="${CARD_BOX} text-center">
        <div class="font-mono text-xl font-semibold text-[var(--color-fg-primary)] tabular-nums">${summary.total_goals}</div>
        <div class="mt-1 ${DECK_LABEL}">전체 목표</div>
      </div>
      <div class="${CARD_BOX} text-center">
        <div class="font-mono text-xl font-semibold text-[var(--color-fg-primary)] tabular-nums">${summary.phase_counts.executing ?? 0}</div>
        <div class="mt-1 ${DECK_LABEL}">실행</div>
      </div>
      <div class="${CARD_BOX} text-center">
        <div class="font-mono text-xl font-semibold text-[var(--color-fg-primary)] tabular-nums">${summary.phase_counts.completed ?? 0}</div>
        <div class="mt-1 ${DECK_LABEL}">완료</div>
      </div>
      <div class="${CARD_BOX} text-center">
        <div class="font-mono text-xl font-semibold text-[var(--color-fg-primary)] tabular-nums">${summary.phase_counts.blocked ?? 0}</div>
        <div class="mt-1 ${DECK_LABEL}">Blocked phase</div>
      </div>
      <div class="${CARD_BOX} text-center">
        <div class="font-mono text-xl font-semibold text-[var(--color-fg-primary)] tabular-nums">${summary.pending_approvals}</div>
        <div class="mt-1 ${DECK_LABEL}">승인 대기</div>
      </div>
      ${awaitingVerificationCount > 0 ? html`
        <div class="rounded-[var(--r-0)] border border-[var(--color-brass-border)] bg-[var(--color-brass-soft)] p-3 text-center">
          <div class="font-mono text-xl font-semibold text-[var(--color-accent-fg)] tabular-nums">${awaitingVerificationCount}</div>
          <div class="mt-1 font-mono text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-accent-fg)]/80">Task 검증 대기</div>
        </div>
      ` : null}
    </div>
  `
}

function workspaceViolationsForGoal(goalId: string): DashboardWorkspaceFsmViolation[] {
  const violations = workspaceFsmSnapshot.value?.violations ?? []
  return violations.filter(violation => violation.refs?.goal_id === goalId)
}

function TreeTask({ task }: { task: GoalTreeTask }) {
  return html`
    <div class="flex flex-wrap items-center gap-2 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] px-2 py-1.5 text-xs">
      <span class="size-2 rounded-[var(--r-0)] shrink-0" style="background:${task.status_color}"></span>
      <span class="min-w-0 flex-1 truncate text-text-body">${task.title}</span>
      <span class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-1.5 py-0.5 text-3xs font-medium text-text-muted">
        ${task.linkage_source === 'explicit' ? 'goal_id' : 'title tag'}
      </span>
      ${task.assignee ? html`
        <span class="rounded-[var(--r-1)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-1.5 py-0.5 text-3xs font-medium text-accent-fg">${task.assignee}</span>
      ` : null}
      <${StatusBadge} status=${task.status} />
    </div>
  `
}

function goalCompletionPctLabel(summary: GoalCompletionSummary): string {
  if (summary.metric_evaluation === 'unevaluated') return 'metric unevaluated'
  if (summary.pct == null) return 'unmeasured'
  return `${summary.pct}%`
}

function goalCompletionTruthTitle(
  summary: GoalCompletionSummary,
  label: string,
): string {
  const pct = summary.pct == null ? 'pct=unmeasured' : `pct=${summary.pct}%`
  const metric = `metric_evaluation=${summary.metric_evaluation}`
  const source = `source=${summary.pct_source}`
  const unevaluated =
    summary.metric_evaluation === 'unevaluated'
      ? '; pct is task-derived/proxy data, not an evaluated goal metric'
      : ''
  return `Completion: ${label}; ${pct}; ${source}; ${metric}${unevaluated}`
}

function GoalCompletionStrip({
  node,
  compact = false,
}: {
  node: GoalTreeNode
  compact?: boolean
}) {
  const summary = goalCompletionSummaryForNode(node)
  const tone = goalCompletionTone(summary)
  const label = goalCompletionLabel(summary)
  const pctLabel = goalCompletionPctLabel(summary)
  const title = goalCompletionTruthTitle(summary, label)

  if (compact) {
    return html`
      <span
        class="rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-semibold ${completionToneClass(tone)}"
        title=${title}
        data-goal-completion-metric-evaluation=${summary.metric_evaluation}
        data-goal-completion-pct-source=${summary.pct_source}
      >
        ${label}
      </span>
    `
  }

  return html`
    <div class=${CARD_BOX} data-goal-completion-summary>
      <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
        <div>
          <div class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">완료 판정</div>
          <div class="mt-1 text-sm text-text-body">${label} · ${pctLabel}</div>
        </div>
        <span class="rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-semibold ${completionToneClass(tone)}">${label}</span>
      </div>
      <div class="grid grid-cols-[repeat(auto-fit,minmax(120px,1fr))] gap-2 text-xs">
        <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
          <div class="text-3xs uppercase text-text-muted">basis</div>
          <div
            class="mt-1 font-semibold text-text-strong"
            title=${title}
            data-goal-completion-metric-evaluation=${summary.metric_evaluation}
            data-goal-completion-pct-source=${summary.pct_source}
          >
            ${summary.pct_source}${summary.metric_evaluation === 'unevaluated' ? ' · metric unevaluated' : ''}
          </div>
        </div>
        <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
          <div class="text-3xs uppercase text-text-muted">task open</div>
          <div class="mt-1 font-semibold text-text-strong">${summary.task_open}</div>
        </div>
      </div>
    </div>
  `
}

function GoalTaskRelationStrip({
  node,
  compact = false,
}: {
  node: GoalTreeNode
  compact?: boolean
}) {
  const summary = goalTaskSummaryForNode(node)
  if (compact) {
    if (summary.total === 0) return null
    return html`
      <span
        class="rounded-[var(--r-1)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-medium text-accent-fg"
        title=${`Goal-Task links: ${goalTaskCompletionLabel(summary)}; ${goalTaskLinkageLabel(summary)}`}
      >
        Task ${summary.done}/${summary.total}
      </span>
    `
  }

  return html`
    <div class=${CARD_BOX} data-goal-task-summary>
      <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
        <div>
          <div class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">Goal-Task 관계</div>
          <div class="mt-1 text-sm text-text-body">${goalTaskCompletionLabel(summary)}</div>
        </div>
        <span class="rounded-[var(--r-1)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-medium text-accent-fg">
          ${goalTaskLinkageLabel(summary)}
        </span>
      </div>
      <div class="grid grid-cols-[repeat(auto-fit,minmax(110px,1fr))] gap-2 text-xs">
        <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
          <div class="text-3xs uppercase text-text-muted">open</div>
          <div class="mt-1 font-semibold text-text-strong">${summary.open}</div>
        </div>
        <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
          <div class="text-3xs uppercase text-text-muted">awaiting verify</div>
          <div class="mt-1 font-semibold text-text-strong">${summary.awaiting_verification}</div>
        </div>
        <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
          <div class="text-3xs uppercase text-text-muted">cancelled</div>
          <div class="mt-1 font-semibold text-text-strong">${summary.cancelled}</div>
        </div>
        <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
          <div class="text-3xs uppercase text-text-muted">unassigned</div>
          <div class="mt-1 font-semibold text-text-strong">${summary.unassigned}</div>
        </div>
      </div>
    </div>
  `
}

function goalTransitionLabel(action: GoalTransitionAction): string {
  switch (action) {
    case 'request_complete': return 'Request completion'
  }
}

function goalTransitionStatusLabel(action: GoalTransitionAction): string {
  switch (action) {
    case 'request_complete': return 'requested completion'
  }
}

function lifecycleActionsForGoal(node: GoalTreeNode): Array<{
  action: GoalTransitionAction
  variant: 'primary' | 'ok' | 'danger'
}> {
  const summary = goalCompletionSummaryForNode(node)
  const actions: Array<{
    action: GoalTransitionAction
    variant: 'primary' | 'ok' | 'danger'
  }> = []

  if (summary.ready_to_request_completion) {
    actions.push({ action: 'request_complete', variant: 'primary' })
  }
  return actions
}

function GoalLifecycleActionPanel({ node }: { node: GoalTreeNode }) {
  const actions = lifecycleActionsForGoal(node)
  const [pendingAction, setPendingAction] = useState<GoalTransitionAction | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [lastAction, setLastAction] = useState<GoalTransitionAction | null>(null)

  useEffect(() => {
    setPendingAction(null)
    setError(null)
    setLastAction(null)
  }, [node.id])

  const runAction = useCallback((action: GoalTransitionAction) => {
    const actorId = currentDashboardActor()
    setPendingAction(action)
    setError(null)
    setLastAction(null)
    void (async () => {
      try {
        await callMcpTool('masc_goal_transition', {
          goal_id: node.id,
          action,
          actor: {
            id: actorId,
            display_name: actorId,
          },
        })
        setLastAction(action)
        await Promise.all([
          refreshTree(),
          refreshGoalDetail(node.id),
        ])
      } catch (err) {
        setError(errorToString(err))
      } finally {
        setPendingAction(null)
      }
    })()
  }, [node.id])

  if (actions.length === 0) return null

  return html`
    <div class=${CARD_BOX} data-goal-lifecycle-actions>
      <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
        <div>
          <div class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">Goal lifecycle</div>
          <div class="mt-1 text-sm text-text-body">${goalCompletionLabel(goalCompletionSummaryForNode(node))}</div>
        </div>
        <span class="${DECK_CHIP} text-[var(--color-fg-secondary)]">${node.phase}</span>
      </div>
      <div class="flex flex-wrap gap-2">
        ${actions.map(({ action, variant }) => {
          const label = goalTransitionLabel(action)
          const isPending = pendingAction === action
          return html`
            <${ActionButton}
              key=${action}
              variant=${variant}
              size="sm"
              disabled=${pendingAction !== null}
              ariaBusy=${isPending}
              ariaLabel=${label}
              title=${label}
              onClick=${() => runAction(action)}
            >
              ${isPending ? 'Working...' : label}
            <//>
          `
        })}
      </div>
      ${lastAction ? html`
        <div class="mt-3 rounded-[var(--r-1)] border border-[var(--ok-25)] bg-[var(--ok-10)] px-3 py-2 text-xs text-[var(--color-status-ok)]" data-testid="goal-lifecycle-action-status">
          ${goalTransitionStatusLabel(lastAction)}
        </div>
      ` : null}
      ${error ? html`
        <div class="mt-3 rounded-[var(--r-1)] border border-[var(--err-25)] bg-[var(--err-10)] px-3 py-2 text-xs text-[var(--color-status-err)]" data-testid="goal-lifecycle-action-error">
          ${error}
        </div>
      ` : null}
    </div>
  `
}

function TreeNode({ node, depth }: { node: GoalTreeNode; depth: number }) {
  const isExpanded = expandedNodes.value.has(node.id)
  const hasContent = node.children.length > 0 || node.tasks.length > 0
  const isSelected = selectedGoalId.value === node.id
  const workspaceViolations = workspaceViolationsForGoal(node.id)
  const workspaceHasError = workspaceViolations.some(v => v.severity === 'error')
  const indent = depth * 20
  const headerBase = isSelected
    ? TREE_NODE_CARD_ACTIVE
    : `${TREE_NODE_CARD_BASE} border-[var(--color-border-default)] bg-[var(--color-bg-surface)] hover:border-[var(--color-border-strong)]`

  return html`
    <div class="flex flex-col" style="margin-left:${indent}px">
      <button
        type="button"
        class="v2-workspace-row ${headerBase} ${hasContent ? 'cursor-pointer' : ''} ${ringFocusClasses()}"
        onClick=${() => {
          selectGoal(node.id)
          if (hasContent) toggleNode(node.id)
        }}
        aria-expanded=${hasContent ? isExpanded : undefined}
      >
        ${hasContent ? html`
          <span class="mt-0.5 shrink-0 text-xs text-text-dim transition-transform ${isExpanded ? 'rotate-90' : ''}">\u25B6</span>
        ` : html`
          <span class="mt-0.5 shrink-0 text-xs text-text-dim/30">\u25CB</span>
        `}

        <div class="min-w-0 flex-1">
          <div class="mb-1 flex flex-wrap items-center gap-2">
            <${StatusBadge} status=${goalPhaseStatus(node.phase)} label=${goalPhaseLabel(node.phase)} />
            <${GoalFsmBadge} fsm=${node.goal_fsm} />
            <span class="break-words text-base font-semibold text-text-strong line-clamp-2">${node.title}</span>
            <span class="text-2xs text-text-dim">${priorityStars(node.priority)}</span>
          </div>

          <div class="flex flex-wrap items-center gap-2.5 text-2xs text-text-muted">
            <${StatusBadge} status=${node.status} />
            ${node.task_count > 0 ? html`<div class="w-32"><${TaskProgressBar} done=${node.task_done_count} total=${node.task_count} size="sm" /></div>` : null}
            <${GoalCompletionStrip} node=${node} compact />
            <${GoalTaskRelationStrip} node=${node} compact />
            ${node.metric ? html`
              <span
                class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-1.5 py-0.5 font-mono text-3xs text-text-secondary"
                title=${`metric · ${node.metric}${node.target_value ? ` → ${node.target_value}` : ''}`}
              >
                <span aria-hidden="true">↗ </span>${node.metric}${node.target_value ? html`<span class="ml-1 text-text-strong"> · ${node.target_value}</span>` : null}
              </span>
            ` : null}
            <${GoalAttainmentChip} attainment=${node.attainment} />
            ${(() => {
              const awaiting = countAwaitingVerificationTasks(node.tasks)
              return awaiting > 0 ? html`
                <span class="rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-medium text-accent-fg" title="verifier keeper의 독립 실측을 기다리는 task">
                  Task 검증 대기 ${awaiting}
                </span>
              ` : null
            })()}
            ${node.child_count > 0 ? html`<span>${node.child_count} 하위 목표</span>` : null}
            ${node.pending_approval_count > 0 ? html`
              <span class="rounded-[var(--r-1)] border border-warn/30 bg-warn/10 px-2 py-0.5 text-3xs font-medium text-warn">
                approval ${node.pending_approval_count}
              </span>
            ` : null}
            ${workspaceViolations.length > 0 ? html`
              <span
                class="rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-medium ${workspaceHasError ? 'border-bad/30 bg-bad/10 text-bad' : 'border-warn/30 bg-warn/10 text-warn'}"
                title="Goal x Task x Board x Reward"
              >
                FSM ${workspaceViolations.length}
              </span>
            ` : null}
            ${node.latest_keeper_ref ? html`
              <span class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs font-medium text-text-body">
                ${node.latest_keeper_ref}${node.latest_turn_ref != null ? ` · turn ${node.latest_turn_ref}` : ''}
              </span>
            ` : null}
          </div>

        </div>

        <div class="flex shrink-0 flex-col items-end gap-1">
          <span class="text-3xs text-text-dim">
            <${TimeAgo} timestamp=${node.last_activity_at} />
          </span>
          ${isSelected ? html`
            <span class="rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-semibold text-accent-fg">selected</span>
          ` : null}
        </div>
      </button>

      ${isExpanded ? html`
        <div class="mt-1.5 flex flex-col gap-1.5">
          ${node.tasks.length > 0 ? html`
            <div class="ml-6 flex flex-col gap-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] p-2">
              <div class="mb-1 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-text-dim">연결된 태스크</div>
              ${node.tasks.map(task => html`<${TreeTask} key=${task.id} task=${task} />`)}
            </div>
          ` : null}
          ${node.children.map(child => html`
            <${TreeNode} key=${child.id} node=${child} depth=${depth + 1} />
          `)}
        </div>
      ` : null}
    </div>
  `
}

function DetailMetric({
  label,
  value,
  tone = 'default',
}: {
  label: string
  value: string | number
  tone?: 'default' | 'ok' | 'warn' | 'bad'
}) {
  const toneClass =
    tone === 'ok'
      ? 'text-ok'
      : tone === 'warn'
        ? 'text-warn'
        : tone === 'bad'
          ? 'text-bad'
          : 'text-text-strong'
  return html`
    <div class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] p-3">
      <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">${label}</div>
      <div class="mt-2 text-lg font-semibold tabular-nums ${toneClass}">${value}</div>
    </div>
  `
}

function DetailTabs({ active }: { active: GoalDetailTab }) {
  const tabs: GoalDetailTab[] = ['summary', 'tasks', 'evidence']
  return html`
    <div class="flex flex-wrap gap-2">
      ${tabs.map(tab => html`
        <button
          key=${tab}
          type="button"
          class="rounded-[var(--r-1)] border px-3 py-1.5 text-xs font-semibold uppercase tracking-wider transition-colors ${active === tab
            ? 'border-[var(--accent-35)] bg-[var(--accent-10)] text-accent-fg'
            : 'border-card-border/60 bg-[var(--color-bg-surface)] text-text-body hover:border-card-border/90'}"
          onClick=${() => { detailTab.value = tab }}
        >
          ${tab}
        </button>
      `)}
    </div>
  `
}

function KeeperCard({ keeper }: { keeper: GoalDetailKeeper }) {
  const trust = keeper.runtime_trust
  const execution = trust?.execution_summary ?? null
  const latestEvent = keeper.latest_causal_event ?? trust?.latest_causal_event ?? null
  const trustSummary =
    trust?.snapshot_error?.trim()
    || trust?.attention_reason?.trim()
    || trust?.disposition_reason?.trim()
    || execution?.sandbox_summary?.trim()
    || null
  const runtimeAttemptCount = execution?.provider_attempt_count
  const runtimeFailoverApplied = execution?.provider_fallback_applied
  const runtimeSelectedLane = execution?.provider_selected_model?.trim() || null
  const executionRuntimeOutcome = execution?.runtime_outcome?.trim() || null
  const sandboxRoot = execution?.sandbox_root?.trim() || null
  const latestTerminalCode = trust?.latest_terminal_reason?.code?.trim() || null
  const latestTerminalSummary = trust?.latest_terminal_reason?.summary?.trim() || null
  const latestNextAction = trust?.latest_next_action?.trim() || null
  const operatorDispositionReason = trust?.operator_disposition_reason?.trim() || null
  const pendingApproval = trust?.approval_state?.pending_first ?? null
  const pendingApprovalId = pendingApproval?.id?.trim() || null
  const pendingApprovalTool = pendingApproval?.tool_name?.trim() || null
  const pendingApprovalTask = pendingApproval?.task_id?.trim() || null
  const pendingApprovalBlocker = pendingApproval?.blocker_class?.trim() || null
  const shouldShowOperatorDispositionReason =
    operatorDispositionReason !== null && operatorDispositionReason !== trustSummary
  const shouldShowTrustSummary =
    Boolean(trustSummary)
    || Boolean(trust?.snapshot_status)
    || Boolean(trust?.approval_state?.state)
    || Boolean(trust?.next_human_action)
    || Boolean(latestTerminalCode)
    || Boolean(latestNextAction)
    || typeof runtimeAttemptCount === 'number'
    || runtimeFailoverApplied === true
    || Boolean(runtimeSelectedLane)
    || Boolean(executionRuntimeOutcome)
    || Boolean(sandboxRoot)
    || trustHasPendingFirstEvidence(trust?.approval_state ?? null)

  return html`
    <div class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] p-3">
      <div class="flex items-start justify-between gap-3">
        <div>
          <div class="text-sm font-semibold text-text-strong">${keeper.name}</div>
          <div class="mt-1 text-2xs text-text-muted">${keeper.agent_name}</div>
        </div>
        <div class="flex flex-wrap justify-end gap-1.5">
          ${trust?.disposition ? html`
            <span class="rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-semibold ${keeperTrustDispositionClass(trust)}">
              검증 ${trustDispositionLabel(trust.disposition)}
            </span>
          ` : null}
          ${keeper.latest_execution_outcome ? html`
            <span class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs font-semibold text-text-body" title=${keeper.latest_execution_outcome}>
              ${executionOutcomeLabel(keeper.latest_execution_outcome)}
            </span>
          ` : null}
        </div>
      </div>
      <div class="mt-3 grid grid-cols-2 gap-2 text-2xs text-text-muted">
        <div>샌드박스</div>
        <div class="text-right text-text-body">${keeper.sandbox_profile}</div>
        <div>승인</div>
        <div class="text-right text-text-body">${trust?.approval_state?.summary ?? '-'}</div>
        <div>런타임</div>
        <div class="text-right text-text-body">${keeper.runtime_id ?? executionRuntimeOutcome ?? '-'}</div>
        <div>결과</div>
        <div class="text-right text-text-body" title=${keeper.runtime_outcome ?? executionRuntimeOutcome ?? ''}>${runtimeOutcomeLabel(keeper.runtime_outcome ?? executionRuntimeOutcome) ?? '-'}</div>
      </div>
      ${shouldShowTrustSummary ? html`
        <div class="mt-3 rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-3">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">검증 요약</div>
          ${trustSummary ? html`
            <div class="mt-2 text-xs leading-relaxed text-text-body">${trustSummary}</div>
          ` : null}
          ${latestTerminalCode ? html`
            <div class="mt-2 text-xs leading-relaxed text-text-body">종료: ${latestTerminalCode}${latestTerminalSummary ? html` · ${latestTerminalSummary}` : null}</div>
          ` : null}
          <div class="mt-2 flex flex-wrap gap-2 text-3xs text-text-muted">
            ${trust?.snapshot_status ? html`
              <span>snapshot ${trust.snapshot_status}</span>
            ` : null}
            ${trust?.approval_state?.state ? html`
              <span>승인 상태 ${trust.approval_state.state}${trust.approval_state.latest_event_at ? html` · <${TimeAgo} timestamp=${trust.approval_state.latest_event_at} />` : null}</span>
            ` : null}
            ${pendingApprovalId ? html`
              <span>승인 ID ${pendingApprovalId}</span>
            ` : null}
            ${pendingApprovalTool ? html`
              <span>승인 도구 ${pendingApprovalTool}</span>
            ` : null}
            ${pendingApprovalTask ? html`
              <span>승인 작업 ${pendingApprovalTask}</span>
            ` : null}
            ${pendingApprovalBlocker ? html`
              <span>승인 차단 ${pendingApprovalBlocker}</span>
            ` : null}
            ${typeof runtimeAttemptCount === 'number' || runtimeFailoverApplied === true || runtimeSelectedLane ? html`
              <span>
                runtime
                ${typeof runtimeAttemptCount === 'number' ? ` ${runtimeAttemptCount}회` : ''}
                ${runtimeFailoverApplied === true ? ' failover' : ''}
                ${runtimeSelectedLane ? ` ${runtimeSelectedLane}` : ''}
              </span>
            ` : null}
            ${executionRuntimeOutcome ? html`
              <span>runtime ${executionRuntimeOutcome}</span>
            ` : null}
            ${sandboxRoot ? html`
              <span title=${sandboxRoot}>sandbox ${sandboxRoot}</span>
            ` : null}
            ${trust?.next_human_action ? html`
              <span>다음 ${trust.next_human_action}</span>
            ` : null}
            ${latestNextAction ? html`
              <span>권장 ${latestNextAction}</span>
            ` : null}
            ${/* Show receipt-level operator cause when it adds detail beyond trustSummary. */
              shouldShowOperatorDispositionReason ? html`
              <span title=${operatorDispositionReason ?? ''}>운영자 ${operatorDispositionReasonLabel(operatorDispositionReason)}</span>
            ` : null}
          </div>
        </div>
      ` : null}
      ${latestEvent ? html`
        <div class="mt-3 rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">최근 키퍼 이벤트</div>
            <div class="text-3xs text-text-dim">
              <${TimeAgo} timestamp=${latestEvent.ts} />
            </div>
          </div>
          <div class="mt-2 text-xs font-semibold text-text-strong">${latestEvent.title}</div>
          <div class="mt-1 text-2xs leading-relaxed text-text-body">${latestEvent.summary}</div>
          <div class="mt-2 flex flex-wrap gap-2 text-3xs text-text-muted">
            <span>${latestEvent.kind}</span>
            ${latestEvent.keeper_turn_id != null ? html`
              <span>turn ${latestEvent.keeper_turn_id}</span>
            ` : null}
            ${latestEvent.next_human_action ? html`
              <span>next ${latestEvent.next_human_action}</span>
            ` : null}
            ${latestEvent.trace_id ? html`
              <span class="font-mono" title=${latestEvent.trace_id}>trace ${latestEvent.trace_id.slice(0, 8)}</span>
            ` : null}
          </div>
        </div>
      ` : null}
      ${keeper.latest_execution_at ? html`
        <div class="mt-3 text-3xs text-text-dim">
          최근 실행 <${TimeAgo} timestamp=${keeper.latest_execution_at} />
        </div>
      ` : null}
    </div>
  `
}

function GoalTimeline({ events }: { events: GoalDetailTimelineEvent[] }) {
  if (events.length === 0) {
    return html`<${EmptyState} message="최근 evidence가 없습니다" compact />`
  }
  return html`
    <div class="flex flex-col gap-2">
      ${events.map(event => html`
        <div key=${`${event.kind}:${event.lane}:${event.ts}`} class="rounded-[var(--r-1)] border p-3 ${timelineSeverityClass(event.severity)}">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div class="text-sm font-semibold">${event.title}</div>
            <div class="text-3xs text-text-dim">
              <${TimeAgo} timestamp=${event.ts} />
            </div>
          </div>
          <div class="mt-1 text-2xs text-text-muted">${event.lane}</div>
          <div class="mt-2 text-xs leading-relaxed text-text-body">${event.summary}</div>
        </div>
      `)}
    </div>
  `
}

function GoalDetailPanel({
  selectedNode,
}: {
  selectedNode: GoalTreeNode | null
}) {
  const data = detailData.value
  const loading = detailLoading.value
  const error = detailError.value
  const activeTab = detailTab.value

  if (!selectedNode) {
    return html`
      <section class=${GOAL_PANEL} aria-label="목표 상세">
        <${EmptyState} message="왼쪽에서 목표를 선택하면 Summary / Tasks / Evidence가 표시됩니다." />
      </section>
    `
  }

  const detail = data?.goal.id === selectedNode.id ? data : null
  return html`
    <section
      class=${`${GOAL_PANEL} flex flex-col gap-4`}
      aria-label="목표 상세"
      data-testid="goal-detail-panel"
      data-selected-goal-id=${selectedNode.id}
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="max-w-150">
          <div class="text-2xs font-semibold uppercase tracking-[var(--track-label)] text-text-muted">목표 상세</div>
          <h3 class="mt-1 text-xl font-semibold tracking-[-0.02em] text-text-strong">${selectedNode.title}</h3>
          <div class="mt-2 flex flex-wrap items-center gap-2">
            <${StatusBadge} status=${selectedNode.status} />
            <${StatusBadge} status=${goalPhaseStatus(selectedNode.phase)} label=${goalPhaseLabel(selectedNode.phase)} />
            <${GoalFsmBadge} fsm=${selectedNode.goal_fsm} />
            ${selectedNode.metric ? html`
              <span
                class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5 font-mono text-3xs text-text-secondary"
                title="이 목표가 추적하는 metric"
              >
                <span class="text-text-muted">metric</span>
                <span class="ml-1.5">${selectedNode.metric}</span>
                ${selectedNode.target_value ? html`
                  <span class="text-text-muted">·</span>
                  <span class="ml-1 text-text-strong">${selectedNode.target_value}</span>
                ` : null}
              </span>
            ` : null}
          </div>
        </div>
        <div class="flex items-center gap-2">
          <${ActionButton}
            variant="ghost"
            size="sm"
            disabled=${loading}
            onClick=${() => { void refreshGoalDetail(selectedNode.id) }}
          >
            ${loading ? 'detail 갱신 중...' : 'detail 새로고침'}
          <//>
        </div>
      </div>

      <${GoalCompletionStrip} node=${selectedNode} />
      <${GoalTaskRelationStrip} node=${selectedNode} />
      <${GoalLifecycleActionPanel} node=${selectedNode} />

      <${DetailTabs} active=${activeTab} />

      ${error ? html`<${ErrorState} message=${error} />` : null}
      ${loading && !detail ? html`<${LoadingState}>goal detail 로드 중...<//>` : null}

      ${activeTab === 'summary' ? html`
        <div class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] p-4">
          <div class="mb-2 flex flex-wrap items-center gap-2">
            <span class="text-2xs font-semibold uppercase text-text-muted">Goal FSM</span>
            <span class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs font-semibold text-text-body">
              ${selectedNode.goal_fsm.source}
            </span>
          </div>
          <div class="grid grid-cols-[repeat(auto-fit,minmax(150px,1fr))] gap-2 text-xs text-text-body">
            <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
              <div class="text-3xs uppercase text-text-muted">state</div>
              <div class="mt-1 font-semibold text-text-strong">${goalPhaseLabel(selectedNode.goal_fsm.state)}</div>
            </div>
            <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
              <div class="text-3xs uppercase text-text-muted">activity</div>
              <div class="mt-1 font-semibold text-text-strong">${goalFsmObservationLabel(selectedNode.goal_fsm.activity_observation)}</div>
            </div>
          </div>
          ${selectedNode.goal_fsm.next_actions.length > 0 ? html`
            <div class="mt-3 flex flex-wrap gap-1.5">
              ${selectedNode.goal_fsm.next_actions.map(action => html`
                <code key=${action} class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-1.5 py-0.5 text-3xs text-text-secondary">${action}</code>
              `)}
            </div>
          ` : null}
        </div>

        <div class="grid grid-cols-[repeat(auto-fit,minmax(140px,1fr))] gap-3">
          <${DetailMetric} label="목표 달성" value=${attainmentValueLabel(selectedNode.attainment)} tone=${attainmentTone(selectedNode.attainment)} />
          <${DetailMetric} label="작업" value=${`${selectedNode.task_done_count}/${selectedNode.task_count}`} tone=${selectedNode.task_done_count === selectedNode.task_count && selectedNode.task_count > 0 ? 'ok' : 'default'} />
          <${DetailMetric} label="연결된 키퍼" value=${selectedNode.linked_keeper_names.length} />
          <${DetailMetric} label="승인 대기" value=${selectedNode.pending_approval_count} tone=${selectedNode.pending_approval_count > 0 ? 'warn' : 'default'} />
          <${DetailMetric} label="연결 출처" value=${selectedNode.linkage_source} />
          <${DetailMetric}
            label="최근 활동"
            value=${selectedNode.stagnation_seconds == null
              ? 'unavailable'
              : selectedNode.stagnation_seconds > 0
                ? `${Math.floor(selectedNode.stagnation_seconds / SECONDS_PER_HOUR)}h idle`
                : 'now'}
          />
        </div>

        <div class=${CARD_BOX}>
          <div class="mb-3 flex items-center justify-between gap-3">
            <div>
              <div class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">Goal 범위 태스크</div>
              <div class="mt-1 text-sm text-text-body">이 goal에 직접 연결되는 새 태스크를 backlog에 넣습니다.</div>
            </div>
          </div>
          <${TaskCreateForm} goalId=${selectedNode.id} goalTitle=${selectedNode.title} />
        </div>
      ` : null}

      ${activeTab === 'tasks' ? html`
        ${detail ? (
          detail.linked_tasks.length > 0
            ? html`
              <div class="flex flex-col gap-2">
                ${detail.linked_tasks.map(task => html`<${TreeTask} key=${task.id} task=${task} />`)}
              </div>
            `
            : html`<${EmptyState} message="이 goal에 직접 연결된 태스크가 없습니다" compact />`
        ) : null}
      ` : null}

      ${activeTab === 'evidence' ? html`
        <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
          <div class="flex flex-col gap-4">
            <div class=${CARD_BOX}>
              <div class="mb-3 text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">키퍼 준비 상태</div>
              ${detail ? (
                detail.linked_keepers.length > 0
                  ? html`
                    <div class="flex flex-col gap-2">
                      ${detail.linked_keepers.map(keeper => html`<${KeeperCard} key=${keeper.name} keeper=${keeper} />`)}
                    </div>
                  `
                  : html`<${EmptyState} message="연결된 keeper가 없습니다" compact />`
              ) : null}
            </div>

            <div class=${CARD_BOX}>
              <div class="mb-3 text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">승인 대기</div>
              ${detail ? (
                detail.approvals.length > 0
                  ? html`
                    <div class="flex flex-col gap-2">
                      ${detail.approvals.map((approval, index) => html`
                        <div key=${String(approval.id ?? index)} class="rounded-[var(--r-1)] border border-warn/20 bg-warn/6 p-3 text-xs">
                          <div class="flex flex-wrap items-center justify-between gap-2">
                            <strong class="text-text-strong">${String(approval.tool_name ?? '(unknown tool)')}</strong>
                            <span class="text-text-dim">Human HITL · nonblocking</span>
                          </div>
                          <div class="mt-2 text-text-muted">${String(approval.input_preview ?? 'pending operator decision')}</div>
                        </div>
                      `)}
                    </div>
                  `
                  : html`<${EmptyState} message="approval 대기 없음" compact />`
              ) : null}
            </div>
          </div>

          <div class=${CARD_BOX}>
            <div class="mb-3 text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">통합 타임라인</div>
            ${detail ? html`<${GoalTimeline} events=${detail.timeline} />` : null}
          </div>
        </div>
      ` : null}
    </section>
  `
}

export function GoalTree() {
  useEffect(() => {
    void refreshTree()
  }, [])

  const data = treeData.value
  const loading = treeLoading.value
  const error = treeError.value
  const query = filterQuery.value
  const activePhaseFilter = treePhaseFilter.value
  const selectedId = selectedGoalId.value
  const routeGoalId = cleanRouteGoalId(route.value.params.goal)

  const visibleTree = useMemo(
    () => {
      if (!data) return []
      const filtered = filterGoalTree(filterGoalTreeByPhase(data.tree, activePhaseFilter), query)
      return [...filtered].sort((a, b) => (a.priority ?? 99) - (b.priority ?? 99))
    },
    [activePhaseFilter, data, query],
  )

  const allNodes = useMemo(
    () => (data ? flattenGoalTree(data.tree) : []),
    [data],
  )

  const visibleNodes = useMemo(
    () => flattenGoalTree(visibleTree),
    [visibleTree],
  )

  const selectedNode = useMemo(
    () => visibleNodes.find(node => node.id === selectedId) ?? null,
    [selectedId, visibleNodes],
  )

  useEffect(() => {
    if (!data || allNodes.length === 0) {
      selectedGoalId.value = null
      return
    }
    if (visibleNodes.length === 0) {
      selectedGoalId.value = null
      return
    }
    if (routeGoalId) {
      const expansionPath = goalExpansionPath(data.tree, routeGoalId)
      if (expansionPath && visibleNodes.some(node => node.id === routeGoalId)) {
        if (selectedGoalId.value !== routeGoalId) selectedGoalId.value = routeGoalId
        if (expansionPath.some(id => !expandedNodes.value.has(id))) {
          expandedNodes.value = new Set([...expandedNodes.value, ...expansionPath])
        }
        return
      }
    }
    if (!selectedGoalId.value || !visibleNodes.some(node => node.id === selectedGoalId.value)) {
      selectedGoalId.value = visibleNodes[0]!.id
      expandedNodes.value = new Set([visibleNodes[0]!.id])
    }
  }, [allNodes, data, routeGoalId, visibleNodes])

  useEffect(() => {
    if (!selectedId) {
      detailData.value = null
      detailError.value = null
      return
    }
    void refreshGoalDetail(selectedId)
  }, [selectedId])

  const phaseCounts = useMemo(() => {
    const counts: Record<GoalPhaseFilter, number> = {
      all: allNodes.length,
      executing: 0,
      blocked: 0,
      paused: 0,
      completed: 0,
      dropped: 0,
    }
    for (const node of allNodes) {
      if (node.phase in counts) {
        counts[node.phase as Exclude<GoalPhaseFilter, 'all'>] += 1
      }
    }
    return counts
  }, [allNodes])

  const isFiltering = query.trim() !== '' || activePhaseFilter !== 'all'

  return html`
    <div class="v2-workspace-surface flex flex-col gap-5">
      <section class="${GOAL_PANEL} v2-workspace-panel" aria-label="목표 관리자">
        <div class="mb-4 flex flex-wrap items-start justify-between gap-4">
          <div class="max-w-190">
            <h3 class="text-2xl font-semibold tracking-[-0.02em] text-text-strong">목표 관리자</h3>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            ${data && data.tree.length > 0 ? html`
              <input
                type="search"
                value=${query}
                placeholder="목표 / 태스크 제목 필터"
                aria-label="목표 트리 필터"
                onInput=${(e: Event) => { filterQuery.value = (e.target as HTMLInputElement).value }}
                class="min-w-45 max-w-65 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-xs text-text-body placeholder:text-text-dim focus:outline-none focus:border-accent-fg"
              />
              <${ActionButton} variant="ghost" size="sm" class="v2-workspace-action" onClick=${() => expandAll(data.tree)}>
                모두 펼치기
              <//>
              <${ActionButton} variant="ghost" size="sm" class="v2-workspace-action" onClick=${collapseAll}>
                모두 접기
              <//>
            ` : null}
            <${ActionButton}
              variant="ghost"
              size="md"
              class="v2-workspace-action"
              disabled=${loading}
              onClick=${() => { void refreshTree() }}
            >
              ${loading ? '새로고침 중...' : '새로고침'}
            <//>
          </div>
        </div>

        ${data && data.tree.length > 0 ? html`
          <div class="mb-4 flex flex-wrap items-center gap-2">
            <span class="text-3xs font-semibold uppercase tracking-[var(--track-label)] text-text-muted">목표 단계</span>
            <${FilterChips}
              chips=${([
                'all',
                'executing',
                'blocked',
                'paused',
                'completed',
                'dropped',
              ] as GoalPhaseFilter[]).map(filter => ({
                key: filter,
                label: phaseFilterLabel(filter),
                count: phaseCounts[filter],
              }))}
              active=${treePhaseFilter}
              tone="accent"
              size="sm"
            />
          </div>
        ` : null}

        ${error ? html`<${ErrorState} message=${error} />` : null}

        ${loading && data ? html`
          <div class="text-3xs text-text-dim" data-testid="goal-tree-loading">목표 트리 갱신 중...</div>
        ` : null}

        ${data ? html`
          <${TreeSummary}
            summary=${data.summary}
            awaitingVerificationCount=${countAwaitingVerificationInTree(data.tree)}
          />
        ` : null}
      </section>

      ${loading && !data ? html`
        <${LoadingState}>goal manager 로드 중...<//>
      ` : data && data.tree.length === 0 ? html`
        <${EmptyState} message="등록된 목표가 없습니다." />
      ` : data && isFiltering && visibleTree.length === 0 ? html`
        <section class="py-4 text-center text-xs text-text-dim" aria-label="필터 결과 없음">
          필터 결과 없음 (${data.tree.length} 목표)
        </section>
      ` : data ? html`
        <div class="grid gap-4 xl:grid-cols-[minmax(0,1.05fr)_minmax(360px,0.95fr)]">
          <section class="flex flex-col gap-2" aria-label="목표 트리">
            ${visibleTree.map(node => html`<${TreeNode} key=${node.id} node=${node} depth=${0} />`)}
          </section>
          <${GoalDetailPanel} selectedNode=${selectedNode} />
        </div>
      ` : null}
    </div>
  `
}
