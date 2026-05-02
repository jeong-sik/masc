// MASC Dashboard — Unified Agents Tab
// Absorbs: agent-roster + execution + keeper-roster + FSM hub into one view with chip toggle.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { computed } from '@preact/signals'
import { FilterChips } from './common/filter-chips'
import { navigate, route } from '../router'
import { agents, keepers, executionLoaded, shellCounts } from '../store'
import { AgentRoster, countRuntimeKinds } from './agent-roster'
import { AgentProfile } from './agent-profile'
import { KeeperDetailPage } from './keeper-detail'
import { RouteLink } from './common/route-link'
import { namespaceTruth } from '../namespace-truth-store'
import { resolveRuntimeCounts } from '../runtime-counts'
import { KeeperSpawnPanel } from './keeper-spawn/keeper-spawn-panel'
import { KeeperTokenStats } from './keeper-token-stats'
import { KeeperMultiSelect } from './keeper-multi-select'
import { FsmHub } from './fsm-hub'
import { FleetFsmMatrix } from './fleet-fsm-matrix'
import { HandoffTimeline } from './handoff-timeline'
import { CompositeFsmFlowchart } from './composite-fsm-flowchart'

type AgentsView = 'all' | 'agents' | 'keepers' | 'fsm'

const VALID_VIEWS: AgentsView[] = ['all', 'agents', 'keepers', 'fsm']

// Derive active view from route params. Single source of truth — no
// useEffect sync needed. Falls back to 'all' when view param is absent.
const activeView = computed<AgentsView>(() => {
  const v = route.value.params.view
  return v && (VALID_VIEWS as string[]).includes(v) ? v as AgentsView : 'all'
})

const CHIPS: { id: AgentsView; label: string; description: string }[] = [
  { id: 'all', label: '전체', description: '에이전트와 키퍼를 한 목록에서 봅니다.' },
  { id: 'agents', label: '에이전트', description: '키퍼가 연결되지 않은 일반 에이전트만 봅니다.' },
  { id: 'keepers', label: '키퍼', description: '키퍼만 따로 봅니다.' },
  { id: 'fsm', label: 'FSM', description: '키퍼 composite FSM lifecycle 상태를 봅니다.' },
]

export function AgentsUnified() {
  const keeperParam = route.value.params.keeper as string | undefined
  if (keeperParam) {
    return html`<${KeeperDetailPage} />`
  }

  // If an agent name is in the route params, show the profile page
  const agentParam = route.value.params.agent as string | undefined
  if (agentParam) {
    return html`<${AgentProfile} name=${agentParam} />`
  }

  const currentView = activeView.value

  // Compute counts for chip badges.
  const liveRuntimeCounts = countRuntimeKinds(agents.value, keepers.value)
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
  const configuredKeeperDelta = Math.max(0, runtimeCounts.configuredKeepers - keeperCount)
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

      ${configuredKeeperDelta > 0 ? html`
        <div class="monitor-muted-panel flex w-fit flex-wrap items-center gap-2 px-3 py-2 text-xs text-[var(--color-fg-muted)]">
          <span class="text-2xs font-semibold uppercase tracking-1 text-[var(--color-fg-muted)]">runtime truth</span>
          <span>live runtime ${keeperCount} · configured keeper ${runtimeCounts.configuredKeepers} · 일시정지/미기동 ${configuredKeeperDelta}</span>
        </div>
      ` : null}

      ${currentView !== 'fsm' ? html`
        <div class="monitor-muted-panel flex flex-wrap items-center gap-2 px-4 py-3 text-xs text-[var(--color-fg-muted)]">
          <span class="text-2xs font-semibold uppercase tracking-1 text-[var(--color-fg-muted)]">이 화면 밖</span>
          <span>cached 조율 스냅샷, 이벤트 로그, 도구 품질, 거버넌스</span>
          <${RouteLink}
            tab="monitoring"
            params=${{ section: 'fleet-health' }}
            class="inline-flex shrink-0 items-center justify-center rounded-[var(--r-0)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-3 py-1.5 text-xs font-medium text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--accent-20)]"
          >
            플릿 텔레메트리 열기
          <//>
        </div>
      ` : null}

      ${currentView === 'fsm'
        ? html`<${FleetAndFsmHubPanel} />`
        : html`
          ${currentView !== 'agents' ? html`<${KeeperSpawnPanel} />` : null}

          ${currentView === 'keepers' ? html`
            <${KeeperMultiSelect}
              hint="필터를 적용하면 아래 토큰 집계가 선택한 keeper 만 합산합니다. 비어 있으면 전체 합산입니다."
            />
            <${KeeperTokenStats} />
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

/**
 * LT-16d+e: matrix (live fleet state) → spec flowchart (structural
 * reference) → FsmHub (per-keeper drill-down). Wide-to-narrow scan.
 * Row-click in the matrix pins the keeper in the hub below. Local
 * state keeps coupling minimal — no new store signal.
 */
function FleetAndFsmHubPanel() {
  const [pinned, setPinned] = useState<string | null>(null)
  return html`
    <div class="flex flex-col gap-4">
      <${FleetFsmMatrix} onSelectKeeper=${(name: string) => setPinned(name)} />
      <${HandoffTimeline}
        onSelectKeeper=${(name: string) => setPinned(name)}
        selectedKeeper=${pinned}
      />
      <${CompositeFsmFlowchart} />
      <${FsmHub} selectedName=${pinned} />
    </div>
  `
}
