import { signal } from '@preact/signals'
import { navigate, route } from '../router'
import type { Keeper, TabId } from '../types'
import { hydrateKeeperStatus, selectKeeper } from '../keeper-runtime'
import { activeKeeperName } from '../keeper-state'
import { registerKeeperTurnRefresh } from '../sse-store'
import { loadKeeperConfig, resetKeeperConfig } from './keeper-config-state'
import { keeperMobilePane } from './keeper-mobile-pane-state'
export { keeperMobilePane, type KeeperMobilePane } from './keeper-mobile-pane-state'

export const selectedKeeper = signal<Keeper | null>(null)

registerKeeperTurnRefresh((keeperName: string) => {
  if (keeperName !== activeKeeperName.value) return
  void hydrateKeeperStatus(keeperName, true)
  void import('./keeper-trajectory-timeline')
    .then(({ loadTrajectory }) => {
      void loadTrajectory(keeperName)
    })
    .catch(err => {
      // Mirrors sse-store.ts §256: when the trajectory module fails to load,
      // the keeper detail timeline goes stale silently. Promote to warn so
      // operators see it without changing DevTools filter level.
      console.warn('[keeper] trajectory refresh unavailable', err instanceof Error ? err.message : '')
    })
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
