// Shared poller for /api/v1/keepers/turns — the roster's "answering now"
// badge. Same shape as dashboard-full-health-state: one visibility-aware
// interval shared by every subscriber, cancelled when the last one leaves.
// 5s, not the health poll's 60s: a turn that starts and ends inside a
// minute is exactly what the badge exists to show.

import { computed, signal } from '@preact/signals'
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
  const previousRows = keeperTurnsResource.state.value.data?.keepers ?? []
  return keeperTurnsResource
    .load(signal => fetchKeeperTurns({ signal }))
    .then(() => {
      const currentRows = keeperTurnsResource.state.value.data?.keepers
      // A failed poll leaves data unchanged; advancing on it would fabricate
      // finishes out of the same snapshot compared with itself.
      if (currentRows && currentRows !== previousRows) {
        keeperFinishes.value = advanceFinishes(
          Date.now(), previousRows, currentRows, keeperFinishes.value,
        )
      }
    })
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

// ── the finish glow ────────────────────────────────────────────────
//
// Same contract as the TUI's advance_finishes (#31208): two consecutive
// polls are what "just finished" is made of — running in the previous,
// idle in this one. Unavailable→idle is not a finish (an owner lookup
// failure says nothing about the turn), a keeper missing from the current
// poll is not a finish (removed, not answered), and a keeper that starts
// running again drops its glow — one keeper must not read as both
// answering and answered.

export const FINISH_GLOW_TTL_MS = 60_000

export interface KeeperFinish {
  keeper_name: string
  finished_at_ms: number
}

function isRunning(row: KeeperTurnRow | undefined): boolean {
  return row?.status === 'ok' && row.turn !== null
}

function isIdle(row: KeeperTurnRow | undefined): boolean {
  return row?.status === 'ok' && row.turn === null
}

export function advanceFinishes(
  nowMs: number,
  previousRows: readonly KeeperTurnRow[],
  currentRows: readonly KeeperTurnRow[],
  finishes: readonly KeeperFinish[],
): KeeperFinish[] {
  const currentByName = new Map(currentRows.map(row => [row.keeper_name, row]))
  const fresh: KeeperFinish[] = previousRows
    .filter(row => isRunning(row) && isIdle(currentByName.get(row.keeper_name)))
    .map(row => ({ keeper_name: row.keeper_name, finished_at_ms: nowMs }))
  const freshNames = new Set(fresh.map(finish => finish.keeper_name))
  const kept = finishes.filter(finish =>
    nowMs - finish.finished_at_ms <= FINISH_GLOW_TTL_MS
    && !freshNames.has(finish.keeper_name)
    && !isRunning(currentByName.get(finish.keeper_name)),
  )
  return [...fresh, ...kept]
}

/** The live glow for [keeperName], or null — expired entries filtered by the
 *  reader's own clock so the glow dies on time, not on the next poll. */
export function finishGlowFor(
  finishes: readonly KeeperFinish[],
  keeperName: string,
  nowMs: number,
): KeeperFinish | null {
  const finish = finishes.find(candidate => candidate.keeper_name === keeperName)
  return finish && nowMs - finish.finished_at_ms <= FINISH_GLOW_TTL_MS
    ? finish
    : null
}

export const keeperFinishes = signal<readonly KeeperFinish[]>([])
