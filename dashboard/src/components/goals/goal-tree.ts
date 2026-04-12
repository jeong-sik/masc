// Goal Tree — hierarchical goal decomposition with convergence indicators

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { fetchDashboardGoalsTree } from '../../api/dashboard'
import { EmptyState, ErrorState, LoadingState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import { StatusBadge } from '../common/status-badge'
import { TimeAgo } from '../common/time-ago'
import type {
  DashboardGoalsTreeResponse,
  GoalTreeNode,
  GoalTreeTask,
  GoalTreeSummary,
} from '../../types'
import { horizonLabel, horizonColor, priorityStars } from './goal-helpers'

// --- State ---

const treeData = signal<DashboardGoalsTreeResponse | null>(null)
const treeLoading = signal(false)
const treeError = signal<string | null>(null)
const expandedNodes = signal<Set<string>>(new Set())

function toggleNode(id: string) {
  const next = new Set(expandedNodes.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedNodes.value = next
}

function expandAll(nodes: GoalTreeNode[]) {
  const ids = new Set(expandedNodes.value)
  function walk(ns: GoalTreeNode[]) {
    for (const n of ns) {
      ids.add(n.id)
      walk(n.children)
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
    treeData.value = await fetchDashboardGoalsTree()
  } catch (err) {
    treeError.value = err instanceof Error ? err.message : String(err)
  } finally {
    treeLoading.value = false
  }
}

// --- Convergence bar ---

function ConvergenceBar({ pct, size = 'md' }: { pct: number; size?: 'sm' | 'md' }) {
  const clamped = Math.max(0, Math.min(100, pct))
  const barColor =
    clamped >= 80 ? '#4ade80'
    : clamped >= 50 ? '#f59e0b'
    : clamped >= 20 ? '#fb923c'
    : '#ef4444'

  const h = size === 'sm' ? 'h-1.5' : 'h-2.5'
  return html`
    <div class="flex items-center gap-2">
      <div class="flex-1 ${h} rounded-full bg-white/10 overflow-hidden">
        <div class="${h} rounded-full transition-all duration-500" style="width:${clamped}%;background:${barColor}"></div>
      </div>
      <span class="text-[11px] font-semibold tabular-nums text-text-muted w-[36px] text-right">${clamped}%</span>
    </div>
  `
}

// --- Summary stats ---

function TreeSummary({ summary }: { summary: GoalTreeSummary }) {
  return html`
    <div class="grid grid-cols-[repeat(auto-fit,minmax(120px,1fr))] gap-3">
      <div class="rounded-xl border border-card-border/60 bg-[rgba(7,12,20,0.82)] p-3 text-center">
        <div class="text-2xl font-bold text-text-strong tabular-nums">${summary.total_goals}</div>
        <div class="text-[10px] font-semibold uppercase tracking-widest text-text-muted mt-1">전체 목표</div>
      </div>
      <div class="rounded-xl border border-card-border/60 bg-[rgba(7,12,20,0.82)] p-3 text-center">
        <div class="text-2xl font-bold text-ok tabular-nums">${summary.active_goals}</div>
        <div class="text-[10px] font-semibold uppercase tracking-widest text-text-muted mt-1">진행 중</div>
      </div>
      <div class="rounded-xl border border-card-border/60 bg-[rgba(7,12,20,0.82)] p-3 text-center">
        <div class="text-2xl font-bold text-text-strong tabular-nums">${summary.total_tasks}</div>
        <div class="text-[10px] font-semibold uppercase tracking-widest text-text-muted mt-1">연결 태스크</div>
      </div>
      <div class="rounded-xl border border-card-border/60 bg-[rgba(7,12,20,0.82)] p-3 text-center">
        <div class="text-2xl font-bold text-ok tabular-nums">${summary.done_tasks}</div>
        <div class="text-[10px] font-semibold uppercase tracking-widest text-text-muted mt-1">완료</div>
      </div>
      <div class="rounded-xl border border-card-border/60 bg-[rgba(7,12,20,0.82)] p-3">
        <div class="text-[10px] font-semibold uppercase tracking-widest text-text-muted mb-2">전체 수렴도</div>
        <${ConvergenceBar} pct=${summary.overall_convergence_pct} />
      </div>
    </div>
  `
}

// --- Task row inside a goal ---

function TreeTask({ task }: { task: GoalTreeTask }) {
  return html`
    <div class="flex items-center gap-2 py-1.5 px-2 rounded-lg bg-white/3 text-[12px]">
      <span class="size-2 rounded-full shrink-0" style="background:${task.status_color}"></span>
      <span class="flex-1 min-w-0 truncate text-text-body">${task.title}</span>
      ${task.assignee ? html`
        <span class="shrink-0 rounded-md border border-accent/20 bg-[var(--accent-10)] px-1.5 py-0.5 text-[10px] font-medium text-accent">${task.assignee}</span>
      ` : null}
      <${StatusBadge} status=${task.status} />
    </div>
  `
}

// --- Goal tree node (recursive) ---

function TreeNode({ node, depth }: { node: GoalTreeNode; depth: number }) {
  const isExpanded = expandedNodes.value.has(node.id)
  const hasContent = node.children.length > 0 || node.tasks.length > 0
  const indent = depth * 20

  return html`
    <div class="flex flex-col" style="margin-left:${indent}px">
      <div
        class="group flex items-start gap-3 rounded-xl border border-card-border/60 bg-[rgba(8,13,22,0.86)] p-3 transition-colors hover:border-card-border/90 ${hasContent ? 'cursor-pointer' : ''}"
        onClick=${hasContent ? () => toggleNode(node.id) : undefined}
      >
        ${hasContent ? html`
          <span class="shrink-0 mt-0.5 text-[12px] text-text-dim transition-transform ${isExpanded ? 'rotate-90' : ''}">\u25B6</span>
        ` : html`
          <span class="shrink-0 mt-0.5 text-[12px] text-text-dim/30">\u25CB</span>
        `}

        <div class="flex-1 min-w-0">
          <div class="flex flex-wrap items-center gap-2 mb-1">
            <span class="shrink-0 rounded-md border border-white/10 bg-white/5 px-2 py-0.5 text-[10px] font-bold uppercase tracking-widest" style="color:${horizonColor(node.horizon)}">
              ${horizonLabel(node.horizon)}
            </span>
            <span class="text-[14px] font-semibold text-text-strong break-words line-clamp-2">${node.title}</span>
            <span class="text-[11px] text-text-dim">${priorityStars(node.priority)}</span>
          </div>

          <div class="flex flex-wrap items-center gap-3 text-[11px] text-text-muted">
            ${node.metric ? html`
              <span class="rounded-md border border-accent/20 bg-[var(--accent-10)] px-2 py-0.5 text-accent">
                ${node.metric}${node.target_value ? ` \u2192 ${node.target_value}` : ''}
              </span>
            ` : null}
            ${node.due_date ? html`
              <span class="rounded-md border border-bad/20 bg-bad/10 px-2 py-0.5 text-bad">
                마감 <${TimeAgo} timestamp=${node.due_date} />
              </span>
            ` : null}
            ${node.task_count > 0 ? html`
              <span class="font-medium">${node.task_done_count}/${node.task_count} 태스크</span>
            ` : null}
            ${node.child_count > 0 ? html`
              <span class="font-medium">${node.child_count} 하위 목표</span>
            ` : null}
          </div>

          <div class="mt-2 max-w-[400px]">
            <${ConvergenceBar} pct=${node.convergence_pct} size="sm" />
          </div>
        </div>

        <div class="flex flex-col items-end gap-1 shrink-0">
          <${StatusBadge} status=${node.status} />
          <span class="text-[10px] text-text-dim">
            <${TimeAgo} timestamp=${node.updated_at} />
          </span>
        </div>
      </div>

      ${isExpanded ? html`
        <div class="mt-1.5 flex flex-col gap-1.5">
          ${node.tasks.length > 0 ? html`
            <div class="ml-6 flex flex-col gap-1 rounded-lg border border-card-border/40 bg-[rgba(5,9,16,0.6)] p-2">
              <div class="text-[10px] font-semibold uppercase tracking-widest text-text-dim mb-1">연결된 태스크</div>
              ${node.tasks.map(t => html`<${TreeTask} key=${t.id} task=${t} />`)}
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

// --- Main GoalTree component ---

export function GoalTree() {
  useEffect(() => {
    void refreshTree()
  }, [])

  const data = treeData.value
  const loading = treeLoading.value
  const error = treeError.value

  return html`
    <div class="flex flex-col gap-5">
      <section class="rounded-2xl border border-card-border/70 bg-[rgba(9,14,24,0.88)] p-5">
        <div class="flex flex-wrap items-start justify-between gap-4 mb-4">
          <div class="max-w-[760px]">
            <div class="text-[11px] font-semibold uppercase tracking-[0.18em] text-text-muted">Goal Tree</div>
            <h3 class="mt-1 text-[20px] font-semibold tracking-[-0.02em] text-text-strong">목표 계층 구조</h3>
            <p class="mt-1.5 text-[13px] leading-relaxed text-text-muted">
              목표의 부모-자식 관계와 연결된 태스크를 트리 형태로 보여줍니다. 수렴도는 하위 태스크 완료율 기반입니다.
            </p>
          </div>
          <div class="flex items-center gap-2">
            ${data && data.tree.length > 0 ? html`
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

        ${error ? html`<${ErrorState} message=${error} />` : null}

        ${data ? html`<${TreeSummary} summary=${data.summary} />` : null}
      </section>

      ${loading && !data ? html`
        <${LoadingState}>목표 트리 불러오는 중...<//>
      ` : data && data.tree.length === 0 ? html`
        <${EmptyState} message="등록된 목표가 없습니다. masc_goal_upsert 도구로 목표를 등록하세요." />
      ` : data ? html`
        <section class="flex flex-col gap-2">
          ${data.tree.map(node => html`<${TreeNode} key=${node.id} node=${node} depth=${0} />`)}
        </section>
      ` : null}
    </div>
  `
}
