import { fetchKeeperCurrentTurn, fetchKeeperTurnEvents, type KeeperTurnCursor } from './api/keeper-turn-events'
import { applyKeeperAutonomousTurnEvent } from './keeper-stream'
import { keeperThreads, updateThreadEntry } from './keeper-state'

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
  const newerNotification = state.inFlight !== null && sequence > state.target
  state.target = Math.max(state.target, sequence)
  state.pullRequested ||= force || newerNotification
  if (state.inFlight) return state.inFlight
  if (!state.pullRequested && state.cursor.sequence !== null && state.cursor.sequence >= state.target) return Promise.resolve()
  const current = state
  const recoveryStatus = (status: { kind: 'unavailable'; detail: string } | null): void => {
    const parent = (keeperThreads.value[name] ?? []).find(entry => entry.source === 'autonomous_turn' && entry.turnRef === turnRef)
    if (parent) updateThreadEntry(name, parent.id, entry => ({ ...entry, autonomousJournalRecovery: status }))
  }
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
  current.inFlight = drain().then(() => recoveryStatus(null)).catch(error => {
    failed = true
    recoveryStatus({ kind: 'unavailable', detail: error instanceof Error ? error.message : 'Journal recovery failed' })
    throw error
  }).finally(() => {
    current.inFlight = null
    // A notification can arrive in the microtask between drain and cleanup.
    // A fresh request received during a failed read still owns a recovery
    // attempt. Failure alone never schedules another attempt.
    if (current.pullRequested || !failed && (current.cursor.sequence === null || current.cursor.sequence < current.target)) {
      void recoverKeeperAutonomousTurn(name, turnRef, current.target, current.pullRequested).catch(error => {
        console.debug('[keeper-autonomous-stream] journal recovery failed', error instanceof Error ? error.name : 'read failure')
      })
    }
  })
  return current.inFlight
}

export function _resetKeeperAutonomousRecoveryForTests(): void { recovery.clear() }

/** Persisted autonomous identity discovers completed turns as well as live
 * ones. Replay only explicit autonomous rows, never matching text or counters. */
export async function recoverKeeperAutonomousHistory(name: string): Promise<void> {
  const turns = new Set((keeperThreads.value[name] ?? []).flatMap(entry =>
    entry.source === 'autonomous_turn' && entry.turnRef ? [entry.turnRef] : []))
  const results = await Promise.allSettled(Array.from(turns, turnRef =>
    recoverKeeperAutonomousTurn(name, turnRef, 0, true)))
  if (results.some(result => result.status === 'rejected')) throw new Error('Autonomous history journal recovery incomplete')
}

/** A reconnect may have lost completion or the first notice of a new turn.
 * Discover the current producer for each known Keeper and recover its known
 * journals as well; no periodic polling is introduced. */
export async function recoverKnownKeeperAutonomousTurns(): Promise<void> {
  const keepers = Array.from(recovery, async ([name, turns]) => {
    const targets = new Map(Array.from(turns, ([turnRef, state]) => [turnRef, state.target]))
    const reads = Array.from(targets, ([turnRef, sequence]) =>
      recoverKeeperAutonomousTurn(name, turnRef, sequence, true))
    reads.push(fetchKeeperCurrentTurn(name).then(async current => {
      if (current.state === 'idle') return
      const knownTarget = targets.get(current.turnRef)
      if (knownTarget !== undefined && current.sequence <= knownTarget) return
      await recoverKeeperAutonomousTurn(name, current.turnRef, current.sequence, true)
    }))
    const results = await Promise.allSettled(reads)
    if (results.some(result => result.status === 'rejected')) {
      throw new Error('Autonomous Keeper reconnect recovery incomplete')
    }
  })
  const results = await Promise.allSettled(keepers)
  if (results.some(result => result.status === 'rejected')) throw new Error('Autonomous reconnect journal recovery incomplete')
}

/** Discover producer identity from the server; never derive it from turn count. */
export async function discoverKeeperAutonomousTurn(name: string): Promise<void> {
  const current = await fetchKeeperCurrentTurn(name)
  if (current.state === 'observed') await recoverKeeperAutonomousTurn(name, current.turnRef, current.sequence, true)
}
