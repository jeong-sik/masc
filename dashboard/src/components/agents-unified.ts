// MASC Dashboard — Unified Agents Tab
// Absorbs: agent-roster + execution + keeper-roster + FSM hub into one view with chip toggle.

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { FilterChips } from './common/filter-chips'
import { navigate, route } from '../router'
import { agents, keepers, executionLoaded, shellCounts } from '../store'
import { missionKeeperBriefs } from '../mission-signals'
import { AgentRoster, countRuntimeKinds } from './agent-roster'
import { AgentProfile } from './agent-profile'
import { namespaceTruth } from '../namespace-truth-store'
import { resolveRuntimeCounts } from '../runtime-counts'
import { KeeperSpawnPanel } from './keeper-spawn/keeper-spawn-panel'
import { KeeperFleetOverview } from './keeper-fleet-overview'
import { FsmHub } from './fsm-hub'

type AgentsView = 'all' | 'agents' | 'keepers' | 'fsm'

const VALID_VIEWS: AgentsView[] = ['all', 'agents', 'keepers', 'fsm']

// Derive active view from route params. Single source of truth — no
// useEffect sync needed. Falls back to 'all' when view param is absent.
const activeView = computed<AgentsView>(() => {
  const v = route.value.params.view
  return v && (VALID_VIEWS as string[]).includes(v) ? v as AgentsView : 'all'
})

const CHIPS: { id: AgentsView; label: string; description: string }[] = [
  { id: 'all', label: '전체 보기', description: '에이전트와 키퍼를 한 목록에서 봅니다.' },
  { id: 'agents', label: '일반 에이전트', description: '키퍼가 연결되지 않은 일반 에이전트만 봅니다.' },
  { id: 'keepers', label: '키퍼', description: '키퍼만 따로 봅니다.' },
  { id: 'fsm', label: 'FSM', description: '키퍼 composite FSM lifecycle 상태를 봅니다.' },
]

export function AgentsUnified() {
  // If an agent name is in the route params, show the profile page
  const agentParam = route.value.params.agent as string | undefined
  if (agentParam) {
    return html`<${AgentProfile} name=${agentParam} />`
  }

  const currentView = activeView.value

  // Compute counts for chip badges.
  const liveRuntimeCounts = countRuntimeKinds(agents.value, keepers.value, missionKeeperBriefs.value)
  const runtimeCounts = resolveRuntimeCounts({
    executionLoaded: executionLoaded.value,
    agentsCount: liveRuntimeCounts.agents,
    keepersCount: liveRuntimeCounts.keepers,
    namespaceTruthCounts: namespaceTruth.value?.root.counts,
    namespaceTruthConfiguredKeepers: namespaceTruth.value?.root.configured_keepers,
    shellCounts: shellCounts.value,
    shellConfiguredKeepers: shellCounts.value?.configured_keepers,
  })
  const totalCount = runtimeCounts.totalRuntimes
  const keeperCount = runtimeCounts.keepers
  const agentOnlyCount = runtimeCounts.agents
  function chipCount(id: AgentsView): number | null {
    if (id === 'all') return totalCount
    if (id === 'agents') return agentOnlyCount
    if (id === 'keepers') return keeperCount
    return null
  }
  const viewChips = CHIPS.map(chip => ({
    key: chip.id,
    label: chip.label,
    count: chipCount(chip.id),
    title: chip.description,
  }))

  return html`
    <div class="flex flex-col gap-4">
      <${FilterChips}
        chips=${viewChips}
        value=${currentView}
        onChange=${(key: AgentsView) => {
          navigate('monitoring', key === 'all' ? { section: 'agents' } : { section: 'agents', view: key })
        }}
        size="md"
        tone="accent"
        class="monitor-muted-panel w-fit p-1.5 shadow-[inset_0_1px_0_var(--white-3)]"
      />

      ${currentView === 'fsm'
        ? html`<${FsmHub} />`
        : html`
          ${currentView !== 'agents' ? html`<${KeeperSpawnPanel} />` : null}

          ${currentView !== 'agents' && keepers.value.length > 0 ? html`
            <${KeeperFleetOverview} keepers=${keepers.value} />
          ` : null}

          <${AgentRoster}
            keeperFilter=${currentView === 'keepers' ? 'keeper-only'
              : currentView === 'agents' ? 'agent-only'
              : 'all'}
          />
        `}
    </div>
  `
}
