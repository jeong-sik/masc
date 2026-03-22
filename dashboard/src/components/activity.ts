// MASC Dashboard — Activity Tab
// Live stream default, activity graph collapsible.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Live } from './live'
import { ActivityGraphSurface } from './activity-graph'

const activityGraphExpanded = signal(false)

export function Activity() {
  return html`
    <div class="flex flex-col gap-4">
      <${Live} />
      <details
        class="rounded-lg border border-[var(--card-border)] overflow-hidden"
        open=${activityGraphExpanded.value}
        onToggle=${(e: Event) => { activityGraphExpanded.value = (e.target as HTMLDetailsElement).open }}
      >
        <summary class="px-4 py-3 cursor-pointer text-xs font-medium text-[var(--text-muted)] hover:text-[var(--text-body)] transition-colors">활동 그래프</summary>
        <div class="p-4 pt-0">
          <${ActivityGraphSurface} />
        </div>
      </details>
    </div>
  `
}
