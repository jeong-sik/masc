// Planning Panel — Phase 7 unified view for planning section.
// FilterChips toggle between kanban (Planning) and goal-tree (GoalTree).
// Revives GoalTree which became dead code after Phase 1 removed the
// standalone goals section.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { route } from '../router'
import { FilterChips } from './common/filter-chips'
import { Planning } from './goals'
import { GoalTree } from './goals/goal-tree'

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
  { key: 'goal-tree', label: 'Goal Manager' },
  { key: 'default',   label: 'Backlog' },
]

function updateViewParam(view: PlanningView): void {
  const hash = view === 'goal-tree'
    ? '#workspace?section=planning'
    : `#workspace?section=planning&view=${view}`
  history.replaceState(null, '', hash)
  window.dispatchEvent(new HashChangeEvent('hashchange'))
}

export function PlanningPanel() {
  const view = activeView.value

  return html`
    <div class="flex flex-col gap-4">
      <${FilterChips}
        chips=${VIEW_CHIPS}
        value=${view}
        onChange=${updateViewParam}
        size="sm"
        tone="accent"
      />
      ${view === 'goal-tree'
        ? html`<${GoalTree} />`
        : html`<${Planning} />`}
    </div>
  `
}
