// MASC Dashboard — Unified Agents Tab
// Absorbs: agent-roster + execution + keeper-roster into one view with chip toggle.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { navigate, route } from '../router'
import { agents, keepers } from '../store'
import { missionKeeperBriefs } from '../mission-signals'
import { AgentRoster } from './agent-roster'
import { AgentProfile } from './agent-profile'
import { Execution } from './agents'

type AgentsView = 'all' | 'agents' | 'keepers' | 'sessions'

const activeView = signal<AgentsView>('all')

/** Determine which agents have keeper runtime from keepers store + mission snapshot. */
function keeperNameSet(): Set<string> {
  const names = new Set<string>()
  for (const k of keepers.value) {
    const name = (k as { name?: string; agent_name?: string }).name
      ?? (k as { agent_name?: string }).agent_name
    if (name) names.add(name)
  }
  for (const kb of missionKeeperBriefs.value) {
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
  { id: 'sessions', label: '실행' },
]

export function AgentsUnified() {
  // If an agent name is in the route params, show the profile page
  const agentParam = route.value.params.agent as string | undefined
  if (agentParam) {
    return html`<${AgentProfile} name=${agentParam} />`
  }

  const viewParam = route.value.params.view as string | undefined
  const routeView =
    viewParam === 'sessions' || viewParam === 'keepers' || viewParam === 'agents'
      ? viewParam
      : null
  const currentView = routeView ?? activeView.value

  useEffect(() => {
    if (routeView && activeView.value !== routeView) {
      activeView.value = routeView
    }
  }, [routeView])

  // Compute counts for chip badges
  const kNames = keeperNameSet()
  const agentList = agents.value
  const totalCount = agentList.length
  const keeperCount = agentList.filter((a: { name: string }) => kNames.has(a.name)).length
  const agentOnlyCount = totalCount - keeperCount

  return html`
    <div class="grid gap-[var(--space-md,16px)]">
      <div class="flex gap-1.5">
        ${CHIPS.map(c => html`
          <button
            key=${c.id}
            class=${`agents-chip ${currentView === c.id ? 'agents-chip--active' : ''}`}
            onClick=${() => {
              activeView.value = c.id
              navigate('status', c.id === 'all' ? { section: 'agents' } : { section: 'agents', view: c.id })
            }}
          >
            ${c.label}
            ${c.id === 'all' ? html`<span class="agents-chip-count rounded-lg">${totalCount}</span>` : null}
            ${c.id === 'agents' ? html`<span class="agents-chip-count rounded-lg">${agentOnlyCount}</span>` : null}
            ${c.id === 'keepers' ? html`<span class="agents-chip-count rounded-lg">${keeperCount}</span>` : null}
          </button>
        `)}
      </div>

      ${currentView === 'sessions'
        ? html`<${Execution} />`
        : html`<${AgentRoster}
            keeperFilter=${currentView === 'keepers' ? 'keeper-only'
              : currentView === 'agents' ? 'agent-only'
              : 'all'}
          />`
      }
    </div>
  `
}
