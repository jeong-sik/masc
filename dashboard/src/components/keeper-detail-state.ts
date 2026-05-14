import { signal } from '@preact/signals'
import { navigate, route } from '../router'
import type { Keeper } from '../types'
import { hydrateKeeperStatus, selectKeeper } from '../keeper-runtime'
import { activeKeeperName } from '../keeper-state'
import { registerKeeperTurnRefresh } from '../sse-store'
import { loadKeeperConfig, resetKeeperConfig } from './keeper-config-panel'

export const selectedKeeper = signal<Keeper | null>(null)

registerKeeperTurnRefresh((keeperName: string) => {
  if (keeperName !== activeKeeperName.value) return
  void hydrateKeeperStatus(keeperName, true)
  void import('./keeper-trajectory-timeline')
    .then(({ loadTrajectory }) => {
      void loadTrajectory(keeperName)
    })
    .catch(err => {
      console.debug('[keeper] trajectory refresh unavailable', err instanceof Error ? err.message : '')
    })
})

function selectedKeeperMatches(keeperName: string): boolean {
  const selected = selectedKeeper.value
  if (!selected) return false
  const trimmed = keeperName.trim()
  return selected.name === trimmed || selected.agent_name === trimmed
}

function baseAgentDirectoryRouteParams(): Record<string, string> {
  if (route.value.tab === 'monitoring' && route.value.params.section === 'agents') {
    const next: Record<string, string> = { ...route.value.params, section: 'agents' }
    delete next.agent
    delete next.keeper
    return next
  }
  return { section: 'agents' }
}

export function openKeeperDetail(k: Keeper) {
  selectedKeeper.value = k
  selectKeeper(k.name)
  void loadKeeperConfig(k.name)
  navigate('monitoring', { ...baseAgentDirectoryRouteParams(), keeper: k.name })
}

export function clearKeeperDetailSelection(keeperName?: string) {
  if (keeperName && !selectedKeeperMatches(keeperName)) return
  selectedKeeper.value = null
  selectKeeper('')
  resetKeeperConfig()
}

export function closeKeeperDetail() {
  clearKeeperDetailSelection()
  navigate('monitoring', baseAgentDirectoryRouteParams())
}
