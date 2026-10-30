// How much of the keepers' metrics the server could read, for the cost view.

import type { KeeperCostMetric, KeeperMetricsRead } from '../../api/dashboard'

/** How completely the server read one keeper's metrics store.
 *  - `unread`: the store could not be read; the keeper's sums are empty.
 *  - `partial`: some rows were malformed or unreadable; the sums count only the
 *    rows that were read ("at least").
 *  - `complete`: every row was read. */
export type KeeperReadCompleteness = 'unread' | 'partial' | 'complete'

export function keeperReadCompleteness(read: KeeperMetricsRead): KeeperReadCompleteness {
  switch (read.state) {
    case 'failed':
      return 'unread'
    case 'read':
      return read.malformed_rows > 0 || read.unread_turn_rows > 0 ? 'partial' : 'complete'
  }
}

/** Which keepers' metrics were not read in full. A total built from either is a
 *  lower bound, never an exact figure. */
export interface KeeperCostReadCoverage {
  unreadKeepers: string[]
  partialKeepers: string[]
}

export function keeperCostReadCoverage(keepers: readonly KeeperCostMetric[]): KeeperCostReadCoverage {
  const unreadKeepers: string[] = []
  const partialKeepers: string[] = []
  for (const keeper of keepers) {
    switch (keeperReadCompleteness(keeper.metrics_read)) {
      case 'unread':
        unreadKeepers.push(keeper.keeper_name)
        break
      case 'partial':
        partialKeepers.push(keeper.keeper_name)
        break
      case 'complete':
        break
    }
  }
  return { unreadKeepers, partialKeepers }
}
