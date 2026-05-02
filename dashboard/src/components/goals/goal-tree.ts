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
import { ringFocusClasses } from '../common/ring'
import { TimeAgo } from '../common/time-ago'
import { TaskCreateForm } from '../task-manage/task-create-form'
import { Tk } from '../tk'
import type {
  DashboardGoalDetailResponse,
  DashboardCoordinationFsmViolation,
  GoalDetailKeeper,
  GoalDetailTimelineEvent,
  GoalFsmProjection,
  GoalTreeNode,
  GoalTreeTask,
  GoalTreeSummary,
  GoalVerificationRequest,
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
  TaskProgressBar,
} from './goal-helpers'

type GoalDetailTab = 'summary' | 'tasks' | 'evidence'

const CARD_BOX = 'rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3'
const DECK_LABEL = 'font-mono text-3xs font-semibold uppercase tracking-[0.08em] text-[var(--color-fg-muted)]'
const DECK_META = 'font-mono text-3xs text-[var(--color-fg-disabled)]'
const DECK_CHIP = 'rounded-[var(--r-0)] border border-[var(--color-border-strong)] bg-[var(--color-bg-elevated)] px-1.5 py-0.5 font-mono text-3xs'
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
    case 'sandbox': return '샌드박스'
    case 'cascade': return 'Cascade'
    case 'task_verification_pending': return 'Task 검증 대기'
    case 'stalled': return '정체'
    case 'activity_unobserved': return '활동 관측 부족'
    case 'linkage_warning': return '연결 경고'
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
    case 'activity_unobserved':
      return 'border-card-border/60 bg-[var(--color-bg-elevated)] text-text-muted'
    case 'sandbox':
      return 'border-[var(--accent-30)] bg-[var(--accent-10)] text-accent-fg'
    case 'linkage_warning':
      return 'border-bad/30 bg-bad/10 text-bad'
    default:
      return 'border-card-border/60 bg-[var(--color-bg-elevated)] text-text-body'
  }
}

function healthLabel(health: GoalTreeNode['health']): string {
  switch (health) {
    case 'done': return '완료'
    case 'paused': return '일시정지'
    case 'blocked': return '차단'
    case 'at_risk': return '위험'
    case 'on_track': return '정상'
    default: return health
  }
}

function trustDispositionLabel(disposition: string | null | undefined): string | null {
  if (!disposition) return null
  return ({ Alert: '경보', Pause: '정지', Pass: '통과' } as Record<string, string>)[
    disposition
  ] ?? disposition
}

function healthClass(health: GoalTreeNode['health']): string {
  switch (health) {
    case 'done': return 'border-[var(--color-ok-border)] bg-[var(--color-ok-soft)] text-[var(--color-ok-fg)]'
    case 'paused': return 'border-warn/30 bg-warn/10 text-warn'
    case 'blocked': return 'border-bad/35 bg-bad/10 text-bad'
    case 'at_risk': return 'border-warn/30 bg-warn/10 text-warn'
    case 'on_track': return 'border-ok/30 bg-ok/10 text-ok'
    default: return 'border-card-border/60 bg-[var(--color-bg-elevated)] text-text-body'
  }
}

function blockerSourceLabel(source: GoalTreeNode['blocking_source']): string {
  switch (source) {
    case 'goal_phase': return 'Goal 단계'
    case 'child_goal': return '하위 Goal'
    case 'approval': return '승인'
    case 'keeper_runtime': return '키퍼 런타임'
    case 'task_fsm': return 'Task FSM'
    case 'goal_linkage': return 'Goal 연결'
    case 'stalled': return '정체'
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
      return 'border-card-border/60 bg-[var(--color-bg-elevated)] text-text-body'
  }
}

export function goalFsmStateKindLabel(kind: GoalFsmProjection['state_kind']): string {
  switch (kind) {
    case 'executing': return '실행'
    case 'verification_gate': return '검증 게이트'
    case 'approval_gate': return '승인 게이트'
    case 'blocked': return '차단'
    case 'paused': return '일시정지'
    case 'completed': return '완료'
    case 'dropped': return '중단'
    default: return kind
  }
}

