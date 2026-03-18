// MASC Dashboard — Activity Tab
// Absorbs: live + social into one view. Live stream default, social graph collapsible.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Live } from './live'
import { Social } from './social'

const socialExpanded = signal(false)

export function Activity() {
  return html`
    <div class="tab-unified">
      <${Live} />
      <details
        class="tab-collapsible"
        open=${socialExpanded.value}
        onToggle=${(e: Event) => { socialExpanded.value = (e.target as HTMLDetailsElement).open }}
      >
        <summary class="tab-collapsible__summary">소셜 그래프</summary>
        <${Social} />
      </details>
    </div>
  `
}
