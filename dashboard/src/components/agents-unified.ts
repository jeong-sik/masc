// MASC Dashboard — Unified Agents Tab
// Absorbs: agent-roster + execution + keeper-roster into one view with chip toggle.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { CountBadge } from './common/badge'
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

  function chipCount(id: AgentsView): number | null {
    if (id === 'all') return totalCount
    if (id === 'agents') return agentOnlyCount
    if (id === 'keepers') return keeperCount
    return null
  }

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex gap-1 p-1 bg-[var(--white-3)] rounded-lg w-fit">
        ${CHIPS.map(c => html`
          <button
            key=${c.id}
            class="flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium transition-all cursor-pointer border-0 ${currentView === c.id ? 'bg-[var(--accent-soft)] text-[var(--accent)]' : 'bg-transparent text-[var(--text-muted)] hover:text-[var(--text-body)]'}"
            onClick=${() => {
              activeView.value = c.id
              navigate('status', c.id === 'all' ? { section: 'agents' } : { section: 'agents', view: c.id })
            }}
          >
            ${c.label}
            ${chipCount(c.id) != null ? html`<${CountBadge}>${chipCount(c.id)}<//>` : null}
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
