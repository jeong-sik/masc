/**
 * keeper-line-ownership-store — Preact signal adapter for RFC 0019.
 *
 * The accumulator in design-system/headless-core owns the line-range and
 * hue-index rules. This store only publishes immutable snapshots for dashboard
 * consumers and keeps the mock editor on the same contract future live events
 * will use.
 */

import { signal } from '@preact/signals'
import {
  createKeeperLineOwnershipAccumulator,
  type KeeperEdit,
  type LineOwnership,
} from '../../../design-system/headless-core/keeper-line-ownership'

export type { KeeperEdit, LineOwnership }

export interface KeeperLineOwnershipStore {
  readonly filePath: () => string
  readonly ownership: () => ReadonlyMap<number, LineOwnership>
  readonly eventsForLine: (line: number) => ReadonlyArray<KeeperEdit>
  readonly knownKeepers: () => ReadonlyArray<string>
  readonly ingest: (event: KeeperEdit) => boolean
  readonly reset: (filePath?: string) => void
  readonly subscribe: (listener: () => void) => () => void
  readonly dispose: () => void
}

export function createKeeperLineOwnershipStore(
  initialFilePath: string,
): KeeperLineOwnershipStore {
  const accumulator = createKeeperLineOwnershipAccumulator(initialFilePath)
  const ownershipSignal = signal<ReadonlyMap<number, LineOwnership>>(new Map())
  const keepersSignal = signal<ReadonlyArray<string>>([])

  const publish = (): void => {
    ownershipSignal.value = new Map(accumulator.ownership())
    keepersSignal.value = accumulator.knownKeepers()
  }

  const ingest = (event: KeeperEdit): boolean => {
    const accepted = accumulator.ingest(event)
    if (accepted) publish()
    return accepted
  }

  const reset = (filePath?: string): void => {
    accumulator.reset(filePath)
    publish()
  }

  const subscribe = (listener: () => void): (() => void) => {
    let sawInitialSnapshot = false
    const unsubscribe = ownershipSignal.subscribe(() => {
      if (!sawInitialSnapshot) {
        sawInitialSnapshot = true
        return
      }
      listener()
    })
    return unsubscribe
  }

  const dispose = (): void => {
    reset()
  }

  return {
    filePath: accumulator.filePath,
    ownership: () => ownershipSignal.value,
    eventsForLine: accumulator.eventsForLine,
    knownKeepers: () => keepersSignal.value,
    ingest,
    reset,
    subscribe,
    dispose,
  }
}
