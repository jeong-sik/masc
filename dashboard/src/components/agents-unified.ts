// MASC Dashboard — Unified Agents Tab
// Absorbs: agent-roster + execution + keeper-roster into one view with chip toggle.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
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

type AgentsView = 'all' | 'agents' | 'keepers'

const activeView = signal<AgentsView>('all')

const CHIPS: { id: AgentsView; label: string; description: string }[] = [
  { id: 'all', label: '전체 보기', description: '에이전트와 키퍼를 한 목록에서 봅니다.' },
  { id: 'agents', label: '일반 에이전트', description: '키퍼가 연결되지 않은 일반 에이전트만 봅니다.' },
  { id: 'keepers', label: '키퍼 런타임', description: '키퍼 런타임만 따로 봅니다.' },
]

export function AgentsUnified() {
  // If an agent name is in the route params, show the profile page
  const agentParam = route.value.params.agent as string | undefined
  if (agentParam) {
    return html`<${AgentProfile} name=${agentParam} />`
  }

  const viewParam = route.value.params.view as string | undefined
  const routeView =
    viewParam === 'keepers' || viewParam === 'agents'
      ? viewParam
      : null
  const currentView = routeView ?? activeView.value

  useEffect(() => {
    if (routeView && activeView.value !== routeView) {
      activeView.value = routeView
    }
  }, [routeView])

  // Compute counts for chip badges.
  const liveRuntimeCounts = countRuntimeKinds(agents.value, keepers.value, missionKeeperBriefs.value)
  const runtimeCounts = resolveRuntimeCounts({
    executionLoaded: executionLoaded.value,
    agentsCount: liveRuntimeCounts.agents,
    keepersCount: liveRuntimeCounts.keepers,
    namespaceTruthCounts: namespaceTruth.value?.namespace.counts,
    shellCounts: shellCounts.value,
  })
  const totalCount = runtimeCounts.totalRuntimes
  const keeperCount = runtimeCounts.keepers
  const agentOnlyCount = runtimeCounts.agents
  const currentViewMeta = CHIPS.find(chip => chip.id === currentView) ?? {
    id: 'all' as const,
    label: '전체 보기',
    description: '에이전트와 키퍼를 한 목록에서 봅니다.',
  }

  function chipCount(id: AgentsView): number | null {
    if (id === 'all') return totalCount
    if (id === 'agents') return agentOnlyCount
    if (id === 'keepers') return keeperCount
    return null
  }

  const currentViewSummary =
    currentView === 'all'
      ? `일반 에이전트 ${agentOnlyCount}개와 키퍼 런타임 ${keeperCount}개를 한 목록에서 봅니다.`
      : currentView === 'agents'
        ? `일반 에이전트 ${agentOnlyCount}개만 표시합니다.`
        : `키퍼 런타임 ${keeperCount}개만 표시합니다.`
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
        active=${activeView}
        onChange=${(key: AgentsView) => {
          navigate('monitoring', key === 'all' ? { section: 'agents' } : { section: 'agents', view: key })
        }}
        size="md"
        tone="accent"
        class="monitor-muted-panel w-fit p-1.5 shadow-[inset_0_1px_0_var(--white-3)]"
      />
      <div class="monitor-muted-panel bg-[linear-gradient(180deg,var(--accent-soft),var(--white-2))] px-4 py-3 text-[12px] leading-[1.5] text-[var(--text-body)]">
        <strong class="mr-2 text-[var(--text-strong)]">${currentViewMeta.label}</strong>
        <span>${currentViewSummary}</span>
      </div>

      ${currentView !== 'agents' ? html`<${KeeperSpawnPanel} />` : null}

      ${currentView !== 'agents' && keepers.value.length > 0 ? html`
        <${KeeperFleetOverview} keepers=${keepers.value} />
      ` : null}

      <${AgentRoster}
        keeperFilter=${currentView === 'keepers' ? 'keeper-only'
          : currentView === 'agents' ? 'agent-only'
          : 'all'}
      />
    </div>
  `
}
