// MASC Dashboard — Unified Agents Tab
// Absorbs: agent-roster + execution + keeper-roster into one view with chip toggle.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { route } from '../router'
import { AgentRoster } from './agent-roster'
import { Execution } from './agents'

type AgentsView = 'roster' | 'sessions'

const activeView = signal<AgentsView>('roster')

function chipClass(view: AgentsView): string {
  return `agents-chip ${activeView.value === view ? 'agents-chip--active' : ''}`
}

export function AgentsUnified() {
  // Sync from route params if present
  const viewParam = route.value.params.view
  if (viewParam === 'sessions' && activeView.value !== 'sessions') {
    activeView.value = 'sessions'
  }

  return html`
    <div class="agents-unified">
      <div class="agents-chip-bar">
        <button class=${chipClass('roster')} onClick=${() => { activeView.value = 'roster' }}>
          에이전트/키퍼
        </button>
        <button class=${chipClass('sessions')} onClick=${() => { activeView.value = 'sessions' }}>
          세션
        </button>
      </div>

      ${activeView.value === 'roster'
        ? html`<${AgentRoster} />`
        : html`<${Execution} />`
      }
    </div>
  `
}
