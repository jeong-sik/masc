// MASC Dashboard — Unified Agents Tab
// Absorbs: agent-roster + execution + keeper-roster into one view with chip toggle.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { route } from '../router'
import { agents, keepers } from '../store'
import { missionSnapshot } from '../mission-store'
import { AgentRoster } from './agent-roster'
import { AgentProfile } from './agent-profile'
import { Execution } from './agents'
import { openAgentDetail, closeAgentDetail, selectedAgentName } from './agent-detail'

type AgentsView = 'all' | 'agents' | 'keepers' | 'sessions'

const activeView = signal<AgentsView>('all')

function chipClass(view: AgentsView): string {
  return `agents-chip ${activeView.value === view ? 'agents-chip--active' : ''}`
}

/** Determine which agents have keeper runtime from keepers store + mission snapshot. */
function keeperNameSet(): Set<string> {
  const names = new Set<string>()
  for (const k of keepers.value) {
    const name = (k as { name?: string; agent_name?: string }).name
      ?? (k as { agent_name?: string }).agent_name
    if (name) names.add(name)
  }
  const snap = missionSnapshot.value
  const briefs = snap?.keeper_briefs ?? []
  for (const kb of briefs) {
    const name = (kb as { name?: string; agent_name?: string }).name
      ?? (kb as { agent_name?: string }).agent_name
    if (name) names.add(name)
  }
  return names
}

const CHIPS: { id: AgentsView; label: string }[] = [
  { id: 'all', label: '전체' },
  { id: 'agents', label: '에이전트' },
  { id: 'keepers', label: '키퍼' },
  { id: 'sessions', label: '세션' },
]

export function AgentsUnified() {
  // If an agent name is in the route params, show the profile page
  const agentParam = route.value.params.agent as string | undefined
  if (agentParam) {
    return html`<${AgentProfile} name=${agentParam} />`
  }

  // Sync from route params if present
  const viewParam = route.value.params.view as string | undefined
  if (viewParam === 'sessions' && activeView.value !== 'sessions') {
    activeView.value = 'sessions'
  } else if (viewParam === 'keepers' && activeView.value !== 'keepers') {
    activeView.value = 'keepers'
  } else if (viewParam === 'agents' && activeView.value !== 'agents') {
    activeView.value = 'agents'
  }

  // Sync agent detail overlay from route param (deep-link / Overview navigation)
  const agentParam = route.value.params.agent as string | undefined
  if (agentParam && selectedAgentName.value !== agentParam) {
    openAgentDetail(agentParam)
  } else if (!agentParam && selectedAgentName.value) {
    closeAgentDetail()
  }

  // Compute counts for chip badges
  const kNames = keeperNameSet()
  const agentList = agents.value
  const totalCount = agentList.length
  const keeperCount = agentList.filter((a: { name: string }) => kNames.has(a.name)).length
  const agentOnlyCount = totalCount - keeperCount

  return html`
    <div class="agents-unified">
      <div class="agents-chip-bar">
        ${CHIPS.map(c => html`
          <button
            key=${c.id}
            class=${chipClass(c.id)}
            onClick=${() => { activeView.value = c.id }}
          >
            ${c.label}
            ${c.id === 'all' ? html`<span class="agents-chip-count">${totalCount}</span>` : null}
            ${c.id === 'agents' ? html`<span class="agents-chip-count">${agentOnlyCount}</span>` : null}
            ${c.id === 'keepers' ? html`<span class="agents-chip-count">${keeperCount}</span>` : null}
          </button>
        `)}
      </div>

      ${activeView.value === 'sessions'
        ? html`<${Execution} />`
        : html`<${AgentRoster}
            keeperFilter=${activeView.value === 'keepers' ? 'keeper-only'
              : activeView.value === 'agents' ? 'agent-only'
              : 'all'}
          />`
      }
    </div>
  `
}