export function goalFsmObservationLabel(
  observation: GoalFsmProjection['activity_observation'],
): string {
  switch (observation) {
    case 'runtime': return 'runtime evidence'
    case 'approval': return 'approval event'
    case 'task': return 'task update'
    case 'child': return 'child goal'
    case 'goal_metadata': return 'goal metadata only'
    default: return observation
  }
}

export function goalFsmStagnationLabel(
  status: GoalFsmProjection['stagnation_status'],
): string {
  switch (status) {
    case 'recent': return 'recent'
    case 'stalled': return 'stalled'
    case 'unobserved': return 'unobserved'
    default: return status
  }
}

function GoalFsmBadge({ fsm }: { fsm: GoalFsmProjection }) {
  const toneClass =
    fsm.stagnation_status === 'stalled'
      ? 'border-warn/30 bg-warn/10 text-warn'
      : fsm.state_kind === 'blocked'
        ? 'border-bad/35 bg-bad/10 text-bad'
        : fsm.state_kind === 'verification_gate' || fsm.state_kind === 'approval_gate'
          ? 'border-[var(--color-warn-border)] bg-[var(--color-warn-soft)] text-[var(--color-warn-fg)]'
          : 'border-card-border/60 bg-[var(--color-bg-elevated)] text-text-body'
  return html`
    <span
      class="inline-flex items-center rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-semibold uppercase ${toneClass}"
      title=${`source=${fsm.source}; activity=${goalFsmObservationLabel(fsm.activity_observation)}; stagnation=${goalFsmStagnationLabel(fsm.stagnation_status)}`}
    >
      Goal FSM · ${goalFsmStateKindLabel(fsm.state_kind)}
    </span>
  `
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

const EMPTY_GOAL_VERIFICATION_SUMMARY: GoalVerificationSummary = {
  effective_policy: null,
  open_request: null,
  latest_request: null,
  approve_count: 0,
  reject_count: 0,
  remaining_possible: 0,
}

function verificationPrincipalLabel(principal: GoalVerificationRequest['requested_by']) {
  return `${principal.kind}:${principal.display_name ?? principal.id}`
}

function verificationStatusLabel(
  request: GoalVerificationRequest | null,
  isOpen: boolean,
) {
  if (!request) return '정책 설정됨'
  if (isOpen) return '확인 대기'
  switch (request.status) {
    case 'approved': return '확인됨'
    case 'rejected': return '반려됨'
    case 'cancelled': return '취소됨'
    default: return request.status
  }
}

function verificationStatusClass(
  request: GoalVerificationRequest | null,
  isOpen: boolean,
) {
  if (!request) return 'border-card-border/60 bg-[var(--color-bg-elevated)] text-text-muted'
  if (isOpen) return 'border-[var(--color-warn-border)] bg-[var(--color-warn-soft)] text-[var(--color-warn-fg)]'
  switch (request.status) {
    case 'approved': return 'border-ok/25 bg-ok/10 text-ok'
    case 'rejected': return 'border-bad/25 bg-bad/10 text-bad'
    case 'cancelled': return 'border-warn/25 bg-warn/10 text-warn'
    default: return 'border-card-border/60 bg-[var(--color-bg-elevated)] text-text-body'
  }
}

function GoalVerificationEvidencePanel({
  summary,
  compact = false,
}: {
  summary: GoalVerificationSummary
  compact?: boolean
}) {
  const request = summary.open_request ?? summary.latest_request ?? null
  const isOpen = Boolean(summary.open_request)
  const policy = request?.policy_snapshot ?? summary.effective_policy ?? null
  if (!policy && !request) return null

  const requiredVerdicts = policy?.required_verdicts ?? 0
  const statusClass = verificationStatusClass(request, isOpen)
  const votes = request?.votes ?? []
  const panelClass = compact
    ? 'ml-6 rounded-[var(--r-0)] border border-[var(--color-warn-border)] bg-[var(--color-warn-soft)] p-2 text-xs text-[var(--color-warn-fg)]'
    : CARD_BOX

  return html`
    <div class=${panelClass}>
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="${DECK_LABEL}">AI 확인</div>
        <span class="rounded-[var(--r-0)] border px-1.5 py-0.5 font-mono text-3xs font-semibold ${statusClass}">
          ${verificationStatusLabel(request, isOpen)}
        </span>
      </div>
      <div class="mt-2 flex flex-wrap items-center gap-1.5 font-mono text-3xs text-[var(--color-fg-secondary)]">
        <span class="rounded-[var(--r-0)] border border-[var(--color-warn-border)] bg-[var(--color-warn-soft)] px-1.5 py-0.5 text-[var(--color-warn-fg)]">
          quorum ${summary.approve_count}/${requiredVerdicts}
        </span>
        <span>reject ${summary.reject_count}</span>
        <span>remaining ${summary.remaining_possible}</span>
      </div>
      ${request ? html`
        <div class="mt-2 flex flex-wrap gap-2 font-mono text-3xs text-[var(--color-fg-muted)]">
          <span>request ${request.id}</span>
          <span>target ${request.target_phase}</span>
          <span>opened <${TimeAgo} timestamp=${request.created_at} /></span>
          ${request.resolved_at ? html`
            <span>resolved <${TimeAgo} timestamp=${request.resolved_at} /></span>
          ` : null}
        </div>
      ` : null}
      ${policy && policy.eligible_principals.length > 0 ? html`
        <div class="mt-3 flex flex-wrap gap-1.5">
          ${policy.eligible_principals.map(principal => html`
            <span key=${`${principal.kind}:${principal.id}`} class="${DECK_CHIP} font-medium text-[var(--color-fg-secondary)]">
              ${verificationPrincipalLabel(principal)}
            </span>
          `)}
        </div>
      ` : null}
      ${votes.length > 0 ? html`
        <div class="mt-3 flex flex-col gap-2">
          ${votes.map(vote => {
            const evidenceRefs = vote.evidence_refs ?? []
            return html`
              <div key=${`${vote.principal.kind}:${vote.principal.id}:${vote.submitted_at}`} class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] p-2 text-xs text-[var(--color-fg-secondary)]">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="font-semibold text-[var(--color-fg-primary)]">${verificationPrincipalLabel(vote.principal)}</span>
                  <span class="${DECK_CHIP} uppercase tracking-[0.08em] text-[var(--color-fg-muted)]">${vote.decision}</span>
                  <span class="${DECK_META}"><${TimeAgo} timestamp=${vote.submitted_at} /></span>
                </div>
                ${vote.note ? html`
                  <div class="mt-1 leading-relaxed text-[var(--color-fg-muted)]">${vote.note}</div>
                ` : null}
                ${evidenceRefs.length > 0 ? html`
                  <div class="mt-2 flex flex-wrap gap-1">
                    ${evidenceRefs.map(ref => html`
                      <code key=${ref} class="${DECK_CHIP} text-[var(--color-fg-secondary)]">${ref}</code>
                    `)}
                  </div>
                ` : null}
              </div>
            `
          })}
        </div>
      ` : request ? html`
        <div class="mt-3 text-xs text-text-muted">verifier vote 없음</div>
      ` : null}
    </div>
  `
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
    clamped >= 80 ? 'var(--color-status-ok)'
    : clamped >= 50 ? 'var(--color-amber-bright)'
    : clamped >= 20 ? 'var(--color-orange-400)'
    : 'var(--color-status-err)'

  const h = size === 'sm' ? 'h-1.5' : 'h-2.5'
  return html`
    <div class="flex items-center gap-2">
      <div class="flex-1 ${h} rounded-[var(--r-0)] bg-[var(--color-bg-elevated)] overflow-hidden">
        <div class="${h} rounded-[var(--r-0)] transition-[width] duration-[var(--t-xslow)]" style="width:${clamped}%;background:${barColor}"></div>
      </div>
      <span class="${DECK_META} w-9 text-right font-semibold tabular-nums">${clamped}%</span>
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
    <div class="grid grid-cols-[repeat(auto-fit,minmax(112px,1fr))] gap-2">
      <div class="${CARD_BOX} text-center">
        <div class="font-mono text-xl font-semibold text-[var(--color-fg-primary)] tabular-nums">${summary.total_goals}</div>
        <div class="mt-1 ${DECK_LABEL}">전체 목표</div>
      </div>
      <div class="rounded-[var(--r-0)] border border-ok/25 bg-ok/10 p-3 text-center">
        <div class="font-mono text-xl font-semibold text-ok tabular-nums">${summary.active_goals}</div>
        <div class="mt-1 font-mono text-3xs font-semibold uppercase tracking-[0.08em] text-ok/80">정상</div>
      </div>
      <div class="rounded-[var(--r-0)] border border-warn/25 bg-warn/10 p-3 text-center">
        <div class="font-mono text-xl font-semibold text-warn tabular-nums">${summary.at_risk_goals}</div>
        <div class="mt-1 font-mono text-3xs font-semibold uppercase tracking-[0.08em] text-warn/80">위험</div>
      </div>
      <div class="rounded-[var(--r-0)] border border-bad/25 bg-bad/10 p-3 text-center">
        <div class="font-mono text-xl font-semibold text-bad tabular-nums">${summary.blocked_goals}</div>
        <div class="mt-1 font-mono text-3xs font-semibold uppercase tracking-[0.08em] text-bad/80">차단</div>
      </div>
      <div class="${CARD_BOX} text-center">
        <div class="font-mono text-xl font-semibold text-[var(--color-fg-primary)] tabular-nums">${summary.pending_approvals}</div>
        <div class="mt-1 ${DECK_LABEL}">승인 대기</div>
      </div>
      ${goalVerificationCount > 0 ? html`
        <div class="rounded-[var(--r-0)] border border-[var(--color-warn-border)] bg-[var(--color-warn-soft)] p-3 text-center">
          <div class="font-mono text-xl font-semibold text-[var(--color-warn-fg)] tabular-nums">${goalVerificationCount}</div>
          <div class="mt-1 font-mono text-3xs font-semibold uppercase tracking-[0.08em] text-[var(--color-warn-fg)]">Goal 검증 대기</div>
        </div>
      ` : null}
      ${awaitingVerificationCount > 0 ? html`
        <div class="rounded-[var(--r-0)] border border-[var(--color-brass-border)] bg-[var(--color-brass-soft)] p-3 text-center">
          <div class="font-mono text-xl font-semibold text-[var(--color-accent-fg)] tabular-nums">${awaitingVerificationCount}</div>
          <div class="mt-1 font-mono text-3xs font-semibold uppercase tracking-[0.08em] text-[var(--color-accent-fg)]/80">Task 검증 대기</div>
        </div>
      ` : null}
      <div class="${CARD_BOX}">
        <div class="mb-2 ${DECK_LABEL}">전체 수렴도</div>
        <${ConvergenceBar} pct=${summary.overall_convergence_pct} />
      </div>
    </div>
  `
}

function HealthBadge({ health }: { health: GoalTreeNode['health'] }) {
  return html`
    <span class="inline-flex items-center rounded-[var(--r-0)] border px-1.5 py-0.5 font-mono text-3xs font-semibold uppercase tracking-[0.08em] ${healthClass(health)}">
      ${healthLabel(health)}
    </span>
  `
}

function GoalBadges({ badges }: { badges: string[] }) {
  if (badges.length === 0) return null
  return html`
    <div class="flex flex-wrap gap-1">
      ${badges.map(badge => html`
        <span
          key=${badge}
          class="inline-flex items-center rounded-[var(--r-0)] border px-1.5 py-0.5 font-mono text-3xs font-semibold uppercase tracking-[0.08em] ${badgeClass(badge)}"
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

function TreeNode({ node, depth }: { node: GoalTreeNode; depth: number }) {
  const isExpanded = expandedNodes.value.has(node.id)
  const hasContent = node.children.length > 0 || node.tasks.length > 0
  const isSelected = selectedGoalId.value === node.id
  const verificationSummary = node.verification_summary ?? EMPTY_GOAL_VERIFICATION_SUMMARY
  const coordinationViolations = coordinationViolationsForGoal(node.id)
  const coordinationHasError = coordinationViolations.some(v => v.severity === 'error')
  const indent = depth * 20
  const headerBase = isSelected
    ? TREE_NODE_CARD_ACTIVE
    : `${TREE_NODE_CARD_BASE} border-[var(--color-border-default)] bg-[var(--color-bg-surface)] hover:border-[var(--color-border-strong)]`

  return html`
    <div class="flex flex-col" style="margin-left:${indent}px">
      <button
        type="button"
        class="${headerBase} ${hasContent ? 'cursor-pointer' : ''} ${ringFocusClasses()}"
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
              class="shrink-0 rounded-md border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs font-bold uppercase tracking-[var(--track-caps)]"
              style="color:${horizonColor(node.horizon)}"
            >
              ${horizonLabel(node.horizon)}
            </span>
            <${StatusBadge} status=${goalPhaseStatus(node.phase)} label=${goalPhaseLabel(node.phase)} />
            <${GoalFsmBadge} fsm=${node.goal_fsm} />
            <span class="break-words text-base font-semibold text-text-strong line-clamp-2">${node.title}</span>
            <span class="text-2xs text-text-dim">${priorityStars(node.priority)}</span>
          </div>

          <div class="flex flex-wrap items-center gap-2.5 text-2xs text-text-muted">
            <${HealthBadge} health=${node.health} />
            <${StatusBadge} status=${node.status} />
            ${node.task_count > 0 ? html`<div class="w-32"><${TaskProgressBar} done=${node.task_done_count} total=${node.task_count} size="sm" /></div>` : null}
            ${node.metric ? html`
              <span
                class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-1.5 py-0.5 font-mono text-3xs text-text-secondary"
                title=${`metric · ${node.metric}${node.target_value ? ` → ${node.target_value}` : ''}`}
              >
                <span aria-hidden="true">↗ </span>${node.metric}${node.target_value ? html`<span class="ml-1 text-text-strong"> · ${node.target_value}</span>` : null}
              </span>
            ` : null}
            ${(() => {
              const awaiting = countAwaitingVerificationTasks(node.tasks)
              return awaiting > 0 ? html`
                <span class="rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-medium text-accent-fg" title="verifier keeper의 독립 실측을 기다리는 task">
                  Task 검증 대기 ${awaiting}
                </span>
              ` : null
            })()}
            ${node.pending_verification_count > 0 ? html`
              <span class="rounded-[var(--r-1)] border border-[var(--color-warn-border)] bg-[var(--color-warn-soft)] px-2 py-0.5 text-3xs font-medium text-[var(--color-warn-fg)]">
                Goal 검증 대기 ${node.pending_verification_count}
              </span>
            ` : null}
            ${node.phase === 'awaiting_approval' ? html`
              <span class="rounded-[var(--r-1)] border border-rose-400/30 bg-rose-400/10 px-2 py-0.5 text-3xs font-medium text-rose-200">
                승인 대기
              </span>
            ` : null}
            ${node.child_count > 0 ? html`<span>${node.child_count} 하위 목표</span>` : null}
            ${verificationSummary.effective_policy ? html`
              <span>quorum ${verificationSummary.approve_count}/${verificationSummary.effective_policy.required_verdicts}</span>
            ` : null}
            ${node.pending_approval_count > 0 ? html`
              <span class="rounded-[var(--r-1)] border border-warn/30 bg-warn/10 px-2 py-0.5 text-3xs font-medium text-warn">
                approval ${node.pending_approval_count}
              </span>
            ` : null}
            ${coordinationViolations.length > 0 ? html`
              <span
                class="rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-medium ${coordinationHasError ? 'border-bad/30 bg-bad/10 text-bad' : 'border-warn/30 bg-warn/10 text-warn'}"
                title="Goal x Task x Board x Reward"
              >
                FSM ${coordinationViolations.length}
              </span>
            ` : null}
            ${node.blocking_source !== 'none' ? html`
              <span
                class="rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-medium ${blockerSourceClass(node.blocking_source)}"
                title=${node.blocking_reason}
              >
                ${blockerSourceLabel(node.blocking_source)}
              </span>
            ` : null}
            ${node.infra_risk_count > 0 ? html`
              <span class="rounded-[var(--r-1)] border border-bad/25 bg-bad/10 px-2 py-0.5 text-3xs font-medium text-bad">
                infra ${node.infra_risk_count}
              </span>
            ` : null}
            ${node.latest_keeper_ref ? html`
              <span class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs font-medium text-text-body">
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
            <span class="rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-semibold text-accent-fg">selected</span>
          ` : null}
        </div>
      </button>

      ${isExpanded ? html`
        <div class="mt-1.5 flex flex-col gap-1.5">
          <${GoalVerificationEvidencePanel} summary=${verificationSummary} compact />
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
  const latestEvent = keeper.latest_causal_event ?? trust?.latest_causal_event ?? null
  const trustSummary =
    trust?.attention_reason
    ?? trust?.disposition_reason
    ?? trust?.execution_summary?.mutation_guard_summary
    ?? trust?.execution_summary?.sandbox_summary
    ?? null

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
            <span class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs font-semibold text-text-body">
              ${keeper.latest_execution_outcome}
            </span>
          ` : null}
        </div>
      </div>
      <div class="mt-3 grid grid-cols-2 gap-2 text-2xs text-text-muted">
        <div>샌드박스</div>
        <div class="text-right text-text-body">${keeper.sandbox_profile}</div>
        <div>승인</div>
        <div class="text-right text-text-body">${trust?.approval_state?.summary ?? keeper.approval_profile ?? '-'}</div>
        <div>캐스케이드</div>
        <div class="text-right text-text-body">${keeper.cascade_name}</div>
        <div>결과</div>
        <div class="text-right text-text-body">${keeper.cascade_outcome ?? '-'}</div>
      </div>
      ${trustSummary || trust?.approval_state?.state || trust?.next_human_action ? html`
        <div class="mt-3 rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-3">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">검증 요약</div>
          ${trustSummary ? html`
            <div class="mt-2 text-xs leading-relaxed text-text-body">${trustSummary}</div>
          ` : null}
          <div class="mt-2 flex flex-wrap gap-2 text-3xs text-text-muted">
            ${trust?.approval_state?.state ? html`
              <span>승인 상태 ${trust.approval_state.state}</span>
            ` : null}
            ${trust?.execution_summary?.tool_contract_result ? html`
              <span>계약 ${trust.execution_summary.tool_contract_result}</span>
            ` : null}
            ${trust?.next_human_action ? html`
              <span>다음 ${trust.next_human_action}</span>
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
  const verificationSummary = selectedNode.verification_summary ?? EMPTY_GOAL_VERIFICATION_SUMMARY

  return html`
    <section class=${`${GOAL_PANEL} flex flex-col gap-4`} aria-label="목표 상세">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="max-w-150">
          <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-text-muted">목표 상세</div>
          <h3 class="mt-1 text-xl font-semibold tracking-[-0.02em] text-text-strong">${selectedNode.title}</h3>
          <div class="mt-2 flex flex-wrap items-center gap-2">
            <${HealthBadge} health=${selectedNode.health} />
            <${StatusBadge} status=${selectedNode.status} />
            <${StatusBadge} status=${goalPhaseStatus(selectedNode.phase)} label=${goalPhaseLabel(selectedNode.phase)} />
            <${GoalFsmBadge} fsm=${selectedNode.goal_fsm} />
            <span class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs font-semibold uppercase tracking-[var(--track-caps)]" style="color:${horizonColor(selectedNode.horizon)}">
              ${horizonLabel(selectedNode.horizon)}
            </span>
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

      <div class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] px-3 py-2 text-sm text-text-body">
        ${selectedNode.status_reason}
      </div>

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
              <div class="text-3xs uppercase text-text-muted">kind</div>
              <div class="mt-1 font-semibold text-text-strong">${goalFsmStateKindLabel(selectedNode.goal_fsm.state_kind)}</div>
            </div>
            <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
              <div class="text-3xs uppercase text-text-muted">activity</div>
              <div class="mt-1 font-semibold text-text-strong">${goalFsmObservationLabel(selectedNode.goal_fsm.activity_observation)}</div>
            </div>
            <div class="rounded-[var(--r-1)] border border-card-border/50 bg-[var(--color-bg-surface)] p-2">
              <div class="text-3xs uppercase text-text-muted">stagnation</div>
              <div class="mt-1 font-semibold text-text-strong">${goalFsmStagnationLabel(selectedNode.goal_fsm.stagnation_status)}</div>
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

        ${selectedNode.blocking_source !== 'none' ? html`
          <div class=${CARD_BOX}>
            <div class="mb-2 flex flex-wrap items-center gap-2">
              <span class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">차단 맥락</span>
              <span class="rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-semibold ${blockerSourceClass(selectedNode.blocking_source)}">
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
          <${DetailMetric} label="작업" value=${`${selectedNode.task_done_count}/${selectedNode.task_count}`} tone=${selectedNode.task_done_count === selectedNode.task_count && selectedNode.task_count > 0 ? 'ok' : 'default'} />
          <${DetailMetric} label="연결된 키퍼" value=${selectedNode.linked_keeper_names.length} />
          <${DetailMetric} label="승인 대기" value=${selectedNode.pending_approval_count} tone=${selectedNode.pending_approval_count > 0 ? 'warn' : 'default'} />
          <${DetailMetric} label="목표 검증" value=${selectedNode.pending_verification_count} tone=${selectedNode.pending_verification_count > 0 ? 'warn' : 'default'} />
          <${DetailMetric} label="인프라 위험" value=${selectedNode.infra_risk_count} tone=${selectedNode.infra_risk_count > 0 ? 'bad' : 'default'} />
          <${DetailMetric} label="연결 출처" value=${selectedNode.linkage_source} tone=${selectedNode.linkage_warning_count > 0 ? 'warn' : 'default'} />
          <${DetailMetric} label="최근 활동" value=${selectedNode.stagnation_seconds > 0 ? `${Math.floor(selectedNode.stagnation_seconds / 3600)}h idle` : 'now'} tone=${selectedNode.badges.includes('stalled') ? 'warn' : 'default'} />
        </div>

        <${GoalVerificationEvidencePanel} summary=${verificationSummary} />

        ${selectedNode.badges.length > 0 ? html`
          <div class=${CARD_BOX}>
            <div class="mb-2 text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted">배지</div>
            <${GoalBadges} badges=${selectedNode.badges} />
          </div>
        ` : null}

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
            <${GoalVerificationEvidencePanel} summary=${verificationSummary} />

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
      <section class=${GOAL_PANEL} aria-label="목표 관리자">
        <div class="mb-4 flex flex-wrap items-start justify-between gap-4">
          <div class="max-w-190">
            <div class="text-2xs font-semibold uppercase tracking-[0.18em] text-text-muted">목표 관리자</div>
            <h3 class="mt-1 text-2xl font-semibold tracking-[-0.02em] text-text-strong">목표 중심 계획 뷰</h3>
            <p class="mt-1.5 text-sm leading-relaxed text-text-muted">
              goal-task 연결, keeper evidence, approval 대기, sandbox/cascade 신호를 한 표면에서 봅니다.
              신규 태스크는 <${Tk}>goal_id<//>로 직접 연결됩니다.
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
                class="min-w-45 max-w-65 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-xs text-text-body placeholder:text-text-dim focus:outline-none focus:border-accent-fg"
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
            <span class="text-3xs font-semibold uppercase tracking-[0.18em] text-text-muted">목표 단계</span>
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
