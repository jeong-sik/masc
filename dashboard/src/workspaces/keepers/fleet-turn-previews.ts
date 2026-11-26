import { previewForObservedTurn, retainTurnPreview, type ReceivedTurnPreview } from './chat-turn-progress'
import type { KeeperRosterItem } from './types'

// The turns read is a snapshot taken when a turn begins or ends. What the turn
// does in between arrives as preview frames on the Observer stream. The Chat
// tab follows those frames for its one Keeper. This keeps them for every
// Keeper, so the header and the roster say what a turn is doing now and not
// what it was doing when the snapshot was read. The TUI holds its fleet the
// same way (`Fleet_store.observe_turn_preview`).

/** The previews received for each Keeper's turns, by Keeper name. */
export type FleetTurnPreviews = ReadonlyMap<string, readonly ReceivedTurnPreview[]>

export const NO_FLEET_TURN_PREVIEWS: FleetTurnPreviews = new Map()

/**
 * The previews with one more kept. Returns the same map when the preview is
 * not newer than the one already held for its turn. A Keeper's own list keeps
 * its identity when another Keeper's preview is kept.
 */
export function retainFleetTurnPreview(
  fleet: FleetTurnPreviews,
  keeperName: string,
  incoming: ReceivedTurnPreview,
): FleetTurnPreviews {
  const held = fleet.get(keeperName) ?? []
  const kept = retainTurnPreview(held, undefined, incoming)
  return kept === held ? fleet : new Map(fleet).set(keeperName, kept)
}

/**
 * The Keeper with its turn as last seen: a preview received for this same
 * turn after the snapshot is laid over the snapshot's own. `received` is what
 * the fleet holds for this Keeper. Returns the same Keeper when nothing is
 * laid over it.
 */
export function withObservedTurn(
  keeper: KeeperRosterItem,
  received: readonly ReceivedTurnPreview[] | undefined,
): KeeperRosterItem {
  const turn = keeper.active_turn
  if (!turn || !received) return keeper
  const newer = previewForObservedTurn(received, turn, undefined)
  if (!newer) return keeper
  return {
    ...keeper,
    active_turn: { ...turn, preview: newer.preview, preview_observed_through: newer.preview.revision },
  }
}
