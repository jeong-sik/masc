import { fetchKeeperTurnEvents, type KeeperTurnCursor } from './api/keeper-turn-events'
import { applyKeeperAutonomousTurnEvent } from './keeper-stream'

type TurnRecovery = {
  cursor: KeeperTurnCursor
  target: number
  inFlight: Promise<void> | null
  pullRequested: boolean
}
const recovery = new Map<string, Map<string, TurnRecovery>>()

/** Notifications carry no content. Recover the canonical authenticated journal
 * with one request chain per exact Keeper/turn, coalescing newer notifications. */
export function recoverKeeperAutonomousTurn(name: string, turnRef: string, sequence: number, force = false): Promise<void> {
  if (!name.trim() || !turnRef.trim() || !Number.isSafeInteger(sequence) || sequence < 0) {
    return Promise.reject(new Error('Invalid autonomous journal notification'))
  }
  let turns = recovery.get(name)
  if (!turns) { turns = new Map(); recovery.set(name, turns) }
  let state = turns.get(turnRef)
  if (!state) {
    state = { cursor: { sequence: null, offset: 0 }, target: sequence, inFlight: null, pullRequested: false }
    turns.set(turnRef, state)
  }
  state.target = Math.max(state.target, sequence)
  state.pullRequested ||= force
  if (state.inFlight) return state.inFlight
  if (!state.pullRequested && state.cursor.sequence !== null && state.cursor.sequence >= state.target) return Promise.resolve()
  const current = state
  let failed = false
  const drain = async (): Promise<void> => {
    let hasMore = false
    do {
      current.pullRequested = false
      const before = current.cursor
      const page = await fetchKeeperTurnEvents(name, turnRef, before)
      for (const row of page.events) {
        if (row.event) applyKeeperAutonomousTurnEvent(name, turnRef, row.sequence, row.event)
      }
      current.cursor = page.cursor
      hasMore = page.hasMore
      if (current.cursor.sequence === before.sequence && current.cursor.offset === before.offset
        && (current.cursor.sequence === null || current.cursor.sequence < current.target)) {
        throw new Error('Autonomous journal has not reached its notified cursor')
      }
    } while (hasMore || current.pullRequested || current.cursor.sequence === null || current.cursor.sequence < current.target)
  }
  current.inFlight = drain().catch(error => { failed = true; throw error }).finally(() => {
    current.inFlight = null
    // A notification can arrive in the microtask between drain and cleanup.
    // Recheck the target without automatically retrying failed reads.
    if (!failed && (current.pullRequested || current.cursor.sequence === null || current.cursor.sequence < current.target)) {
      void recoverKeeperAutonomousTurn(name, turnRef, current.target, current.pullRequested).catch(error => {
        console.debug('[keeper-autonomous-stream] journal recovery failed', error instanceof Error ? error.name : 'read failure')
      })
    }
  })
  return current.inFlight
}

export function _resetKeeperAutonomousRecoveryForTests(): void { recovery.clear() }

/** A reconnect may have lost the last notification, including completion.
 * Pull each already-discovered journal once; no periodic polling is introduced. */
export async function recoverKnownKeeperAutonomousTurns(): Promise<void> {
  const reads: Promise<void>[] = []
  for (const [name, turns] of recovery) for (const [turnRef, state] of turns) {
    reads.push(recoverKeeperAutonomousTurn(name, turnRef, state.target, true))
  }
  const results = await Promise.allSettled(reads)
  if (results.some(result => result.status === 'rejected')) throw new Error('Autonomous reconnect journal recovery incomplete')
}
