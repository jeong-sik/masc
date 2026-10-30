// Keeper lookup utilities — canonical keeper resolution by name.

import { keepers } from '../store'
import type { Keeper } from '../types'
import { keeperIdentityKeys } from '../components/common/keeper-identity'

/** Find a keeper by name. Returns null when not found or name is empty. */
export function findKeeper(name?: string | null): Keeper | null {
  if (!name) return null
  const needle = name.trim().toLowerCase()
  if (!needle) return null
  return keepers.value.find(k =>
    keeperIdentityKeys(k.keeper_id, k.name).includes(needle),
  ) ?? null
}
