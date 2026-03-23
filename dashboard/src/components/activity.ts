// MASC Dashboard — Activity Tab
// Live stream default, activity graph collapsible.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Live } from './live'
import { ActivityGraphSurface } from './activity-graph'
import { CollapsibleSection } from './common/collapsible'

const activityGraphExpanded = signal(false)

export function Activity() {
  return html`
    <div class="flex flex-col gap-4">
      <${Live} />
      <${CollapsibleSection}
        title="활동 그래프"
        open=${activityGraphExpanded.value}
      >
        <${ActivityGraphSurface} />
      <//>
    </div>
  `
}
