// How much of the keepers' metrics the server could read, for the cost view.

import type { KeeperCostMetric } from '../../api/dashboard'

/** Which keepers' metrics were not read in full. A keeper whose store could not
 *  be read has empty sums; a keeper with malformed or unreadable rows has sums
 *  that count only the readable ones ("at least"). A total built from either is
 *  a lower bound, never an exact figure. */
export interface KeeperCostReadCoverage {
  unreadKeepers: string[]
  partialKeepers: string[]
}

export function keeperCostReadCoverage(keepers: readonly KeeperCostMetric[]): KeeperCostReadCoverage {
  const unreadKeepers: string[] = []
  const partialKeepers: string[] = []
  for (const keeper of keepers) {
    switch (keeper.metrics_read.state) {
      case 'failed':
        unreadKeepers.push(keeper.keeper_name)
        break
      case 'read':
        if (keeper.metrics_read.malformed_rows > 0 || keeper.metrics_read.unread_turn_rows > 0) {
          partialKeepers.push(keeper.keeper_name)
        }
        break
    }
  }
  return { unreadKeepers, partialKeepers }
}
