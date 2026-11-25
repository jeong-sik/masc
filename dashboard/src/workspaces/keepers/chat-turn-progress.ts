import type { KeeperActiveTurn, KeeperActiveTurnPreview } from './types'

export interface ReceivedTurnPreview {
  readonly ownerKey: string
  readonly preview: KeeperActiveTurnPreview
  readonly receivedAt: number
  readonly live: boolean
}

export function retainTurnPreview(
  previous: readonly ReceivedTurnPreview[],
  activeOwner: string | null | undefined,
  incoming: ReceivedTurnPreview,
): readonly ReceivedTurnPreview[] {
  const prior = previous.find((sample) => sample.ownerKey === incoming.ownerKey)
  if (prior) {
    const before = prior.preview
    const after = incoming.preview
    if (before.revision !== null && (after.revision === null || after.revision <= before.revision)) return previous
    if (before.revision === null && after.revision === null && after.updated_at_unix <= before.updated_at_unix) {
      return previous
    }
  }
  // Keep the displayed owner's observation while a preview for the next turn
  // precedes its HTTP snapshot. Revisions are comparable only within one owner.
  const other = activeOwner && activeOwner !== incoming.ownerKey
    ? previous.find((sample) => sample.ownerKey === activeOwner)
    : previous.find((sample) => sample.ownerKey !== incoming.ownerKey)
  return other ? [incoming, other] : [incoming]
}

export function previewForObservedTurn(
  previews: readonly ReceivedTurnPreview[],
  activeTurn: KeeperActiveTurn | null,
  snapshotAt: number | undefined,
): ReceivedTurnPreview | undefined {
  if (activeTurn) {
    const through = activeTurn.preview_observed_through ?? activeTurn.preview?.revision ?? 0
    return previews.find((sample) => sample.ownerKey === activeTurn.owner_key
      && (sample.preview.revision ?? 0) > through)
  }
  return previews.find((sample) => snapshotAt === undefined || sample.receivedAt > snapshotAt)
}
