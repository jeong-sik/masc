// RFC-0267 Phase 2 — the control the RFC named: "The Work board's 미배정 작업
// section gains a per-row goal에 배정 control: a picker of active goals that
// calls masc_task_set_goal, then refreshes ['goals','execution']".
//
// The tool, the backend writer and assignTaskToGoal all shipped; only this was
// missing, so a goalless task could be linked from MCP but not from the board
// (#34204).

import { html } from 'htm/preact'
import type { Goal } from '../../types'
import { goals } from '../../store'
import { assignTaskToGoal } from '../task-manage/task-manage-state'

// A completed or dropped goal is not somewhere new work should land. Every
// other phase is offered, including ones this build does not know: the phase
// vocabulary is the server's, and an unknown phase is not evidence the goal
// is closed.
const CLOSED_PHASES: ReadonlySet<string> = new Set(['completed', 'dropped'])

export function activeGoals(all: readonly Goal[]): Goal[] {
  return all.filter(goal => !CLOSED_PHASES.has(goal.phase))
}

/** Per-row picker for a backlog task that carries no goal. Renders nothing
    when no goal is open, because an empty picker offers no action. */
export function GoalAssignPicker({ taskId }: { taskId: string }) {
  const options = activeGoals(goals.value)
  if (options.length === 0) return null
  return html`
    <select
      class="wk-bl-assign mono"
      data-testid="assign-goal"
      aria-label=${`${taskId}를 목표에 배정`}
      onClick=${(event: Event) => event.stopPropagation()}
      onChange=${(event: Event) => {
        const select = event.currentTarget as HTMLSelectElement
        const goalId = select.value
        // Reset first: the row re-renders from the refreshed store, and a
        // select left on a goal would read as a saved choice rather than an
        // action that already happened.
        select.value = ''
        if (goalId) void assignTaskToGoal(taskId, goalId)
      }}
    >
      <option value="">goal에 배정</option>
      ${options.map(goal => html`<option key=${goal.id} value=${goal.id}>${goal.title}</option>`)}
    </select>
  `
}
