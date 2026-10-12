import { fetchKeeperCurrentTurn, fetchKeeperTurnEvents, type KeeperTurnCursor } from './api/keeper-turn-events'
import { applyKeeperAutonomousTurnEvent, ensureKeeperAutonomousObservationEntry } from './keeper-stream'
import { keeperThreads, updateThreadEntry } from './keeper-state'

type TurnRecovery = {
  cursor: KeeperTurnCursor
  target: number
  inFlight: Promise<void> | null
  pullRequested: boolean
  /** The journal's own terminal event (RUN_FINISHED/RUN_ERROR) was applied.
   *  A reconnect never re-reads a terminal turn and drops its state there;
   *  until a terminal is seen, the notified cursor only means "everything
   *  known so far", and a reconnect re-read is how a lost later notification
   *  is still discovered. */
  terminalSeen: boolean
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
    state = { cursor: { sequence: null, offset: 0 }, target: sequence, inFlight: null, pullRequested: false, terminalSeen: false }
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
    if (parent) {
      updateThreadEntry(name, parent.id, entry => ({ ...entry, autonomousJournalRecovery: status }))
      return
    }
    if (status === null) return
    // The first journal request failed before any event could create the
    // parent bubble, so attaching the diagnostic to a parent would drop it.
    // Create the exact autonomous observation entry the journal replays into
    // and carry the warning there; a later successful recovery applies into
    // the same entry.
    const entryId = ensureKeeperAutonomousObservationEntry(name, turnRef)
    updateThreadEntry(name, entryId, entry => ({ ...entry, autonomousJournalRecovery: status }))
  }
  let failed = false
  const drain = async (): Promise<void> => {
    let hasMore = false
    do {
      current.pullRequested = false
      const before = current.cursor
      const page = await fetchKeeperTurnEvents(name, turnRef, before)
      for (const row of page.events) {
        if (row.event) {
          if (row.event.type === 'RUN_FINISHED' || row.event.type === 'RUN_ERROR') current.terminalSeen = true
          applyKeeperAutonomousTurnEvent(name, turnRef, row.sequence, row.event)
        }
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
    const reads = Array.from(targets, ([turnRef, sequence]) => {
      const state = turns.get(turnRef)
      // A turn whose journal terminal was consumed is complete: a reconnect
      // never needs to re-read it, so dropping its state here is what bounds
      // the reconnect batch to active turns instead of every turn the
      // session has ever seen. Non-terminal turns stay: their cursor is the
      // resume position a reconnect continues from, which is how a terminal
      // event whose notification was lost is still recovered. An in-flight
      // or re-requested read still owns its state.
      if (state && state.terminalSeen && state.inFlight === null && !state.pullRequested) {
        turns.delete(turnRef)
        return null
      }
      return recoverKeeperAutonomousTurn(name, turnRef, sequence, true)
    }).filter((read): read is Promise<void> => read !== null)
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
