// Planning Panel — Phase 7 unified view for planning section.
// FilterChips toggle between goal tree and kanban.
// Revives GoalTree which became dead code after Phase 1 removed the
// standalone goals section.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { replaceRoute, route } from '../router'
import { goals, tasks } from '../store'
import { FilterChips } from './common/filter-chips'
import { Planning } from './goals/planning'
import { GoalTree } from './goals/goal-tree'
import { PlanningFocusPanel } from './planning-focus-panel'
import { openTaskDetail } from './goals/task-detail-state'

type PlanningView = 'default' | 'goal-tree'

const PLANNING_VIEWS: PlanningView[] = ['default', 'goal-tree']

function isPlanningView(v: string | undefined): v is PlanningView {
  return !!v && (PLANNING_VIEWS as string[]).includes(v)
}

const activeView = computed<PlanningView>(() => {
  const v = route.value.params.view
  return isPlanningView(v) ? v : 'goal-tree'
})

const VIEW_CHIPS: Array<{ key: PlanningView; label: string }> = [
  { key: 'goal-tree', label: '목표 관리자' },
  { key: 'default',   label: '백로그' },
]

function updateViewParam(view: PlanningView): void {
  const params: Record<string, string> = { ...route.value.params, section: 'planning' }
  if (view === 'goal-tree') {
    delete params.view
  } else {
    params.view = view
  }
  replaceRoute('workspace', params)
}

function cleanRouteFocusId(value: string | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed && trimmed.length > 0 ? trimmed : null
}

function clearPlanningRouteFocus(): void {
  const params: Record<string, string> = { ...route.value.params, section: 'planning' }
  delete params.goal
  delete params.task
  replaceRoute('workspace', params)
}

function PlanningRouteFocusPanel() {
  const params = route.value.params as Record<string, string | undefined>
  const goalId = cleanRouteFocusId(params.goal)
  const taskId = cleanRouteFocusId(params.task)
  const goal = goalId ? goals.value.find(item => item.id === goalId) ?? null : null
  const task = taskId ? tasks.value.find(item => item.id === taskId) ?? null : null

  useEffect(() => {
    if (task) openTaskDetail(task)
  }, [task])

  if (!goalId && !taskId) return null

  return html`
    <section
      class="v2-workspace-panel rounded-[var(--r-1)] border border-[var(--color-brass-border)] bg-[var(--color-brass-soft)] px-3 py-2"
      data-testid="planning-route-focus"
      data-route-focused-goal=${goalId ?? undefined}
      data-route-focused-task=${taskId ?? undefined}
      aria-label="Planning route focus"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="font-mono text-3xs font-semibold uppercase tracking-[var(--track-section)] text-[var(--color-accent-fg)]">
            ROUTE FOCUS
          </div>
          <div class="mt-1 flex min-w-0 flex-wrap items-center gap-2 text-xs text-text-body">
            ${goalId ? html`
              <span class="rounded-[var(--r-0)] border border-[var(--color-brass-border)] bg-[var(--color-bg-page)] px-2 py-1 font-mono text-3xs text-[var(--color-accent-fg)]">
                GOAL ${goalId}
              </span>
              <span class="min-w-0 truncate text-sm font-semibold text-text-strong">
                ${goal?.title ?? 'goal not loaded'}
              </span>
              ${goal?.phase ? html`<span class="font-mono text-3xs text-text-muted">${goal.phase}</span>` : null}
            ` : null}
            ${taskId ? html`
              <span class="rounded-[var(--r-0)] border border-[var(--color-brass-border)] bg-[var(--color-bg-page)] px-2 py-1 font-mono text-3xs text-[var(--color-accent-fg)]">
                TASK ${taskId}
              </span>
              <span class="min-w-0 truncate text-sm font-semibold text-text-strong">
                ${task?.title ?? 'task not loaded'}
              </span>
              ${task?.assignee ? html`<span class="font-mono text-3xs text-text-muted">@${task.assignee}</span>` : null}
            ` : null}
          </div>
        </div>
        <button
          type="button"
          class="v2-workspace-action rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2 py-1 font-mono text-3xs text-text-muted transition-colors hover:border-[var(--color-border-strong)] hover:text-text-strong"
          onClick=${clearPlanningRouteFocus}
        >
          CLEAR
        </button>
      </div>
    </section>
  `
}

export function PlanningPanel() {
  const view = activeView.value

  return html`
    <div class="v2-workspace-surface flex flex-col gap-4">
      <${FilterChips}
        chips=${VIEW_CHIPS}
        value=${view}
        onChange=${updateViewParam}
        size="sm"
        tone="accent"
      />
      <${PlanningRouteFocusPanel} />
      <${PlanningFocusPanel} />
      ${view === 'goal-tree' ? html`<${GoalTree} />` : html`<${Planning} />`}
    </div>
  `
}
