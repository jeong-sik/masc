// Goal Manager — goal-first planning surface with health, detail, and evidence.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useMemo } from 'preact/hooks'
import { fetchDashboardGoalDetail, fetchDashboardGoalsTree } from '../../api/dashboard'
import {
  goalTreeData as treeData,
  goalTreeError as treeError,
  goalTreeLoading as treeLoading,
  hydrateGoalTreeSnapshot,
} from '../../goal-tree-state'
import { coordinationFsmSnapshot } from '../../store'
import { EmptyState, ErrorState, LoadingState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import { FilterChips } from '../common/filter-chips'
import { StatusBadge } from '../common/status-badge'
import { TimeAgo } from '../common/time-ago'
import { TaskCreateForm } from '../task-manage/task-create-form'
import type {
  DashboardGoalDetailResponse,
  DashboardCoordinationFsmViolation,
  GoalDetailKeeper,
  GoalDetailTimelineEvent,
  GoalTreeNode,
  GoalTreeTask,
  GoalTreeSummary,
  GoalVerificationSummary,
} from '../../types'
import {
  horizonLabel,
  horizonColor,
  priorityStars,
  countAwaitingVerificationTasks,
  countAwaitingVerificationInTree,
  countGoalVerificationInTree,
  type GoalPhaseFilter,
  goalPhaseLabel,
  goalPhaseStatus,
  matchesGoalPhaseFilter,
  phaseFilterLabel,
} from './goal-helpers'

type GoalDetailTab = 'summary' | 'tasks' | 'evidence'

/**
 * Pure hierarchy filter for goal tree nodes.
 *
 * Case-insensitive substring match on `node.title` and on `task.title` for
 * any task attached to the node. Ancestors of matching nodes are preserved
 * so the operator retains context (parent goal, horizon) — the tree shape
 * is never broken by the filter.
 */
export function filterGoalTree(
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

export function filterGoalTreeByPhase(
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

function badgeLabel(badge: string): string {
  switch (badge) {
    case 'awaiting_approval': return '승인 대기'
    case 'sandbox': return 'Sandbox'
    case 'cascade': return 'Cascade'
    case 'task_verification_pending': return 'Task 검증 대기'
    case 'stalled': return 'Stalled'
    case 'linkage_warning': return 'Linkage'
    default: return badge
  }
}

function badgeClass(badge: string): string {
  switch (badge) {
    case 'awaiting_approval':
    case 'cascade':
    case 'task_verification_pending':
    case 'stalled':
      return 'border-warn/30 bg-warn/10 text-warn'
    case 'sandbox':
      return 'border-accent/30 bg-[var(--accent-10)] text-accent'
    case 'linkage_warning':
      return 'border-bad/30 bg-bad/10 text-bad'
    default:
      return 'border-card-border/60 bg-white/4 text-text-body'
  }
}

function healthLabel(health: GoalTreeNode['health']): string {
  switch (health) {
    case 'done': return 'Done'
    case 'paused': return 'Paused'
    case 'blocked': return 'Blocked'
    case 'at_risk': return 'At Risk'
    case 'on_track': return 'On Track'
    default: return health
  }
}

function healthClass(health: GoalTreeNode['health']): string {
  switch (health) {
    case 'done': return 'border-sky-400/30 bg-sky-500/10 text-sky-300'
    case 'paused': return 'border-warn/30 bg-warn/10 text-warn'
    case 'blocked': return 'border-bad/35 bg-bad/10 text-bad'
    case 'at_risk': return 'border-warn/30 bg-warn/10 text-warn'
    case 'on_track': return 'border-ok/30 bg-ok/10 text-ok'
    default: return 'border-card-border/60 bg-white/4 text-text-body'
  }
}

function blockerSourceLabel(source: GoalTreeNode['blocking_source']): string {
  switch (source) {
    case 'goal_phase': return 'Goal phase'
    case 'child_goal': return 'Child goal'
    case 'approval': return 'Approval'
    case 'keeper_runtime': return 'Keeper runtime'
    case 'task_fsm': return 'Task FSM'
    case 'goal_linkage': return 'Goal linkage'
    case 'stalled': return 'Stalled'
    default: return source
  }
}

function blockerSourceClass(source: GoalTreeNode['blocking_source']): string {
  switch (source) {
    case 'goal_phase':
    case 'keeper_runtime':
      return 'border-bad/25 bg-bad/10 text-bad'
    case 'child_goal':
    case 'approval':
    case 'task_fsm':
    case 'goal_linkage':
    case 'stalled':
      return 'border-warn/25 bg-warn/10 text-warn'
    default:
      return 'border-card-border/60 bg-white/4 text-text-body'
  }
}

function keeperTrustDispositionClass(
  trust: GoalDetailKeeper['runtime_trust'],
): string {
  const disposition = trust?.disposition
  if (disposition === 'Alert') return 'border-bad/25 bg-bad/10 text-bad'
  if (disposition === 'Pause' || trust?.needs_attention) {
    return 'border-warn/25 bg-warn/10 text-warn'
  }
  if (disposition === 'Pass') return 'border-ok/25 bg-ok/10 text-ok'
  return 'border-card-border/60 bg-white/4 text-text-body'
}

function timelineSeverityClass(severity: GoalDetailTimelineEvent['severity']): string {
  switch (severity) {
    case 'bad': return 'border-bad/25 bg-bad/10 text-bad'
    case 'warn': return 'border-warn/25 bg-warn/10 text-warn'
    default: return 'border-card-border/50 bg-white/3 text-text-body'
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

const EMPTY_GOAL_VERIFICATION_SUMMARY: GoalVerificationSummary = {
  effective_policy: null,
  open_request: null,
  approve_count: 0,
  reject_count: 0,
  remaining_possible: 0,
}

function toggleNode(id: string) {
  const next = new Set(expandedNodes.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedNodes.value = next
}

function selectGoal(id: string) {
  selectedGoalId.value = id
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
    treeError.value = err instanceof Error ? err.message : String(err)
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
    detailError.value = err instanceof Error ? err.message : String(err)
  } finally {
    if (detailRequestSeq === reqId) detailLoading.value = false
  }
}

function ConvergenceBar({ pct, size = 'md' }: { pct: number; size?: 'sm' | 'md' }) {
  const clamped = Math.max(0, Math.min(100, pct))
  const barColor =
    clamped >= 80 ? 'var(--ok)'
    : clamped >= 50 ? 'var(--amber-bright)'
    : clamped >= 20 ? '#fb923c'
    : 'var(--bad)'

  const h = size === 'sm' ? 'h-1.5' : 'h-2.5'
  return html`
    <div class="flex items-center gap-2">
      <div class="flex-1 ${h} rounded-sm bg-white/10 overflow-hidden">
        <div class="${h} rounded-sm transition-all duration-500" style="width:${clamped}%;background:${barColor}"></div>
      </div>
      <span class="text-2xs font-semibold tabular-nums text-text-muted w-9 text-right">${clamped}%</span>
    </div>
  `
}

function TreeSummary({
  summary,
  awaitingVerificationCount,
  goalVerificationCount,
}: {
  summary: GoalTreeSummary
  awaitingVerificationCount: number
  goalVerificationCount: number
}) {
  return html`
    <div class="grid grid-cols-[repeat(auto-fit,minmax(128px,1fr))] gap-3">
      <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-3 text-center">
        <div class="text-2xl font-bold text-text-strong tabular-nums">${summary.total_goals}</div>
        <div class="mt-1 text-3xs font-semibold uppercase tracking-widest text-text-muted">전체 목표</div>
      </div>
      <div class="rounded border border-ok/25 bg-ok/10 p-3 text-center">
        <div class="text-2xl font-bold text-ok tabular-nums">${summary.active_goals}</div>
        <div class="mt-1 text-3xs font-semibold uppercase tracking-widest text-ok/80">On Track</div>
      </div>
      <div class="rounded border border-warn/25 bg-warn/10 p-3 text-center">
        <div class="text-2xl font-bold text-warn tabular-nums">${summary.at_risk_goals}</div>
        <div class="mt-1 text-3xs font-semibold uppercase tracking-widest text-warn/80">At Risk</div>
      </div>
      <div class="rounded border border-bad/25 bg-bad/10 p-3 text-center">
        <div class="text-2xl font-bold text-bad tabular-nums">${summary.blocked_goals}</div>
        <div class="mt-1 text-3xs font-semibold uppercase tracking-widest text-bad/80">Blocked</div>
      </div>
      <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-3 text-center">
        <div class="text-2xl font-bold text-text-strong tabular-nums">${summary.pending_approvals}</div>
        <div class="mt-1 text-3xs font-semibold uppercase tracking-widest text-text-muted">Approval</div>
      </div>
      ${goalVerificationCount > 0 ? html`
        <div class="rounded border border-amber-400/30 bg-amber-400/10 p-3 text-center">
          <div class="text-2xl font-bold text-amber-200 tabular-nums">${goalVerificationCount}</div>
          <div class="mt-1 text-3xs font-semibold uppercase tracking-widest text-amber-100/80">Goal 검증 대기</div>
        </div>
      ` : null}
      ${awaitingVerificationCount > 0 ? html`
        <div class="rounded border border-accent/30 bg-[var(--accent-10)] p-3 text-center">
          <div class="text-2xl font-bold text-accent tabular-nums">${awaitingVerificationCount}</div>
          <div class="mt-1 text-3xs font-semibold uppercase tracking-widest text-accent/80">Task 검증 대기</div>
        </div>
      ` : null}
      <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-3">
        <div class="mb-2 text-3xs font-semibold uppercase tracking-widest text-text-muted">전체 수렴도</div>
        <${ConvergenceBar} pct=${summary.overall_convergence_pct} />
      </div>
    </div>
  `
}

function HealthBadge({ health }: { health: GoalTreeNode['health'] }) {
  return html`
    <span class="inline-flex items-center rounded border px-2 py-0.5 text-3xs font-semibold uppercase tracking-wider ${healthClass(health)}">
      ${healthLabel(health)}
    </span>
  `
}

function GoalBadges({ badges }: { badges: string[] }) {
  if (badges.length === 0) return null
  return html`
    <div class="flex flex-wrap gap-1.5">
      ${badges.map(badge => html`
        <span
          key=${badge}
          class="inline-flex items-center rounded border px-2 py-0.5 text-3xs font-semibold uppercase tracking-wider ${badgeClass(badge)}"
        >
          ${badgeLabel(badge)}
        </span>
      `)}
    </div>
  `
}

function coordinationViolationsForGoal(goalId: string): DashboardCoordinationFsmViolation[] {
  const violations = coordinationFsmSnapshot.value?.violations ?? []
  return violations.filter(violation => violation.refs?.goal_id === goalId)
}

function TreeTask({ task }: { task: GoalTreeTask }) {
  return html`
    <div class="flex flex-wrap items-center gap-2 rounded bg-white/3 px-2 py-1.5 text-xs">
      <span class="size-2 rounded-sm shrink-0" style="background:${task.status_color}"></span>
      <span class="min-w-0 flex-1 truncate text-text-body">${task.title}</span>
      <span class="rounded border border-card-border/60 bg-white/4 px-1.5 py-0.5 text-3xs font-medium text-text-muted">
        ${task.linkage_source === 'explicit' ? 'goal_id' : 'title tag'}
      </span>
      ${task.assignee ? html`
        <span class="rounded border border-accent/20 bg-[var(--accent-10)] px-1.5 py-0.5 text-3xs font-medium text-accent">${task.assignee}</span>
      ` : null}
      <${StatusBadge} status=${task.status} />
    </div>
  `
}

function TreeNode({ node, depth }: { node: GoalTreeNode; depth: number }) {
  const isExpanded = expandedNodes.value.has(node.id)
  const hasContent = node.children.length > 0 || node.tasks.length > 0
  const isSelected = selectedGoalId.value === node.id
  const verificationSummary = node.verification_summary ?? EMPTY_GOAL_VERIFICATION_SUMMARY
  const coordinationViolations = coordinationViolationsForGoal(node.id)
  const coordinationHasError = coordinationViolations.some(v => v.severity === 'error')
  const indent = depth * 20
  const headerBase = isSelected
    ? 'group flex items-start gap-3 rounded border border-accent/35 bg-[rgba(11,18,32,0.94)] p-3 transition-colors w-full text-left shadow-[0_0_0_1px_rgba(110,231,255,0.08)]'
    : 'group flex items-start gap-3 rounded border border-card-border/60 bg-[rgba(8,13,22,0.86)] p-3 transition-colors hover:border-card-border/90 w-full text-left'

  return html`
    <div class="flex flex-col" style="margin-left:${indent}px">
      <button
        type="button"
        class="${headerBase} ${hasContent ? 'cursor-pointer' : ''} focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-accent"
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
            <span
              class="shrink-0 rounded-md border border-white/10 bg-white/5 px-2 py-0.5 text-3xs font-bold uppercase tracking-widest"
              style="color:${horizonColor(node.horizon)}"
            >
              ${horizonLabel(node.horizon)}
            </span>
            <${StatusBadge} status=${goalPhaseStatus(node.phase)} label=${goalPhaseLabel(node.phase)} />
            <span class="break-words text-base font-semibold text-text-strong line-clamp-2">${node.title}</span>
            <span class="text-2xs text-text-dim">${priorityStars(node.priority)}</span>
          </div>

          <div class="flex flex-wrap items-center gap-2.5 text-2xs text-text-muted">
            <${HealthBadge} health=${node.health} />
            <${StatusBadge} status=${node.status} />
            ${node.task_count > 0 ? html`<span>${node.task_done_count}/${node.task_count} 태스크</span>` : null}
            ${(() => {
              const awaiting = countAwaitingVerificationTasks(node.tasks)
              return awaiting > 0 ? html`
                <span class="rounded border border-accent/30 bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-medium text-accent" title="verifier keeper의 독립 실측을 기다리는 task">
                  Task 검증 대기 ${awaiting}
                </span>
              ` : null
            })()}
            ${node.pending_verification_count > 0 ? html`
              <span class="rounded border border-amber-400/30 bg-amber-400/10 px-2 py-0.5 text-3xs font-medium text-amber-200">
                Goal 검증 대기 ${node.pending_verification_count}
              </span>
            ` : null}
            ${node.phase === 'awaiting_approval' ? html`
              <span class="rounded border border-rose-400/30 bg-rose-400/10 px-2 py-0.5 text-3xs font-medium text-rose-200">
                승인 대기
              </span>
            ` : null}
            ${node.child_count > 0 ? html`<span>${node.child_count} 하위 목표</span>` : null}
            ${verificationSummary.effective_policy ? html`
              <span>quorum ${verificationSummary.approve_count}/${verificationSummary.effective_policy.required_verdicts}</span>
            ` : null}
            ${node.pending_approval_count > 0 ? html`
              <span class="rounded border border-warn/30 bg-warn/10 px-2 py-0.5 text-3xs font-medium text-warn">
                approval ${node.pending_approval_count}
              </span>
            ` : null}
            ${coordinationViolations.length > 0 ? html`
              <span
                class="rounded border px-2 py-0.5 text-3xs font-medium ${coordinationHasError ? 'border-bad/30 bg-bad/10 text-bad' : 'border-warn/30 bg-warn/10 text-warn'}"
                title="Goal x Task x Board x Reward"
              >
                FSM ${coordinationViolations.length}
              </span>
            ` : null}
            ${node.blocking_source !== 'none' ? html`
              <span
                class="rounded border px-2 py-0.5 text-3xs font-medium ${blockerSourceClass(node.blocking_source)}"
                title=${node.blocking_reason}
              >
                ${blockerSourceLabel(node.blocking_source)}
              </span>
            ` : null}
            ${node.infra_risk_count > 0 ? html`
              <span class="rounded border border-bad/25 bg-bad/10 px-2 py-0.5 text-3xs font-medium text-bad">
                infra ${node.infra_risk_count}
              </span>
            ` : null}
            ${node.latest_keeper_ref ? html`
              <span class="rounded border border-card-border/60 bg-white/4 px-2 py-0.5 text-3xs font-medium text-text-body">
                ${node.latest_keeper_ref}${node.latest_turn_ref != null ? ` · turn ${node.latest_turn_ref}` : ''}
              </span>
            ` : null}
          </div>

          <div class="mt-2 max-w-110">
            <${ConvergenceBar} pct=${node.convergence_pct} size="sm" />
          </div>

          ${node.blocking_source !== 'none' && node.blocking_reason ? html`
            <div class="mt-2 text-xs leading-relaxed text-text-muted">
              ${node.blocking_reason}
            </div>
          ` : null}

          ${node.badges.length > 0 ? html`
            <div class="mt-2">
              <${GoalBadges} badges=${node.badges} />
            </div>
          ` : null}
        </div>

        <div class="flex shrink-0 flex-col items-end gap-1">
          <span class="text-3xs text-text-dim">
            <${TimeAgo} timestamp=${node.last_activity_at} />
          </span>
          ${isSelected ? html`
            <span class="rounded border border-accent/30 bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-semibold text-accent">selected</span>
          ` : null}
        </div>
      </button>

      ${isExpanded ? html`
        <div class="mt-1.5 flex flex-col gap-1.5">
          ${verificationSummary.open_request ? html`
            <div class="ml-6 rounded border border-amber-400/20 bg-amber-400/8 p-2 text-xs text-amber-100">
              <div class="mb-1 text-3xs font-semibold uppercase tracking-widest text-amber-200/80">Goal Verification</div>
              <div>request ${verificationSummary.open_request.id}</div>
              <div>
                quorum ${verificationSummary.approve_count}/${verificationSummary.open_request.policy_snapshot.required_verdicts},
                reject ${verificationSummary.reject_count},
                remaining ${verificationSummary.remaining_possible}
              </div>
            </div>
          ` : null}
          ${node.tasks.length > 0 ? html`
            <div class="ml-6 flex flex-col gap-1 rounded border border-card-border/40 bg-[rgba(5,9,16,0.6)] p-2">
              <div class="mb-1 text-3xs font-semibold uppercase tracking-widest text-text-dim">연결된 태스크</div>
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
    <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-3">
      <div class="text-3xs font-semibold uppercase tracking-widest text-text-muted">${label}</div>
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
          class="rounded border px-3 py-1.5 text-xs font-semibold uppercase tracking-wider transition-colors ${active === tab
            ? 'border-accent/35 bg-[var(--accent-10)] text-accent'
            : 'border-card-border/60 bg-white/3 text-text-body hover:border-card-border/90'}"
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
  const latestEvent = keeper.latest_causal_event ?? trust?.latest_causal_event ?? null
  const trustSummary =
    trust?.attention_reason
    ?? trust?.disposition_reason
    ?? trust?.execution_summary?.mutation_guard_summary
    ?? trust?.execution_summary?.sandbox_summary
    ?? null

  return html`
    <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-3">
      <div class="flex items-start justify-between gap-3">
        <div>
          <div class="text-sm font-semibold text-text-strong">${keeper.name}</div>
          <div class="mt-1 text-2xs text-text-muted">${keeper.agent_name}</div>
        </div>
        <div class="flex flex-wrap justify-end gap-1.5">
          ${trust?.disposition ? html`
            <span class="rounded border px-2 py-0.5 text-3xs font-semibold ${keeperTrustDispositionClass(trust)}">
              Trust ${trust.disposition}
            </span>
          ` : null}
          ${keeper.latest_execution_outcome ? html`
            <span class="rounded border border-card-border/60 bg-white/4 px-2 py-0.5 text-3xs font-semibold text-text-body">
              ${keeper.latest_execution_outcome}
            </span>
          ` : null}
        </div>
      </div>
      <div class="mt-3 grid grid-cols-2 gap-2 text-2xs text-text-muted">
        <div>Sandbox</div>
        <div class="text-right text-text-body">${keeper.sandbox_profile}</div>
        <div>Approval</div>
        <div class="text-right text-text-body">${trust?.approval_state?.summary ?? keeper.approval_profile ?? '-'}</div>
        <div>Cascade</div>
        <div class="text-right text-text-body">${keeper.cascade_name}</div>
        <div>Outcome</div>
        <div class="text-right text-text-body">${keeper.cascade_outcome ?? '-'}</div>
      </div>
      ${trustSummary || trust?.approval_state?.state || trust?.next_human_action ? html`
        <div class="mt-3 rounded border border-card-border/50 bg-white/3 p-3">
          <div class="text-3xs font-semibold uppercase tracking-widest text-text-muted">Trust Summary</div>
          ${trustSummary ? html`
            <div class="mt-2 text-xs leading-relaxed text-text-body">${trustSummary}</div>
          ` : null}
          <div class="mt-2 flex flex-wrap gap-2 text-3xs text-text-muted">
            ${trust?.approval_state?.state ? html`
              <span>approval ${trust.approval_state.state}</span>
            ` : null}
            ${trust?.execution_summary?.tool_contract_result ? html`
              <span>contract ${trust.execution_summary.tool_contract_result}</span>
            ` : null}
            ${trust?.next_human_action ? html`
              <span>next ${trust.next_human_action}</span>
            ` : null}
          </div>
        </div>
      ` : null}
      ${latestEvent ? html`
        <div class="mt-3 rounded border border-card-border/50 bg-white/3 p-3">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <div class="text-3xs font-semibold uppercase tracking-widest text-text-muted">Latest Keeper Event</div>
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
        <div key=${`${event.kind}:${event.lane}:${event.ts}`} class="rounded border p-3 ${timelineSeverityClass(event.severity)}">
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
      <section class="rounded border border-card-border/70 bg-[rgba(9,14,24,0.88)] p-5">
        <${EmptyState} message="왼쪽에서 목표를 선택하면 Summary / Tasks / Evidence가 표시됩니다." />
      </section>
    `
  }

  const detail = data?.goal.id === selectedNode.id ? data : null
  const verificationSummary = selectedNode.verification_summary ?? EMPTY_GOAL_VERIFICATION_SUMMARY

  return html`
    <section class="flex flex-col gap-4 rounded border border-card-border/70 bg-[rgba(9,14,24,0.88)] p-5">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="max-w-150">
          <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-text-muted">Goal Detail</div>
          <h3 class="mt-1 text-xl font-semibold tracking-[-0.02em] text-text-strong">${selectedNode.title}</h3>
          <div class="mt-2 flex flex-wrap items-center gap-2">
            <${HealthBadge} health=${selectedNode.health} />
            <${StatusBadge} status=${selectedNode.status} />
            <${StatusBadge} status=${goalPhaseStatus(selectedNode.phase)} label=${goalPhaseLabel(selectedNode.phase)} />
            <span class="rounded border border-white/10 bg-white/5 px-2 py-0.5 text-3xs font-semibold uppercase tracking-widest" style="color:${horizonColor(selectedNode.horizon)}">
              ${horizonLabel(selectedNode.horizon)}
            </span>
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

      <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2 text-sm text-text-body">
        ${selectedNode.status_reason}
      </div>

      <${DetailTabs} active=${activeTab} />

      ${error ? html`<${ErrorState} message=${error} />` : null}
      ${loading && !detail ? html`<${LoadingState}>goal detail 로드 중...<//>` : null}

      ${activeTab === 'summary' ? html`
        ${selectedNode.blocking_source !== 'none' ? html`
          <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-4">
            <div class="mb-2 flex flex-wrap items-center gap-2">
              <span class="text-2xs font-semibold uppercase tracking-widest text-text-muted">Blocking Context</span>
              <span class="rounded border px-2 py-0.5 text-3xs font-semibold ${blockerSourceClass(selectedNode.blocking_source)}">
                ${blockerSourceLabel(selectedNode.blocking_source)}
              </span>
            </div>
            <div class="text-sm leading-relaxed text-text-body">${selectedNode.blocking_reason || selectedNode.status_reason}</div>
            <div class="mt-3 flex flex-wrap gap-2 text-3xs text-text-muted">
              ${selectedNode.latest_keeper_ref ? html`
                <span>keeper ${selectedNode.latest_keeper_ref}</span>
              ` : null}
              ${selectedNode.latest_turn_ref != null ? html`
                <span>turn ${selectedNode.latest_turn_ref}</span>
              ` : null}
              ${selectedNode.stalled_since ? html`
                <span>since <${TimeAgo} timestamp=${selectedNode.stalled_since} /></span>
              ` : null}
            </div>
          </div>
        ` : null}

        <div class="grid grid-cols-[repeat(auto-fit,minmax(140px,1fr))] gap-3">
          <${DetailMetric} label="Task" value=${`${selectedNode.task_done_count}/${selectedNode.task_count}`} tone=${selectedNode.task_done_count === selectedNode.task_count && selectedNode.task_count > 0 ? 'ok' : 'default'} />
          <${DetailMetric} label="Linked Keepers" value=${selectedNode.linked_keeper_names.length} />
          <${DetailMetric} label="Approval" value=${selectedNode.pending_approval_count} tone=${selectedNode.pending_approval_count > 0 ? 'warn' : 'default'} />
          <${DetailMetric} label="Goal Verification" value=${selectedNode.pending_verification_count} tone=${selectedNode.pending_verification_count > 0 ? 'warn' : 'default'} />
          <${DetailMetric} label="Infra Risk" value=${selectedNode.infra_risk_count} tone=${selectedNode.infra_risk_count > 0 ? 'bad' : 'default'} />
          <${DetailMetric} label="Linkage" value=${selectedNode.linkage_source} tone=${selectedNode.linkage_warning_count > 0 ? 'warn' : 'default'} />
          <${DetailMetric} label="Last Activity" value=${selectedNode.stagnation_seconds > 0 ? `${Math.floor(selectedNode.stagnation_seconds / 3600)}h idle` : 'now'} tone=${selectedNode.badges.includes('stalled') ? 'warn' : 'default'} />
        </div>

        ${verificationSummary.effective_policy ? html`
          <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-4">
            <div class="mb-2 text-2xs font-semibold uppercase tracking-widest text-text-muted">Goal Verification</div>
            <div class="flex flex-wrap items-center gap-2 text-xs text-text-body">
              <span class="rounded border border-amber-400/20 bg-amber-400/8 px-2 py-1 text-amber-100">
                quorum ${verificationSummary.approve_count}/${verificationSummary.effective_policy.required_verdicts}
              </span>
              <span>reject ${verificationSummary.reject_count}</span>
              <span>remaining ${verificationSummary.remaining_possible}</span>
            </div>
            <div class="mt-3 flex flex-wrap gap-1.5">
              ${verificationSummary.effective_policy.eligible_principals.map(principal => html`
                <span key=${`${principal.kind}:${principal.id}`} class="rounded border border-card-border/60 bg-white/4 px-2 py-0.5 text-3xs font-medium text-text-body">
                  ${principal.kind}:${principal.display_name ?? principal.id}
                </span>
              `)}
            </div>
            ${verificationSummary.open_request ? html`
              <div class="mt-3 rounded border border-amber-400/20 bg-amber-400/8 p-3 text-xs text-amber-100">
                <div>request ${verificationSummary.open_request.id}</div>
                <div class="mt-1">status ${verificationSummary.open_request.status}</div>
              </div>
            ` : null}
          </div>
        ` : null}

        ${selectedNode.badges.length > 0 ? html`
          <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-4">
            <div class="mb-2 text-2xs font-semibold uppercase tracking-widest text-text-muted">Badges</div>
            <${GoalBadges} badges=${selectedNode.badges} />
          </div>
        ` : null}

        <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-4">
          <div class="mb-3 flex items-center justify-between gap-3">
            <div>
              <div class="text-2xs font-semibold uppercase tracking-widest text-text-muted">Goal-Scoped Task</div>
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
            <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-4">
              <div class="mb-3 text-2xs font-semibold uppercase tracking-widest text-text-muted">Keeper Readiness</div>
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

            <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-4">
              <div class="mb-3 text-2xs font-semibold uppercase tracking-widest text-text-muted">Pending Approvals</div>
              ${detail ? (
                detail.approvals.length > 0
                  ? html`
                    <div class="flex flex-col gap-2">
                      ${detail.approvals.map((approval, index) => html`
                        <div key=${String(approval.id ?? index)} class="rounded border border-warn/20 bg-warn/6 p-3 text-xs">
                          <div class="flex flex-wrap items-center justify-between gap-2">
                            <strong class="text-text-strong">${String(approval.tool_name ?? 'tool')}</strong>
                            <span class="text-text-dim">${String(approval.risk_level ?? 'risk')}</span>
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

          <div class="rounded border border-card-border/60 bg-[var(--backdrop-deep)] p-4">
            <div class="mb-3 text-2xs font-semibold uppercase tracking-widest text-text-muted">Unified Timeline</div>
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

  const visibleTree = useMemo(
    () => {
      if (!data) return []
      return filterGoalTree(filterGoalTreeByPhase(data.tree, activePhaseFilter), query)
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
    if (!selectedGoalId.value || !visibleNodes.some(node => node.id === selectedGoalId.value)) {
      selectedGoalId.value = visibleNodes[0]!.id
      expandedNodes.value = new Set([visibleNodes[0]!.id])
    }
  }, [allNodes, data, visibleNodes])

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
      awaiting_verification: 0,
      awaiting_approval: 0,
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
    <div class="flex flex-col gap-5">
      <section class="rounded border border-card-border/70 bg-[rgba(9,14,24,0.88)] p-5">
        <div class="mb-4 flex flex-wrap items-start justify-between gap-4">
          <div class="max-w-190">
            <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-text-muted">Goal Manager</div>
            <h3 class="mt-1 text-2xl font-semibold tracking-[-0.02em] text-text-strong">목표 중심 계획 뷰</h3>
            <p class="mt-1.5 text-sm leading-relaxed text-text-muted">
              goal-task 연결, keeper evidence, approval 대기, sandbox/cascade 신호를 한 표면에서 봅니다.
              신규 태스크는 <code class="rounded bg-white/5 px-1 py-0.5 text-2xs text-text-strong">goal_id</code>로 직접 연결됩니다.
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            ${data && data.tree.length > 0 ? html`
              <input
                type="search"
                value=${query}
                placeholder="목표 / 태스크 제목 필터"
                aria-label="목표 트리 필터"
                onInput=${(e: Event) => { filterQuery.value = (e.target as HTMLInputElement).value }}
                class="min-w-45 max-w-65 rounded border border-white/10 bg-white/5 px-2 py-1 text-xs text-text-body placeholder:text-text-dim focus:outline-none focus:border-accent"
              />
              <${ActionButton} variant="ghost" size="sm" onClick=${() => expandAll(data.tree)}>
                모두 펼치기
              <//>
              <${ActionButton} variant="ghost" size="sm" onClick=${collapseAll}>
                모두 접기
              <//>
            ` : null}
            <${ActionButton}
              variant="ghost"
              size="md"
              disabled=${loading}
              onClick=${() => { void refreshTree() }}
            >
              ${loading ? '새로고침 중...' : '새로고침'}
            <//>
          </div>
        </div>

        ${data && data.tree.length > 0 ? html`
          <div class="mb-4 flex flex-wrap items-center gap-2">
            <span class="text-3xs font-semibold uppercase tracking-[0.18em] text-text-muted">Goal Phase</span>
            <${FilterChips}
              chips=${([
                'all',
                'executing',
                'awaiting_verification',
                'awaiting_approval',
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

        ${data ? html`
          <${TreeSummary}
            summary=${data.summary}
            awaitingVerificationCount=${countAwaitingVerificationInTree(data.tree)}
            goalVerificationCount=${countGoalVerificationInTree(data.tree)}
          />
        ` : null}
      </section>

      ${loading && !data ? html`
        <${LoadingState}>goal manager 로드 중...<//>
      ` : data && data.tree.length === 0 ? html`
        <${EmptyState} message="등록된 목표가 없습니다. masc_goal_upsert로 목표를 등록하세요. 연결 태스크는 task.goal_id가 우선이고, 제목의 [goal:<id>]는 레거시 fallback으로만 읽습니다." />
      ` : data && isFiltering && visibleTree.length === 0 ? html`
        <section class="py-4 text-center text-xs text-text-dim">
          필터 결과 없음 (${data.tree.length} 목표)
        </section>
      ` : data ? html`
        <div class="grid gap-4 xl:grid-cols-[minmax(0,1.05fr)_minmax(360px,0.95fr)]">
          <section class="flex flex-col gap-2">
            ${visibleTree.map(node => html`<${TreeNode} key=${node.id} node=${node} depth=${0} />`)}
          </section>
          <${GoalDetailPanel} selectedNode=${selectedNode} />
        </div>
      ` : null}
    </div>
  `
}
