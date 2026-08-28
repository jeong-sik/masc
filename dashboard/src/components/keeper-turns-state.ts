// Shared poller for /api/v1/keepers/turns — the roster's "answering now"
// badge. Same shape as dashboard-full-health-state: one visibility-aware
// interval shared by every subscriber, cancelled when the last one leaves.
// 5s, not the health poll's 60s: a turn that starts and ends inside a
// minute is exactly what the badge exists to show.

import { computed } from '@preact/signals'
import {
  fetchKeeperTurns,
  type KeeperTurnRow,
  type KeeperTurnsResponse,
} from '../api/dashboard-keeper-turns'
import { createManagedAsyncResource } from '../lib/async-state'
import { setupVisibleAutoRefresh } from '../lib/auto-refresh'

export const keeperTurnsResource = createManagedAsyncResource<KeeperTurnsResponse>()

export const keeperTurns = computed<KeeperTurnRow[]>(() => {
  const state = keeperTurnsResource.state.value
  return state.data?.keepers ?? []
})

export function loadKeeperTurns(): Promise<void> {
  return keeperTurnsResource
    .load(signal => fetchKeeperTurns({ signal }))
    .then(() => undefined)
}

export const KEEPER_TURNS_REFRESH_MS = 5_000

let subscriberCount = 0
let stopRefresh: (() => void) | null = null

export function subscribeKeeperTurnsRefresh(): () => void {
  subscriberCount += 1
  if (subscriberCount === 1) {
    void loadKeeperTurns()
    stopRefresh = setupVisibleAutoRefresh(() => {
      void loadKeeperTurns()
    }, KEEPER_TURNS_REFRESH_MS)
  }
  return () => {
    subscriberCount -= 1
    if (subscriberCount === 0) {
      stopRefresh?.()
      stopRefresh = null
      keeperTurnsResource.cancel()
    }
  }
}

/** The running turn for [keeperName], or null when it is idle, unavailable,
 *  or absent from the poll — the badge never guesses. */
export function runningTurnFor(
  rows: readonly KeeperTurnRow[],
  keeperName: string,
): { lane: string; started_at_unix: number } | null {
  const row = rows.find(candidate => candidate.keeper_name === keeperName)
  return row?.status === 'ok' ? row.turn : null
}
