import type { Keeper } from '../types'
import { isKeeperCrashed } from './keeper-predicates'

export const FLEET_KEEPER_FILTERS = {
  attention: { label: '주의 Keeper', matches: (keeper: Keeper) => keeper.needs_attention === true },
  failures: { label: '실패한 Keeper', matches: isKeeperCrashed },
} as const

export type FleetKeeperFilter = keyof typeof FLEET_KEEPER_FILTERS

export function fleetKeeperFilterFromRoute(value: string | undefined): FleetKeeperFilter | null {
  switch (value) {
    case 'attention':
    case 'failures': return value
    default: return null
  }
}
