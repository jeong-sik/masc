import { signal } from '@preact/signals'
import { navigate, route } from '../router'
import type { Keeper } from '../types'
import { hydrateKeeperStatus, selectKeeper } from '../keeper-runtime'
import { activeKeeperName } from '../keeper-state'
import { registerKeeperTurnRefresh } from '../sse-store'
import { loadKeeperConfig, resetKeeperConfig } from './keeper-config-panel'

export const selectedKeeper = signal<Keeper | null>(null)

/** Mobile (≤860px) single-pane switch for the keeper workspace grid.
 * Desktop shows roster | conversation | rail side by side; below 860px only
 * one pane fits at a time, so this selects the visible one. Defaults to 'chat'
 * because entering keeper detail means a keeper is focused. Roster row select
 * and `openKeeperDetail` set 'chat'; the chat header back button sets 'roster'.
 * Read by `.kw-grid[data-mobile-pane]` in keeper-workspace.css. */
export type KeeperMobilePane = 'roster' | 'chat'
export const keeperMobilePane = signal<KeeperMobilePane>('chat')

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
  keeperMobilePane.value = 'chat'
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
