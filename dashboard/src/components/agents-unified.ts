// MASC Dashboard — Keeper Fleet / Workspace Agents
// The route hosts multiple live namespaces. Do not collapse workspace agents,
// keeper runtime fibers, configured keepers, and task owners into one count.

import { html } from 'htm/preact'
import { useMemo, useState } from 'preact/hooks'
import { computed } from '@preact/signals'
import { FilterChips } from './common/filter-chips'
import { navigate, route } from '../router'
import { agents, keepers, executionLoaded, shellCounts, shellRuntimeResolution } from '../store'
import { AgentRoster, countRuntimeKinds } from './agent-roster'
import { AgentProfile } from './agent-profile'
import { KeeperDetailPage } from './keeper-detail-page'
import { namespaceTruth } from '../namespace-truth-store'
import { buildCompositeByKeeperKey, fleetCompositeSnapshot } from '../composite-signals'
import {
  formatKeeperRosterCount,
  formatRuntimeRosterCount,
  resolveRuntimeCounts,
} from '../runtime-counts'
import { KeeperSpawnPanel } from './keeper-spawn/keeper-spawn-panel'
import { KeeperTokenStats } from './keeper-token-stats'
import { KeeperMultiSelect } from './keeper-multi-select'
import { FsmHub } from './fsm-hub'
import { FleetFsmMatrix } from './fleet-fsm-matrix'
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
  { id: 'all', label: 'Runtime Ops', description: 'workspace agents와 keeper runtime 행을 함께 보되 count surface는 분리합니다.' },
  { id: 'agents', label: 'Workspace Agents', description: '/api/v1/agents workspace presence만 봅니다. keeper fiber나 task owner가 아닙니다.' },
  { id: 'keepers', label: 'Keeper Runtime', description: 'keeper 실행 fiber, runtime detail row, configured keeper inventory를 봅니다.' },
  { id: 'fsm', label: 'Keeper FSM', description: '키퍼 composite FSM lifecycle 상태를 봅니다.' },
]

export function AgentsUnified() {
  const keeperParam = route.value.params.keeper as string | undefined
  const agentParam = route.value.params.agent as string | undefined
  const currentView = activeView.value

  // countRuntimeKinds is an O(N) scan over agents+keepers. Memoized so an
  // execution_snapshot that only touches unrelated signals (or a re-render from
  // activeView/namespaceTruth/shellCounts) skips the rescan when agents/keepers
  // themselves are unchanged.
  //
  // Must run before any conditional return: when the route has a keeper/agent
  // param this component renders a detail page, but navigating back to the
  // fleet view re-enters this branch. Keeping the hook sequence stable prevents
  // Preact hook-order failures during detail-to-list navigation.
  // RFC-0295: pass the same fleet-wide composite snapshot map AgentRoster
  // uses (and reads from `fleetCompositeSnapshot`) so countRuntimeKinds and
  // the per-row band derivation agree on transient/attention membership.
  const fleetSnapshot = fleetCompositeSnapshot.value
  const compositeByKeeperKey = useMemo(() => buildCompositeByKeeperKey(fleetSnapshot), [fleetSnapshot])
  const liveRuntimeCounts = useMemo(
    () => countRuntimeKinds(agents.value, keepers.value, compositeByKeeperKey),
    [agents.value, keepers.value, compositeByKeeperKey],
  )

  if (keeperParam) {
    return html`<${KeeperDetailPage} />`
  }

  // If an agent name is in the route params, show the profile page
  if (agentParam) {
    return html`<${AgentProfile} name=${agentParam} />`
  }

  const runtimeCounts = resolveRuntimeCounts({
    executionLoaded: executionLoaded.value,
    agentsCount: liveRuntimeCounts.agents,
    keepersCount: liveRuntimeCounts.keepers,
    pausedKeepersCount: liveRuntimeCounts.pausedKeepers,
    transientKeepersCount: liveRuntimeCounts.transientKeepers,
    offlineKeepersCount: liveRuntimeCounts.offlineKeepers,
    keeperRowsCount: liveRuntimeCounts.keeperRows,
    namespaceTruthCounts: namespaceTruth.value?.root.counts,
    namespaceTruthConfiguredKeepers: namespaceTruth.value?.root.configured_keepers,
    shellCounts: shellCounts.value,
    shellConfiguredKeepers: shellCounts.value?.configured_keepers,
    runtimeFleetSafety: shellRuntimeResolution.value?.fleet_safety ?? null,
    runtimeHealthGeneratedAt: shellRuntimeResolution.value?.generated_at ?? null,
  })
  function chipCount(id: AgentsView): number | string | null {
    if (id === 'all') return formatRuntimeRosterCount(runtimeCounts)
    if (id === 'agents') return `workspace agents ${runtimeCounts.live.agents}`
    if (id === 'keepers') return formatKeeperRosterCount(runtimeCounts)
    return null
  }
  const viewChips = CHIPS.map(chip => ({
    key: chip.id,
    label: chip.label,
    count: chipCount(chip.id),
    title: chip.description,
  }))

  return html`
    <div class="v2-monitoring-surface flex flex-col gap-4">
      <${FilterChips}
        chips=${viewChips}
        value=${currentView}
        onChange=${(key: AgentsView) => {
          navigate('monitoring', key === 'all' ? { section: 'agents' } : { section: 'agents', view: key })
        }}
        size="md"
        tone="accent"
        class="monitor-muted-panel w-fit p-1.5 shadow-[inset_0_1px_0_var(--color-border-default)]"
      />

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
    <div class="v2-monitoring-panel flex flex-col gap-4">
      <${FleetFsmMatrix} onSelectKeeper=${(name: string) => setPinned(name)} />
      <${CompositeFsmFlowchart} />
      <${FsmHub} selectedName=${pinned} />
    </div>
  `
}
