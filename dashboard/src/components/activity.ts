// MASC Dashboard — Activity Tab
// Absorbs: live + activity graph into one view. Live stream default, activity graph collapsible.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Live } from './live'
import { ActivityGraphSurface } from './activity-graph'

const activityGraphExpanded = signal(false)

export function Activity() {
  return html`
    <div class="tab-unified grid gap-[var(--space-md,16px)]">
      <${Live} />
      <details
        class="tab-collapsible rounded-lg"
        open=${activityGraphExpanded.value}
        onToggle=${(e: Event) => { activityGraphExpanded.value = (e.target as HTMLDetailsElement).open }}
      >
        <summary class="tab-collapsible__summary">활동 그래프</summary>
        <${ActivityGraphSurface} />
      </details>
    </div>
  `
}
