// MASC Dashboard — Keeper Fleet / Workspace Agents
// The route hosts multiple live namespaces. Do not collapse workspace agents,
// keeper runtime fibers, configured keepers, and task owners into one count.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { route } from '../router'
import { AgentRoster } from './agent-roster'
import { AgentProfile } from './agent-profile'
import { KeeperDetailPage } from './keeper-detail-page'
import { KeeperSpawnPanel } from './keeper-spawn/keeper-spawn-panel'
import { FsmHub } from './fsm-hub'
import { FleetFsmMatrix } from './fleet-fsm-matrix'
import { CompositeFsmFlowchart } from './composite-fsm-flowchart'
import { showSpawnPanel } from './keeper-spawn/keeper-spawn-state'

type AgentsView = 'all' | 'agents' | 'keepers' | 'fsm'

const VALID_VIEWS: AgentsView[] = ['all', 'agents', 'keepers', 'fsm']

// Derive active view from route params. Fleet no longer exposes this as a
// top-of-page switcher, but existing deep links still narrow the roster.
function activeView(): AgentsView {
  const v = route.value.params.view
  return v && (VALID_VIEWS as string[]).includes(v) ? v as AgentsView : 'all'
}

export function AgentsUnified() {
  const keeperParam = route.value.params.keeper as string | undefined
  const agentParam = route.value.params.agent as string | undefined
  const currentView = activeView()

  if (keeperParam) {
    return html`<${KeeperDetailPage} />`
  }

  // If an agent name is in the route params, show the profile page
  if (agentParam) {
    return html`<${AgentProfile} name=${agentParam} />`
  }

  return html`
    <div class="v2-monitoring-surface flex h-full min-h-0 flex-col">
      ${currentView === 'fsm'
        ? html`<${FleetAndFsmHubPanel} />`
        : html`
            ${currentView !== 'agents' && showSpawnPanel.value ? html`<${KeeperSpawnPanel} />` : null}
            <${AgentRoster}
              keeperFilter=${currentView === 'keepers' ? 'keeper-only'
                : currentView === 'agents' ? 'agent-only'
                : 'all'}
            />
          `}
    </div>
  `
}

/**
 * LT-16d+e: matrix (live fleet state) → spec flowchart (structural
 * reference) → FsmHub (per-keeper drill-down). Wide-to-narrow scan.
 * Row-click in the matrix pins the keeper in the hub below. Local
 * state keeps coupling minimal — no new store signal.
 */
function FleetAndFsmHubPanel() {
  const [pinned, setPinned] = useState<string | null>(null)
  return html`
    <div class="v2-monitoring-panel flex flex-col gap-4">
      <${FleetFsmMatrix} onSelectKeeper=${(name: string) => setPinned(name)} />
      <${CompositeFsmFlowchart} />
      <${FsmHub} selectedName=${pinned} />
    </div>
  `
}
