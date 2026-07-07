import { signal } from '@preact/signals'
import { navigate, route } from '../router'
import type { Keeper, TabId } from '../types'
import { hydrateKeeperStatus, selectKeeper } from '../keeper-actions'
import { activeKeeperName } from '../keeper-state'
import { registerKeeperTurnRefresh } from '../sse-store'
import { loadKeeperConfig, resetKeeperConfig } from './keeper-config-state'
import { keeperMobilePane } from './keeper-mobile-pane-state'
export { keeperMobilePane, type KeeperMobilePane } from './keeper-mobile-pane-state'

export const selectedKeeper = signal<Keeper | null>(null)

registerKeeperTurnRefresh((keeperName: string) => {
  if (keeperName !== activeKeeperName.value) return
  void hydrateKeeperStatus(keeperName, true)
  // The keeper-trajectory-timeline refresh that used to fire here was dead
  // weight: its UI was retired and loadTrajectory wrote into a signal with
  // zero readers, costing one /api/v1/keepers/:name/trajectory request per
  // turn event. Module deleted with this change.
})

function selectedKeeperMatches(keeperName: string): boolean {
  const selected = selectedKeeper.value
  if (!selected) return false
  const trimmed = keeperName.trim()
  return selected.name === trimmed || selected.agent_name === trimmed
}

function baseAgentDirectoryRoute(): { tab: TabId; params: Record<string, string> } {
  if (route.value.tab === 'keepers') {
    const next: Record<string, string> = { ...route.value.params }
    delete next.agent
    delete next.keeper
    delete next.section
    return { tab: 'keepers', params: next }
  }
  if (route.value.tab === 'monitoring' && route.value.params.section === 'agents') {
    const next: Record<string, string> = { ...route.value.params, section: 'agents' }
    delete next.agent
    delete next.keeper
    return { tab: 'monitoring', params: next }
  }
  return { tab: 'monitoring', params: { section: 'agents' } }
}

export function openKeeperDetail(k: Keeper) {
  selectedKeeper.value = k
  keeperMobilePane.value = 'chat'
  selectKeeper(k.name)
  void loadKeeperConfig(k.name)
  const base = baseAgentDirectoryRoute()
  navigate(base.tab, { ...base.params, keeper: k.name })
}

export function clearKeeperDetailSelection(keeperName?: string) {
  if (keeperName && !selectedKeeperMatches(keeperName)) return
  selectedKeeper.value = null
  selectKeeper('')
  resetKeeperConfig()
}

export function closeKeeperDetail() {
  clearKeeperDetailSelection()
  const base = baseAgentDirectoryRoute()
  navigate(base.tab, base.params)
}
